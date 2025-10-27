#!/bin/bash

# Deploy Pixel Streaming Infrastructure on AWS using Modular Nested Stacks
# This script uploads nested templates to S3 and deploys the master stack

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deployment-config.json"
NESTED_STACKS_DIR="$SCRIPT_DIR/infra/nested-stacks"
LAMBDA_DIR="$SCRIPT_DIR/lambda-deployment"

# Parse command line arguments
SKIP_AMI_CHECK=false
FORCE_UPDATE=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --skip-ami-check)
            SKIP_AMI_CHECK=true
            shift
            ;;
        --force-update)
            FORCE_UPDATE=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --skip-ami-check    Skip checking for AMI availability"
            echo "  --force-update     Force update existing stack"
            echo "  --help             Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: Configuration file not found at $CONFIG_FILE${NC}"
    exit 1
fi

if [[ ! -d "$NESTED_STACKS_DIR" ]]; then
    echo -e "${RED}Error: Nested stacks directory not found at $NESTED_STACKS_DIR${NC}"
    exit 1
fi

# Parse configuration
REGION=$(jq -r '.deployment.region' "$CONFIG_FILE")
STACK_NAME=$(jq -r '.deployment.stackName' "$CONFIG_FILE")
SIGNALLING_AMI=$(jq -r '.infrastructure.signallingServerAMI // empty' "$CONFIG_FILE")
MATCHMAKER_AMI=$(jq -r '.infrastructure.matchmakerAMI // empty' "$CONFIG_FILE")
FRONTEND_AMI=$(jq -r '.infrastructure.frontendAMI // empty' "$CONFIG_FILE")

echo -e "${BLUE}=== Deploying Pixel Streaming Infrastructure (Modular Architecture) ===${NC}"
echo -e "${YELLOW}Region: $REGION${NC}"
echo -e "${YELLOW}Stack Name: $STACK_NAME${NC}"
echo ""

# Function to print status
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check prerequisites
print_status "Checking prerequisites..."

if ! command -v aws &> /dev/null; then
    print_error "AWS CLI is required but not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    print_error "jq is required but not installed"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured or invalid"
    exit 1
fi

# Check AMI IDs if not skipping
if [[ "$SKIP_AMI_CHECK" == false ]]; then
    if [[ -z "$SIGNALLING_AMI" || -z "$MATCHMAKER_AMI" || -z "$FRONTEND_AMI" ]]; then
        print_error "AMI IDs not found in configuration. Please run ./create-amis.sh first or use --skip-ami-check"
        exit 1
    fi
    
    print_status "Validating AMI availability..."
    
    # Check if AMIs exist and are available
    for ami_id in "$SIGNALLING_AMI" "$MATCHMAKER_AMI" "$FRONTEND_AMI"; do
        if ! aws ec2 describe-images --image-ids "$ami_id" --region "$REGION" &> /dev/null; then
            print_error "AMI $ami_id not found or not accessible"
            exit 1
        fi
    done
    
    print_status "AMI validation complete"
else
    # Use default AMIs from the original template
    SIGNALLING_AMI="ami-014fefbaf7bdafab3"
    MATCHMAKER_AMI="ami-0c284ed6bd6a72b4a"
    FRONTEND_AMI="ami-05422fc3670401f9a"
    print_warning "Using default AMIs from template (may not work correctly)"
fi

# Create S3 bucket for nested stack templates
print_status "Setting up S3 bucket for nested stack templates..."

# Generate unique bucket name
BUCKET_SUFFIX=$(openssl rand -hex 4)
S3_BUCKET="${STACK_NAME}-templates-${BUCKET_SUFFIX}"

# Create bucket with proper region configuration
if [[ "$REGION" == "us-east-1" ]]; then
    aws s3 mb "s3://$S3_BUCKET" --region "$REGION"
else
    aws s3 mb "s3://$S3_BUCKET" --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION"
fi

print_status "S3 bucket created: $S3_BUCKET"

# Upload nested stack templates to S3
print_status "Uploading nested stack templates to S3..."

NESTED_TEMPLATES=(
    "iam.yaml"
    "core-infrastructure.yaml" 
    "load-balancers.yaml"
    "compute.yaml"
    "serverless.yaml"
    "services.yaml"
)

