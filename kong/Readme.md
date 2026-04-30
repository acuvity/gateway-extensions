# Kong AI Gateway with Acuvity Guard

A custom Lua plugin (`acuvity-guard`) for Kong AI Gateway that enforces Acuvity policy checks on LLM request prompts and responses.

## Coverage

| Phase | Supported | Notes |
|-------|:---------:|-------|
| Prompt | Yes | Access phase scans user messages before forwarding to LLM |
| Response | Yes | Response phase scans completions before returning to client |
| Streaming | No | Requires response buffering |

## Configuration

| Parameter | Required | Default | Description |
|-----------|:--------:|---------|-------------|
| `apex_url` | Yes | - | Acuvity Apex endpoint (e.g. `https://xxx.acuvity.ai`) |
| `acuvity_token` | Yes | - | Acuvity app token |
| `username` | Yes | - | Username sent to Acuvity in the user context |
| `apptoken_name` | Yes | - | App token name sent to Acuvity (e.g. `my-kong-token`) |
| `message` | No | `Blocked by policy` | Error message returned when request is blocked |
| `provider` | No | `kong-proxy` | Provider name sent to Acuvity |
| `timeout_ms` | No | `3000` | Acuvity API request timeout in milliseconds |
| `debug` | No | `false` | Enable debug logging |

## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| **jq** | JSON processing in shell scripts | `brew install jq` |
| **decK CLI** | Kong declarative config sync (cloud only) | [docs.konghq.com/deck](https://docs.konghq.com/deck/latest/installation/) |
| **uv** | Python package manager (demo only) | [docs.astral.sh/uv](https://docs.astral.sh/uv/getting-started/installation/) |

## How It Works

```
┌────────┐     ┌──────────────────────────────────────┐     ┌─────┐
│ Client │────►│  Kong + acuvity-guard plugin         │────►│ LLM │
└────────┘     │                                      │     └─────┘
               │  ACCESS PHASE:                       │
               │   • Extract user message             │
               │   • Scan via Acuvity API             │
               │   • Block (403) or redact + forward  │
               │                                      │
               │  RESPONSE PHASE:                     │
               │   • Extract completion text          │
               │   • Scan via Acuvity API             │
               │   • Block (403) or redact + return   │
               └──────────────────────────────────────┘
```

Requests must be in **OpenAI chat completions format** (`{"messages": [...]}`). 

---

## Setup: Dedicated Cloud Gateway

Fully managed by Kong — no Docker, no certs, no local proxy process. Assumes you have an existing Konnect Dedicated Cloud Gateway control plane with a service and route already configured.

### Configure the Gateway

```bash
export KONNECT_TOKEN=        # Konnect Personal Access Token
export CONTROL_PLANE_ID=     # Your control plane ID
export SERVICE_ID=           # ID of the AI Gateway service
export APEX_URL=             # Acuvity Apex endpoint
export ACUVITY_TOKEN=        # Acuvity app token

./cloud/deploy-cloud.sh
```

The script uploads the `acuvity-guard` Lua plugin to Konnect and attaches it to your service.


### Test

```bash
export PROXY_URL=https://<your-id>.gateways.konggateway.com

curl -sS -X POST "${PROXY_URL}/<your-route-path>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello Claude"}]}'
```

Test it with the Python agent

```bash
export KONG_AI_GATEWAY_URL=
export SSL_VERIFY=
export ANTHROPIC_API_KEY=

uv run demo/agent.py
```

---

## Setup: Hybrid Mode (Konnect CP + Self-Managed Data Plane)

Konnect manages the control plane; you run the data plane yourself via Docker or Kubernetes. The plugin schema is uploaded to Konnect and the Lua code is mounted into your data plane container.

### Step 1 — Upload schema and enable plugin

```bash
export KONNECT_TOKEN=        # Konnect Personal Access Token
export CONTROL_PLANE_ID=     # Your control plane ID
export SERVICE_ID=           # ID of the AI Gateway service
export APEX_URL=             # Acuvity Apex endpoint
export ACUVITY_TOKEN=        # Acuvity app token

./hybrid/configure-gateway.sh
```

### Step 2 — Run the data plane

Save your Konnect data plane certificate and key (generated in Konnect UI under **Data Planes → New Data Plane**):

```bash
export KONG_CLUSTER_CERT="$(cat /path/to/cert.pem)"
export KONG_CLUSTER_CERT_KEY="$(cat /path/to/key.pem)"
export PLUGIN_DIR=/path/to/kong/plugins/acuvity-guard
```

**Docker:**

```bash
docker run -d \
  -e "KONG_ROLE=data_plane" \
  -e "KONG_DATABASE=off" \
  -e "KONG_VITALS=off" \
  -e "KONG_CLUSTER_MTLS=pki" \
  -e "KONG_CLUSTER_CONTROL_PLANE=<cp-id>.us.cp.konghq.com:443" \
  -e "KONG_CLUSTER_SERVER_NAME=<cp-id>.us.cp.konghq.com" \
  -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=<cp-id>.us.tp.konghq.com:443" \
  -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=<cp-id>.us.tp.konghq.com" \
  -e "KONG_CLUSTER_CERT=$KONG_CLUSTER_CERT" \
  -e "KONG_CLUSTER_CERT_KEY=$KONG_CLUSTER_CERT_KEY" \
  -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" \
  -e "KONG_KONNECT_MODE=on" \
  -e "KONG_ROUTER_FLAVOR=expressions" \
  -e "KONG_PLUGINS=bundled,acuvity-guard" \
  -v "$PLUGIN_DIR:/usr/local/share/lua/5.1/kong/plugins/acuvity-guard:ro" \
  -p 8000:8000 \
  -p 8443:8443 \
  kong/kong-gateway:3.14
```

### Step 3 — Test

```bash
curl -sk -X POST "https://localhost:8443/<your-route-path>" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello Claude"}]}'
```

Test it with the Python agent

```bash
export KONG_AI_GATEWAY_URL=
export SSL_VERIFY=
export ANTHROPIC_API_KEY=

uv run demo/agent.py
```

---

## Demo Agent

A LangGraph agent that routes through Kong:

```bash
export KONG_AI_GATEWAY_URL=https://<proxy-url>/<route-path>
export ANTHROPIC_API_KEY=...
export SSL_VERIFY=false   # set to false for local hybrid deployment

uv run demo/agent.py
```

## Limitations

Current Limitations
- Supported LLM providers are OpenAI and Anthropic

- When creating the AI Gateway, make sure you use **llm/v1/chat** for the route type. 
