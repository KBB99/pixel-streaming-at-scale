#!/bin/bash

# Cleanup Script for Pixel Streaming at Scale
# This script removes all AWS resources created by the deployment

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deployment-config.json"

# Parse command line arguments
FORCE_DELETE=false
DELETE_AMIS=false
DELETE_KEYS=false
REGION=""
STACK_NAME=""

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Cleanup all AWS resources created by Pixel Streaming deployment"
    echo ""
    echo "Options:"
    echo "  --region <region>           AWS region to clean up (default: us-east-1)"
    echo "  --stack-name <name>         CloudFormation stack name to delete"
    echo "  --delete-amis              Delete created AMIs and snapshots"
    echo "  --delete-keys              Delete SSH key pairs created by scripts"
    echo "  --force                    Skip confirmation prompts"
    echo "  --help                     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Interactive cleanup"
    echo "  $0 --force --delete-amis             # Force cleanup including AMIs"
    echo "  $0 --region us-west-2                # Cleanup in specific region"
    echo ""
}

while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            REGION="$2"
            shift 2
            ;;
        --stack-name)
            STACK_NAME="$2"
            shift 2
            ;;
        --delete-amis)
            DELETE_AMIS=true
            shift
            ;;
        --delete-keys)
            DELETE_KEYS=true
            shift
            ;;
        --force)
            FORCE_DELETE=true
            shift
            ;;
        --help)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 1
            ;;
    esac
done

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

print_header() {
    echo ""
    echo -e "${BOLD}${BLUE}================================================================${NC}"
    echo -e "${BOLD}${BLUE} $1${NC}"
    echo -e "${BOLD}${BLUE}================================================================${NC}"
    echo ""
}

# Load configuration if available
if [[ -f "$CONFIG_FILE" ]]; then
    if [[ -z "$REGION" ]]; then
        REGION=$(jq -r '.deployment.region' "$CONFIG_FILE")
    fi
    
    if [[ -z "$STACK_NAME" ]]; then
        STACK_NAME=$(jq -r '.deployment.stackName' "$CONFIG_FILE")
    fi
fi

# Set defaults if not specified
REGION=${REGION:-"us-east-1"}
STACK_NAME=${STACK_NAME:-"pixel-streaming-at-scale"}

print_header "PIXEL STREAMING CLEANUP"

echo -e "This script will delete AWS resources created by the Pixel Streaming deployment"
echo -e "${RED}${BOLD}WARNING: This action cannot be undone!${NC}"
echo ""

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

# Display cleanup plan
echo -e "${BOLD}Cleanup Configuration:${NC}"
echo -e "  Region:     ${BLUE}$REGION${NC}"
echo -e "  Stack Name: ${BLUE}$STACK_NAME${NC}"
echo ""

echo -e "${BOLD}Resources to be deleted:${NC}"
echo -e "  ${RED}✗${NC} CloudFormation stack and all its resources"
echo -e "  ${RED}✗${NC} EC2 instances (Frontend, Matchmaker)"
echo -e "  ${RED}✗${NC} Lambda functions"
echo -e "  ${RED}✗${NC} Cognito user pool and users"
echo -e "  ${RED}✗${NC} DynamoDB tables"
echo -e "  ${RED}✗${NC} Application Load Balancers"
echo -e "  ${RED}✗${NC} VPC, subnets, and networking components"

if [[ "$DELETE_AMIS" == true ]]; then
    echo -e "  ${RED}✗${NC} Custom AMIs and associated snapshots"
fi

if [[ "$DELETE_KEYS" == true ]]; then
    echo -e "  ${RED}✗${NC} SSH key pairs created by deployment scripts"
fi

echo ""

# Get confirmation unless force mode
if [[ "$FORCE_DELETE" == false ]]; then
    echo -e "${YELLOW}This will permanently delete all resources listed above.${NC}"
    read -p "Are you absolutely sure you want to proceed? (yes/no): " -r
    echo
    if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
        print_status "Cleanup cancelled"
        exit 0
    fi
    
    # Double confirmation for AMI deletion
    if [[ "$DELETE_AMIS" == true ]]; then
        echo -e "${RED}AMI deletion was requested. This will also delete EBS snapshots.${NC}"
        read -p "Confirm AMI deletion (yes/no): " -r
        echo
        if [[ ! $REPLY =~ ^[Yy][Ee][Ss]$ ]]; then
            DELETE_AMIS=false
            print_warning "Skipping AMI deletion"
        fi
    fi
