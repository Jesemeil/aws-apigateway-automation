#!/bin/bash

# Configuration (must match your create script)
AWS_PROFILE="semicolon"
API_NAME="EnumMicroservicesGateway"
STAGE_NAME="systest"
REGION="us-east-1"

# Function to delete all resources recursively
delete_resources() {
  local rest_api_id=$1
  local parent_id=$2

  # Get all child resources
  child_resources=$(aws apigateway get-resources \
    --rest-api-id "$rest_api_id" \
    --query "items[?parentId=='$parent_id'].id" \
    --output text \
    --region "$REGION" \
    --profile "$AWS_PROFILE")

  # Recursively delete child resources first
  for resource_id in $child_resources; do
    delete_resources "$rest_api_id" "$resource_id"
  done

  # Delete the current resource (if not root)
  if [ "$parent_id" != "null" ]; then
    echo "Deleting resource ID: $parent_id"
    aws apigateway delete-resource \
      --rest-api-id "$rest_api_id" \
      --resource-id "$parent_id" \
      --region "$REGION" \
      --profile "$AWS_PROFILE"
  fi
}

# Main execution
echo "Starting tear down of $API_NAME..."

# Get API ID
API_ID=$(aws apigateway get-rest-apis \
  --query "items[?name=='$API_NAME'].id" \
  --output text \
  --region "$REGION" \
  --profile "$AWS_PROFILE")

if [ -z "$API_ID" ]; then
  echo "API $API_NAME not found. Nothing to delete."
  exit 0
fi

echo "Found API ID: $API_ID"

# Delete deployments first
echo "Deleting deployments..."
deployments=$(aws apigateway get-deployments \
  --rest-api-id "$API_ID" \
  --query "items[].id" \
  --output text \
  --region "$REGION" \
  --profile "$AWS_PROFILE")

for deployment_id in $deployments; do
  echo "Deleting deployment: $deployment_id"
  aws apigateway delete-deployment \
    --rest-api-id "$API_ID" \
    --deployment-id "$deployment_id" \
    --region "$REGION" \
    --profile "$AWS_PROFILE"
done

# Delete stages
echo "Deleting stage: $STAGE_NAME"
aws apigateway delete-stage \
  --rest-api-id "$API_ID" \
  --stage-name "$STAGE_NAME" \
  --region "$REGION" \
  --profile "$AWS_PROFILE"

# Delete all resources (recursive)
echo "Deleting all resources..."
delete_resources "$API_ID" "null"

# Finally delete the REST API
echo "Deleting REST API: $API_ID"
aws apigateway delete-rest-api \
  --rest-api-id "$API_ID" \
  --region "$REGION" \
  --profile "$AWS_PROFILE"

echo "Tear down complete. All resources for $API_NAME have been deleted."