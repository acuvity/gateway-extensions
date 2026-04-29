#!/bin/bash
set -e

# === Konnect Dedicated Cloud Gateway ===
# Uploads custom plugin and syncs config to a Dedicated Cloud Gateway control plane.
# The control plane and cloud gateway must be created first via the Konnect UI or API.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

: "${KONNECT_TOKEN:?Export KONNECT_TOKEN with your Konnect PAT}"
: "${APEX_URL:?Export APEX_URL (e.g. https://xxx.acuvity.dev)}"
: "${ACUVITY_TOKEN:?Export ACUVITY_TOKEN with your Acuvity app token}"
: "${CP_NAME:?Export CP_NAME with your cloud gateway control plane name (e.g. test-gateway)}"

KONNECT_API="https://us.api.konghq.com/v2"
PLUGIN_NAME="acuvity-guard"

# 1. Look up control plane
echo "Looking up control plane '$CP_NAME'..."
CP_LIST=$(curl -s "$KONNECT_API/control-planes" \
  -H "Authorization: Bearer $KONNECT_TOKEN")
CONTROL_PLANE_ID=$(echo "$CP_LIST" | jq -r --arg name "$CP_NAME" '.data[] | select(.name == $name) | .id' | head -1)

if [ -z "$CONTROL_PLANE_ID" ]; then
  echo "Control plane '$CP_NAME' not found."
  exit 1
fi

echo "Control Plane ID: $CONTROL_PLANE_ID"

# 2. Upload custom plugin
echo "Uploading custom plugin '$PLUGIN_NAME'..."
UPLOAD_RESPONSE=$(curl -s -X POST \
  "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/custom-plugins" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  -d "$(jq -n \
    --arg handler "$(cat "$SCRIPT_DIR/plugins/$PLUGIN_NAME/handler.lua")" \
    --arg schema "$(cat "$SCRIPT_DIR/plugins/$PLUGIN_NAME/schema.lua")" \
    --arg name "$PLUGIN_NAME" \
    '{handler:$handler, name:$name, schema:$schema}')")

# If plugin already exists, update it
if echo "$UPLOAD_RESPONSE" | jq -e '.status' > /dev/null 2>&1; then
  echo "Plugin already exists, updating..."
  curl -s -X PUT \
    "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/custom-plugins/$PLUGIN_NAME" \
    -H "Content-Type: application/json" \
    -H "Authorization: Bearer $KONNECT_TOKEN" \
    -d "$(jq -n \
      --arg handler "$(cat "$SCRIPT_DIR/plugins/$PLUGIN_NAME/handler.lua")" \
      --arg schema "$(cat "$SCRIPT_DIR/plugins/$PLUGIN_NAME/schema.lua")" \
      --arg name "$PLUGIN_NAME" \
      '{handler:$handler, name:$name, schema:$schema}')" > /dev/null
fi

# 3. Register plugin schema
echo "Registering plugin schema..."
curl -s -X PUT \
  "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/plugin-schemas/$PLUGIN_NAME" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  --json "{\"lua_schema\": $(jq -Rs . "$SCRIPT_DIR/plugins/$PLUGIN_NAME/schema.lua")}" > /dev/null

# 4. Sync services, routes, and plugin config
echo "Syncing services, routes, and plugins..."
envsubst '${APEX_URL} ${ACUVITY_TOKEN}' < "$SCRIPT_DIR/service-route.yaml" > /tmp/kong-service-route.yaml
deck gateway sync /tmp/kong-service-route.yaml \
  --konnect-token "$KONNECT_TOKEN" \
  --konnect-control-plane-name "$CP_NAME"

# 5. Get proxy URL
echo ""
CP_INFO=$(curl -s "$KONNECT_API/control-planes/$CONTROL_PLANE_ID" \
  -H "Authorization: Bearer $KONNECT_TOKEN")
PROXY_URL=$(echo "$CP_INFO" | jq -r '
  (.config.proxy_urls // [])[] |
  select(.host != null) |
  (.protocol // "https") + "://" + .host
' | head -1)

# Fallback: derive from control plane endpoint (replace .cp. with .gateways.konggateway)
if [ -z "$PROXY_URL" ]; then
  CP_HOST=$(echo "$CP_INFO" | jq -r '.config.control_plane_endpoint // empty' | sed 's|^https://||')
  if [ -n "$CP_HOST" ]; then
    GW_ID=$(echo "$CP_HOST" | cut -d. -f1)
    PROXY_URL="https://${GW_ID}.gateways.konggateway.com"
  fi
fi

echo "=== Done ==="
echo "Control Plane ID: $CONTROL_PLANE_ID"
if [ -n "$PROXY_URL" ]; then
  echo "Proxy URL: $PROXY_URL"
  echo ""
  echo "Test with:"
  echo "  KONG_PROXY_URL=$PROXY_URL uv run demo/agent.py"
else
  echo "Proxy URL: (not yet available — check Konnect UI for provisioning status)"
fi