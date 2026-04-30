# Kong AI Gateway with Acuvity Guard

A custom Lua plugin (`acuvity-guard`) for Kong AI Gateway that enforces Acuvity policy checks on both request and response phases.


## Prerequisites

| Tool | Purpose | Install |
|------|---------|---------|
| **decK CLI** | Kong declarative config sync | [docs.konghq.com/deck](https://docs.konghq.com/deck/latest/installation/) |
| **jq** | JSON processing in shell scripts | `brew install jq` |
| **uv** | Python package manager (demo only) | [docs.astral.sh/uv](https://docs.astral.sh/uv/getting-started/installation/) |

## Environment Variables

```bash
export KONNECT_TOKEN=        # Konnect Personal Access Token
export CP_NAME=              # Control plane name (e.g. "my-ai-gateway")
export APEX_URL=             # Acuvity Apex endpoint (e.g. https://xxx.acuvity.dev)
export ACUVITY_TOKEN=        # Acuvity app token
export ANTHROPIC_API_KEY=    # Anthropic API key
```

## Setup: Dedicated Cloud Gateway

Fully managed by Kong — no Docker, no certs, no local proxy process.

### Step 1 — Create a Control Plane

In the [Konnect UI](https://cloud.konghq.com/gateway-manager/), create a **Dedicated Cloud Gateway** control plane with **Public** access. Copy the control plane name.

### Step 2 — Deploy (skip this step if you already have control plane, services, route configured)

```bash
export CP_NAME="your-control-plane-name"
./cloud/deploy-cloud.sh
```

The script will:
1. Look up your control plane ID
2. Upload the `acuvity-guard` custom plugin (Lua source)
3. Sync services, routes, and plugin config via decK
4. Print the proxy URL

NOTE: If you already have a plugin, you will have to manually delete for the changes to take place.

### Step 3 — Add the AI Proxy Plugin

After the script runs, set the IDs it printed and attach the AI proxy:

```bash
export CONTROL_PLANE_ID=     # printed by deploy-cloud.sh
export SERVICE_ID=           # ID of the target service (e.g. anthropic-service)
```

```bash
curl -sS -X POST "https://us.api.konghq.com/v2/control-planes/${CONTROL_PLANE_ID}/core-entities/plugins" \
  -H "Authorization: Bearer ${KONNECT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "ai-proxy-advanced",
    "service": {"id": "'"$SERVICE_ID"'"},
    "config": {
      "targets": [
        {
          "route_type": "llm/v1/chat",
          "model": {
            "provider": "anthropic",
            "name": "claude-sonnet-4-5",
            "options": {
              "anthropic_version": "2023-06-01",
              "max_tokens": 1024
            }
          },
          "auth": {
            "header_name": "x-api-key",
            "header_value": "'"$ANTHROPIC_API_KEY"'"
          }
        }
      ]
    }
  }'
```
If you ran the script above the deploy the plugin, the plugin exists for all services.
Run the command below to add the plugin to a particular service.

```bash
curl -X POST "https://us.api.konghq.com/v2/control-planes/${CONTROL_PLANE_ID}/core-entities/plugins" \
  -H "Authorization: Bearer ${KONNECT_TOKEN}" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "acuvity-guard",
    "service": {"id": "'"$SERVICE_ID"'"},
    "config": {
      "message": "Blocked by policy",
      "timeout_ms": 60000,
      "apex_url": "'"$APEX_URL"'",
      "acuvity_token": "'"$ACUVITY_TOKEN"'"
    }
  }'
```

## Routes

The `service-route.yaml` creates three upstream routes:

| Path | Upstream |
|------|----------|
| `/anthropic` | `https://api.anthropic.com` |
| `/openai` | `https://api.openai.com` |

All routes share the `acuvity-guard` plugin for policy enforcement.

## Testing

Replace `PROXY_URL` with the value printed by `deploy-cloud.sh`.

```bash
export PROXY_URL=https://<your-id>.gateways.konggateway.com
```

```bash
curl -sS -X POST "${PROXY_URL}/anthropic" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Hello Claude"}]}'
```