fi

# Start cleanup process
print_header "STARTING CLEANUP"

# Check if stack exists
STACK_EXISTS=false
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null; then
    STACK_EXISTS=true
    print_status "Found CloudFormation stack: $STACK_NAME"
else
    print_warning "CloudFormation stack not found: $STACK_NAME"
fi

# Delete CloudFormation stack
if [[ "$STACK_EXISTS" == true ]]; then
    print_status "Deleting CloudFormation stack..."
    
    aws cloudformation delete-stack \
        --stack-name "$STACK_NAME" \
        --region "$REGION"
    
    print_status "Waiting for stack deletion to complete..."
    print_warning "This may take 10-15 minutes..."
    
    # Wait for stack deletion with timeout
    if timeout 1800 aws cloudformation wait stack-delete-complete --stack-name "$STACK_NAME" --region "$REGION"; then
        print_status "CloudFormation stack deleted successfully"
    else
        print_error "Stack deletion timed out or failed"
        print_warning "Some resources may need manual deletion"
    fi
fi

# Delete AMIs if requested
if [[ "$DELETE_AMIS" == true ]]; then
    print_status "Deleting custom AMIs..."
    
    # Get AMI IDs from ami-ids.json file if it exists
    AMI_IDS_FILE="$SCRIPT_DIR/ami-ids.json"
    
    if [[ -f "$AMI_IDS_FILE" ]]; then
        SIGNALLING_AMI=$(jq -r '.amis.SignallingWebServer' "$AMI_IDS_FILE")
        MATCHMAKER_AMI=$(jq -r '.amis.Matchmaker' "$AMI_IDS_FILE")
        FRONTEND_AMI=$(jq -r '.amis.Frontend' "$AMI_IDS_FILE")
        
        for ami_id in "$SIGNALLING_AMI" "$MATCHMAKER_AMI" "$FRONTEND_AMI"; do
            if [[ "$ami_id" != "null" && -n "$ami_id" ]]; then
                print_status "Deleting AMI: $ami_id"
                
                # Get snapshot IDs before deregistering AMI
                SNAPSHOT_IDS=$(aws ec2 describe-images --image-ids "$ami_id" --region "$REGION" --query 'Images[0].BlockDeviceMappings[*].Ebs.SnapshotId' --output text 2>/dev/null || echo "")
                
                # Deregister AMI
                if aws ec2 deregister-image --image-id "$ami_id" --region "$REGION" 2>/dev/null; then
                    print_status "AMI $ami_id deregistered"
                    
                    # Delete associated snapshots
                    if [[ -n "$SNAPSHOT_IDS" ]]; then
                        for snapshot_id in $SNAPSHOT_IDS; do
                            if [[ "$snapshot_id" != "None" ]]; then
                                print_status "Deleting snapshot: $snapshot_id"
                                aws ec2 delete-snapshot --snapshot-id "$snapshot_id" --region "$REGION" 2>/dev/null || print_warning "Failed to delete snapshot $snapshot_id"
                            fi
                        done
                    fi
                else
                    print_warning "Failed to deregister AMI $ami_id (may not exist)"
                fi
            fi
        done
    else
        print_warning "AMI IDs file not found, searching for AMIs with stack name tag..."
        
        # Search for AMIs created by this deployment
        AMI_LIST=$(aws ec2 describe-images \
            --owners self \
            --filters "Name=name,Values=${STACK_NAME}-*" \
            --query 'Images[*].ImageId' \
            --output text \
            --region "$REGION" 2>/dev/null || echo "")
        
        if [[ -n "$AMI_LIST" ]]; then
            for ami_id in $AMI_LIST; do
                print_status "Deleting AMI: $ami_id"
                aws ec2 deregister-image --image-id "$ami_id" --region "$REGION" 2>/dev/null || print_warning "Failed to delete AMI $ami_id"
            done
        else
            print_warning "No custom AMIs found to delete"
        fi
    fi
fi