for template in "${NESTED_TEMPLATES[@]}"; do
    if [[ -f "$NESTED_STACKS_DIR/$template" ]]; then
        print_status "Uploading $template..."
        aws s3 cp "$NESTED_STACKS_DIR/$template" "s3://$S3_BUCKET/nested-stacks/$template" --region "$REGION"
    else
        print_error "Template not found: $NESTED_STACKS_DIR/$template"
        exit 1
    fi
done

print_status "All nested templates uploaded successfully"

# Package Lambda functions
print_status "Packaging Lambda functions..."
chmod +x "$LAMBDA_DIR/package-lambda.sh"
"$LAMBDA_DIR/package-lambda.sh"

# Check if stack exists
STACK_EXISTS=false
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null; then
    STACK_EXISTS=true
    print_status "Stack $STACK_NAME already exists"
    
    if [[ "$FORCE_UPDATE" == false ]]; then
        read -p "Do you want to update the existing stack? (y/N): " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            print_status "Deployment cancelled"
            exit 0
        fi
    fi
fi

# Prepare CloudFormation parameters
CF_PARAMETERS="ParameterKey=SignallingServerAMI,ParameterValue=$SIGNALLING_AMI"
CF_PARAMETERS="$CF_PARAMETERS ParameterKey=MatchmakerAMI,ParameterValue=$MATCHMAKER_AMI"
CF_PARAMETERS="$CF_PARAMETERS ParameterKey=FrontEndAMI,ParameterValue=$FRONTEND_AMI"
CF_PARAMETERS="$CF_PARAMETERS ParameterKey=StackName,ParameterValue=$STACK_NAME"
CF_PARAMETERS="$CF_PARAMETERS ParameterKey=NestedStacksS3Bucket,ParameterValue=$S3_BUCKET"

# Deploy or update CloudFormation stack
if [[ "$STACK_EXISTS" == true ]]; then
    print_status "Updating CloudFormation master stack..."
    aws cloudformation update-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://"$NESTED_STACKS_DIR/master.yaml" \
        --parameters $CF_PARAMETERS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"
    
    print_status "Waiting for stack update to complete (this may take 10-15 minutes)..."
    aws cloudformation wait stack-update-complete --stack-name "$STACK_NAME" --region "$REGION"
else
    print_status "Creating CloudFormation master stack..."
    aws cloudformation create-stack \
        --stack-name "$STACK_NAME" \
        --template-body file://"$NESTED_STACKS_DIR/master.yaml" \
        --parameters $CF_PARAMETERS \
        --capabilities CAPABILITY_NAMED_IAM \
        --region "$REGION"
    
    print_status "Waiting for stack creation to complete (this may take 15-20 minutes)..."
    aws cloudformation wait stack-create-complete --stack-name "$STACK_NAME" --region "$REGION"
fi

# Get stack outputs
print_status "Retrieving stack outputs..."
STACK_OUTPUTS=$(aws cloudformation describe-stacks \
    --stack-name "$STACK_NAME" \
    --region "$REGION" \
    --query 'Stacks[0].Outputs')

