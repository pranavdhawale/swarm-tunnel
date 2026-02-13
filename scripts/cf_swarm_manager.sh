#!/bin/bash

# Configuration
CRED_SECRET_NAME="cf_manager_creds"
TEMP_READER_SERVICE="cf_reader_$(date +%s)"

# --- Utility Functions ---

check_deps() {
  local missing=0
  for cmd in curl jq docker; do
    if ! command -v $cmd &> /dev/null; then
      echo "❌ Error: $cmd is required but not installed."
      missing=1
    fi
  done
  if [ $missing -eq 1 ]; then
    echo "Please install missing dependencies and try again."
    exit 1
  fi
}

pause() {
  read -p "Press Enter to continue..."
}

# --- Credential Management (Swarm Native) ---

setup_credentials() {
  echo "----------------------------------------------------------------"
  echo "🔐 Setup Cloudflare Credentials (Swarm Secret)"
  echo "----------------------------------------------------------------"
  echo "These credentials will be stored as a Docker Secret ($CRED_SECRET_NAME)."
  echo "This ensures they are securely available to manager nodes."
  echo ""
  
  read -p "Enter Cloudflare Account ID: " account_id
  while [ -z "$account_id" ]; do read -p "Account ID cannot be empty: " account_id; done

  read -s -p "Enter Cloudflare API Token: " api_token
  echo ""
  while [ -z "$api_token" ]; do read -s -p "API Token cannot be empty: " api_token; echo ""; done

  read -p "Enter Cloudflare Zone ID: " zone_id
  while [ -z "$zone_id" ]; do read -p "Zone ID cannot be empty: " zone_id; done

  read -p "Enter Domain Name (e.g. autowhat.ai): " domain_name
  while [ -z "$domain_name" ]; do read -p "Domain Name cannot be empty: " domain_name; done
  
  # Check if secret already exists
  if docker secret inspect "$CRED_SECRET_NAME" > /dev/null 2>&1; then
      echo "⚠️  Secret '$CRED_SECRET_NAME' already exists."
      read -p "Overwrite? (y/N): " choice
      if [[ "$choice" =~ ^[Yy]$ ]]; then
          docker secret rm "$CRED_SECRET_NAME" > /dev/null
      else
          echo "Cancelled."
          return
      fi
  fi
  
  # Create JSON payload
  local json_data
  json_data=$(jq -n \
                  --arg aid "$account_id" \
                  --arg tok "$api_token" \
                  --arg zid "$zone_id" \
                  --arg dom "$domain_name" \
                  '{AccountID: $aid, Token: $tok, ZoneID: $zid, Domain: $dom}')
                  
  # Use -c to compact JSON for cleaner logs/storage
  echo "$json_data" | jq -c . | docker secret create "$CRED_SECRET_NAME" - > /dev/null
  
  if [ $? -eq 0 ]; then
      echo "✅ Credentials securely stored in Docker Secret '$CRED_SECRET_NAME'."
  else
      echo "❌ Failed to create Docker secret."
      exit 1
  fi
}