# Delete SSH key pairs if requested
if [[ "$DELETE_KEYS" == true ]]; then
    print_status "Deleting SSH key pairs..."
    
    # Try to get key pair name from config
    KEY_PAIR_NAME=""
    if [[ -f "$CONFIG_FILE" ]]; then
        KEY_PAIR_NAME=$(jq -r '.deployment.keyPairName' "$CONFIG_FILE")
    fi
    
    KEY_PAIR_NAME=${KEY_PAIR_NAME:-"pixel-streaming-keypair"}
    
    if aws ec2 describe-key-pairs --key-names "$KEY_PAIR_NAME" --region "$REGION" &> /dev/null; then
        aws ec2 delete-key-pair --key-name "$KEY_PAIR_NAME" --region "$REGION"
        print_status "Deleted key pair: $KEY_PAIR_NAME"
        
        # Remove local key file if it exists
        if [[ -f "$SCRIPT_DIR/${KEY_PAIR_NAME}.pem" ]]; then
            rm -f "$SCRIPT_DIR/${KEY_PAIR_NAME}.pem"
            print_status "Removed local key file: ${KEY_PAIR_NAME}.pem"
        fi
    else
        print_warning "Key pair not found: $KEY_PAIR_NAME"
    fi
fi

# Clean up local files
print_status "Cleaning up local files..."

LOCAL_FILES=(
    "deployment-info.json"
    "user-credentials.json"
    "ami-ids.json"
    "epic-infrastructure"
    "lambda-deployment/packages"
)

for file in "${LOCAL_FILES[@]}"; do
    if [[ -e "$SCRIPT_DIR/$file" ]]; then
        rm -rf "$SCRIPT_DIR/$file"
        print_status "Removed: $file"
    fi
done

# Final verification
print_header "CLEANUP VERIFICATION"

# Check for remaining resources
print_status "Checking for remaining resources..."

# Check EC2 instances
REMAINING_INSTANCES=$(aws ec2 describe-instances \
    --filters "Name=tag:aws:cloudformation:stack-name,Values=$STACK_NAME" "Name=instance-state-name,Values=running,pending,stopping,stopped" \
    --query 'Reservations[*].Instances[*].InstanceId' \
    --output text \
    --region "$REGION" 2>/dev/null || echo "")

if [[ -n "$REMAINING_INSTANCES" && "$REMAINING_INSTANCES" != "None" ]]; then
    print_warning "Remaining EC2 instances found: $REMAINING_INSTANCES"
    echo "These may need manual termination."
fi

# Check CloudFormation stack
if aws cloudformation describe-stacks --stack-name "$STACK_NAME" --region "$REGION" &> /dev/null; then
    print_warning "CloudFormation stack still exists (may be in DELETE_IN_PROGRESS state)"
else
    print_status "CloudFormation stack successfully deleted"
fi

print_header "CLEANUP COMPLETE"

echo -e "${GREEN}Cleanup process finished!${NC}"
echo ""
echo -e "${BOLD}Summary:${NC}"
echo -e "  Region: ${BLUE}$REGION${NC}"
echo -e "  Stack: ${BLUE}$STACK_NAME${NC}"

if [[ "$STACK_EXISTS" == true ]]; then
    echo -e "  ${GREEN}✓${NC} CloudFormation stack deletion initiated"
else
    echo -e "  ${YELLOW}⊘${NC} CloudFormation stack was not found"
fi

if [[ "$DELETE_AMIS" == true ]]; then
    echo -e "  ${GREEN}✓${NC} Custom AMIs deleted"
else
    echo -e "  ${YELLOW}⊘${NC} Custom AMIs preserved"
fi

if [[ "$DELETE_KEYS" == true ]]; then
    echo -e "  ${GREEN}✓${NC} SSH key pairs deleted"
else
    echo -e "  ${YELLOW}⊘${NC} SSH key pairs preserved"
fi

echo -e "  ${GREEN}✓${NC} Local files cleaned up"
echo ""

if [[ -n "$REMAINING_INSTANCES" && "$REMAINING_INSTANCES" != "None" ]]; then
    echo -e "${YELLOW}Note:${NC} Some resources may require manual cleanup."
    echo -e "Check the AWS Console for any remaining resources."
else
    echo -e "${GREEN}All resources appear to be successfully removed.${NC}"
fi

echo ""
echo -e "${BLUE}Thank you for using Pixel Streaming at Scale!${NC}"
echo ""
