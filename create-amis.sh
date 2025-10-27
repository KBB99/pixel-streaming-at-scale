#!/bin/bash

# Create AMIs for Pixel Streaming components
# This script creates EC2 instances, deploys code, and creates AMIs

set -e

# Disable AWS CLI paging for automation
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deployment-config.json"
EPIC_DIR="$SCRIPT_DIR/epic-infrastructure"
USERDATA_DIR="$SCRIPT_DIR/ami-userdata"

# S3 bucket for deployment artifacts (will be created)
S3_BUCKET=""

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: Configuration file not found at $CONFIG_FILE${NC}"
    exit 1
fi

if [[ ! -d "$EPIC_DIR" ]]; then
    echo -e "${RED}Error: Epic infrastructure not found. Please run ./setup-epic-infrastructure.sh first${NC}"
    exit 1
fi

# Parse configuration
REGION=$(jq -r '.deployment.region' "$CONFIG_FILE")
KEY_PAIR=$(jq -r '.deployment.keyPairName' "$CONFIG_FILE")
BASE_AMI=$(jq -r '.infrastructure.baseAmiId' "$CONFIG_FILE")
BUILD_INSTANCE_TYPE=$(jq -r '.infrastructure.buildInstanceType' "$CONFIG_FILE")
STACK_NAME=$(jq -r '.deployment.stackName' "$CONFIG_FILE")

echo -e "${BLUE}=== Creating AMIs for Pixel Streaming Components ===${NC}"
echo -e "${YELLOW}Region: $REGION${NC}"
echo -e "${YELLOW}Base AMI: $BASE_AMI${NC}"
echo -e "${YELLOW}Instance Type: $BUILD_INSTANCE_TYPE${NC}"
echo ""

# Function to print status
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
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

if ! command -v ssh &> /dev/null; then
    print_error "ssh is required but not installed"
    exit 1
fi

# Check AWS credentials
if ! aws sts get-caller-identity &> /dev/null; then
    print_error "AWS credentials not configured or invalid"
    exit 1
fi

# Check if key pair exists
if ! aws ec2 describe-key-pairs --key-names "$KEY_PAIR" --region "$REGION" &> /dev/null; then
    print_warning "Key pair '$KEY_PAIR' not found. Creating it..."
    aws ec2 create-key-pair --key-name "$KEY_PAIR" --region "$REGION" --query 'KeyMaterial' --output text > "${KEY_PAIR}.pem"
    chmod 400 "${KEY_PAIR}.pem"
    print_status "Key pair created and saved as ${KEY_PAIR}.pem"
fi

# Create IAM role for EC2 instances to access S3
IAM_ROLE_NAME="${STACK_NAME}-ami-builder-role"
IAM_INSTANCE_PROFILE_NAME="${STACK_NAME}-ami-builder-profile"

print_status "Creating IAM role for S3 access..."

# Create trust policy for EC2
cat > /tmp/trust-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Principal": {
                "Service": "ec2.amazonaws.com"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF

# Create IAM role (ignore error if it already exists)
aws iam create-role --role-name "$IAM_ROLE_NAME" --assume-role-policy-document file:///tmp/trust-policy.json --region "$REGION" &> /dev/null || true

# Create S3 access policy
cat > /tmp/s3-policy.json << EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "s3:GetObject",
                "s3:ListBucket"
            ],
            "Resource": [
                "arn:aws:s3:::*"
            ]
        }
    ]
}
EOF

# Attach S3 policy to role
aws iam put-role-policy --role-name "$IAM_ROLE_NAME" --policy-name "S3AccessPolicy" --policy-document file:///tmp/s3-policy.json --region "$REGION"

# Create instance profile (ignore error if it already exists)
aws iam create-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --region "$REGION" &> /dev/null || true

# Add role to instance profile (ignore error if already added)
aws iam add-role-to-instance-profile --instance-profile-name "$IAM_INSTANCE_PROFILE_NAME" --role-name "$IAM_ROLE_NAME" --region "$REGION" &> /dev/null || true

# Wait for instance profile to be ready
sleep 10

print_status "IAM role and instance profile created for S3 access"

# Cleanup temp files
rm -f /tmp/trust-policy.json /tmp/s3-policy.json

# Create temporary security group for AMI creation
TEMP_SG_NAME="temp-ami-creation-sg-$(date +%s)"
print_status "Creating temporary security group: $TEMP_SG_NAME"

