local http = require("resty.http")
local cjson = require("cjson.safe")

local plugin = {
    PRIORITY = 760,
    VERSION = "0.3.0",
}

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

local function get_tool_name()
    return "kong-tool-placeholder"
end
-- Extract the last user message content from an OpenAI-format request body
local function extract_messages(body)
    local parsed = cjson.decode(body)
    if not parsed or type(parsed.messages) ~= "table" then
        return { body }
    end
    local prompt
    for _, msg in ipairs(parsed.messages) do
        if msg.role == "user" and type(msg.content) == "string" then
            prompt = msg.content
        end
    end
    return { prompt or body }
end

-- Helper: check extractions for redaction and return redacted data if any
local function get_redacted_data(result)
    local extractions = result.extractions
    if not extractions or #extractions == 0 then
        return nil
    end

    local ext = extractions[1]
    local detections = ext.detections or {}
    for _, d in ipairs(detections) do
        if d.redacted then
            return ext.data or ""
        end
    end

    return nil
end

function plugin:access(conf)
    local raw = kong.request.get_raw_body()
    if not raw or raw == "" then
        raw = "{}"
    end

    local messages = extract_messages(raw)
    local provider = conf.provider or "kong-proxy"
    local tool_name = get_tool_name()

    local police_payload = {
        messages = messages,
        anonymization = "VariableSize",
        provider = provider,
        type = "Input",
        tools = {
            [tool_name] = { name = tool_name, category = "Server" },
        },
        user = {
            userClaims = {
                "provider=" .. provider,
                "@apptoken:name=new-kong-test-token",
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

    -- Redaction on input: replace user message content with redacted version
    local redacted = get_redacted_data(result)
    if redacted then
        local original = cjson.decode(raw)
        if original and original.messages then
            for _, msg in ipairs(original.messages) do
                if msg.role == "user" and type(msg.content) == "string" then
                    msg.content = redacted
                end
            end
            kong.service.request.set_raw_body(cjson.encode(original))
        end
    end

    kong.service.request.clear_header("Accept-Encoding")
end

function plugin:response(conf)
    local raw = kong.service.response.get_raw_body()
    if not raw or raw == "" then
        return
    end

    -- Re-set the body and Content-Length to ensure consistency after buffering
    kong.response.set_raw_body(raw)
    kong.response.set_header("Content-Length", tostring(#raw))

    local original = cjson.decode(raw)
    if not original then
        return
    end

    local completion
    -- OpenAI-format response (Kong AI Gateway normalizes Anthropic → OpenAI)
    if original.choices and type(original.choices) == "table" and original.choices[1] then
        local msg = original.choices[1].message
        if msg and type(msg.content) == "string" then
            completion = msg.content
        end
    end
    -- Fallback: native Anthropic format
    if not completion and original.content and type(original.content) == "table" then
        for _, block in ipairs(original.content) do
            if block.type == "text" and type(block.text) == "string" then
                completion = block.text
                break
            end
        end
    end
    local messages = { completion or raw }

    local provider = conf.provider or "kong-proxy"
    local tool_name = get_tool_name()

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
                "@apptoken:name=new-kong-test-token",
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

    local redacted = get_redacted_data(result)
    if redacted and original then
        local rewrote = false
        if original.choices and original.choices[1] and original.choices[1].message then
            original.choices[1].message.content = redacted
            rewrote = true
        elseif original.content then
            for _, block in ipairs(original.content) do
                if block.type == "text" then
                    block.text = redacted
                    break
                end
            end
            rewrote = true
        end
        if rewrote then
            local new_body = cjson.encode(original)
            kong.response.set_raw_body(new_body)
            kong.response.set_header("Content-Length", tostring(#new_body))
        end
    end
end

return plugin
