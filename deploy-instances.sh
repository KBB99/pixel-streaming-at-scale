#!/bin/bash

# Deploy EC2 Instances Script
# Creates Frontend and Matchmaker instances after CloudFormation deployment
# Registers them with Target Groups

set -e

# Disable AWS CLI paging
export AWS_PAGER=""

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deployment-config.json"
REGION=$(jq -r '.deployment.region' "$CONFIG_FILE")
STACK_NAME=$(jq -r '.deployment.stackName' "$CONFIG_FILE")

print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

echo -e "${BLUE}=== Deploying EC2 Instances ===${NC}"
echo -e "${YELLOW}Region: $REGION${NC}"
echo -e "${YELLOW}Stack Name: $STACK_NAME${NC}"
echo ""

# Get subnet ID (use first private subnet)
print_status "Getting subnet ID..."
SUBNET_ID=$(aws ec2 describe-subnets \
    --region "$REGION" \
    --filters "Name=tag:StackName,Values=${STACK_NAME}" "Name=tag:Name,Values=*private*" \
    --query 'Subnets[0].SubnetId' \
    --output text)

if [[ "$SUBNET_ID" == "None" || -z "$SUBNET_ID" ]]; then
    print_error "Could not find private subnet"
    exit 1
fi
print_status "Using subnet: $SUBNET_ID"

# Create Matchmaker Instance
print_status "Creating Matchmaker instance..."
MATCHMAKER_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --launch-template LaunchTemplateName=ps-scale-Matchmaker-LT \
    --subnet-id "$SUBNET_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-Matchmaker},{Key=type,Value=matchmaker},{Key=StackName,Value=${STACK_NAME}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

print_status "Matchmaker instance created: $MATCHMAKER_ID"

# Create Frontend Instance
print_status "Creating Frontend instance..."
FRONTEND_ID=$(aws ec2 run-instances \
    --region "$REGION" \
    --launch-template LaunchTemplateName=ps-scale-Frontend-LT \
    --subnet-id "$SUBNET_ID" \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${STACK_NAME}-Frontend},{Key=type,Value=frontend},{Key=StackName,Value=${STACK_NAME}}]" \
    --query 'Instances[0].InstanceId' \
    --output text)

print_status "Frontend instance created: $FRONTEND_ID"

# Wait for instances to be running
print_status "Waiting for instances to be running..."
aws ec2 wait instance-running --region "$REGION" --instance-ids "$MATCHMAKER_ID" "$FRONTEND_ID"
print_status "Instances are running"

# Give instances time to initialize (important for health checks)
print_status "Waiting 60 seconds for instance initialization..."
sleep 60

# Get Target Group ARNs
print_status "Getting Target Group ARNs..."
MATCHMAKER_TG=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query "TargetGroups[?contains(TargetGroupName, 'ps-scale-Matchmaker')].TargetGroupArn" \
    --output text)

FRONTEND_TG=$(aws elbv2 describe-target-groups \
    --region "$REGION" \
    --query "TargetGroups[?contains(TargetGroupName, 'ps-scale-Frontend')].TargetGroupArn" \
    --output text)

if [[ -z "$MATCHMAKER_TG" || -z "$FRONTEND_TG" ]]; then
    print_error "Could not find Target Groups"
    exit 1
fi

print_status "Matchmaker Target Group: $MATCHMAKER_TG"
print_status "Frontend Target Group: $FRONTEND_TG"

# Register instances with Target Groups
print_status "Registering Matchmaker instance with Target Group..."
aws elbv2 register-targets \
    --region "$REGION" \
    --target-group-arn "$MATCHMAKER_TG" \
    --targets Id="$MATCHMAKER_ID"

print_status "Registering Frontend instance with Target Group..."
aws elbv2 register-targets \
    --region "$REGION" \
    --target-group-arn "$FRONTEND_TG" \
    --targets Id="$FRONTEND_ID"

print_status "Instances registered with Target Groups"

# Wait for targets to become healthy
print_status "Waiting for targets to become healthy (this may take 2-3 minutes)..."
print_status "Checking Matchmaker target health..."

MAX_ATTEMPTS=30
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    MATCHMAKER_HEALTH=$(aws elbv2 describe-target-health \
        --region "$REGION" \
        --target-group-arn "$MATCHMAKER_TG" \
        --targets Id="$MATCHMAKER_ID" \
        --query 'TargetHealthDescriptions[0].TargetHealth.State' \
        --output text)
    
    if [[ "$MATCHMAKER_HEALTH" == "healthy" ]]; then
        print_status "Matchmaker target is healthy"
        break
    fi
    
    echo -n "."
    sleep 10
    ((ATTEMPT++))
done

if [[ "$MATCHMAKER_HEALTH" != "healthy" ]]; then
    print_warning "Matchmaker target did not become healthy (current state: $MATCHMAKER_HEALTH)"
    print_warning "This may be normal if the application needs more time to start"
fi

print_status "Checking Frontend target health..."
ATTEMPT=1
while [ $ATTEMPT -le $MAX_ATTEMPTS ]; do
    FRONTEND_HEALTH=$(aws elbv2 describe-target-health \
        --region "$REGION" \
        --target-group-arn "$FRONTEND_TG" \
        --targets Id="$FRONTEND_ID" \
        --query 'TargetHealthDescriptions[0].TargetHealth.State' \
        --output text)
    
    if [[ "$FRONTEND_HEALTH" == "healthy" ]]; then
        print_status "Frontend target is healthy"
        break
    fi
    
    echo -n "."
    sleep 10
    ((ATTEMPT++))
done

if [[ "$FRONTEND_HEALTH" != "healthy" ]]; then
    print_warning "Frontend target did not become healthy (current state: $FRONTEND_HEALTH)"
    print_warning "This may be normal if the application needs more time to start"
fi

# Get ALB DNS names
print_status "Getting ALB DNS names..."
MATCHMAKER_ALB=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'ps-scale-MatchMaker')].DNSName" \
    --output text)

FRONTEND_ALB=$(aws elbv2 describe-load-balancers \
    --region "$REGION" \
    --query "LoadBalancers[?contains(LoadBalancerName, 'ps-scale-Frontend')].DNSName" \
    --output text)

# Display summary
echo ""
echo -e "${GREEN}=== Instance Deployment Complete ===${NC}"
echo ""
echo -e "${BLUE}Instances Created:${NC}"
echo -e "  Matchmaker: $MATCHMAKER_ID"
echo -e "  Frontend:   $FRONTEND_ID"
echo ""
echo -e "${BLUE}Target Health:${NC}"
echo -e "  Matchmaker: ${MATCHMAKER_HEALTH}"
echo -e "  Frontend:   ${FRONTEND_HEALTH}"
echo ""
echo -e "${BLUE}Access Endpoints:${NC}"
echo -e "  Matchmaker: http://${MATCHMAKER_ALB}"
echo -e "  Frontend:   http://${FRONTEND_ALB}"
echo ""

if [[ "$MATCHMAKER_HEALTH" == "healthy" && "$FRONTEND_HEALTH" == "healthy" ]]; then
    echo -e "${GREEN}✓ All instances are healthy and serving traffic!${NC}"
else
    echo -e "${YELLOW}⚠ Some instances are not yet healthy. They may need more time to start.${NC}"
    echo -e "${YELLOW}  Check AWS Console > EC2 > Target Groups for detailed health status.${NC}"
fi

echo ""
