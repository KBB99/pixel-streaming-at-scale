#!/bin/bash

# Complete End-to-End Deployment Script for Pixel Streaming at Scale
# This is the master script that orchestrates the entire deployment process

set -e

# Disable AWS CLI paging for automation
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deployment-config.json"

# Parse command line arguments
SKIP_EPIC_SETUP=false
SKIP_AMI_CREATION=false
SKIP_INFRASTRUCTURE=false
SKIP_USER_CREATION=false
FORCE_UPDATE=false
REGION=""
STACK_NAME=""

print_usage() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Complete end-to-end deployment of Pixel Streaming at Scale"
    echo ""
    echo "Options:"
    echo "  --region <region>           AWS region to deploy to (default: us-east-1)"
    echo "  --stack-name <name>         CloudFormation stack name (default: pixel-streaming-at-scale)"
    echo "  --skip-epic-setup          Skip Epic Games infrastructure setup"
    echo "  --skip-ami-creation        Skip AMI creation (use existing AMIs)"
    echo "  --skip-infrastructure      Skip infrastructure deployment"
    echo "  --skip-user-creation       Skip test user creation"
    echo "  --force-update             Force update existing CloudFormation stack"
    echo "  --help                     Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                                    # Full deployment with defaults"
    echo "  $0 --region us-west-2                # Deploy to us-west-2"
    echo "  $0 --skip-ami-creation               # Skip AMI creation step"
    echo "  $0 --stack-name my-pixel-streaming   # Use custom stack name"
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
        --skip-epic-setup)
            SKIP_EPIC_SETUP=true
            shift
            ;;
        --skip-ami-creation)
            SKIP_AMI_CREATION=true
            shift
            ;;
        --skip-infrastructure)
            SKIP_INFRASTRUCTURE=true
            shift
            ;;
        --skip-user-creation)
            SKIP_USER_CREATION=true
            shift
            ;;
        --force-update)
            FORCE_UPDATE=true
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

# Function to print status with different levels
print_header() {
    echo ""
    echo -e "${BOLD}${CYAN}================================================================${NC}"
    echo -e "${BOLD}${CYAN} $1${NC}"
    echo -e "${BOLD}${CYAN}================================================================${NC}"
    echo ""
}

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_step() {
    echo -e "${BLUE}▶${NC} ${BOLD}$1${NC}"
}

# Update configuration if command line arguments provided
update_config() {
    if [[ -n "$REGION" || -n "$STACK_NAME" ]]; then
        print_status "Updating configuration with command line parameters..."
        
        local temp_config=$(mktemp)
        local config_updates=""
        
        if [[ -n "$REGION" ]]; then
            config_updates="$config_updates | .deployment.region = \"$REGION\""
        fi
        
        if [[ -n "$STACK_NAME" ]]; then
            config_updates="$config_updates | .deployment.stackName = \"$STACK_NAME\""
        fi
        
        jq "$config_updates" "$CONFIG_FILE" > "$temp_config"
        mv "$temp_config" "$CONFIG_FILE"
        
        print_status "Configuration updated"
    fi
}

# Check prerequisites
check_prerequisites() {
    print_step "Checking prerequisites"
    
    local missing_tools=()
    
    if ! command -v aws &> /dev/null; then
        missing_tools+=("aws")
    fi
    
    if ! command -v jq &> /dev/null; then
        missing_tools+=("jq")
    fi
    
    if ! command -v git &> /dev/null; then
        missing_tools+=("git")
    fi
    
    if ! command -v node &> /dev/null; then
        missing_tools+=("node")
    fi
    
    if ! command -v npm &> /dev/null; then
        missing_tools+=("npm")
    fi
    
    if ! command -v ssh &> /dev/null; then
        missing_tools+=("ssh")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        echo ""
        echo "Please install the missing tools:"
        echo "  AWS CLI: https://aws.amazon.com/cli/"
        echo "  jq: https://stedolan.github.io/jq/"
        echo "  Git: https://git-scm.com/"
        echo "  Node.js: https://nodejs.org/"
        echo "  SSH client: Usually pre-installed"
        exit 1
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity &> /dev/null; then
        print_error "AWS credentials not configured or invalid"
        echo ""
        echo "Please configure AWS credentials:"
        echo "  aws configure"
        echo "or set environment variables:"
        echo "  export AWS_ACCESS_KEY_ID=your-access-key"
        echo "  export AWS_SECRET_ACCESS_KEY=your-secret-key"
        exit 1
    fi
    
    # Check configuration file
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Configuration file not found: $CONFIG_FILE"
        exit 1
    fi
    
    print_status "Prerequisites check passed"
}

