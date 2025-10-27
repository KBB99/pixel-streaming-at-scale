#!/bin/bash

# Create a test user in Cognito User Pool
# This script creates a user that can be used to test the pixel streaming application

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
DEPLOYMENT_INFO_FILE="$SCRIPT_DIR/deployment-info.json"

# Parse command line arguments
USERNAME=""
EMAIL=""
PASSWORD=""
TEMP_PASSWORD=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --username)
            USERNAME="$2"
            shift 2
            ;;
        --email)
            EMAIL="$2"
            shift 2
            ;;
        --password)
            PASSWORD="$2"
            shift 2
            ;;
        --temp-password)
            TEMP_PASSWORD=true
            shift
            ;;
        --help)
            echo "Usage: $0 [OPTIONS]"
            echo "Options:"
            echo "  --username <username>    Username for the new user"
            echo "  --email <email>         Email address for the new user"
            echo "  --password <password>   Password for the new user"
            echo "  --temp-password         Create user with temporary password"
            echo "  --help                  Show this help message"
            echo ""
            echo "If no options are provided, values from deployment-config.json will be used"
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

# Parse configuration
REGION=$(jq -r '.deployment.region' "$CONFIG_FILE")

# Use config values if not provided via command line
if [[ -z "$USERNAME" ]]; then
    USERNAME=$(jq -r '.testUser.username' "$CONFIG_FILE")
fi

if [[ -z "$EMAIL" ]]; then
    EMAIL=$(jq -r '.testUser.email' "$CONFIG_FILE")
fi

if [[ -z "$PASSWORD" ]]; then
    PASSWORD=$(jq -r '.testUser.password' "$CONFIG_FILE")
fi

echo -e "${BLUE}=== Creating Test User in Cognito ===${NC}"
echo -e "${YELLOW}Region: $REGION${NC}"
echo -e "${YELLOW}Username: $USERNAME${NC}"
echo -e "${YELLOW}Email: $EMAIL${NC}"
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

# Validate inputs
if [[ -z "$USERNAME" || -z "$EMAIL" || -z "$PASSWORD" ]]; then
    print_error "Username, email, and password are required"
    exit 1
fi

# Find the user pool
print_status "Finding Cognito User Pool..."

USER_POOL_ID=$(aws cognito-idp list-user-pools --max-items 10 --region "$REGION" --query "UserPools[?Name=='ueauthenticationpool'].Id | [0]" --output text)

if [[ "$USER_POOL_ID" == "None" || -z "$USER_POOL_ID" ]]; then
    print_error "User pool 'ueauthenticationpool' not found. Make sure the infrastructure is deployed."
    exit 1
fi

print_status "Found user pool: $USER_POOL_ID"

# Check if user already exists
print_status "Checking if user already exists..."

if aws cognito-idp admin-get-user --user-pool-id "$USER_POOL_ID" --username "$USERNAME" --region "$REGION" &> /dev/null; then
    print_warning "User $USERNAME already exists"
    
    read -p "Do you want to delete and recreate the user? (y/N): " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        print_status "Deleting existing user..."
        aws cognito-idp admin-delete-user \
            --user-pool-id "$USER_POOL_ID" \
            --username "$USERNAME" \
            --region "$REGION"
        print_status "User deleted"
    else
        print_status "User creation cancelled"
        exit 0
    fi
fi

# Create the user
print_status "Creating user..."

if [[ "$TEMP_PASSWORD" == true ]]; then
    # Create user with temporary password (user must change on first login)
    aws cognito-idp admin-create-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$USERNAME" \
        --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
        --temporary-password "$PASSWORD" \
        --message-action SUPPRESS \
        --region "$REGION"
    
    print_status "User created with temporary password"
else
    # Create user with permanent password
    aws cognito-idp admin-create-user \
        --user-pool-id "$USER_POOL_ID" \
        --username "$USERNAME" \
        --user-attributes Name=email,Value="$EMAIL" Name=email_verified,Value=true \
        --temporary-password "$PASSWORD" \
        --message-action SUPPRESS \
        --region "$REGION"
    
    # Set permanent password
    aws cognito-idp admin-set-user-password \
        --user-pool-id "$USER_POOL_ID" \
        --username "$USERNAME" \
        --password "$PASSWORD" \
        --permanent \
        --region "$REGION"
    
    print_status "User created with permanent password"
