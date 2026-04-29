# Kong Gateway + Acuvity Guard Plugin

A custom Lua plugin (`acuvity-guard`) for Kong Gateway that enforces Acuvity policy checks on both request and response phases. Supports proxying to Anthropic and Exa APIs with input/output scanning and redaction.

## Prerequisites

- **Docker Desktop** – running and accessible
- **uv** – Python package manager ([install](https://docs.astral.sh/uv/getting-started/installation/))
- **Konnect account** – with a Personal Access Token (PAT)
- **Acuvity Apex** – cloud instance (e.g. `https://xxx.acuvity.dev`)
- **decK CLI** – Kong declarative config tool ([install](https://docs.konghq.com/deck/latest/installation/))

## Project Structure

| File | Description |
|---|---|
| `plugins/acuvity-guard/handler.lua` | Lua plugin — calls Acuvity `/police` on input & output, handles redaction |
| `plugins/acuvity-guard/schema.lua` | Plugin config schema (`apex_url`, `acuvity_token`, `timeout_ms`, etc.) |
| `service-route.yaml` | Declarative Kong config: services, routes, and plugin bindings |
| `Dockerfile.kong-python` | Builds Kong image with the Lua plugin baked in |
| `run-konnect.sh` | Creates/reuses Konnect control plane, syncs config, runs data plane |
| `demo/agent.py` | LangGraph agent with Exa search tool, routed through Kong |

## Setup & Deploy

### 1. Set environment variables

```bash
export KONNECT_TOKEN="kpat_..."                  # Konnect Personal Access Token
export APEX_URL="https://xxx.acuvity.dev"        # Acuvity Apex endpoint
export ACUVITY_TOKEN="eyJ..."                    # Acuvity app token
export ANTHROPIC_API_KEY="sk-ant-..."            # Anthropic API key
export EXA_API_KEY="..."                         # Exa API key (for agent)

# Data plane mTLS cert/key (from Konnect dashboard)
export KONG_CLUSTER_CERT="-----BEGIN CERTIFICATE-----
...
-----END CERTIFICATE-----"
export KONG_CLUSTER_CERT_KEY="-----BEGIN PRIVATE KEY-----
...
-----END PRIVATE KEY-----"
```

### 2. Install Python dependencies

```bash
cd kong/
uv sync
```

### 3. Deploy

```bash
./run-konnect.sh
```

This will:
1. Create or reuse a Konnect control plane (`acuvity-gateway`)
2. Register the plugin schema with Konnect
3. Sync services, routes, and plugin config via decK
4. Start a local Kong data plane container connected to the control plane

### 4. Test

```bash
uv run demo/agent.py
```

## Updating

- **Plugin code changes** — edit `handler.lua` or `schema.lua`, then reload:
  ```bash
  docker exec kong-konnect-dp kong reload
  ```
- **Config changes** — edit `service-route.yaml`, then re-run:
  ```bash
  ./run-konnect.sh
  ```
