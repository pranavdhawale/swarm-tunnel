################################################################################
# CLOUDFLARE TUNNEL - DOCKER SWARM MANUAL SETUP GUIDE
################################################################################
# This file provides a step-by-step manual reference for deploying a 
# Cloudflare Tunnel on a Docker Swarm cluster and routing it to NPM.
################################################################################

################################################################################
# STEP 0: GET YOUR CREDENTIALS
################################################################################
# A. Get Account ID:
#    1. Log in to dash.cloudflare.com.
#    2. Click on your website (or the account name).
#    3. On the right sidebar, scroll down to "API" section.
#    4. Copy "Account ID".
# 
# B. Get API Token:
#    1. Go to: https://dash.cloudflare.com/profile/api-tokens
#    2. Click "Create Token".
#    3. Use template: "Cloudflare Tunnel" (if available) OR "Create Custom Token".
#    4. Permissions (Custom):
#       - Account -> Cloudflare Tunnel -> Edit
#       - Zone -> DNS -> Edit
#    5. Account Resources:
#       - Include -> "Specific zone" -> Select your domain
#    6. Click "Continue to summary" -> "Create Token".
#    7. Copy the token immediately (you won't see it again).
# 
# ------------------------------------------------------------------------------
# STEP 1: EXPORT CREDENTIALS (REPLACE THESE VALUES)
# ------------------------------------------------------------------------------
# These variables will be used in all subsequent curl commands.
export DOMAIN_NAME="DOMAIN_NAME"
export CF_ACCOUNT_ID="CF_ACCOUNT_ID"
export CF_API_TOKEN="CF_API_TOKEN"
export CF_ZONE_ID="CF_ZONE_ID"
 
# ------------------------------------------------------------------------------
# STEP 2: CREATE THE NETWORK (Run this first)
# ------------------------------------------------------------------------------
# We create an attachable overlay network. 
# Overlay: Spans across all Swarm nodes.
# Attachable: Allows standalone containers to join the network.
docker network create --driver overlay --attachable public_edge_net
 
# ------------------------------------------------------------------------------
# STEP 3: CREATE THE TUNNEL (Run this once)
# ------------------------------------------------------------------------------
# This creates a "Cloudflare-Managed" tunnel resource in your account.
# Note down the "id" and "token" from the JSON output.
curl -X POST "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/tunnels" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "name": "swarm-prod-tunnel",
    "config_src": "cloudflare"
  }'
 
# ------------------------------------------------------------------------------
# STEP 4: GET THE TUNNEL ID (Run and copy the ID from output)
# ------------------------------------------------------------------------------
# Replace 'TUNNEL_ID' with the UUID from the step above.
export TUNNEL_ID="TUNNEL_ID"
 
# ------------------------------------------------------------------------------
# STEP 5: CREATE DOCKER SECRET (Run this)
# ------------------------------------------------------------------------------
# Copy the token string from the output of Step 3 (a very long base64 string).
# Paste it inside the quotes below. Docker Secrets keep it secure/encrypted.
echo "TUNNEL_TOKEN" | docker secret create cloudflare_tunnel_token -
 
# ------------------------------------------------------------------------------
# STEP 6: DEPLOY CLOUDFLARE TUNNEL (Run this)
# ------------------------------------------------------------------------------
# This deploys the 'cloudflared' connector using the cloudflare.yml stack file.
docker stack deploy -c cloudflare.yml public_edge
 
# ------------------------------------------------------------------------------
# STEP 7: DEPLOY NGINX PROXY MANAGER (Run this)
# ------------------------------------------------------------------------------
# This deploys NPM on the same 'public_edge_net' network.
# It acts as the internal destination for your tunnel traffic.
docker stack deploy -c npm.yml npm_stack
 
# ------------------------------------------------------------------------------
# STEP 8: VERIFICATION COMMANDS
# ------------------------------------------------------------------------------
 
# Check if the network was created correctly
docker network ls | grep public_edge_net
 
# Check if the services are replicated and running
docker service ls
 
# Watch cloudflared logs to confirm it has established connections to Cloudflare Edge
docker service logs -f public_edge_cloudflared

# Check NPM logs for startup status
docker service logs -f npm_stack_nginx-proxy-manager
 
