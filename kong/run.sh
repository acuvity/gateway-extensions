#!/bin/bash
set -e

echo "Building kong-pyblocker image..."
docker build --no-cache -t kong-pyblocker:3.14 -f Dockerfile.kong-python .

echo "Stopping existing kong container..."
docker rm -f kong 2>/dev/null || true

echo "Starting kong container..."
# docker run -d --name kong \
#   -p 8000:8000 -p 8443:8443 -p 8001:8001 \
#   -e KONG_DATABASE=off \
#   -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
#   -e KONG_DECLARATIVE_CONFIG=/kong/declarative/kong.yml \
#   -e KONG_PLUGINS=bundled,py-blocker \
#   -e KONG_PLUGINSERVER_NAMES=py-blocker \
#   -e "KONG_PLUGINSERVER_PY_BLOCKER_SOCKET=/usr/local/kong/py-blocker.socket" \
#   -e "KONG_PLUGINSERVER_PY_BLOCKER_START_CMD=/opt/kong-python/bin/python /plugins/plugin.py --socket-name py-blocker.socket" \
#   -e "KONG_PLUGINSERVER_PY_BLOCKER_QUERY_CMD=/opt/kong-python/bin/python /plugins/plugin.py --dump" \
#   -v /Users/kgupta/Desktop/gateway-extensions/kong/kong-setup/service-route.yaml:/kong/declarative/kong.yml:ro \
#   kong-pyblocker:3.14

docker run -d --name kong \
  -p 8000:8000 -p 8443:8443 -p 8001:8001 \
  -e KONG_DATABASE=off \
  -e KONG_ADMIN_LISTEN=0.0.0.0:8001 \
  -e KONG_DECLARATIVE_CONFIG=/kong/declarative/kong.yml \
  -e KONG_PLUGINS=bundled,acuvity-guard \
  -e KONG_LUA_SSL_TRUSTED_CERTIFICATE=/etc/kong/ca-chain-external.pem,system \
  -e KONG_LUA_SSL_VERIFY_DEPTH=4 \
  -v $(pwd)/kong-setup/service-route.yaml:/kong/declarative/kong.yml:ro \
  -v ~/Desktop/acuvity/backend/dev/data/certificates/ca-chain-external.pem:/etc/kong/ca-chain-external.pem:ro \
  kong-pyblocker:3.14

echo "Waiting for Kong to start..."
sleep 5

uv run main.py