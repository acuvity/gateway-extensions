local http = require("resty.http")
local cjson = require("cjson.safe")

local plugin = {
    PRIORITY = 760,
    VERSION = "0.3.0",
}

local function police_request(conf, payload)
    local httpc = http.new()
    httpc:set_timeout(conf.timeout_ms)

    local res, err = httpc:request_uri(conf.apex_url .. "/_acuvity/police", {
        method = "POST",
        body = cjson.encode(payload),
        headers = {
            ["Authorization"] = "Bearer " .. (conf.acuvity_token or ""),
            ["Content-Type"] = "application/json",
        },
        ssl_verify = true,
    })

    return res, err
end

local function get_redacted_data(result)
    local extractions = result.extractions
    if not extractions or #extractions == 0 then
        return nil
    end
    local ext = extractions[1]
    for _, d in ipairs(ext.detections or {}) do
        if d.redacted then
            return ext.data or ""
        end
    end
    return nil
end

local function build_payload(conf, messages, scan_type)
    local provider = conf.provider or "kong-proxy"
    local tool_name = "kong-acuvity-guard"
    return {
        messages = messages,
        anonymization = "VariableSize",
        provider = provider,
        type = scan_type,
        tools = {
            [tool_name] = { name = tool_name, category = "Server" },
        },
        user = {
            claims = {
                "provider=" .. provider,
                "@apptoken:name=" .. (conf.apptoken_name or ""),
            },
            name = conf.username or "",
        },
    }
end

function plugin:access(conf)
    local raw = kong.request.get_raw_body()
    if conf.debug then kong.log.debug("acuvity-guard: raw request body=" .. tostring(raw)) end
    if not raw or raw == "" then
        return kong.response.exit(400, { error = "empty request body" })
    end

    local body = cjson.decode(raw)
    if conf.debug then kong.log.debug("acuvity-guard: decoded request body=" .. cjson.encode(body)) end
    if not body or type(body.messages) ~= "table" then
        return kong.response.exit(400, { error = "request is not OpenAI chat completions format" })
    end

    local prompt
    for _, msg in ipairs(body.messages) do
        if conf.debug then kong.log.debug("acuvity-guard: message role=" .. tostring(msg.role) .. " content_type=" .. type(msg.content)) end
        if msg.role == "user" and type(msg.content) == "string" then
            prompt = msg.content
        end
    end

    if conf.debug then kong.log.debug("acuvity-guard: prompt=" .. tostring(prompt)) end
    if not prompt then
        return kong.response.exit(400, { error = "no user message found in request: " .. raw })
    end

    local res, err = police_request(conf, build_payload(conf, { prompt }, "Input"))
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
        local reason = (result.reasons and result.reasons[1]) or (conf.message or "Blocked by policy")
        return kong.response.exit(403, { error = reason })
    end

    local redacted = get_redacted_data(result)
    if redacted then
        for _, msg in ipairs(body.messages) do
            if msg.role == "user" and type(msg.content) == "string" then
                msg.content = redacted
            end
        end
        kong.service.request.set_raw_body(cjson.encode(body))
    end

    kong.service.request.clear_header("Accept-Encoding")
end

function plugin:response(conf)
    local raw = kong.service.response.get_raw_body()
    if not raw or raw == "" then
        return
    end

    local body = cjson.decode(raw)
    if not body then
        kong.log.err("acuvity-guard: response is not valid JSON: " .. raw:sub(1, 200))
        return kong.response.exit(502, { error = "upstream response is not valid JSON" })
    end

    local completion
    local format

    -- OpenAI chat completions format
    if body.choices and type(body.choices) == "table" and body.choices[1] then
    local msg = body.choices[1].message
        if msg and type(msg.content) == "string" then
            completion = msg.content
            format = "openai"
        end
    end

    -- Native Anthropic format fallback
    if not completion and body.content and type(body.content) == "table" then
        for _, block in ipairs(body.content) do
            if block.type == "text" and type(block.text) == "string" then
                completion = block.text
                format = "anthropic"
                break
            end
        end
    end

    if not completion then
        return kong.response.exit(502, { error = "upstream response missing completion text" })
    end

    local res, err = police_request(conf, build_payload(conf, { completion }, "Output"))
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
        local reason = (result.reasons and result.reasons[1]) or (conf.message or "Blocked by policy")
        return kong.response.exit(403, { error = reason })
    end

    local redacted = get_redacted_data(result)
    if redacted then
        if format == "openai" then
        body.choices[1].message.content = redacted
        elseif format == "anthropic" then
            for _, block in ipairs(body.content) do
                if block.type == "text" then
                    block.text = redacted
                    break
                end
            end
        end
        local new_body = cjson.encode(body)
        kong.response.set_raw_body(new_body)
        kong.response.set_header("Content-Length", tostring(#new_body))
    end
end

return plugin