load_credentials() {
  # 1. Check if secret exists
  if ! docker secret inspect "$CRED_SECRET_NAME" > /dev/null 2>&1; then
      echo "⚠️  Credentials not found (Secret '$CRED_SECRET_NAME' missing)."
      read -p "Setup credentials now? (y/N): " choice
      if [[ "$choice" =~ ^[Yy]$ ]]; then
          setup_credentials
          load_credentials
          return
      else
          echo "Exiting."
          exit 0
      fi
  fi
  
  # 2. Spawn ephemeral service to read secret
  echo "📖 Reading credentials from Swarm..."
  # Create a service that cats the secret and exits (restart-condition none)
  # We use 'alpine' as it's small.
  local svc_id
  svc_id=$(docker service create \
              --name "$TEMP_READER_SERVICE" \
              --secret "$CRED_SECRET_NAME" \
              --restart-condition none \
              --detach \
              alpine cat /run/secrets/"$CRED_SECRET_NAME")
              
  if [ -z "$svc_id" ]; then
      echo "❌ Failed to create reader service."
      exit 1
  fi
  
  # Wait briefly for execution - polling logs
  local attempt=0
  local cred_json=""
  
  while [ $attempt -lt 10 ]; do
      # Extract JSON from logs. 
      # 1. grep "{" to find start of JSON (or lines containing JSON)
      # 2. sed to strip the "service_name | " prefix common in service logs
      cred_json=$(docker service logs "$TEMP_READER_SERVICE" 2>&1 | grep -v "service is not running" | grep "{" | sed 's/^.*| //')
      
      if [ -n "$cred_json" ]; then
          # If we got data, wait a split second to ensure we got all lines if multiline
          sleep 1
          # Re-read to get full content
          cred_json=$(docker service logs "$TEMP_READER_SERVICE" 2>&1 | grep -v "service is not running" | sed 's/^.*| //')
          break
      fi
      sleep 1
      ((attempt++))
  done
  
  # Clean up service
  docker service rm "$TEMP_READER_SERVICE" > /dev/null 2>&1
  
  if [ -z "$cred_json" ]; then
      echo "❌ Failed to read credentials from reader service."
      exit 1
  fi
  
  # Parse JSON
  # Use -r to get raw strings, but handle potential jq errors
  if ! echo "$cred_json" | jq -e . >/dev/null 2>&1; then
      echo "❌ Error parsing credential JSON from logs."
      echo "Raw output: $cred_json"
      exit 1
  fi
  # echo "DEBUG: Raw creds: $cred_json"
  
  CF_ACCOUNT_ID=$(echo "$cred_json" | jq -r '.AccountID')
  # echo "DEBUG: Extracted CF_ACCOUNT_ID='$CF_ACCOUNT_ID'"
  
  CF_API_TOKEN=$(echo "$cred_json" | jq -r '.Token')
  # echo "DEBUG: Extracted CF_API_TOKEN='${CF_API_TOKEN:0:5}...'"
  
  CF_ZONE_ID=$(echo "$cred_json" | jq -r '.ZoneID')
  DOMAIN_NAME=$(echo "$cred_json" | jq -r '.Domain')
  
  if [ "$CF_ACCOUNT_ID" == "null" ] || [ -z "$CF_ACCOUNT_ID" ]; then
       echo "❌ Invalid credential format."
       exit 1
  fi
  
  export CF_ACCOUNT_ID CF_API_TOKEN CF_ZONE_ID DOMAIN_NAME
  echo "✅ Credentials loaded for: $DOMAIN_NAME"
}

# --- Phase 2: Active Tunnel Detection ---

cf_curl() {
  local method="$1"
  local endpoint="$2"
  local data="$3"
  
  local args=(-s -X "$method" "https://api.cloudflare.com/client/v4$endpoint" \
       -H "Authorization: Bearer $CF_API_TOKEN" \
       -H "Content-Type: application/json")
       
  if [ -n "$data" ]; then
    args+=(--data "$data")
  fi
  
  curl "${args[@]}"
}

get_active_tunnel_id() {
  # Returns the tunnel ID if found, otherwise empty string.
  
  # 1. Check if service is running
  if ! docker service inspect public_edge_cloudflared >/dev/null 2>&1; then
      return
  fi

  # 2. Look for "tunnelID=" specifically to avoid false positives.
  local t_id
  t_id=$(docker service logs public_edge_cloudflared --tail 200 2>&1 | grep -oE 'tunnelID=[0-9a-f]{8}-([0-9a-f]{4}-){3}[0-9a-f]{12}' | cut -d= -f2 | sort -u | head -n 1)
  echo "$t_id"
}

get_tunnel_details() {
  local t_id="$1"
  if [ -z "$t_id" ]; then
      echo "No Tunnel ID provided."
      return 1
  fi
  
  local response
  response=$(cf_curl GET "/accounts/$CF_ACCOUNT_ID/tunnels/$t_id")
  
  if [ "$(echo "$response" | jq -r '.success')" == "true" ]; then
      local name status created
      name=$(echo "$response" | jq -r '.result.name')
      status=$(echo "$response" | jq -r '.result.status')
      created=$(echo "$response" | jq -r '.result.created_at')
      
      echo "----------------------------------------------------------------"
      echo "🚇 Active Tunnel Details"
      echo "----------------------------------------------------------------"
      echo "Details for Tunnel ID: $t_id"
      echo "Name:   $name"
      echo "Status: $status"
      echo "Created: $created"
      echo "----------------------------------------------------------------"
  else
      echo "❌ Failed to fetch tunnel details."
      echo "$response" | jq .errors
  fi
}

