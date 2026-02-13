#!/bin/bash

# Configuration
NETWORK_NAME="public_edge_net"
# NPM Stack - Commented out for now, uncomment when needed
# STACK_NAME="npm_stack"
# STACK_FILE="stacks/npm.yml"

echo "----------------------------------------------------------------"
echo "🐋 Docker Swarm Initialization"
echo "----------------------------------------------------------------"

# Check if network exists
if docker network ls --format '{{.Name}}' | grep -q "^${NETWORK_NAME}$"; then
    NET_EXISTS=true
else
    NET_EXISTS=false
fi

# Check if stack exists
# if docker stack ls --format '{{.Name}}' | grep -q "^${STACK_NAME}$"; then
#     STACK_EXISTS=true
# else
#     STACK_EXISTS=false
# fi

# 1. Exit if both present
# if [ "$NET_EXISTS" = true ] && [ "$STACK_EXISTS" = true ]; then
#     echo "✅ Network '$NETWORK_NAME' and Stack '$STACK_NAME' already exist."
#     echo "👋 Exiting."
#     exit 0
# fi

# 2. Create Network if missing
if [ "$NET_EXISTS" = false ]; then
    echo "--> Creating network '$NETWORK_NAME'..."
    docker network create --driver overlay --attachable "$NETWORK_NAME"
    if [ $? -eq 0 ]; then
        echo "✅ Network created."
    else
        echo "❌ Failed to create network."
        exit 1
    fi
else
    echo "✅ Network '$NETWORK_NAME' already exists."
fi

# 3. Deploy NPM Stack if missing (commented out for now)
# if [ "$STACK_EXISTS" = false ]; then
#     echo "--> Deploying stack '$STACK_NAME'..."
#     if [ ! -f "$STACK_FILE" ]; then
#         echo "❌ Error: Stack file '$STACK_FILE' not found!"
#         exit 1
#     fi
#     
#     docker stack deploy -c "$STACK_FILE" "$STACK_NAME"
#     
#     if [ $? -eq 0 ]; then
#         echo "✅ Stack deployed."
#     else
#         echo "❌ Failed to deploy stack."
#         exit 1
#     fi
# else
#     echo "✅ Stack '$STACK_NAME' already exists."
# fi

echo "🎉 Initialization complete."