# Get default VPC ID
DEFAULT_VPC=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=is-default,Values=true" --query 'Vpcs[0].VpcId' --output text)

if [[ "$DEFAULT_VPC" == "None" ]]; then
    print_error "No default VPC found. Please ensure you have a default VPC in the region."
    exit 1
fi

TEMP_SG_ID=$(aws ec2 create-security-group \
    --group-name "$TEMP_SG_NAME" \
    --description "Temporary security group for AMI creation" \
    --vpc-id "$DEFAULT_VPC" \
    --region "$REGION" \
    --query 'GroupId' \
    --output text)

# Add SSH access to security group
aws ec2 authorize-security-group-ingress \
    --group-id "$TEMP_SG_ID" \
    --protocol tcp \
    --port 22 \
    --cidr 0.0.0.0/0 \
    --region "$REGION"

# Add HTTP/HTTPS access for testing
aws ec2 authorize-security-group-ingress \
    --group-id "$TEMP_SG_ID" \
    --protocol tcp \
    --port 80 \
    --cidr 0.0.0.0/0 \
    --region "$REGION"

aws ec2 authorize-security-group-ingress \
    --group-id "$TEMP_SG_ID" \
    --protocol tcp \
    --port 443 \
    --cidr 0.0.0.0/0 \
    --region "$REGION"

# Add application-specific ports
aws ec2 authorize-security-group-ingress \
    --group-id "$TEMP_SG_ID" \
    --protocol tcp \
    --port 8080 \
    --cidr 0.0.0.0/0 \
    --region "$REGION"

aws ec2 authorize-security-group-ingress \
    --group-id "$TEMP_SG_ID" \
    --protocol tcp \
    --port 90 \
    --cidr 0.0.0.0/0 \
    --region "$REGION"

print_status "Security group created: $TEMP_SG_ID"