# --- Phase 3: Tunnel Operations ---

create_tunnel() {
  # 1. Check for active tunnel
  local active_id
  active_id=$(get_active_tunnel_id)
  
  if [ -n "$active_id" ]; then
      echo "❌ Active tunnel already exists ($active_id)."
      echo "   Please deactivate and delete it first."
      pause
      return
  fi
  
  read -p "Enter name for new tunnel: " t_name
  if [ -z "$t_name" ]; then echo "Cancelled."; pause; return; fi

  echo "--> Creating tunnel '$t_name'..."
  
  local data="{\"name\": \"$t_name\", \"config_src\": \"cloudflare\"}"
  local response
  response=$(cf_curl POST "/accounts/$CF_ACCOUNT_ID/tunnels" "$data")
  
  # echo "DEBUG: Raw Tunnel Create Response: $response"

  local id
  id=$(echo "$response" | jq -r '.result.id')
  
  if [ "$id" == "null" ] || [ -z "$id" ]; then
    echo "❌ Failed to create tunnel."
    echo "$response" | jq .errors
    pause
    return
  fi

  echo "✅ Tunnel created. ID: $id"
  
  # 2. Fetch connection token
  # Try extracting from creation response first
  local token
  token=$(echo "$response" | jq -r '.result.token // .result.runner_token // empty')
  
  if [ -z "$token" ]; then
      echo "--> Fetching tunnel token (GET)..."
      local token_resp
      token_resp=$(cf_curl GET "/accounts/$CF_ACCOUNT_ID/tunnels/$id/token")
      token=$(echo "$token_resp" | jq -r '.result')
      # echo "DEBUG: Raw Token Response (GET): $token_resp"
  fi
  
  if [ -z "$token" ] || [ "$token" == "null" ]; then
      echo "❌ Failed to fetch token."
      pause
      return
  fi
  
  # 3. Create Docker Secret
  echo "--> Creating Docker Secret 'cloudflare_tunnel_token'..."
  # Remove if exists (start fresh)
  docker secret rm cloudflare_tunnel_token >/dev/null 2>&1
  echo -n "$token" | docker secret create cloudflare_tunnel_token - >/dev/null
  
  if [ $? -ne 0 ]; then
      echo "❌ Failed to create Docker Secret."
      pause
      return
  fi
  
  # 4. Deploy Stack
  echo "--> Deploying Docker Stack 'public_edge'..."
  if [ -f "stacks/cloudflare.yml" ]; then
      docker stack deploy -c stacks/cloudflare.yml public_edge
      echo "✅ Stack deployed. Waiting for service to start..."
      sleep 5
      echo "   Check status with Option 1 later."
      
      # Update secret with Tunnel ID
      store_tunnel_id_in_secret "$id"
  else
      echo "❌ 'stacks/cloudflare.yml' not found! Cannot deploy stack."
  fi
  pause
}

