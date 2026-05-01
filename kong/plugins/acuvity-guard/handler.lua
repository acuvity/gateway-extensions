local http = require("resty.http")
local cjson = require("cjson.safe")

local plugin = {
    PRIORITY = 760,
    VERSION = "0.3.0",
}

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

function plugin:access(conf)
    local raw = kong.request.get_raw_body()
    if not raw or raw == "" then
        log_error(conf, "empty request body")
        return kong.response.exit(400, { error = "empty request body" })
    end
    log_info(conf, "raw request body: " .. raw)

    local body = cjson.decode(raw)
    if not body or type(body.messages) ~= "table" then
        log_error(conf, "request is not OpenAI chat completions format: " .. raw)
        return kong.response.exit(400, { error = "request is not OpenAI chat completions format" })
    end

    local prompt
    for _, msg in ipairs(body.messages) do
        log_info(conf, "message role=" .. tostring(msg.role) .. " content_type=" .. type(msg.content))
        if msg.role == "user" and type(msg.content) == "string" then
            prompt = msg.content
        end
    end

    if not prompt then
        log_error(conf, "no user message found in request body: " .. raw)
        return kong.response.exit(400, { error = "no user message found in request: " .. raw })
    end
    log_info(conf, "extracted prompt: " .. prompt)

    local payload = build_payload(conf, { prompt }, "Input")
    log_info(conf, "acuvity request payload: " .. cjson.encode(payload))

    local res, err = police_request(conf, payload)
    if not res then
        log_error(conf, "policy check failed: " .. tostring(err))
        return kong.response.exit(403, { error = "policy check failed: " .. tostring(err) })
    end
    if res.status ~= 200 then
        log_error(conf, "policy check HTTP " .. res.status .. ": " .. (res.body or ""))
        return kong.response.exit(403, { error = "policy check HTTP " .. res.status .. ": " .. (res.body or "") })
    end

    local result = cjson.decode(res.body)
    if not result then
        log_error(conf, "failed to decode acuvity response" .. res.body)
        return kong.response.exit(500, { error = "Failed to decode acuvity response" .. res.body })
    end

    log_info(conf, "input scan decision: " .. tostring(result.decision))
    log_info(conf, "acuvity response: " .. res.body)

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
        log_warn(conf, "output blocked " .. reason)
        return kong.response.exit(403, { error = reason })
    end

    local redacted = get_redacted_data(result)
    if redacted then
        log_warn(conf, "input redacted by acuvity")
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
    log_info(conf, "raw response body: " .. raw)

    local body = cjson.decode(raw)
    if not body then
        log_error(conf, "response is not valid JSON: " .. raw:sub(1, 200))
        return kong.response.exit(502, { error = "upstream response is not valid JSON: " .. raw:sub(1, 200) })
    end

    local completion
    local format

    if body.choices and type(body.choices) == "table" and body.choices[1] then
    local msg = body.choices[1].message
        if msg and type(msg.content) == "string" then
            completion = msg.content
            format = "openai"
            log_info(conf, "detected response format: " .. tostring(format))
        end
    end

    if not completion and body.content and type(body.content) == "table" then
        for _, block in ipairs(body.content) do
            if block.type == "text" and type(block.text) == "string" then
                completion = block.text
                format = "anthropic"
                log_info(conf, "detected response format: " .. tostring(format))
                break
            end
        end
    end

    if not completion then
        log_error(conf, "upstream response missing completion text")
        return kong.response.exit(502, { error = "upstream response missing completion text" })
    end
    log_info(conf, "detected response format: " .. tostring(format))

    local res, err = police_request(conf, build_payload(conf, { completion }, "Output"))
    if not res then
        log_error(conf, "output policy check failed: " .. tostring(err))
        return kong.response.exit(403, { error = "output policy check failed: " .. tostring(err) })
    end
    if res.status ~= 200 then
        log_error(conf, "output policy check HTTP " .. res.status .. ": " .. (res.body or ""))
        return kong.response.exit(403, { error = "output policy check HTTP " .. res.status .. ": " .. (res.body or "") })
    end

    local result = cjson.decode(res.body)
    if not result then
        log_error(conf, "failed to decode acuvity response: " .. res.body)
        return kong.response.exit(500, { error = "failed to decode acuvity response: " .. res.body })
    end

    log_info(conf, "output scan decision: " .. tostring(result.decision))
    log_info(conf, "acuvity response: " .. res.body)

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
        log_warn(conf, "output blocked " .. reason)
        return kong.response.exit(403, { error = reason })
    end

    local redacted = get_redacted_data(result)
    if redacted then
        log_warn(conf, "output redacted by acuvity")
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
