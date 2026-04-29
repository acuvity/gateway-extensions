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
                    { message = { type = "string", default = "Blocked by policy" } },
                    { provider = { type = "string", default = "kong-proxy" } },
                    { timeout_ms = { type = "number", default = 3000 } },
                    { apex_url = { type = "string", required = true } },
                    { acuvity_token = { type = "string", required = true } },
                    -- { ca_cert_path = { type = "string", default = "/etc/kong/ca-chain-external.pem" } },
                },
            },
        },
    },
}