# Function to validate IP address format
validate_ip() {
    local ip="$1"
    if [[ $ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        return 0
    else
        return 1
    fi
}

# Function to wait for instance to be running and accessible
wait_for_instance() {
    local instance_id=$1
    local instance_name=$2
    
    print_status "Waiting for $instance_name ($instance_id) to be running..."
    aws ec2 wait instance-running --instance-ids "$instance_id" --region "$REGION"
    
    # Get public IP with proper handling of edge cases
    local raw_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    # Debug output to see what AWS returns
    print_status "Raw IP from AWS: '$raw_ip'"
    
    # Handle AWS CLI returning "None" or null
    if [[ "$raw_ip" == "None" || "$raw_ip" == "null" || -z "$raw_ip" ]]; then
        print_error "No public IP address assigned to instance $instance_id"
        return 1
    fi
    
    # Extract IP using grep to ensure we get a valid IP format
    local public_ip=$(echo "$raw_ip" | grep -oE '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | head -1)
    
    # Validate the extracted IP
    if ! validate_ip "$public_ip"; then
        print_error "Invalid IP address format received: '$public_ip' (raw: '$raw_ip')"
        return 1
    fi
    
    print_status "$instance_name public IP: $public_ip"
    
    # Wait for SSH to be available
    print_status "Waiting for SSH to be available on $instance_name..."
    local max_attempts=30
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
        if ssh -i "${KEY_PAIR}.pem" -o StrictHostKeyChecking=no -o ConnectTimeout=10 ec2-user@"$public_ip" 'echo "SSH connected"' &> /dev/null; then
            print_status "SSH connection to $instance_name established"
            break
        fi
        
        echo -n "."
        sleep 10
        ((attempt++))
    done
    
    if [ $attempt -gt $max_attempts ]; then
        print_error "Failed to establish SSH connection to $instance_name"
        return 1
    fi
    
    echo "$public_ip"
}

# Function to deploy code to instance (S3-based - much faster!)
deploy_code() {
    local public_ip=$1
    local component=$2
    local userdata_script=$3
    
    print_status "Deploying $component via S3 (fast method) to $public_ip..."
    
    # Create temporary userdata script with S3 bucket information
    local temp_userdata=$(mktemp)
    
    # Add S3 bucket environment variable to userdata script
    {
        echo "#!/bin/bash"
        echo "export S3_BUCKET='$S3_BUCKET'"
        echo "export AWS_REGION='$REGION'"
        echo "export COMPONENT_NAME='$component'"
        echo ""
        cat "$userdata_script"
    } > "$temp_userdata"
    
    # Copy modified userdata script (only small script, not entire codebase)
    scp -i "${KEY_PAIR}.pem" -o StrictHostKeyChecking=no "$temp_userdata" ec2-user@"$public_ip":/tmp/userdata.sh
    
    # Run userdata script (which will download from S3 internally)
    ssh -i "${KEY_PAIR}.pem" -o StrictHostKeyChecking=no ec2-user@"$public_ip" 'sudo chmod +x /tmp/userdata.sh && sudo /tmp/userdata.sh'
    
    # Cleanup temp file
    rm -f "$temp_userdata"
    
    print_status "$component deployment complete (downloaded from S3)"
}

# Function to create S3 bucket for deployment artifacts
create_s3_bucket() {
    print_status "Creating S3 bucket for deployment artifacts..."
    
    # Generate unique bucket name
    local timestamp=$(date +%s)
    local random_suffix=$(openssl rand -hex 4)
    S3_BUCKET="${STACK_NAME}-deploy-${timestamp}-${random_suffix}"
    
    # Create bucket with proper region configuration
    if [[ "$REGION" == "us-east-1" ]]; then
        aws s3 mb "s3://$S3_BUCKET" --region "$REGION"
    else
        aws s3 mb "s3://$S3_BUCKET" --region "$REGION" --create-bucket-configuration LocationConstraint="$REGION"
    fi
    
    # Enable versioning for better artifact management
    aws s3api put-bucket-versioning --bucket "$S3_BUCKET" --versioning-configuration Status=Enabled --region "$REGION"
    
    print_status "S3 bucket created: $S3_BUCKET"
}

# Function to upload Epic infrastructure to S3
upload_to_s3() {
    print_status "Uploading Epic infrastructure to S3 (this replaces slow SCP transfers)..."
    
    # Upload the entire epic-infrastructure directory to S3
    aws s3 sync "$EPIC_DIR/" "s3://$S3_BUCKET/epic-infrastructure/" --region "$REGION" --delete
    
    print_status "Epic infrastructure uploaded to S3"
    print_status "All instances will now download from S3 instead of using SCP"
}

# Function to create AMI from instance
create_ami() {
    local instance_id=$1
    local component=$2
    local description="$3"
    
    print_status "Creating AMI for $component..."
    
    local ami_name="${STACK_NAME}-${component}-$(date +%Y%m%d-%H%M%S)"
    
    local ami_id=$(aws ec2 create-image \
        --instance-id "$instance_id" \
        --name "$ami_name" \
        --description "$description" \
        --region "$REGION" \
        --no-reboot \
        --query 'ImageId' \
        --output text)
    
    print_status "AMI creation initiated: $ami_id"
    
    # Wait for AMI to be available
    print_status "Waiting for AMI to be available..."
    aws ec2 wait image-available --image-ids "$ami_id" --region "$REGION"
    
    print_status "AMI ready: $ami_id"
    echo "$ami_id"
}

# Arrays to store instance IDs and AMI IDs
declare -a INSTANCE_IDS
declare -a AMI_IDS

# Individual variables for AMI IDs (compatible with older bash)
SIGNALLING_AMI=""
MATCHMAKER_AMI=""
FRONTEND_AMI=""

# Cleanup function
cleanup() {
    print_status "Cleaning up temporary resources..."
    
    # Terminate instances
    for instance_id in "${INSTANCE_IDS[@]}"; do
        if [[ -n "$instance_id" ]]; then
            print_status "Terminating instance: $instance_id"
            aws ec2 terminate-instances --instance-ids "$instance_id" --region "$REGION" &> /dev/null || true
        fi
    done
    
    # Wait a bit for instances to start terminating
    sleep 30
    
    # Delete security group
    if [[ -n "$TEMP_SG_ID" ]]; then
        print_status "Deleting temporary security group: $TEMP_SG_ID"
        aws ec2 delete-security-group --group-id "$TEMP_SG_ID" --region "$REGION" &> /dev/null || true
    fi
}

# Set trap for cleanup
trap cleanup EXIT

# Component definitions (bash compatible)
SIGNALLING_USERDATA="$USERDATA_DIR/signalling-server-userdata.sh"
MATCHMAKER_USERDATA="$USERDATA_DIR/matchmaker-userdata.sh"
FRONTEND_USERDATA="$USERDATA_DIR/frontend-userdata.sh"

# Component list for iteration
COMPONENT_LIST="SignallingWebServer Matchmaker Frontend"

# === S3 ACCELERATION SETUP (replaces slow SCP transfers) ===
print_status "Setting up S3-based deployment (eliminates slow SCP transfers)..."

# Create S3 bucket for deployment artifacts
create_s3_bucket

# Upload Epic infrastructure to S3 once (instead of SCP'ing to each instance)
upload_to_s3

print_status "S3 setup complete - all instances will now download from S3"
echo ""

# Create AMIs for each component
for component in $COMPONENT_LIST; do
    case $component in
        "SignallingWebServer")
            userdata_script="$SIGNALLING_USERDATA"
            ;;
        "Matchmaker")
            userdata_script="$MATCHMAKER_USERDATA"
            ;;
        "Frontend")
            userdata_script="$FRONTEND_USERDATA"
            ;;
        *)
            print_error "Unknown component: $component"
            continue
            ;;
    esac
    
    if [[ ! -f "$userdata_script" ]]; then
        print_error "User data script not found: $userdata_script"
        continue
    fi
    
    print_status "Creating AMI for $component..."
    
    # Launch instance with IAM instance profile for S3 access
    instance_id=$(aws ec2 run-instances \
        --image-id "$BASE_AMI" \
        --count 1 \
        --instance-type "$BUILD_INSTANCE_TYPE" \
        --key-name "$KEY_PAIR" \
        --security-group-ids "$TEMP_SG_ID" \
        --iam-instance-profile Name="$IAM_INSTANCE_PROFILE_NAME" \
        --region "$REGION" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-${component}-builder},{Key=Purpose,Value=AMI-Creation}]" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    INSTANCE_IDS+=("$instance_id")
    print_status "$component instance launched: $instance_id"
    
    # Wait for instance to be ready
    public_ip=$(wait_for_instance "$instance_id" "$component")
    
    # Deploy code and configure instance
    deploy_code "$public_ip" "$component" "$userdata_script"
    
    # Create AMI
    ami_id=$(create_ami "$instance_id" "$component" "Pixel Streaming $component AMI")
    
    # Store AMI ID in appropriate variable
    case $component in
        "SignallingWebServer")
            SIGNALLING_AMI="$ami_id"
            ;;
        "Matchmaker")
            MATCHMAKER_AMI="$ami_id"
            ;;
        "Frontend")
            FRONTEND_AMI="$ami_id"
            ;;
    esac
    
    print_status "$component AMI created: $ami_id"
    echo ""