# Display deployment plan
show_deployment_plan() {
    local region=$(jq -r '.deployment.region' "$CONFIG_FILE")
    local stack_name=$(jq -r '.deployment.stackName' "$CONFIG_FILE")
    local username=$(jq -r '.testUser.username' "$CONFIG_FILE")
    
    print_header "DEPLOYMENT PLAN"
    
    echo -e "${BOLD}Configuration:${NC}"
    echo -e "  Region:     ${BLUE}$region${NC}"
    echo -e "  Stack Name: ${BLUE}$stack_name${NC}"
    echo -e "  Test User:  ${BLUE}$username${NC}"
    echo ""
    
    echo -e "${BOLD}Deployment Steps:${NC}"
    
    if [[ "$SKIP_EPIC_SETUP" == false ]]; then
        echo -e "  ${GREEN}✓${NC} Setup Epic Games infrastructure"
    else
        echo -e "  ${YELLOW}⊘${NC} Skip Epic Games infrastructure setup"
    fi
    
    if [[ "$SKIP_AMI_CREATION" == false ]]; then
        echo -e "  ${GREEN}✓${NC} Create custom AMIs (SignallingServer, Matchmaker, Frontend)"
    else
        echo -e "  ${YELLOW}⊘${NC} Skip AMI creation (use existing AMIs)"
    fi
    
    if [[ "$SKIP_INFRASTRUCTURE" == false ]]; then
        echo -e "  ${GREEN}✓${NC} Deploy CloudFormation infrastructure"
        echo -e "  ${GREEN}✓${NC} Update Lambda functions"
        echo -e "  ${GREEN}✓${NC} Configure services"
    else
        echo -e "  ${YELLOW}⊘${NC} Skip infrastructure deployment"
    fi
    
    if [[ "$SKIP_USER_CREATION" == false ]]; then
        echo -e "  ${GREEN}✓${NC} Create test user"
    else
        echo -e "  ${YELLOW}⊘${NC} Skip test user creation"
    fi
    
    echo ""
    echo -e "${BOLD}Estimated Time:${NC}"
    echo -e "  Epic Setup: ${BLUE}5-10 minutes${NC}"
    echo -e "  AMI Creation: ${BLUE}20-30 minutes${NC}"
    echo -e "  Infrastructure: ${BLUE}10-15 minutes${NC}"
    echo -e "  User Setup: ${BLUE}1-2 minutes${NC}"
    echo -e "  ${BOLD}Total: 35-50 minutes${NC}"
    echo ""
    
    # Auto-proceed with deployment (removed interactive prompt for automation)
    print_status "Proceeding with automated deployment..."
}

# Execute deployment step with error handling
execute_step() {
    local step_name="$1"
    local script_path="$2"
    local script_args="$3"
    
    print_header "$step_name"
    
    local start_time=$(date +%s)
    
    if [[ -f "$script_path" ]]; then
        chmod +x "$script_path"
        
        if [[ -n "$script_args" ]]; then
            eval "$script_path $script_args"
        else
            "$script_path"
        fi
        
        local end_time=$(date +%s)
        local duration=$((end_time - start_time))
        print_status "$step_name completed in ${duration}s"
    else
        print_error "Script not found: $script_path"
        exit 1
    fi
}

