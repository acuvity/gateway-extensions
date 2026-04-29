# Kong Gateway + Acuvity Guard Plugin

A custom Lua plugin (`acuvity-guard`) for Kong Gateway that enforces Acuvity policy checks on both request and response phases. Supports proxying to Anthropic and Exa APIs with input/output scanning and redaction.

## Project Structure

```
kong/
├── plugins/acuvity-guard/
│   ├── handler.lua          # Lua plugin — calls Acuvity /police on input & output
│   └── schema.lua           # Plugin config schema (apex_url, acuvity_token, etc.)
├── cloud/
│   └── run-cloud.sh         # Deploy to Konnect Dedicated Cloud Gateway
├── local/
│   └── run-konnect.sh       # Deploy to local Docker data plane via Konnect
├── demo/
│   └── agent.py             # LangGraph agent with Exa search tool
├── service-route.yaml       # Declarative Kong config: services, routes, plugins
└── pyproject.toml
```

## Prerequisites

- **uv** – Python package manager ([install](https://docs.astral.sh/uv/getting-started/installation/))
- **Konnect account** – with a Personal Access Token
- **Acuvity Apex** – cloud instance (e.g. `https://xxx.acuvity.dev`)
- **decK CLI** – Kong declarative config tool ([install](https://docs.konghq.com/deck/latest/installation/))

## Setup

```bash
cd kong/
uv sync
```

Set environment variables:

```bash
export KONNECT_TOKEN="kpat_..."            # Konnect Personal Access Token
export APEX_URL="https://xxx.acuvity.dev"  # Acuvity Apex endpoint
export ACUVITY_TOKEN="eyJ..."              # Acuvity app token
export ANTHROPIC_API_KEY="sk-ant-..."      # Anthropic API key
export EXA_API_KEY="..."                   # Exa API key
```

## Deploy

### Option A: Dedicated Cloud Gateway (recommended)

Fully managed by Kong — no Docker or certs required.

1. Create a Dedicated Cloud Gateway control plane in the [Konnect UI](https://cloud.konghq.com/gateway-manager/) (select "Public" access)
2. Set the control plane name:
   ```bash
   export CP_NAME="your-control-plane-name"
   ```
3. Run:
   ```bash
   ./cloud/run-cloud.sh
   ```

### Option B: Local Docker Data Plane

Runs a self-managed data plane on your machine.

1. Get mTLS cert/key from the Konnect dashboard and export:
   ```bash
   export KONG_CLUSTER_CERT="-----BEGIN CERTIFICATE-----..."
   export KONG_CLUSTER_CERT_KEY="-----BEGIN PRIVATE KEY-----..."
   ```
2. Run:
   ```bash
   ./local/run-konnect.sh
   ```

## Test

```bash
uv run demo/agent.py
```

For cloud deployments, set the proxy URL:

```bash
KONG_PROXY_URL=https://your-id.gateways.konggateway.com uv run demo/agent.py
```

## Updating

Re-run the deploy script after any changes to plugin code or config:

```bash
./cloud/run-cloud.sh    # cloud
./local/run-konnect.sh  # local
```
