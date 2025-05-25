#!/bin/bash

# Configuration
AWS_PROFILE="semicolon"
API_NAME="EnumMicroservicesGateway"
STAGE_NAME="systest"
REGION="us-east-1"

# Define services with their ngrok and Swagger UI endpoints
declare -A SERVICES=(
  ["events"]="https://quality-fitting-wren.ngrok-free.app|/swagger-ui/index.html"
  ["assessment"]="https://broadly-healthy-rattler.ngrok-free.app|/documentation/identity/swagger-ui/index.html"
  ["application"]="https://proven-distinctly-albacore.ngrok-free.app|/documentation/application/swagger-ui/index.html"
  ["identity"]="https://learning-yeti-lively.ngrok-free.app|/swagger-ui/index.html"
  ["course"]="https://sawfish-hardy-early.ngrok-free.app|/swagger-ui/index.html"
)

# Initialize API
init_api_gateway() {
  API_ID=$(aws apigateway get-rest-apis \
    --query "items[?name=='$API_NAME'].id" \
    --output text \
    --region "$REGION" \
    --profile "$AWS_PROFILE")

  if [ -z "$API_ID" ]; then
    API_ID=$(aws apigateway create-rest-api \
      --name "$API_NAME" \
      --description "Gateway for Enum microservices" \
      --endpoint-configuration types=REGIONAL \
      --region "$REGION" \
      --profile "$AWS_PROFILE" \
      --output text \
      --query 'id')
    echo "Created new API with ID: $API_ID"
  else
    echo "Found existing API with ID: $API_ID"
  fi
}

# Get or create resource with retries
get_or_create_resource() {
  local parent_id=$1
  local path_part=$2
  local max_retries=3
  local retry_count=0
  local resource_id=""
  
  while [ $retry_count -lt $max_retries ]; do
    resource_id=$(aws apigateway get-resources \
      --rest-api-id "$API_ID" \
      --query "items[?pathPart=='$path_part' && parentId=='$parent_id'].id" \
      --output text \
      --region "$REGION" \
      --profile "$AWS_PROFILE")
    
    if [ -z "$resource_id" ]; then
      resource_id=$(aws apigateway create-resource \
        --rest-api-id "$API_ID" \
        --parent-id "$parent_id" \
        --path-part "$path_part" \
        --region "$REGION" \
        --profile "$AWS_PROFILE" \
        --output text \
        --query 'id' 2>/dev/null)
    fi
    
    if [ -n "$resource_id" ]; then
      break
    fi
    
    ((retry_count++))
    sleep 1
  done
  
  if [ -z "$resource_id" ]; then
    echo "Failed to create resource for path: $path_part" >&2
    exit 1
  fi
  
  echo "$resource_id"
}

# Verify endpoint is reachable
verify_endpoint() {
  local url=$1
  echo "Verifying endpoint: $url"
  
  # Try with curl (timeout after 10 seconds)
  if ! curl -s --head --connect-timeout 10 "$url" >/dev/null; then
    echo "Warning: Could not reach endpoint $url - integration might fail"
    return 1
  fi
  return 0
}