done

# Save AMI IDs to configuration file
print_status "Updating configuration with new AMI IDs..."

# Create a temporary config with the AMI IDs
temp_config=$(mktemp)
jq --arg signalling_ami "$SIGNALLING_AMI" \
   --arg matchmaker_ami "$MATCHMAKER_AMI" \
   --arg frontend_ami "$FRONTEND_AMI" \
   '.infrastructure.signallingServerAMI = $signalling_ami | 
    .infrastructure.matchmakerAMI = $matchmaker_ami | 
    .infrastructure.frontendAMI = $frontend_ami' \
   "$CONFIG_FILE" > "$temp_config"

mv "$temp_config" "$CONFIG_FILE"

# Create AMI output file
cat > "ami-ids.json" << EOF
{
  "creation_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "region": "$REGION",
  "stack_name": "$STACK_NAME",
  "amis": {
    "SignallingWebServer": "$SIGNALLING_AMI",
    "Matchmaker": "$MATCHMAKER_AMI",
    "Frontend": "$FRONTEND_AMI"
  }
}
EOF

print_status "AMI creation complete!"
echo ""
echo -e "${GREEN}=== AMI Creation Summary ===${NC}"
echo -e "SignallingWebServer AMI: ${BLUE}$SIGNALLING_AMI${NC}"
echo -e "Matchmaker AMI: ${BLUE}$MATCHMAKER_AMI${NC}"
echo -e "Frontend AMI: ${BLUE}$FRONTEND_AMI${NC}"
echo ""
echo -e "AMI IDs saved to: ${BLUE}ami-ids.json${NC}"
echo -e "Configuration updated: ${BLUE}$CONFIG_FILE${NC}"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "1. Run ${BLUE}./deploy-infrastructure.sh${NC} to deploy the CloudFormation stack"
echo -e "2. Or run ${BLUE}./deploy-all.sh${NC} for complete end-to-end deployment"
echo ""