delete_tunnel() {
  # 1. Detect local active tunnel
  local t_id
  t_id=$(get_active_tunnel_id)
  
  if [ -z "$t_id" ]; then
      echo "❌ No active tunnel detected on this machine to delete."
      pause
      return
  fi
  
  # 2. Fetch Name
  echo "--> Fetching details for Tunnel ID: $t_id..."
  local t_info
  t_info=$(cf_curl GET "/accounts/$CF_ACCOUNT_ID/tunnels/$t_id")
  local t_name
  t_name=$(echo "$t_info" | jq -r '.result.name')
  
  if [ "$t_name" == "null" ]; then t_name="(Unknown/Deleted)"; fi
  
  echo "✅ Found Local Active Tunnel: $t_name ($t_id)"
  
  # 3. Verify DNS (Placeholder for now, implementation in Phase 4)
  # For now, we trust the user or warn them.
  echo "⚠️  Ensure you have deleted all DNS records associated with this tunnel first!"
  
  echo "----------------------------------------------------------------"
  echo "DEACTIVATION & DELETION"
  echo "----------------------------------------------------------------"
  echo "  1. Stop local Docker service (stack rm public_edge)"
  echo "  2. Delete tunnel '$t_name' from Cloudflare"
  echo "  3. Remove Docker Secret 'cloudflare_tunnel_token'"
  echo "----------------------------------------------------------------"
  
  read -p "⚠️  Are you sure you want to PROCEED? (y/N): " confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
      # Step 1: Remove Stack
      echo "--> [1/3] Removing Docker Stack 'public_edge'..."
      docker stack rm public_edge
      
      echo "⏳ Waiting 10 seconds for Cloudflare disconnection..."
      sleep 10
      
      # Step 2: Delete from Cloudflare
      echo "--> [2/3] Deleting Tunnel from Cloudflare..."
      local del_resp
      del_resp=$(cf_curl DELETE "/accounts/$CF_ACCOUNT_ID/tunnels/$t_id")
      if [ "$(echo "$del_resp" | jq -r '.success')" == "true" ]; then
          echo "✅ Tunnel deleted from Cloudflare."
      else
          echo "❌ Failed to delete tunnel (API Error). It might already be deleted."
          echo "$del_resp" | jq .errors
      fi
      
      # Step 3: Remove Secret
      echo "--> [3/3] Removing Docker Secret..."
      docker secret rm cloudflare_tunnel_token >/dev/null 2>&1
      echo "✅ Secret removed."
      
      # Step 4: Remove Tunnel ID from credentials secret
      remove_tunnel_id_from_secret
      
      echo "🎉 Deletion complete."
  else
      echo "Cancelled."
  fi
  pause
}

menu_tunnels() {
    while true; do
        clear
        echo "=========================================="
        echo "   Tunnel Management"
        echo "=========================================="
        
        # Check status dynamically
        local active_id
        active_id=$(get_active_tunnel_id)
        
        if [ -n "$active_id" ]; then
             echo "✅ Active Tunnel Detected: $active_id"
        else
             echo "ℹ️  No Active Tunnel"
        fi
        echo "------------------------------------------"
        echo "1. Tunnel Details"
        echo "2. Create Tunnel (if none active)"
        echo "3. Deactivate & Delete Tunnel"
        echo "9. Back to Main Menu"
        echo "=========================================="
        read -p "Option: " opt
        case $opt in
            1) 
               if [ -n "$active_id" ]; then
                   get_tunnel_details "$active_id"
               else
                   echo "No active tunnel to show details for."
               fi
               pause 
               ;;
            2) create_tunnel ;;
            3) delete_tunnel ;;
            9) return ;;
            *) echo "Invalid option"; pause ;;
        esac
    done
}

store_tunnel_id_in_secret() {
  local t_id="$1"
  echo "--> Updating credentials secret with Tunnel ID..."
  
  # 1. Read existing secret (we already have vars loaded, but let's read fresh to be safe or just use vars)
  # Actually we can just reconstruct JSON from loaded vars + new ID
  
  if [ -z "$CF_ACCOUNT_ID" ]; then
      echo "❌ Error: Missing credentials in memory. Cannot update secret."
      return
  fi
  
  local json_data
  json_data=$(jq -n \
                  --arg aid "$CF_ACCOUNT_ID" \
                  --arg tok "$CF_API_TOKEN" \
                  --arg zid "$CF_ZONE_ID" \
                  --arg dom "$DOMAIN_NAME" \
                  --arg tid "$t_id" \
                  '{AccountID: $aid, Token: $tok, ZoneID: $zid, Domain: $dom, TunnelID: $tid}')
                  
  # 2. Re-create secret
  # Secrets are immutable, so rm and create
  docker secret rm "$CRED_SECRET_NAME" > /dev/null 2>&1
  
  # Use -c to compact
  echo "$json_data" | jq -c . | docker secret create "$CRED_SECRET_NAME" - > /dev/null
  
  if [ $? -eq 0 ]; then
      echo "✅ Secret '$CRED_SECRET_NAME' updated with Tunnel ID."
  else
      echo "❌ Failed to update secret."
  fi
}

