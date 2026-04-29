local http = require("resty.http")
local cjson = require("cjson.safe")

local plugin = {
    PRIORITY = 1000,
    VERSION = "0.2.0",
}

-- -- Cache for CA cert content (read once from file)
-- local ca_cert_cache = {}

-- local function get_ca_cert(path)
--     if ca_cert_cache[path] then
--         return ca_cert_cache[path]
--     end
--     local f, err = io.open(path, "r")
--     if not f then
--         return nil, "failed to open CA cert file: " .. tostring(err)
--     end
--     local content = f:read("*a")
--     f:close()
--     ca_cert_cache[path] = content
--     return content
-- end

-- Helper: POST JSON to the police endpoint
local function police_request(conf, payload)
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)

    local police_url = conf.apex_url .. "/_acuvity/police"
    local body = cjson.encode(payload)

    local res, err = httpc:request_uri(police_url, {
        method = "POST",
        body = body,
        headers = {
            ["Authorization"] = "Bearer " .. (conf.acuvity_token or ""),
            ["Content-Type"] = "application/json",
        },
        ssl_verify = true,
    })

    return res, err
end

function plugin:access(conf)
    -- auth = kong.request.get_header("authorization") or ""
    -- if not auth:find("^Bearer ") then
    --     return kong.response.exit(401, { error = "missing Bearer token" })
    -- end

    -- local token = auth:gsub("^Bearer%s+", "")

    -- local ok, unverified = pcall(jwt.decode, token, { verify_signature = false })
    -- if not ok then
    --     return kong.response.exit(401, { error = "invalid token: " .. tostring(unverified) })
    -- end

    -- local opaque = unverified.opaque or {}
    -- local apex_url = opaque["apex-url"]
    -- if not apex_url then
    --     return kong.response.exit(500, { error = "apex-url missing from token" })
    -- end

    -- local identity = unverified.identity or {}
    -- local provider = conf.provider or "kong-proxy"
    -- for _, i in ipairs(identity) do
    --     if type(i) == "string" and i:find("^@apptoken:name=") then
    --         provider = i:match("^@apptoken:name=(.+)$")
    --     end
    -- end

    -- local body = kong.request.get_raw_body() or "{}"
    -- local police_payload = {
    --     messages = { body },
    --     anonymization = "VariableSize",
    --     provider = provider,
    --     type = "Input",
    --     tools = { ["anthropic/messages"] = { name = "anthropic/messages", category = "Server" } },
    --     user = { claims = identity, name = cjson.null },
    -- }

    local raw = kong.request.get_raw_body()
    if not raw or raw == "" then
        raw = "{}"
    end
    local body = raw

    local messages = {}
    local parsed = cjson.decode(body)
    if parsed and parsed.messages then
        for _, m in ipairs(parsed.messages) do
            if type(m.content) == "string" then
                messages[#messages + 1] = m.content
            end
        end
    end
    if #messages == 0 then
        messages = { body }
    end

    local provider = conf.provider or "kong-proxy"
    local police_payload = {
        messages = messages,
        anonymization = "VariableSize",
        provider = provider,
        type = "Input",
        tools = {
            ["anthropic/messages"] = { name = "anthropic/messages", category = "Server" },
        },
        user = {
            userClaims = {
                "provider=" .. provider,
                "@apptoken:name=kong-demo",
            },
            username = "kanav@acuvity.ai",
        },
    }

    local res, err = police_request(conf, police_payload)
    if not res then
        return kong.response.exit(403, { error = "policy check failed: " .. tostring(err) })
    end

    if res.status ~= 200 then
        return kong.response.exit(403, { error = "policy check HTTP " .. res.status .. ": " .. (res.body or "") })
    end

    local result = cjson.decode(res.body)
    if not result then
        return kong.response.exit(403, { error = conf.message or "Blocked by policy" })
    end

    if result.decision == "Deny" then
        local reasons = result.reasons
        local reason = (reasons and reasons[1]) or (conf.message or "Blocked by policy")
        return kong.response.exit(403, { error = reason })
    end

    -- Allow request to upstream
    local extractions = result.extractions
    if extractions and #extractions > 0 then
        local ext = extractions[1]
        local has_redaction = false
        local detections = ext.detections or {}
        for _, d in ipairs(detections) do
            if d.redacted then
                has_redaction = true
                break
            end
        end
        if has_redaction then
            local redacted_text = ext.data or ""
            local original = cjson.decode(body)
            if original and original.messages then
                -- Replace user message content with redacted version
                for _, msg in ipairs(original.messages) do
                    if msg.role == "user" and type(msg.content) == "string" then
                        msg.content = redacted_text
                    end
                end
                kong.service.request.set_raw_body(cjson.encode(original))
            end
        end
    end

    kong.service.request.clear_header("Accept-Encoding")
end

function plugin:response(conf)
    local raw = kong.service.response.get_raw_body()
    if not raw or raw == "" then
        return
    end
    local body = raw

    -- Detect which service based on the original request path
    local path = kong.request.get_path() or ""

    local parsed = cjson.decode(body) or {}

    local messages = {}
    local tool_name

    if path:find("/anthropic") then
        -- Anthropic response: {"content": [{"type": "text", "text": "..."}], ...}
        local content_blocks = parsed.content or {}
        for _, b in ipairs(content_blocks) do
            if b.type == "text" and b.text then
                messages[#messages + 1] = b.text
            end
        end
        tool_name = "anthropic/messages"
    elseif path:find("/exa") then
        -- Exa response: {"results": [{"title": "...", "url": "...", ...}]}
        local results = parsed.results or {}
        for _, r in ipairs(results) do
            messages[#messages + 1] = (r.title or "") .. " " .. (r.url or "") .. " " .. (r.text or "")
        end
        tool_name = "exa/search"
    else
        messages = { body }
        tool_name = "unknown"
    end

    if #messages == 0 then
        return
    end

    local provider = conf.provider or "scan/kong-proxy"
    local police_payload = {
        messages = messages,
        anonymization = "VariableSize",
        provider = provider,
        type = "Output",
        tools = {
            [tool_name] = { name = tool_name, category = "Server" },
        },
        user = {
            userClaims = {
                "provider=" .. provider,
                "@apptoken:name=kong-demo",
            },
            username = "kanav@acuvity.ai",
        },
    }

    local res, err = police_request(conf, police_payload)
    if not res then
        return kong.response.exit(403, { error = "output policy check failed: " .. tostring(err) })
    end

    if res.status ~= 200 then
        return kong.response.exit(403, { error = "output policy check HTTP " .. res.status .. ": " .. (res.body or "") })
    end

    local result = cjson.decode(res.body)
    if not result then
        return
    end

    if result.decision == "Deny" then
        local reasons = result.reasons
        local reason = (reasons and reasons[1]) or (conf.message or "Blocked by policy")
        return kong.response.exit(403, { error = reason })
    end
end

return plugin