# ------------------------------------------------------------------------------
# STEP 9: CONFIGURE PUBLIC HOSTNAME (CLI / API)
# ------------------------------------------------------------------------------
# Routing instructions for 'npm.yourdomain.com' -> NPM container.
# 1. Create a CNAME DNS record pointing to your tunnel.
# 2. Update the tunnel configuration to route traffic.
 
# --- REPLACE THESE FIRST ---
export SUBDOMAIN_NAME="npm"  # Makes npm.yourdomain.com
# ---------------------------
 
# A. Create DNS CNAME Record
# Points the public hostname to Cloudflare's tunnel infrastructure.
curl -X POST "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "type": "CNAME",
    "name": "'"$SUBDOMAIN_NAME"'",
    "content": "'$TUNNEL_ID'.cfargotunnel.com",
    "proxied": true
  }'
 
# B. Update Tunnel Ingress Rules
# Maps the incoming hostname to the internal service name 'nginx-proxy-manager'.
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data '{
    "config": {
      "ingress": [
        {
          "hostname": "'"$SUBDOMAIN_NAME"'.'"$DOMAIN_NAME"'",
          "service": "http://nginx-proxy-manager:81"
        },
        {
          "service": "http_status:404"
        }
      ]
    }
  }'
 
 
echo "Configuration updated. Visit https://$SUBDOMAIN_NAME.$DOMAIN_NAME"
 
################################################################################
# STEP 10: UNDO / TEARDOWN COMMANDS (Run these to clean up)
################################################################################
 
# 1. Remove services and stacks
echo "Removing NPM Stack..."
docker stack rm npm_stack
 
echo "Removing Cloudflare Tunnel Stack..."
docker stack rm public_edge
 
# 2. Cleanup shared resources
echo "Removing Docker Secret..."
docker secret rm cloudflare_tunnel_token
 
# 3. Wait for network interfaces to detach
echo "Removing Docker Network..."
sleep 10
docker network rm public_edge_net
 
# 4. Cleanup Cloudflare DNS
echo ""
echo "Deleting DNS Record for $SUBDOMAIN_NAME.$DOMAIN_NAME..."
 
# FETCH the Record ID first using an API GET request
DNS_RECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records?name=$SUBDOMAIN_NAME.$DOMAIN_NAME" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" | jq -r '.result[0].id')
 
if [ "$DNS_RECORD_ID" != "null" ] && [ -n "$DNS_RECORD_ID" ]; then
  # DELETE the record using the ID we just found
  curl -X DELETE "https://api.cloudflare.com/client/v4/zones/$CF_ZONE_ID/dns_records/$DNS_RECORD_ID" \
    -H "Authorization: Bearer $CF_API_TOKEN" \
    -H "Content-Type: application/json"
  echo "DNS Record deleted."
else
  echo "DNS Record not found or already deleted."
fi
 
# 5. Cleanup Tunnel configuration
echo ""
echo "Removing $SUBDOMAIN_NAME.$DOMAIN_NAME from Tunnel Ingress Rules..."
 
# Fetch CURRENT config to filter out only the target hostname
CURRENT_CONFIG=$(curl -s -X GET "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json")
 
# User JQ to filter the array locally
NEW_INGRESS=$(echo "$CURRENT_CONFIG" | jq --arg HOSTNAME "$SUBDOMAIN_NAME.$DOMAIN_NAME" \
  '.result.config.ingress | map(select(.hostname != $HOSTNAME))')
 
# Upload the NEW config (missing the removed mapping)
curl -X PUT "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$TUNNEL_ID/configurations" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json" \
  --data "{\"config\": {\"ingress\": $NEW_INGRESS}}"
 
echo "Tunnel configuration updated (removed $SUBDOMAIN_NAME.$DOMAIN_NAME)."
 
# 6. Delete the Tunnel resource entirely
echo ""
echo "Deleting Tunnel..."
curl -X DELETE "https://api.cloudflare.com/client/v4/accounts/$CF_ACCOUNT_ID/tunnels/$TUNNEL_ID" \
  -H "Authorization: Bearer $CF_API_TOKEN" \
  -H "Content-Type: application/json"
 
echo "Teardown complete."
