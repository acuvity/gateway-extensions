local http = require("resty.http")
local cjson = require("cjson.safe")

local plugin = {
    PRIORITY = 760,
    VERSION = "0.4.0",
}

-- ----------------------------------------------------------------- logging --

local function log_error(conf, msg)
    if conf.log_level == "error" or conf.log_level == "warn" or conf.log_level == "info" then
        kong.log.err("acuvity-guard: " .. msg)
    end
end

local function log_warn(conf, msg)
    if conf.log_level == "warn" or conf.log_level == "info" then
        kong.log.warn("acuvity-guard: " .. msg)
    end
end

local function log_info(conf, msg)
    if conf.log_level == "info" then
        kong.log.notice("acuvity-guard: " .. msg)
    end
end

-- ----------------------------------------------------------------- helpers --

local function truncate(s, n)
    if not s or s == "" then return "" end
    if #s <= n then return s end
    return s:sub(1, n) .. "..."
end

-- Pull joined text from a content-parts array and return (joined, first_idx,
-- first_key) so the caller can write a single redaction back to the exact
-- key+index it came from. Used on the request side where we want one
-- extraction per message even if the message has several text parts.
local function text_from_parts(parts)
    if type(parts) ~= "table" then return nil end
    local out, first_idx, first_key = {}, nil, nil
    for i, p in ipairs(parts) do
        if type(p) == "table" then
            local key
            if type(p.text) == "string" then
                key = "text"
            elseif type(p.input_text) == "string" then
                key = "input_text"
            elseif type(p.output_text) == "string" then
                key = "output_text"
            end
            if key then
                out[#out + 1] = p[key]
                if not first_idx then
                    first_idx, first_key = i, key
                end
            end
        elseif type(p) == "string" then
            out[#out + 1] = p
        end
    end
    if #out == 0 then return nil end
    return table.concat(out, "\n"), first_idx, first_key
end

-- Walk a content-parts array and return one entry per text-bearing block:
-- { text = "...", part_idx = i, text_key = "text"|"input_text"|"output_text" }.
-- Used on the response side where we want one extraction per block, matching
-- the per-block emission of the Acuvity OpenAI/Anthropic extractors.
local function text_blocks_from_parts(parts)
    if type(parts) ~= "table" then return nil end
    local blocks = {}
    for i, p in ipairs(parts) do
        if type(p) == "table" then
            local key
            if type(p.text) == "string" and p.text ~= "" then
                key = "text"
            elseif type(p.input_text) == "string" and p.input_text ~= "" then
                key = "input_text"
            elseif type(p.output_text) == "string" and p.output_text ~= "" then
                key = "output_text"
            end
            if key then
                blocks[#blocks + 1] = {
                    text = p[key],
                    part_idx = i,
                    text_key = key,
                }
            end
        end
    end
    if #blocks == 0 then return nil end
    return blocks
end

-- ------------------------------------------------------------- police call --

local function police_request(conf, payload)
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)

    local start = ngx.now()
    local res, err = httpc:request_uri(conf.apex_url .. "/_acuvity/police", {
        method = "POST",
        body = cjson.encode(payload),
        headers = {
            ["Authorization"] = "Bearer " .. (conf.acuvity_token or ""),
            ["Content-Type"] = "application/json",
        },
        ssl_verify = true,
    })
    local latency_ms = math.floor((ngx.now() - start) * 1000)

    return res, err, latency_ms
end

local function build_payload(conf, messages, scan_type)
    local provider = conf.provider or "kong-proxy"
    return {
        messages = messages,
        anonymization = "VariableSize",
        provider = provider,
        type = scan_type,
        user = {
            claims = {
                "provider=" .. provider,
                "@apptoken:name=" .. (conf.apptoken_name or ""),
            },
            userClaims = {
                "provider=" .. provider,
                "@apptoken:name=" .. (conf.apptoken_name or ""),
            },
            username = conf.username or "",
            name = conf.username or "",
        },
    }
end

-- -------------------------------------------------------------- extractors --

-- Roles whose text we send to the police on the request side. Mirrors what
-- the Acuvity OpenAI Chat Completions extractor pulls out of body.messages.
local REQUEST_ROLES = {
    user = true, system = true, developer = true,
    assistant = true, tool = true, ["function"] = true,
}

-- Iterate body.messages and emit one extraction per message that has text
-- content. Returns (extractions, locations) or nil if nothing extractable.
--
-- TODO: image/audio/file content parts on user messages, assistant refusal
-- and tool_calls/audio, top-level tool definitions (body.tools, body.functions,
-- body.tool_choice), MCP server descriptors. Mirrors the partial set the
-- Acuvity OpenAI extractor handles; expansion is additive.
local function extract_chat_completions_request(body)
    if type(body) ~= "table" or type(body.messages) ~= "table"
            or #body.messages == 0 then
        return nil
    end
    local extractions, locations = {}, {}
    for i, msg in ipairs(body.messages) do
        if type(msg) == "table" then
            local role = type(msg.role) == "string" and msg.role:lower() or nil
            if role and REQUEST_ROLES[role] then
                local c = msg.content
                local extracted, part_idx, text_key
                if type(c) == "string" then
                    if c ~= "" then extracted = c end
                elseif type(c) == "table" then
                    extracted, part_idx, text_key = text_from_parts(c)
                end
                if extracted and extracted ~= "" then
                    extractions[#extractions + 1] = extracted
                    if part_idx then
                        locations[#locations + 1] = {
                            kind = "parts",
                            msg_idx = i,
                            part_idx = part_idx,
                            text_key = text_key,
                        }
                    else
                        locations[#locations + 1] = {
                            kind = "string",
                            msg_idx = i,
                        }
                    end
                end
            end
        end
    end
    if #extractions == 0 then return nil end
    return extractions, locations
end

-- (a) OpenAI Chat Completions: walk every choice in body.choices, emit one
-- extraction per choice (string content) or per text block (parts content).
local function extract_response_chat_completions(body)
    if type(body) ~= "table" or type(body.choices) ~= "table"
            or #body.choices == 0 then
        return nil
    end
    local extractions, locations = {}, {}
    for i, choice in ipairs(body.choices) do
        if type(choice) == "table" and type(choice.message) == "table" then
            local c = choice.message.content
            if type(c) == "string" and c ~= "" then
                extractions[#extractions + 1] = c
                locations[#locations + 1] = {
                    kind = "openai_string",
                    choice_idx = i,
                }
            elseif type(c) == "table" then
                local blocks = text_blocks_from_parts(c)
                if blocks then
                    for _, b in ipairs(blocks) do
                        extractions[#extractions + 1] = b.text
                        locations[#locations + 1] = {
                            kind = "openai_parts",
                            choice_idx = i,
                            part_idx = b.part_idx,
                            text_key = b.text_key,
                        }
                    end
                end
            end
        end
    end
    if #extractions == 0 then return nil end
    return extractions, locations, "openai"
end

-- (b) OpenAI Responses API: body.output is an array of items; for every
-- item.type == "message" emit one extraction per text block in its content.
local function extract_response_responses_api(body)
    if type(body) ~= "table" or type(body.output) ~= "table" then
        return nil
    end
    local extractions, locations = {}, {}
    for i, item in ipairs(body.output) do
        if type(item) == "table" and item.type == "message"
                and type(item.content) == "table" then
            local blocks = text_blocks_from_parts(item.content)
            if blocks then
                for _, b in ipairs(blocks) do
                    extractions[#extractions + 1] = b.text
                    locations[#locations + 1] = {
                        kind = "responses",
                        item_idx = i,
                        part_idx = b.part_idx,
                        text_key = b.text_key,
                    }
                end
            end
        end
    end
    if #extractions == 0 then return nil end
    return extractions, locations, "openai_responses"
end

-- (c) Anthropic Messages: body.content is an array of blocks. Emit one
-- extraction per text block. Tighten the format gate to require type or role
-- markers so we don't match unrelated payloads with a top-level `content`.
local function extract_response_anthropic(body)
    if type(body) ~= "table" or type(body.content) ~= "table" then
        return nil
    end
    if body.type ~= "message" and body.role ~= "assistant" then
        return nil
    end
    local blocks = text_blocks_from_parts(body.content)
    if not blocks then return nil end
    local extractions, locations = {}, {}
    for _, b in ipairs(blocks) do
        extractions[#extractions + 1] = b.text
        locations[#locations + 1] = {
            kind = "anthropic",
            block_idx = b.part_idx,
            text_key = b.text_key,
        }
    end
    if #extractions == 0 then return nil end
    return extractions, locations, "anthropic"
end

-- -------------------------------------------------------------- redaction --

-- Apply per-message redactions returned by the police API in place. The
-- response's extractions array is assumed 1:1 with our locations array (same
-- order). Returns true if any redaction was applied so the caller knows
-- whether to re-encode the body.
local function apply_redactions(conf, body, locations, result)
    local exts = result.extractions or {}
    if #exts == 0 then return false end
    local applied = false
    for i, ext in ipairs(exts) do
        local was_redacted = false
        for _, d in ipairs(ext.detections or {}) do
            if d.redacted then was_redacted = true; break end
        end
        if was_redacted then
            local loc = locations[i]
            if not loc then
                log_warn(conf, string.format(
                    "redaction at extraction[%d] but no matching location", i))
            else
                local data = ext.data or ""
                local kind = loc.kind
                log_info(conf, string.format(
                    "applying redaction kind=%s msg=%s choice=%s item=%s block=%s part=%s",
                    kind,
                    tostring(loc.msg_idx), tostring(loc.choice_idx),
                    tostring(loc.item_idx), tostring(loc.block_idx),
                    tostring(loc.part_idx)))
                if kind == "string" then
                    body.messages[loc.msg_idx].content = data
                    applied = true
                elseif kind == "parts" then
                    body.messages[loc.msg_idx].content[loc.part_idx][loc.text_key] = data
                    applied = true
                elseif kind == "openai_string" then
                    body.choices[loc.choice_idx].message.content = data
                    applied = true
                elseif kind == "openai_parts" then
                    body.choices[loc.choice_idx].message.content[loc.part_idx][loc.text_key] = data
                    applied = true
                elseif kind == "responses" then
                    body.output[loc.item_idx].content[loc.part_idx][loc.text_key] = data
                    applied = true
                elseif kind == "anthropic" then
                    body.content[loc.block_idx][loc.text_key] = data
                    applied = true
                elseif kind == "raw" then
                    log_warn(conf, "redaction skipped: unknown payload shape")
                end
            end
        end
    end
    return applied
end

-- True if any extraction has a redacted detection. Used in the fallback path
-- where we can't apply the redaction (no in-place location available), to
-- log loudly that we passed through unredacted content.
local function any_redaction_requested(result)
    for _, ext in ipairs((result and result.extractions) or {}) do
        for _, d in ipairs(ext.detections or {}) do
            if d.redacted then return true end
        end
    end
    return false
end

-- ------------------------------------------------------------------ access --

function plugin:access(conf)
    local raw = kong.request.get_raw_body() or ""
    if raw == "" then
        log_error(conf, "empty request body")
        return kong.response.exit(400, { error = "empty request body" })
    end
    log_info(conf, "raw request body: " .. raw)

    -- Try Kong's parsed body first; fall back to manual JSON decode (Kong
    -- only parses bodies for certain content types).
    local body, body_err = kong.request.get_body()
    if type(body) ~= "table" then
        local decoded, decode_err = cjson.decode(raw)
        if type(decoded) == "table" then
            body = decoded
        else
            log_warn(conf, string.format(
                "request body is not valid JSON (get_body err=%s, decode err=%s)",
                tostring(body_err), tostring(decode_err)))
            body = nil
        end
    end

    local extractions, locations
    if body then
        extractions, locations = extract_chat_completions_request(body)
    end

    -- Permissive fallback: if the body shape isn't recognized (or wasn't
    -- valid JSON), scan the raw body as a single message rather than failing
    -- closed. fallback=true signals downstream that we cannot write a
    -- redaction back in place.
    local fallback = not extractions or #extractions == 0
    if fallback then
        log_warn(conf, "request shape not recognized; scanning raw body as single message")
        extractions = { raw }
        locations = { { kind = "raw" } }
    else
        log_info(conf, string.format(
            "extracted %d message(s) from request for input scan", #extractions))
    end

    local payload = build_payload(conf, extractions, "Input")
    log_info(conf, "acuvity input payload: " .. cjson.encode(payload))

    local res, err, latency_ms = police_request(conf, payload)
    log_info(conf, string.format(
        "input police_request: latency_ms=%d status=%s extractions=%d",
        latency_ms or -1,
        res and tostring(res.status) or "err",
        #extractions))

    if not res then
        log_error(conf, "policy check failed: " .. tostring(err))
        return kong.response.exit(403, { error = "policy check failed: " .. tostring(err) })
    end
    if res.status ~= 200 then
        log_error(conf, "policy check HTTP " .. res.status .. ": " .. (res.body or ""))
        return kong.response.exit(403, {
            error = "policy check HTTP " .. res.status .. ": " .. truncate(res.body or "", 1024),
        })
    end

    local result = cjson.decode(res.body or "")
    if not result then
        log_error(conf, "failed to decode acuvity response: " .. (res.body or ""))
        return kong.response.exit(500, {
            error = "Failed to decode acuvity response: " .. truncate(res.body or "", 1024),
        })
    end

    log_info(conf, "input scan decision: " .. tostring(result.decision))
    log_info(conf, "acuvity response: " .. (res.body or ""))

    if result.decision == "Deny" then
        local reason = (result.reasons and result.reasons[1]) or (conf.message or "Blocked by policy")
        log_warn(conf, "input blocked: " .. reason)
        return kong.response.exit(403, { error = reason })
    end
    if result.decision == "ForbiddenUser" then
        local reason = (result.reasons and result.reasons[1]) or (conf.message or "Forbidden user")
        log_warn(conf, "forbidden user: " .. reason)
        return kong.response.exit(403, { error = reason })
    end
    if result.decision == "Ask" then
        local reason = (result.reasons and result.reasons[1]) or (conf.message or "Blocked by policy")
        log_warn(conf, "input asked: " .. reason)
        return kong.response.exit(403, { error = reason })
    end

    if fallback then
        if any_redaction_requested(result) then
            log_warn(conf, "input redaction skipped: unknown request shape, original body forwarded")
        end
    else
        local applied = apply_redactions(conf, body, locations, result)
        if applied then
            log_warn(conf, "input redacted by acuvity")
            kong.service.request.set_raw_body(cjson.encode(body))
        end
    end

    kong.service.request.clear_header("Accept-Encoding")
end

-- ---------------------------------------------------------------- response --

function plugin:response(conf)
    local raw = kong.service.response.get_raw_body()
    if not raw or raw == "" then
        return
    end
    log_info(conf, "raw response body: " .. raw)

    local body, decode_err = cjson.decode(raw)
    if type(body) ~= "table" then
        log_warn(conf, string.format(
            "response body is not valid JSON (decode err=%s)", tostring(decode_err)))
        body = nil
    end

    -- Run all three response extractors and merge their results. Each one
    -- targets a distinct top-level key (choices / output / content), so they
    -- don't double-count, and a payload that mixes shapes (rare, but possible
    -- with intermediate wrappers) gets fully scanned instead of being
    -- partially extracted by whichever happens to match first.
    local extractions, locations, formats = {}, {}, {}
    if body then
        local function merge(exts, locs, fmt)
            if not exts then return end
            for i = 1, #exts do
                extractions[#extractions + 1] = exts[i]
                locations[#locations + 1] = locs[i]
            end
            formats[#formats + 1] = fmt
        end
        merge(extract_response_chat_completions(body))
        merge(extract_response_responses_api(body))
        merge(extract_response_anthropic(body))
    end

    local fallback = #extractions == 0
    if fallback then
        log_warn(conf, "response shape not recognized; scanning raw body as single message")
        extractions = { raw }
        locations = { { kind = "raw" } }
        formats = { "unknown" }
    else
        log_info(conf, string.format(
            "detected response format=%s extracted %d message(s) for output scan",
            table.concat(formats, "+"), #extractions))
    end

    local payload = build_payload(conf, extractions, "Output")
    log_info(conf, "acuvity output payload: " .. cjson.encode(payload))

    local res, err, latency_ms = police_request(conf, payload)
    log_info(conf, string.format(
        "output police_request: latency_ms=%d status=%s extractions=%d",
        latency_ms or -1,
        res and tostring(res.status) or "err",
        #extractions))

    if not res then
        log_error(conf, "output policy check failed: " .. tostring(err))
        return kong.response.exit(403, { error = "output policy check failed: " .. tostring(err) })
    end
    if res.status ~= 200 then
        log_error(conf, "output policy check HTTP " .. res.status .. ": " .. (res.body or ""))
        return kong.response.exit(403, {
            error = "output policy check HTTP " .. res.status .. ": " .. truncate(res.body or "", 1024),
        })
    end

    local result = cjson.decode(res.body or "")
    if not result then
        log_error(conf, "failed to decode acuvity response: " .. (res.body or ""))
        return kong.response.exit(500, {
            error = "failed to decode acuvity response: " .. truncate(res.body or "", 1024),
        })
    end

    log_info(conf, "output scan decision: " .. tostring(result.decision))
    log_info(conf, "acuvity response: " .. (res.body or ""))

    if result.decision == "Deny" then
        local reason = (result.reasons and result.reasons[1]) or (conf.message or "Blocked by policy")
        log_warn(conf, "output blocked: " .. reason)
        return kong.response.exit(403, { error = reason })
    end
    if result.decision == "ForbiddenUser" then
        local reason = (result.reasons and result.reasons[1]) or (conf.message or "Forbidden user")
        log_warn(conf, "forbidden user: " .. reason)
        return kong.response.exit(403, { error = reason })
    end
    if result.decision == "Ask" then
        local reason = (result.reasons and result.reasons[1]) or (conf.message or "Blocked by policy")
        log_warn(conf, "output asked: " .. reason)
        return kong.response.exit(403, { error = reason })
    end

    if fallback then
        if any_redaction_requested(result) then
            log_warn(conf, "output redaction skipped: unknown response shape, original body forwarded")
        end
    else
        local applied = apply_redactions(conf, body, locations, result)
        if applied then
            log_warn(conf, "output redacted by acuvity")
            local new_body = cjson.encode(body)
            kong.response.set_raw_body(new_body)
            kong.response.set_header("Content-Length", tostring(#new_body))
        end
    end
end

return plugin
