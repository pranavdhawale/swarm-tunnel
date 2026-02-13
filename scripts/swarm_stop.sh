#!/bin/bash

# Configuration
NETWORK_NAME="public_edge_net"
# NPM Stack - Commented out for now, uncomment when needed
# STACK_NAME="npm_stack"
CRED_SECRET="cf_manager_creds"
TOKEN_SECRET="cloudflare_tunnel_token"
TUNNEL_SERVICE="public_edge_cloudflared"

echo "----------------------------------------------------------------"
echo "🛑 Docker Swarm Cleanup (Safe Removal)"
echo "----------------------------------------------------------------"

# 1. Check for Active Tunnel (Safety)
echo "🔍 Checking for active tunnels..."
if docker service ls --format '{{.Name}}' | grep -q "^${TUNNEL_SERVICE}$"; then
    echo "❌ ERROR: Active tunnel service detected ('$TUNNEL_SERVICE')."
    echo "   You cannot remove the core network/stack while a tunnel is running."
    echo "   Please use './cf_swarm_manager.sh' to deactivate and delete the tunnel first."
    exit 1
fi

echo "✅ No active tunnel detected. Proceeding with cleanup..."

# 2. Remove NPM Stack (commented out for now)
# if docker stack ls --format '{{.Name}}' | grep -q "^${STACK_NAME}$"; then
#     echo "--> Removing stack '$STACK_NAME'..."
#     docker stack rm "$STACK_NAME"
# else
#     echo "ℹ️  Stack '$STACK_NAME' not found."
# fi

# 3. Remove Secrets
echo "--> Cleaning up Docker Secrets..."
for secret in "$CRED_SECRET" "$TOKEN_SECRET"; do
    if docker secret ls --format '{{.Name}}' | grep -q "^${secret}$"; then
        docker secret rm "$secret" > /dev/null
        echo "   - Removed secret: $secret"
    fi
done

# 4. Remove Network
# Wait a few seconds for stack services to release the network
echo "⏳ Waiting for network resources to release..."
sleep 5

if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    echo "--> Removing network '$NETWORK_NAME'..."
    docker network rm "$NETWORK_NAME"
    if [ $? -eq 0 ]; then
        echo "✅ Network removed."
    else
        echo "⚠️  Failed to remove network (it might still be in use by other services)."
    fi
else
    echo "ℹ️  Network '$NETWORK_NAME' not found."
fi

echo "----------------------------------------------------------------"
echo "🎉 Cleanup complete."
echo "----------------------------------------------------------------"
