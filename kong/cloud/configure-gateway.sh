#!/bin/bash
set -e

# === Konnect Dedicated Cloud Gateway ===
# Uploads the acuvity-guard plugin and enables it on an existing AI Gateway service.
# Requires an existing control plane with ai-proxy or ai-proxy-advanced already configured.

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_NAME="acuvity-guard"

: "${KONNECT_TOKEN:?Export KONNECT_TOKEN with your Konnect PAT}"
: "${CONTROL_PLANE_ID:?Export CONTROL_PLANE_ID with your Konnect control plane ID}"
: "${SERVICE_ID:?Export SERVICE_ID with your AI Gateway service ID}"
: "${APEX_URL:?Export APEX_URL (e.g. https://xxx.acuvity.ai)}"
: "${ACUVITY_TOKEN:?Export ACUVITY_TOKEN with your Acuvity app token}"
: "${APPTOKEN_NAME:?Export APPTOKEN_NAME with your Acuvity app token name}"
: "${ACUVITY_USERNAME:?Export ACUVITY_USERNAME with your Acuvity username}"


KONNECT_API="https://us.api.konghq.com/v2"

# Step 1: Upload full plugin (handler + schema) to Konnect
echo "Uploading plugin '$PLUGIN_NAME'..."
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

# Step 2: Enable plugin on the AI Gateway service
echo "Enabling plugin on service '$SERVICE_ID'..."
HTTP_CODE=$(curl -s -o /tmp/enable_response.json -w "%{http_code}" -X POST \
  "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/plugins" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "'"$PLUGIN_NAME"'",
    "service": {"id": "'"$SERVICE_ID"'"},
    "config": {
      "apex_url": "'"$APEX_URL"'",
      "acuvity_token": "'"$ACUVITY_TOKEN"'",
      "apptoken_name": "'"$APPTOKEN_NAME"'",
      "username": "'"$ACUVITY_USERNAME"'"
    }
  }')
if [ "$HTTP_CODE" != "200" ] && [ "$HTTP_CODE" != "201" ]; then
  echo "ERROR: Failed to enable plugin (HTTP $HTTP_CODE): $(cat /tmp/enable_response.json)"
  exit 1
fi
echo "Plugin enabled."

echo ""
echo "=== Done ==="
echo "acuvity-guard is now scanning AI traffic on service $SERVICE_ID"
