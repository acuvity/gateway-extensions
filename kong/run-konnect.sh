#!/bin/bash
set -e

# === Dedicated Cloud Gateways on Konnect ===
# No Docker, no Kubernetes, no Helm. Just API calls.

: "${KONNECT_TOKEN:?Export KONNECT_TOKEN with your Konnect PAT}"

KONNECT_API="https://us.api.konghq.com/v2"
CP_NAME="acuvity-gateway"

# 1. Create a Gateway control plane with Cloud Gateway enabled
echo "Creating Dedicated Cloud Gateway control plane..."
CP_RESPONSE=$(curl -s -X POST "$KONNECT_API/control-planes" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  -H "Content-Type: application/json" \
  --json "{
    \"name\": \"$CP_NAME\",
    \"cluster_type\": \"CLUSTER_TYPE_CONTROL_PLANE\"
  }")

echo "$CP_RESPONSE" | jq .

CONTROL_PLANE_ID=$(echo "$CP_RESPONSE" | jq -r '.id // empty')
if [ -z "$CONTROL_PLANE_ID" ]; then
  echo "Failed to create control plane."
  exit 1
fi
echo "Control Plane ID: $CONTROL_PLANE_ID"

# 2. Upload the plugin schema
echo ""
echo "Registering plugin schema..."
SCHEMA_RESPONSE=$(curl -s -X POST \
  "$KONNECT_API/control-planes/$CONTROL_PLANE_ID/core-entities/plugin-schemas" \
  -H "Content-Type: application/json" \
  -H "Authorization: Bearer $KONNECT_TOKEN" \
  --json "{\"lua_schema\": $(jq -Rs . './plugins/acuvity-guard/schema.lua')}")

echo "$SCHEMA_RESPONSE" | jq .

# 3. Sync services, routes, and plugin config via decK
echo ""
echo "Syncing services, routes, and plugins..."
deck gateway sync kong-setup/service-route.yaml \
  --konnect-token "$KONNECT_TOKEN" \
  --konnect-control-plane-name "$CP_NAME"

# 4. Print results
echo ""
echo "=== Done ==="
echo "Control Plane ID: $CONTROL_PLANE_ID"
echo ""
echo "Next steps:"
echo "  1. Go to https://cloud.konghq.com/gateway-manager"
echo "  2. Select '$CP_NAME'"
echo "  3. Upload the custom plugin files (handler.lua + schema.lua) under Custom Plugins"
echo "  4. Your proxy URL will be shown under 'Data Plane Nodes' once provisioned"
echo ""
echo "Users can then send requests to:"
echo "  https://<proxy-url>/anthropic/v1/messages"