remove_tunnel_id_from_secret() {
  echo "--> Removing Tunnel ID from credentials secret..."
  
  if [ -z "$CF_ACCOUNT_ID" ]; then
      echo "❌ Error: Missing credentials in memory."
      return
  fi
  
  # Reconstruct JSON without TunnelID
  local json_data
  json_data=$(jq -n \
                  --arg aid "$CF_ACCOUNT_ID" \
                  --arg tok "$CF_API_TOKEN" \
                  --arg zid "$CF_ZONE_ID" \
                  --arg dom "$DOMAIN_NAME" \
                  '{AccountID: $aid, Token: $tok, ZoneID: $zid, Domain: $dom}')
                  
  docker secret rm "$CRED_SECRET_NAME" > /dev/null 2>&1
  echo "$json_data" | jq -c . | docker secret create "$CRED_SECRET_NAME" - > /dev/null
  
  if [ $? -eq 0 ]; then
      echo "✅ Secret '$CRED_SECRET_NAME' updated (Tunnel ID removed)."
  else
      echo "❌ Failed to update secret."
  fi
}

# --- Initialization ---
check_deps
load_credentials
echo "Configuration loaded."
sleep 1

# --- Phase 4: DNS & Ingress Operations ---

list_dns_records() {
    local t_id
    t_id=$(get_active_tunnel_id)
    
    if [ -z "$t_id" ]; then
        echo "❌ No active tunnel detected."
        pause
        return
    fi
    
    echo "--> Fetching DNS records for tunnel $t_id..."
    
    local response
    response=$(cf_curl GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME")
    
    if [ "$(echo "$response" | jq -r '.success')" != "true" ]; then
        echo "❌ Failed to fetch DNS records."
        echo "$response" | jq .errors
        pause
        return
    fi
    
    local target="$t_id.cfargotunnel.com"
    
    echo "----------------------------------------------------------------"
    echo "🔗 Active DNS Records (CNAME -> Tunnel)"
    echo "----------------------------------------------------------------"
    
    echo "$response" | jq -r --arg tgt "$target" '.result[] | select(.content == $tgt) | "\(.id) \(.name)"' | while read -r id name; do
        echo "  - $name"
    done
    
    local count
    count=$(echo "$response" | jq -r --arg tgt "$target" '[.result[] | select(.content == $tgt)] | length')
    
    if [ "$count" -eq 0 ]; then
        echo "  (No records found matching $target)"
        echo "  Found these CNAMEs instead:"
        echo "$response" | jq -r '.result[] | "  - \(.name) -> \(.content)"'
    fi
    
    echo "----------------------------------------------------------------"
    pause
}

add_dns_record() {
    local t_id
    t_id=$(get_active_tunnel_id)
    if [ -z "$t_id" ]; then echo "❌ No active tunnel."; pause; return; fi

    echo "----------------------------------------------------------------"
    echo "➕ Add Subdomain"
    echo "----------------------------------------------------------------"
    read -p "Enter Subdomain (e.g. 'npm' for npm.$DOMAIN_NAME): " sub
    if [ -z "$sub" ]; then echo "Cancelled."; pause; return; fi
    
    local hostname="$sub.$DOMAIN_NAME"
    local service="http://nginx-proxy-manager:81"
    
    read -p "Enter Service URL [http://nginx-proxy-manager:81]: " srv_input
    if [ -n "$srv_input" ]; then service="$srv_input"; fi
    
    echo "--> [1/2] Creating CNAME record for $hostname..."
    
    local dns_data
    dns_data=$(jq -n \
                  --arg type "CNAME" \
                  --arg name "$sub" \
                  --arg content "$t_id.cfargotunnel.com" \
                  --argjson proxied true \
                  '{type: $type, name: $name, content: $content, proxied: $proxied}')
                  
    local dns_resp
    dns_resp=$(cf_curl POST "/zones/$CF_ZONE_ID/dns_records" "$dns_data")
    
    if [ "$(echo "$dns_resp" | jq -r '.success')" != "true" ]; then
         echo "❌ Failed to create DNS record."
         echo "$dns_resp" | jq .errors
         pause
         return
    fi
    echo "✅ DNS Record created."
    
    echo "--> [2/2] Updating Tunnel Ingress Rules..."
    # 1. Get current config (using cfd_tunnel for token compat)
    local config_resp
    config_resp=$(cf_curl GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$t_id/configurations")
    
    if [ "$(echo "$config_resp" | jq -r '.success')" != "true" ]; then
         echo "❌ Failed to fetch tunnel config."
         echo "$config_resp" | jq .errors
         pause
         return
    fi
    
    # 2. Check if config exists or needs initialization
    # If no config exists, we might get 404.
    # But usually a created tunnel has no config until we PUT it.
    
    # We need to construct the ingress list.
    # Access existing rules if any.
    local current_ingress
    current_ingress=$(echo "$config_resp" | jq '.result.config.ingress // []')
    
    # Check if empty (no config yet)
    if [ "$current_ingress" == "[]" ] || [ -z "$current_ingress" ]; then
        # Default starter config + 404 catch-all
        current_ingress="[]"
    fi
    
    # Remove catch-all if present (to append new rule before it)
    # We will rebuild the list: [ ...existing_rules_minus_404, new_rule, 404 ]
    
    local new_rule
    new_rule=$(jq -n --arg host "$hostname" --arg svc "$service" '{hostname: $host, service: $svc}')
    
    local catch_all
    catch_all='{"service": "http_status:404"}'
    
    # logic: take existing, filter out 404, add new, add 404.
    local new_ingress
    new_ingress=$(echo "$current_ingress" | jq --argjson new "$new_rule" --argjson u404 "$catch_all" '
       map(select(.service != "http_status:404")) + [$new, $u404]
    ')
    
    # 3. PUT config
    local config_data
    config_data=$(jq -n --argjson ing "$new_ingress" '{"config": {"ingress": $ing}}')
    
    local put_resp
    put_resp=$(cf_curl PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$t_id/configurations" "$config_data")
    
    if [ "$(echo "$put_resp" | jq -r '.success')" == "true" ]; then
        echo "✅ Tunnel Ingress updated."
        echo "🎉 Subdomain $hostname is now active!"
    else
        echo "❌ Failed to update tunnel config."
        echo "$put_resp" | jq .errors
    fi
    pause
}

delete_dns_record() {
    local t_id
    t_id=$(get_active_tunnel_id)
    if [ -z "$t_id" ]; then echo "❌ No active tunnel."; pause; return; fi
    
    echo "--> Fetching DNS records..."
    local response
    response=$(cf_curl GET "/zones/$CF_ZONE_ID/dns_records?type=CNAME")
    local target="$t_id.cfargotunnel.com"
    
    # Store IDs and Names in arrays or map
    # We'll just list them with index
    
    echo "Select record to delete:"
    local i=1
    declare -A records
    
    while read -r id name; do
        echo "  $i) $name"
        records[$i,id]="$id"
        records[$i,name]="$name"
        ((i++))
    done < <(echo "$response" | jq -r --arg tgt "$target" '.result[] | select(.content == $tgt) | "\(.id) \(.name)"')
    
    if [ $i -eq 1 ]; then
        echo "  (No active records found)"
        pause
        return
    fi
    
    read -p "Option: " opt
    local selected_id="${records[$opt,id]}"
    local selected_name="${records[$opt,name]}"
    
    if [ -z "$selected_id" ]; then
        echo "Invalid option."
        pause
        return
    fi
    
    echo "--> [1/2] Deleting DNS Record for $selected_name..."
    local del_resp
    del_resp=$(cf_curl DELETE "/zones/$CF_ZONE_ID/dns_records/$selected_id")
    
    if [ "$(echo "$del_resp" | jq -r '.success')" == "true" ]; then
        echo "✅ DNS Record deleted."
    else
        echo "❌ Failed to delete DNS record."
        pause
        return # Dont proceed to ingress removal if DNS failed? Or proceed anyway? User choice?
        # Let's proceed to ensure cleanup.
    fi
    
    echo "--> [2/2] Removing Ingress Rule from Tunnel Config..."
    
    # 1. Get current config (using cfd_tunnel for token compat)
    local config_resp
    config_resp=$(cf_curl GET "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$t_id/configurations")
    
    if [ "$(echo "$config_resp" | jq -r '.success')" != "true" ]; then
         echo "❌ Failed to fetch tunnel config for removal."
         echo "$config_resp" | jq .errors
         pause
         return
    fi
    
    local current_ingress
    current_ingress=$(echo "$config_resp" | jq '.result.config.ingress // []')
    
    # Filter OUT the hostname
    local new_ingress
    new_ingress=$(echo "$current_ingress" | jq --arg host "$selected_name" 'map(select(.hostname != $host))')
    
    local config_data
    config_data=$(jq -n --argjson ing "$new_ingress" '{"config": {"ingress": $ing}}')
    
    local put_resp
    put_resp=$(cf_curl PUT "/accounts/$CF_ACCOUNT_ID/cfd_tunnel/$t_id/configurations" "$config_data")
    
    if [ "$(echo "$put_resp" | jq -r '.success')" == "true" ]; then
        echo "✅ Ingress rule removed."
    else
        echo "❌ Failed to update tunnel config."
        echo "$put_resp" | jq .errors
    fi
    
    echo "🎉 Removal complete."
    pause
}


menu_dns() {
    while true; do
        clear
        echo "=========================================="
        echo "   DNS & Subdomain Management"
        echo "=========================================="
        echo "1. List Active Subdomains"
        echo "2. Add Subdomain (CNAME + Ingress)"
        echo "3. Remove Subdomain"
        echo "9. Back"
        echo "=========================================="
        read -p "Option: " opt
        case $opt in
            1) list_dns_records ;;
            2) add_dns_record ;;
            3) delete_dns_record ;;
            9) return ;;
            *) echo "Invalid option"; pause ;;
        esac
    done
}

