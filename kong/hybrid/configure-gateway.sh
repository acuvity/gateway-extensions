#!/bin/bash
set -e

# === Konnect Hybrid Mode ===
# Step 1: Upload schema to control plane
# Step 2: Mount plugin files on your data plane (see below)
# Step 3: Enable plugin on a service

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PLUGIN_DIR="$SCRIPT_DIR/plugins/acuvity-guard"
PLUGIN_NAME="acuvity-guard"

: "${KONNECT_TOKEN:?Export KONNECT_TOKEN with your Konnect PAT}"
: "${CONTROL_PLANE_ID:?Export CONTROL_PLANE_ID with your Konnect control plane ID}"
: "${SERVICE_ID:?Export SERVICE_ID with your Konnect service ID}"
: "${APEX_URL:?Export APEX_URL (e.g. https://xxx.acuvity.ai)}"
: "${ACUVITY_TOKEN:?Export ACUVITY_TOKEN with your Acuvity app token}"
: "${APPTOKEN_NAME:?Export APPTOKEN_NAME with your Acuvity app token name}"
: "${ACUVITY_USERNAME:?Export ACUVITY_USERNAME with your Acuvity username}"

KONNECT_API="https://us.api.konghq.com/v2"

# Step 1: Upload schema to control plane
echo "Uploading plugin schema..."
curl -X PUT \
  "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/plugin-schemas/$PLUGIN_NAME" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"lua_schema\": $(jq -Rs '.' "$PLUGIN_DIR/schema.lua")}"

echo ""

# Step 2: Mount plugin files on your data plane
echo "Deploy plugin files to your data plane:"
echo ""
echo "  Docker (volume mount):"
echo "    -v $PLUGIN_DIR:/usr/local/share/lua/5.1/kong/plugins/$PLUGIN_NAME:ro"
echo "    -e KONG_PLUGINS=bundled,$PLUGIN_NAME"
echo ""


# Step 3: Enable plugin on service
echo "Enabling plugin on service..."
curl -X POST \
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
  }'

echo ""
echo "=== Done ==="
echo ""