# Extract important outputs
COGNITO_CLIENT_ID=$(echo "$STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="CognitoClientID") | .OutputValue')
COGNITO_DOMAIN_URL=$(echo "$STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="CognitoDomainURL") | .OutputValue')
COGNITO_CALLBACK_URL=$(echo "$STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="CognitoCallBackURL") | .OutputValue')
API_GATEWAY_WS=$(echo "$STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="APIGatewayWSAPI") | .OutputValue')
SIGNALLING_WS=$(echo "$STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="SignallingServerWSAPI") | .OutputValue')
CLOUDFRONT_DOMAIN=$(echo "$STACK_OUTPUTS" | jq -r '.[] | select(.OutputKey=="CloudFrontDomainName") | .OutputValue')

print_status "CloudFormation deployment complete!"

# Update Lambda functions with actual code
print_status "Updating Lambda functions with repository code..."

LAMBDA_FUNCTIONS=(
    "${STACK_NAME}-authorizeClient"
    "${STACK_NAME}-createInstances" 
    "${STACK_NAME}-keepConnectionAlive"
    "${STACK_NAME}-poller"
    "${STACK_NAME}-registerInstances"
    "${STACK_NAME}-requestSession"
    "${STACK_NAME}-sendSessionDetails"
    "${STACK_NAME}-terminateInstance"
    "${STACK_NAME}-uploadToDDB"
)

for func in "${LAMBDA_FUNCTIONS[@]}"; do
    # Extract original function name for package lookup
    original_func=$(echo "$func" | sed "s/${STACK_NAME}-//")
    
    if [[ -f "$LAMBDA_DIR/packages/$original_func.zip" ]]; then
        print_status "Updating Lambda function: $func"
        aws lambda update-function-code \
            --function-name "$func" \
            --zip-file fileb://"$LAMBDA_DIR/packages/$original_func.zip" \
            --region "$REGION" &> /dev/null || print_warning "Failed to update $func"
    else
        print_warning "Package not found for $original_func"
    fi
done

print_status "Lambda functions updated"

# Initialize DynamoDB
print_status "Initializing DynamoDB..."
aws lambda invoke \
    --function-name "${STACK_NAME}-uploadToDDB" \
    --region "$REGION" \
    /tmp/uploadToDDB-response.json &> /dev/null || print_warning "Failed to initialize DynamoDB"

print_status "DynamoDB initialization attempted"

# Get Cognito client secret (requires manual retrieval for generated secrets)
print_status "Retrieving Cognito client secret..."

# Try to get the client secret programmatically
USER_POOL_ID=$(aws cognito-idp list-user-pools --max-items 10 --region "$REGION" --query "UserPools[?contains(Name, '${STACK_NAME}')].Id | [0]" --output text)

if [[ "$USER_POOL_ID" != "None" && -n "$USER_POOL_ID" ]]; then
    CLIENT_SECRET=$(aws cognito-idp describe-user-pool-client \
        --user-pool-id "$USER_POOL_ID" \
        --client-id "$COGNITO_CLIENT_ID" \
        --region "$REGION" \
        --query 'UserPoolClient.ClientSecret' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$CLIENT_SECRET" && "$CLIENT_SECRET" != "None" ]]; then
        print_status "Cognito client secret retrieved"
    else
        print_warning "Could not retrieve client secret automatically"
        CLIENT_SECRET="MANUAL_RETRIEVAL_REQUIRED"
    fi
else
    print_warning "Could not find user pool"
    CLIENT_SECRET="MANUAL_RETRIEVAL_REQUIRED"
fi

# Save deployment information
cat > "deployment-info.json" << EOF
{
  "deployment_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "$REGION",
  "stack_name": "$STACK_NAME",
  "architecture": "modular_nested_stacks",
  "s3_bucket": "$S3_BUCKET",
  "outputs": {
    "cloudfront_domain": "$CLOUDFRONT_DOMAIN",
    "cognito_client_id": "$COGNITO_CLIENT_ID",
    "cognito_domain_url": "$COGNITO_DOMAIN_URL",
    "cognito_callback_url": "$COGNITO_CALLBACK_URL",
    "cognito_client_secret": "$CLIENT_SECRET",
    "api_gateway_ws": "$API_GATEWAY_WS",
    "signalling_ws": "$SIGNALLING_WS"
  },
  "amis": {
    "signalling_server": "$SIGNALLING_AMI",
    "matchmaker": "$MATCHMAKER_AMI",
    "frontend": "$FRONTEND_AMI"
  }
}
EOF

print_status "Deployment information saved to deployment-info.json"

# Configure frontend if we have an instance
print_status "Checking for frontend instance to configure..."

FRONTEND_INSTANCE_ID=$(aws ec2 describe-instances \
    --region "$REGION" \
    --filters "Name=tag:Name,Values=${STACK_NAME}-Frontend-Instance" "Name=instance-state-name,Values=running" \
    --query 'Reservations[0].Instances[0].InstanceId' \
    --output text 2>/dev/null || echo "None")

if [[ "$FRONTEND_INSTANCE_ID" != "None" && -n "$FRONTEND_INSTANCE_ID" ]]; then
    print_status "Found frontend instance: $FRONTEND_INSTANCE_ID"
    
    if [[ "$CLIENT_SECRET" != "MANUAL_RETRIEVAL_REQUIRED" ]]; then
        print_status "Configuring frontend environment variables..."
        
        # Create temporary script to configure frontend
        cat > /tmp/configure-frontend.sh << EOF
#!/bin/bash
/usr/customapps/pixelstreaming/configure-frontend-env.sh \\
    "$COGNITO_CLIENT_ID" \\
    "$COGNITO_DOMAIN_URL" \\
    "$CLIENT_SECRET" \\
    "$COGNITO_CALLBACK_URL" \\
    "$API_GATEWAY_WS" \\
    "$SIGNALLING_WS" \\
    "somethingsecret"
EOF
        
        # Execute via SSM if possible
        if aws ssm describe-instance-information --region "$REGION" --filters "Name=InstanceIds,Values=$FRONTEND_INSTANCE_ID" &> /dev/null; then
            print_status "Configuring frontend via SSM..."
            
            COMMAND_ID=$(aws ssm send-command \
                --region "$REGION" \
                --document-name "AWS-RunShellScript" \
                --instance-ids "$FRONTEND_INSTANCE_ID" \
                --parameters "commands=[\"$(cat /tmp/configure-frontend.sh | tr '\n' ' ')\"]" \
                --query 'Command.CommandId' \
                --output text)
            
            # Wait for command to complete
            sleep 30
            print_status "Frontend configuration command sent: $COMMAND_ID"
        else
            print_warning "SSM not available for frontend configuration"
            print_warning "Please manually configure frontend with the values in deployment-info.json"
        fi
    else
        print_warning "Frontend configuration skipped - client secret requires manual retrieval"
    fi
else
    print_warning "No running frontend instance found"
fi

print_status "Modular infrastructure deployment complete!"
echo ""
echo -e "${GREEN}=== Deployment Summary ===${NC}"
echo -e "CloudFormation Stack: ${BLUE}$STACK_NAME${NC} (Modular Architecture)"
echo -e "Region: ${BLUE}$REGION${NC}"
echo -e "S3 Bucket: ${BLUE}$S3_BUCKET${NC}"
echo ""
echo -e "${GREEN}=== Access Information ===${NC}"
echo -e "Frontend URL: ${BLUE}https://$CLOUDFRONT_DOMAIN${NC}"
echo -e "Cognito Domain: ${BLUE}$COGNITO_DOMAIN_URL${NC}"
echo -e "Client ID: ${BLUE}$COGNITO_CLIENT_ID${NC}"
echo -e "API Gateway WebSocket: ${BLUE}$API_GATEWAY_WS${NC}"
echo -e "Signalling WebSocket: ${BLUE}$SIGNALLING_WS${NC}"
echo ""

if [[ "$CLIENT_SECRET" == "MANUAL_RETRIEVAL_REQUIRED" ]]; then
    echo -e "${YELLOW}=== Manual Steps Required ===${NC}"
    echo -e "1. Go to AWS Cognito Console"
    echo -e "2. Find user pool: ${BLUE}${STACK_NAME}-authentication-pool${NC}"
    echo -e "3. Go to App Integration -> App clients"
    echo -e "4. Click on your app client"
    echo -e "5. Retrieve the client secret"
    echo -e "6. Update frontend configuration manually"
    echo ""
fi

echo -e "${YELLOW}Next steps:${NC}"
echo -e "1. Run ${BLUE}./create-user.sh${NC} to create a test user"
echo -e "2. Access the application via: ${BLUE}https://$CLOUDFRONT_DOMAIN${NC}"
echo -e "3. Check CloudWatch logs for any issues"
echo ""

echo -e "${GREEN}=== Architecture Benefits ===${NC}"
echo -e "✅ Modular design - each component in separate stack"
echo -e "✅ Size compliant - no more 51KB CloudFormation limit issues"
echo -e "✅ Maintainable - easy to update individual components"
echo -e "✅ Reusable - components can be reused across deployments"
echo ""

# Cleanup temporary files
rm -f /tmp/configure-frontend.sh /tmp/uploadToDDB-response.json

print_status "🎉 AWS's broken template is now FIXED and deployable!"