fi

# Get the hosted UI URL if deployment info exists
HOSTED_UI_URL=""
if [[ -f "$DEPLOYMENT_INFO_FILE" ]]; then
    COGNITO_DOMAIN_URL=$(jq -r '.outputs.cognito_domain_url' "$DEPLOYMENT_INFO_FILE")
    if [[ "$COGNITO_DOMAIN_URL" != "null" && -n "$COGNITO_DOMAIN_URL" ]]; then
        HOSTED_UI_URL="$COGNITO_DOMAIN_URL/login"
    fi
fi

# Create user info file
cat > "user-credentials.json" << EOF
{
  "creation_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "$REGION",
  "user_pool_id": "$USER_POOL_ID",
  "user": {
    "username": "$USERNAME",
    "email": "$EMAIL",
    "password": "$PASSWORD",
    "temporary_password": $TEMP_PASSWORD
  },
  "hosted_ui_url": "$HOSTED_UI_URL"
}
EOF

print_status "User creation complete!"
echo ""
echo -e "${GREEN}=== User Credentials ===${NC}"
echo -e "Username: ${BLUE}$USERNAME${NC}"
echo -e "Email: ${BLUE}$EMAIL${NC}"
echo -e "Password: ${BLUE}$PASSWORD${NC}"

if [[ "$TEMP_PASSWORD" == true ]]; then
    echo -e "Password Type: ${YELLOW}Temporary (must be changed on first login)${NC}"
else
    echo -e "Password Type: ${GREEN}Permanent${NC}"
fi

echo ""

if [[ -n "$HOSTED_UI_URL" ]]; then
    echo -e "${GREEN}=== Access Information ===${NC}"
    echo -e "Hosted UI URL: ${BLUE}$HOSTED_UI_URL${NC}"
    echo ""
    echo -e "${YELLOW}Instructions:${NC}"
    echo -e "1. Open the Hosted UI URL in your browser"
    echo -e "2. Click 'Sign in'"
    echo -e "3. Enter your username and password"
    
    if [[ "$TEMP_PASSWORD" == true ]]; then
        echo -e "4. You will be prompted to set a new password"
        echo -e "5. After setting new password, you can access the application"
    else
        echo -e "4. You should be redirected to the pixel streaming application"
    fi
else
    echo -e "${YELLOW}Note:${NC} To get the hosted UI URL, make sure the infrastructure is deployed"
    echo -e "Run ${BLUE}./deploy-infrastructure.sh${NC} if you haven't already"
fi

echo ""
echo -e "User credentials saved to: ${BLUE}user-credentials.json${NC}"
echo ""

# Test user authentication (optional)
print_status "Testing user authentication..."

# Get the app client ID
if [[ -f "$DEPLOYMENT_INFO_FILE" ]]; then
    CLIENT_ID=$(jq -r '.outputs.cognito_client_id' "$DEPLOYMENT_INFO_FILE")
    
    if [[ "$CLIENT_ID" != "null" && -n "$CLIENT_ID" ]]; then
        # Try to initiate auth (this will validate the user exists and password is correct)
        if aws cognito-idp admin-initiate-auth \
            --user-pool-id "$USER_POOL_ID" \
            --client-id "$CLIENT_ID" \
            --auth-flow ADMIN_NO_SRP_AUTH \
            --auth-parameters USERNAME="$USERNAME",PASSWORD="$PASSWORD" \
            --region "$REGION" &> /dev/null; then
            print_status "User authentication test successful"
        else
            print_warning "User authentication test failed (this might be expected for temporary passwords)"
        fi
    else
        print_warning "Client ID not found - skipping authentication test"
    fi
else
    print_warning "Deployment info not found - skipping authentication test"
fi

print_status "User setup complete!"