# Configure service proxy with proper error handling
configure_service_proxy() {
  local service_name=$1
  local ngrok_url=$2
  local swagger_path=$3

  # Remove trailing slash from ngrok_url if present
  ngrok_url=${ngrok_url%/}

  # Verify ngrok endpoint is reachable
  verify_endpoint "$ngrok_url"

  # Create service resource
  service_resource_id=$(get_or_create_resource "$V3_RESOURCE_ID" "$service_name")

  # Create proxy resource
  proxy_resource_id=$(get_or_create_resource "$service_resource_id" "{proxy+}")

  # Configure ANY method
  aws apigateway put-method \
    --rest-api-id "$API_ID" \
    --resource-id "$proxy_resource_id" \
    --http-method "ANY" \
    --authorization-type "NONE" \
    --no-api-key-required \
    --region "$REGION" \
    --profile "$AWS_PROFILE"

  # Configure integration with proper escaping
  aws apigateway put-integration \
    --rest-api-id "$API_ID" \
    --resource-id "$proxy_resource_id" \
    --http-method "ANY" \
    --type "HTTP_PROXY" \
    --integration-http-method "ANY" \
    --uri "${ngrok_url}/{proxy}" \
    --connection-type "INTERNET" \
    --passthrough-behavior "WHEN_NO_MATCH" \
    --timeout-in-millis 29000 \
    --region "$REGION" \
    --profile "$AWS_PROFILE"

  # Configure Swagger UI if path exists
  if [ -n "$swagger_path" ]; then
    echo "Configuring Swagger UI for $service_name..."
    
    # Get base path without filename
    swagger_dir_path=${swagger_path%/*}
    
    # Create resources for each path component
    IFS='/' read -ra PATH_PARTS <<< "$swagger_dir_path"
    current_parent_id="$service_resource_id"
    
    for path_part in "${PATH_PARTS[@]}"; do
      [ -z "$path_part" ] && continue
      current_parent_id=$(get_or_create_resource "$current_parent_id" "$path_part")
    done
    
    # Create {proxy+} resource for Swagger assets
    swagger_proxy_id=$(get_or_create_resource "$current_parent_id" "{proxy+}")

    # Configure ANY method for assets
    aws apigateway put-method \
      --rest-api-id "$API_ID" \
      --resource-id "$swagger_proxy_id" \
      --http-method "ANY" \
      --authorization-type "NONE" \
      --no-api-key-required \
      --region "$REGION" \
      --profile "$AWS_PROFILE"

    # Configure integration for assets
    aws apigateway put-integration \
      --rest-api-id "$API_ID" \
      --resource-id "$swagger_proxy_id" \
      --http-method "ANY" \
      --type "HTTP_PROXY" \
      --integration-http-method "ANY" \
      --uri "${ngrok_url}${swagger_dir_path}/{proxy}" \
      --connection-type "INTERNET" \
      --passthrough-behavior "WHEN_NO_MATCH" \
      --timeout-in-millis 29000 \
      --region "$REGION" \
      --profile "$AWS_PROFILE"

    # Create index.html resource if it's not the same as the proxy
    if [[ "$swagger_path" != "/index.html" ]]; then
      index_resource_id=$(get_or_create_resource "$current_parent_id" "index.html")

      # Configure GET method for index.html
      aws apigateway put-method \
        --rest-api-id "$API_ID" \
        --resource-id "$index_resource_id" \
        --http-method "GET" \
        --authorization-type "NONE" \
        --no-api-key-required \
        --region "$REGION" \
        --profile "$AWS_PROFILE"

      # Configure integration for index.html
      aws apigateway put-integration \
        --rest-api-id "$API_ID" \
        --resource-id "$index_resource_id" \
        --http-method "GET" \
        --type "HTTP_PROXY" \
        --integration-http-method "GET" \
        --uri "${ngrok_url}${swagger_path}" \
        --connection-type "INTERNET" \
        --passthrough-behavior "WHEN_NO_MATCH" \
        --timeout-in-millis 29000 \
        --region "$REGION" \
        --profile "$AWS_PROFILE"
    fi
  fi
}

# Wait for API changes to propagate
wait_for_api_changes() {
  echo "Waiting 15 seconds for API changes to propagate..."
  sleep 15
}

# Main execution
echo "Initializing API Gateway..."
init_api_gateway

# Get root resource
ROOT_RESOURCE_ID=$(aws apigateway get-resources \
  --rest-api-id "$API_ID" \
  --query "items[?path=='/'].id" \
  --output text \
  --region "$REGION" \
  --profile "$AWS_PROFILE")

# Create API structure
echo "Creating API structure..."
API_RESOURCE_ID=$(get_or_create_resource "$ROOT_RESOURCE_ID" "api")
V3_RESOURCE_ID=$(get_or_create_resource "$API_RESOURCE_ID" "v3")

# Configure all services
for service in "${!SERVICES[@]}"; do
  IFS='|' read -r ngrok_url swagger_path <<< "${SERVICES[$service]}"
  echo "Configuring $service service..."
  configure_service_proxy "$service" "$ngrok_url" "$swagger_path"
done

# Wait for changes to propagate
wait_for_api_changes

# Deploy API
echo "Deploying API..."
DEPLOYMENT_ID=$(aws apigateway create-deployment \
  --rest-api-id "$API_ID" \
  --stage-name "$STAGE_NAME" \
  --region "$REGION" \
  --profile "$AWS_PROFILE" \
  --output text \
  --query 'id')

INVOKE_URL="https://${API_ID}.execute-api.${REGION}.amazonaws.com/${STAGE_NAME}"

# Display results
echo -e "\nAPI Deployment Complete!"
echo "Invoke URL: $INVOKE_URL"

echo -e "\nService Routing Table:"
for service in "${!SERVICES[@]}"; do
  IFS='|' read -r ngrok_url swagger_path <<< "${SERVICES[$service]}"
  echo -e "\nService: $service"
  echo "API Endpoint: ${INVOKE_URL}/api/v3/${service}/{proxy+}"
  echo "Backend URL: ${ngrok_url}/{proxy}"
  if [ -n "$swagger_path" ]; then
    swagger_ui_path="${swagger_path%/*}"
    echo "Swagger UI: ${INVOKE_URL}/api/v3/${service}${swagger_ui_path}/index.html"
    echo "Swagger Assets: ${INVOKE_URL}/api/v3/${service}${swagger_ui_path}/{proxy+}"
    echo "Original Swagger: ${ngrok_url}${swagger_path}"
  fi
done

echo -e "\nAccess Swagger UIs using these exact URLs:"
for service in "${!SERVICES[@]}"; do
  IFS='|' read -r ngrok_url swagger_path <<< "${SERVICES[$service]}"
  if [ -n "$swagger_path" ]; then
    swagger_ui_path="${swagger_path%/*}"
    echo "${service}: ${INVOKE_URL}/api/v3/${service}${swagger_ui_path}/index.html"
  fi
done

echo -e "\nTroubleshooting Tips:"
echo "1. If you get 403 Forbidden errors, verify your ngrok endpoints are running and accessible"
echo "2. Check CloudWatch logs for detailed error information"
echo "3. The deployment might take 1-2 minutes to fully propagate"
echo "4. Verify CORS settings on your backend services if you get CORS errors"A?