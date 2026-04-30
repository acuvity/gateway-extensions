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

# 2. Upload custom plugin (upsert by name)
echo "Uploading custom plugin '$PLUGIN_NAME'..."
HTTP_CODE=$(curl -s -o /tmp/plugin_response.json -w "%{http_code}" -X PUT \
  "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/custom-plugins/$PLUGIN_NAME" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  -d "$(jq -n \
    --arg handler "$(cat "$SCRIPT_DIR/plugins/$PLUGIN_NAME/handler.lua")" \
    --arg schema "$(cat "$SCRIPT_DIR/plugins/$PLUGIN_NAME/schema.lua")" \
    --arg name "$PLUGIN_NAME" \
    '{handler:$handler, name:$name, schema:$schema}')")
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "ERROR: Failed to upload plugin (HTTP $HTTP_CODE): $(cat /tmp/plugin_response.json)"
  exit 1
fi
echo "Plugin uploaded."

# 4. Sync services, routes, and plugin config (scoped by tag to avoid deleting other resources)
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

# Fallback: derive from control plane endpoint
if [ -z "$PROXY_URL" ]; then
  CP_HOST=$(echo "$CP_INFO" | jq -r '.config.control_plane_endpoint // empty' | sed 's|^https://||')
  if [ -n "$CP_HOST" ]; then
    GW_ID=$(echo "$CP_HOST" | cut -d. -f1)
    PROXY_URL="https://${GW_ID}.gateways.konggateway.com"
  fi
fi

echo "=== Done ==="
echo "Control Plane ID: $CONTROL_PLANE_ID"

# Print service IDs
SERVICES=$(curl -s "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/services" \
  -H "Authorization: Bearer $KONNECT_TOKEN")
echo "Service IDs:"
echo "$SERVICES" | jq -r '.data[] | "  " + .name + ": " + .id'

if [ -n "$PROXY_URL" ]; then
  echo "Proxy URL: $PROXY_URL"
  echo ""
  echo "Test with:"
  echo "  KONG_PROXY_URL=$PROXY_URL uv run demo/agent.py"
else
  echo "Proxy URL: (not yet available — check Konnect UI for provisioning status)"
fi