#!/bin/bash
set -e

# === Konnect Control Plane + Docker Data Plane ===
# Creates/reuses a Konnect control plane, syncs config, and runs a local data plane.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

: "${KONNECT_TOKEN:?Export KONNECT_TOKEN with your Konnect PAT}"
: "${APEX_URL:?Export APEX_URL (e.g. https://xxx.acuvity.dev)}"
: "${ACUVITY_TOKEN:?Export ACUVITY_TOKEN with your Acuvity app token}"
: "${KONG_CLUSTER_CERT:?Export KONG_CLUSTER_CERT with your data plane certificate PEM}"
: "${KONG_CLUSTER_CERT_KEY:?Export KONG_CLUSTER_CERT_KEY with your data plane private key PEM}"

KONNECT_API="https://us.api.konghq.com/v2"
CP_NAME="acuvity-gateway"
CONTAINER_NAME="kong-konnect-dp"
PLUGIN_NAME="acuvity-guard"

# 1. Create control plane (or reuse existing)
echo "Creating Konnect control plane..."
CP_RESPONSE=$(curl -s -X POST "$KONNECT_API/control-planes" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  -H "Content-Type: application/json" \
  --json "{
    \"name\": \"$CP_NAME\",
    \"cluster_type\": \"CLUSTER_TYPE_CONTROL_PLANE\"
  }")

CONTROL_PLANE_ID=$(echo "$CP_RESPONSE" | jq -r '.id // empty')

if [ -z "$CONTROL_PLANE_ID" ]; then
  echo "Control plane may already exist, looking up..."
  CP_LIST=$(curl -s "$KONNECT_API/control-planes" \
    -H "Authorization: Bearer $KONNECT_TOKEN")
  CONTROL_PLANE_ID=$(echo "$CP_LIST" | jq -r --arg name "$CP_NAME" '.data[] | select(.name == $name) | .id' | head -1)
fi

if [ -z "$CONTROL_PLANE_ID" ]; then
  echo "Failed to create or find control plane."
  echo "$CP_RESPONSE" | jq .
  exit 1
fi

CP_INFO=$(curl -s "$KONNECT_API/control-planes/$CONTROL_PLANE_ID" \
  -H "Authorization: Bearer $KONNECT_TOKEN")
CP_ENDPOINT=$(echo "$CP_INFO" | jq -r '.config.control_plane_endpoint // empty' | sed 's|^https://||')
TP_ENDPOINT=$(echo "$CP_INFO" | jq -r '.config.telemetry_endpoint // empty' | sed 's|^https://||')

echo "Control Plane ID: $CONTROL_PLANE_ID"

# 2. Register plugin schema
echo "Registering plugin schema..."
curl -s -X PUT \
  "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/plugin-schemas/$PLUGIN_NAME" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  --json "{\"lua_schema\": $(jq -Rs . "$SCRIPT_DIR/plugins/$PLUGIN_NAME/schema.lua")}" > /dev/null

# 4. Sync services, routes, and plugin config (substitute env vars in template)
echo "Syncing services, routes, and plugins..."
envsubst '${APEX_URL} ${ACUVITY_TOKEN}' < "$SCRIPT_DIR/service-route.yaml" > /tmp/kong-service-route.yaml
deck gateway sync /tmp/kong-service-route.yaml \
  --konnect-token "$KONNECT_TOKEN" \
  --konnect-control-plane-name "$CP_NAME"

# 5. Stop existing container if running
docker rm -f "$CONTAINER_NAME" 2>/dev/null || true

# 6. Run data plane with plugin mounted
echo ""
echo "Starting Kong data plane..."
docker run -d --name "$CONTAINER_NAME" \
  -v "$SCRIPT_DIR/plugins/$PLUGIN_NAME:/usr/local/share/lua/5.1/kong/plugins/$PLUGIN_NAME:ro" \
  -e "KONG_ROLE=data_plane" \
  -e "KONG_DATABASE=off" \
  -e "KONG_VITALS=off" \
  -e "KONG_KONNECT_MODE=on" \
  -e "KONG_CLUSTER_MTLS=pki" \
  -e "KONG_CLUSTER_CONTROL_PLANE=$CP_ENDPOINT:443" \
  -e "KONG_CLUSTER_SERVER_NAME=$CP_ENDPOINT" \
  -e "KONG_CLUSTER_TELEMETRY_ENDPOINT=$TP_ENDPOINT:443" \
  -e "KONG_CLUSTER_TELEMETRY_SERVER_NAME=$TP_ENDPOINT" \
  -e "KONG_CLUSTER_CERT=$KONG_CLUSTER_CERT" \
  -e "KONG_CLUSTER_CERT_KEY=$KONG_CLUSTER_CERT_KEY" \
  -e "KONG_LUA_SSL_TRUSTED_CERTIFICATE=system" \
  -e "KONG_PLUGINS=bundled,$PLUGIN_NAME" \
  -p 8000:8000 \
  -p 8443:8443 \
  kong/kong-gateway:3.14

echo "Waiting for Kong to start..."
sleep 5

echo ""
echo "=== Done ==="
echo "Control Plane ID: $CONTROL_PLANE_ID"
echo "Local proxy: http://localhost:8000"
echo ""
echo "Test with:"
echo "  uv run demo/agent.py"
echo ""
echo "For a public URL, run:"
echo "  ngrok http 8000"
