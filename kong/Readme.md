# Kong Gateway + Acuvity Policy Plugin

A Kong Gateway setup with a custom Python plugin (`py-blocker`) that enforces Acuvity policy checks on both request and response phases. Supports proxying to Anthropic and Exa APIs.

## Prerequisites

- **Docker Desktop** – running and accessible
- **uv** – Python package manager ([install](https://docs.astral.sh/uv/getting-started/installation/))
- **Acuvity Apex** – running locally on port `1443`
- **`ANTHROPIC_API_KEY`** – set in your environment
- **`EXA_API_KEY`** – set in your environment (for the agent script)

## Project Structure

| File | Description |
|---|---|
| [Dockerfile.kong-python](cci:7://file:///Users/kgupta/Desktop/gateway-extensions/kong/Dockerfile.kong-python:0:0-0:0) | Builds Kong image with Python + plugin dependencies |
| [plugin.py](cci:7://file:///Users/kgupta/Desktop/gateway-extensions/kong/plugin.py:0:0-0:0) | `py-blocker` Kong plugin – calls Acuvity `/police` on input & output |
| [kong-setup/service-route.yaml](cci:7://file:///Users/kgupta/Desktop/gateway-extensions/kong/kong-setup/service-route.yaml:0:0-0:0) | Declarative Kong config: services, routes, and plugin bindings |
| [run.sh](cci:7://file:///Users/kgupta/Desktop/gateway-extensions/kong/run.sh:0:0-0:0) | Build image, start Kong container, and run test client |
| [main.py](cci:7://file:///Users/kgupta/Desktop/gateway-extensions/kong/main.py:0:0-0:0) | Simple Anthropic API test client routed through Kong |
| [agent.py](cci:7://file:///Users/kgupta/Desktop/gateway-extensions/kong/agent.py:0:0-0:0) | LangGraph agent with Exa search tool, routed through Kong |

## Setup & Deploy

### 1. Configure

Edit [kong-setup/service-route.yaml](cci:7://file:///Users/kgupta/Desktop/gateway-extensions/kong/kong-setup/service-route.yaml:0:0-0:0) to set your `acuvity_token` and `apex_url` in the plugin config blocks.

### 2. Set environment variables

```bash
export ANTHROPIC_API_KEY="sk-ant-..."
export EXA_API_KEY="..."           # only needed for agent.py
```

### 3. Install Python dependencies

```bash
cd kong/
uv sync
```

### 4. Run the setup

```bash
./run.sh
```