# Generate final summary
generate_summary() {
    print_header "DEPLOYMENT COMPLETE"
    
    local deployment_info_file="$SCRIPT_DIR/deployment-info.json"
    local user_credentials_file="$SCRIPT_DIR/user-credentials.json"
    
    if [[ -f "$deployment_info_file" ]]; then
        local cognito_domain=$(jq -r '.outputs.cognito_domain_url' "$deployment_info_file")
        local cognito_callback=$(jq -r '.outputs.cognito_callback_url' "$deployment_info_file")
        local client_id=$(jq -r '.outputs.cognito_client_id' "$deployment_info_file")
        
        echo -e "${BOLD}Access Information:${NC}"
        echo -e "  Application URL: ${BLUE}$cognito_callback${NC}"
        echo -e "  Cognito Login:   ${BLUE}$cognito_domain/login${NC}"
        echo -e "  Client ID:       ${BLUE}$client_id${NC}"
        echo ""
    fi
    
    if [[ -f "$user_credentials_file" ]]; then
        local username=$(jq -r '.user.username' "$user_credentials_file")
        local password=$(jq -r '.user.password' "$user_credentials_file")
        local hosted_ui=$(jq -r '.hosted_ui_url' "$user_credentials_file")
        
        echo -e "${BOLD}Test User Credentials:${NC}"
        echo -e "  Username: ${BLUE}$username${NC}"
        echo -e "  Password: ${BLUE}$password${NC}"
        echo ""
        
        if [[ "$hosted_ui" != "null" && -n "$hosted_ui" ]]; then
            echo -e "${BOLD}Quick Start:${NC}"
            echo -e "1. Open: ${BLUE}$hosted_ui${NC}"
            echo -e "2. Click 'Sign in'"
            echo -e "3. Enter username: ${BLUE}$username${NC}"
            echo -e "4. Enter password: ${BLUE}$password${NC}"
            echo -e "5. Start streaming!"
            echo ""
        fi
    fi
    
    echo -e "${BOLD}Generated Files:${NC}"
    
    local files=(
        "deployment-info.json:Deployment details and endpoints"
        "user-credentials.json:Test user login information"
        "ami-ids.json:Created AMI identifiers"
    )
    
    for file_info in "${files[@]}"; do
        local file_name="${file_info%%:*}"
        local description="${file_info##*:}"
        
        if [[ -f "$SCRIPT_DIR/$file_name" ]]; then
            echo -e "  ${GREEN}✓${NC} ${BLUE}$file_name${NC} - $description"
        fi
    done
    
    echo ""
    echo -e "${BOLD}Monitoring and Logs:${NC}"
    echo -e "  CloudWatch Logs: ${BLUE}/aws/pixelstreaming/*${NC}"
    echo -e "  CloudFormation:  ${BLUE}AWS Console > CloudFormation${NC}"
    echo -e "  EC2 Instances:   ${BLUE}AWS Console > EC2${NC}"
    echo ""
    
    echo -e "${BOLD}Cleanup:${NC}"
    echo -e "  To remove everything: ${BLUE}./cleanup.sh${NC}"
    echo ""
    
    echo -e "${GREEN}${BOLD}🎉 Pixel Streaming at Scale deployment successful!${NC}"
    echo ""
}

# Main execution flow
main() {
    clear
    
    print_header "PIXEL STREAMING AT SCALE - DEPLOYMENT"
    
    echo -e "This script will deploy a complete Pixel Streaming infrastructure on AWS"
    echo -e "including Epic Games components, custom AMIs, and all AWS services."
    echo ""
    
    # Check prerequisites first
    check_prerequisites
    
    # Update configuration if needed
    update_config
    
    # Show deployment plan and get confirmation
    show_deployment_plan
    
    # Record start time
    local deployment_start_time=$(date +%s)
    
    # Execute deployment steps
    if [[ "$SKIP_EPIC_SETUP" == false ]]; then
        execute_step "EPIC GAMES INFRASTRUCTURE SETUP" "$SCRIPT_DIR/setup-epic-infrastructure.sh"
    fi
    
    if [[ "$SKIP_AMI_CREATION" == false ]]; then
        execute_step "AMI CREATION" "$SCRIPT_DIR/create-amis.sh"
    fi
    
    if [[ "$SKIP_INFRASTRUCTURE" == false ]]; then
        local infra_args=""
        if [[ "$FORCE_UPDATE" == true ]]; then
            infra_args="--force-update"
        fi
        if [[ "$SKIP_AMI_CREATION" == true ]]; then
            infra_args="$infra_args --skip-ami-check"
        fi
        execute_step "INFRASTRUCTURE DEPLOYMENT" "$SCRIPT_DIR/deploy-infrastructure.sh" "$infra_args"
        
        # Deploy EC2 instances after infrastructure is ready
        execute_step "EC2 INSTANCE DEPLOYMENT" "$SCRIPT_DIR/deploy-instances.sh"
    fi
    
    if [[ "$SKIP_USER_CREATION" == false ]]; then
        execute_step "TEST USER CREATION" "$SCRIPT_DIR/create-user.sh"
    fi
    
    # Calculate total deployment time
    local deployment_end_time=$(date +%s)
    local total_duration=$((deployment_end_time - deployment_start_time))
    local minutes=$((total_duration / 60))
    local seconds=$((total_duration % 60))
    
    # Generate and display final summary
    generate_summary
    
    echo -e "${BOLD}Total deployment time: ${BLUE}${minutes}m ${seconds}s${NC}"
    echo ""
}

# Handle script interruption
cleanup_on_exit() {
    echo ""
    print_warning "Deployment interrupted"
    echo ""
    echo "Partial deployment may have occurred. Check AWS Console for:"
    echo "  - CloudFormation stacks"
    echo "  - EC2 instances"
    echo "  - AMIs"
    echo ""
    echo "You can resume deployment by running specific scripts:"
    echo "  ./deploy-infrastructure.sh  # Continue from infrastructure"
    echo "  ./create-user.sh           # Create test user only"
    exit 1
}

# Set trap for cleanup
trap cleanup_on_exit INT TERM

# Run main function
main "$@"