# --- Phase 5: Configuration Management ---

delete_credentials() {
    echo "----------------------------------------------------------------"
    echo "⚠️  DELETE CREDENTIALS"
    echo "----------------------------------------------------------------"
    
    # 1. Check for Active Tunnel (Safety)
    local active_id
    active_id=$(get_active_tunnel_id)
    if [ -n "$active_id" ]; then
        echo "❌ ERROR: Active tunnel detected ($active_id)."
        echo "   You MUST deactivate the tunnel before deleting credentials."
        echo "   Please use Option 1 -> Deactivate & Delete Tunnel first."
        pause
        return
    fi

    echo "This will permanently remove the Docker Secret '$CRED_SECRET_NAME'."
    echo "This machine will lose access to manage Cloudflare tunnels."
    echo ""
    read -p "Are you sure you want to DELETE? (y/N): " confirm
    
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        docker secret rm "$CRED_SECRET_NAME" > /dev/null 2>&1
        # Clear memory variables
        unset CF_ACCOUNT_ID CF_API_TOKEN CF_ZONE_ID DOMAIN_NAME
        echo "✅ Credentials deleted."
        echo "👋 Exiting script as credentials are gone."
        exit 0
    else
        echo "Cancelled."
        pause
    fi
}

update_specific_field() {
    while true; do
        clear
        echo "=========================================="
        echo "   Update Specific Field"
        echo "=========================================="
        echo "1. Account ID  ($CF_ACCOUNT_ID)"
        echo "2. API Token   (${CF_API_TOKEN:0:5}...)"
        echo "3. Zone ID     ($CF_ZONE_ID)"
        echo "4. Domain      ($DOMAIN_NAME)"
        echo "9. Back"
        echo "=========================================="
        read -p "Select field to update: " fopt
        
        local new_val=""
        local field_name=""
        
        case $fopt in
            1) 
               field_name="AccountID"
               read -p "Enter new Account ID: " new_val
               if [ -n "$new_val" ]; then CF_ACCOUNT_ID="$new_val"; fi
               ;;
            2) 
               field_name="Token"
               read -s -p "Enter new API Token: " new_val; echo ""
               if [ -n "$new_val" ]; then CF_API_TOKEN="$new_val"; fi
               ;;
            3) 
               field_name="ZoneID"
               read -p "Enter new Zone ID: " new_val
               if [ -n "$new_val" ]; then CF_ZONE_ID="$new_val"; fi
               ;;
            4) 
               field_name="Domain"
               read -p "Enter new Domain: " new_val
               if [ -n "$new_val" ]; then DOMAIN_NAME="$new_val"; fi
               ;;
            9) return ;;
            *) echo "Invalid option."; pause; continue ;;
        esac
        
        if [ -z "$new_val" ]; then
            echo "No change made."
            pause
            continue
        fi
        
        # Update Secret
        echo "--> Updating Secret '$CRED_SECRET_NAME'..."
        
        # We need the Tunnel ID if it exists to preserve it
        local t_id
        t_id=$(get_active_tunnel_id)
        
        # Construct JSON
        local json_data
        if [ -n "$t_id" ]; then
            json_data=$(jq -n \
                          --arg aid "$CF_ACCOUNT_ID" \
                          --arg tok "$CF_API_TOKEN" \
                          --arg zid "$CF_ZONE_ID" \
                          --arg dom "$DOMAIN_NAME" \
                          --arg tid "$t_id" \
                          '{AccountID: $aid, Token: $tok, ZoneID: $zid, Domain: $dom, TunnelID: $tid}')
        else
             json_data=$(jq -n \
                          --arg aid "$CF_ACCOUNT_ID" \
                          --arg tok "$CF_API_TOKEN" \
                          --arg zid "$CF_ZONE_ID" \
                          --arg dom "$DOMAIN_NAME" \
                          '{AccountID: $aid, Token: $tok, ZoneID: $zid, Domain: $dom}')
        fi
        
        docker secret rm "$CRED_SECRET_NAME" > /dev/null 2>&1
        echo "$json_data" | jq -c . | docker secret create "$CRED_SECRET_NAME" - > /dev/null
        
        if [ $? -eq 0 ]; then
            echo "✅ Secret updated successfully."
        else
            echo "❌ Failed to update secret."
        fi
        pause
    done
}

