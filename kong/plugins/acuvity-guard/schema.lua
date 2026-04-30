local typedefs = require("kong.db.schema.typedefs")

return {
    name = "acuvity-guard",
    fields = {
        { consumer = typedefs.no_consumer },
        { protocols = typedefs.protocols_http },
        {
            config = {
                type = "record",
                fields = {
                    { message = { type = "string", default = "Blocked by Acuvity policy" } },
                    { provider = { type = "string", default = "kong-proxy" } },
                    { timeout_ms = { type = "number", default = 3000 } },
                    { apex_url = { type = "string", required = true } },
                    { acuvity_token = { type = "string", required = true } },
                    { username = { type = "string", required = true } },
                    { apptoken_name = { type = "string", required = true } },
                    { log_level = { type = "string", default = "error", one_of = { "error", "warn", "info" } } },
                },
            },
        },
    },
}