view_update_credentials() {
    while true; do
        clear
        echo "=========================================="
        echo "   Credentials Management"
        echo "=========================================="
        echo "Currently loaded configuration:"
        echo "  Account ID: $CF_ACCOUNT_ID"
        echo "  Zone ID:    $CF_ZONE_ID"
        echo "  Domain:     $DOMAIN_NAME"
        echo "  API Token:  ${CF_API_TOKEN:0:5}****************"
        echo "------------------------------------------"
        echo "1. Update ALL (Wizard)"
        echo "2. Update Specific Field"
        echo "3. Delete Credentials"
        echo "9. Back"
        echo "=========================================="
        read -p "Option: " opt
        
        case $opt in
            1) setup_credentials; load_credentials; pause ;;
            2) update_specific_field ;;
            3) delete_credentials; return ;;
            9) return ;;
            *) echo "Invalid option."; pause ;;
        esac
    done
}

# --- Main Menu ---

while true; do
  clear
  echo "=========================================="
  echo "   Cloudflare Manager ($DOMAIN_NAME)"
  echo "   Account: ${CF_ACCOUNT_ID:0:6}..."
  echo "=========================================="
  echo "1. [Tunnel] Manage Tunnels"
  echo "2. [DNS]    Manage DNS Records"
  echo "3. [Config] View/Update Credentials"
  echo "9. Exit"
  echo "=========================================="
  read -p "Select option: " option
  
  case $option in
    1) menu_tunnels ;;
    2) menu_dns ;;
    3) view_update_credentials ;;
    9) echo "Bye!"; exit 0 ;;
    *) echo "Invalid option."; pause ;;
  esac
done
