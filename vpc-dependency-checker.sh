#!/bin/bash

# VPC Dependency Checker Script
# This script helps identify all resources preventing VPC deletion

if [ -z "$1" ]; then
    echo "Usage: $0 <vpc-id>"
    echo "Example: $0 vpc-0c00ce2eb6e9d5b03"
    exit 1
fi

VPC_ID=$1
REGION=${2:-us-east-1}

echo "=== VPC DEPENDENCY CHECKER FOR $VPC_ID ==="
echo ""

# 1. Check EC2 Instances
echo "1. EC2 Instances in VPC:"
INSTANCES=$(aws ec2 describe-instances --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'Reservations[*].Instances[*].[InstanceId,State.Name,Tags[?Key==`Name`].Value|[0]]' --output text)
if [ -z "$INSTANCES" ]; then
    echo "   ✅ No EC2 instances found"
else
    echo "   ❌ Found EC2 instances:"
    echo "$INSTANCES" | while read line; do echo "      $line"; done
    echo "   Command to terminate: aws ec2 terminate-instances --instance-ids INSTANCE_ID --region $REGION"
fi
echo ""

# 2. Check NAT Gateways
echo "2. NAT Gateways in VPC:"
NAT_GWS=$(aws ec2 describe-nat-gateways --region $REGION --filter "Name=vpc-id,Values=$VPC_ID" --query 'NatGateways[?State!=`deleted`].[NatGatewayId,State]' --output text)
if [ -z "$NAT_GWS" ]; then
    echo "   ✅ No NAT Gateways found"
else
    echo "   ❌ Found NAT Gateways:"
    echo "$NAT_GWS" | while read line; do echo "      $line"; done
    echo "   Command to delete: aws ec2 delete-nat-gateway --nat-gateway-id NAT_GW_ID --region $REGION"
fi
echo ""

# 3. Check Network Interfaces
echo "3. Network Interfaces in VPC:"
NIFS=$(aws ec2 describe-network-interfaces --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'NetworkInterfaces[*].[NetworkInterfaceId,InterfaceType,Status,Description]' --output text)
if [ -z "$NIFS" ]; then
    echo "   ✅ No network interfaces found"
else
    echo "   ❌ Found network interfaces:"
    echo "$NIFS" | while read line; do echo "      $line"; done
    echo "   Command to delete (if not attached): aws ec2 delete-network-interface --network-interface-id NIF_ID --region $REGION"
fi
echo ""

# 4. Check Security Groups
echo "4. Non-default Security Groups in VPC:"
SGS=$(aws ec2 describe-security-groups --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'SecurityGroups[?GroupName!=`default`].[GroupId,GroupName,Description]' --output text)
if [ -z "$SGS" ]; then
    echo "   ✅ No non-default security groups found"
else
    echo "   ❌ Found non-default security groups:"
    echo "$SGS" | while read line; do echo "      $line"; done
    echo "   Command to delete: aws ec2 delete-security-group --group-id SG_ID --region $REGION"
fi
echo ""

# 5. Check Route Tables
echo "5. Non-main Route Tables in VPC:"
RTS=$(aws ec2 describe-route-tables --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'RouteTables[?Associations[0].Main==false].[RouteTableId,Associations[0].SubnetId]' --output text)
if [ -z "$RTS" ]; then
    echo "   ✅ No non-main route tables found"
else
    echo "   ❌ Found non-main route tables:"
    echo "$RTS" | while read line; do echo "      $line"; done
    echo "   Command to delete: aws ec2 delete-route-table --route-table-id RT_ID --region $REGION"
fi
echo ""

# 6. Check Internet Gateways
echo "6. Internet Gateways attached to VPC:"
IGWS=$(aws ec2 describe-internet-gateways --region $REGION --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'InternetGateways[*].[InternetGatewayId,Attachments[0].State]' --output text)
if [ -z "$IGWS" ]; then
    echo "   ✅ No internet gateways found"
else
    echo "   ❌ Found internet gateways:"
    echo "$IGWS" | while read line; do echo "      $line"; done
    echo "   Commands to remove:"
    echo "   aws ec2 detach-internet-gateway --internet-gateway-id IGW_ID --vpc-id $VPC_ID --region $REGION"
    echo "   aws ec2 delete-internet-gateway --internet-gateway-id IGW_ID --region $REGION"
fi
echo ""

# 7. Check VPC Endpoints
echo "7. VPC Endpoints in VPC:"
VPE=$(aws ec2 describe-vpc-endpoints --region $REGION --filters "Name=vpc-id,Values=$VPC_ID" --query 'VpcEndpoints[*].[VpcEndpointId,ServiceName,State]' --output text)
if [ -z "$VPE" ]; then
    echo "   ✅ No VPC endpoints found"
else
    echo "   ❌ Found VPC endpoints:"
    echo "$VPE" | while read line; do echo "      $line"; done
    echo "   Command to delete: aws ec2 delete-vpc-endpoint --vpc-endpoint-id VPE_ID --region $REGION"
fi
echo ""

# 8. Check Load Balancers
echo "8. Load Balancers in VPC:"
ELB_CLASSIC=$(aws elb describe-load-balancers --region $REGION --query "LoadBalancerDescriptions[?VPCId=='$VPC_ID'].[LoadBalancerName,VPCId]" --output text 2>/dev/null || echo "")
ELB_V2=$(aws elbv2 describe-load-balancers --region $REGION --query "LoadBalancers[?VpcId=='$VPC_ID'].[LoadBalancerArn,LoadBalancerName]" --output text 2>/dev/null || echo "")

if [ -z "$ELB_CLASSIC" ] && [ -z "$ELB_V2" ]; then
    echo "   ✅ No load balancers found"
else
    if [ -n "$ELB_CLASSIC" ]; then
        echo "   ❌ Found Classic Load Balancers:"
        echo "$ELB_CLASSIC" | while read line; do echo "      $line"; done
        echo "   Command to delete: aws elb delete-load-balancer --load-balancer-name LB_NAME --region $REGION"
    fi
    if [ -n "$ELB_V2" ]; then
        echo "   ❌ Found Application/Network Load Balancers:"
        echo "$ELB_V2" | while read line; do echo "      $line"; done
        echo "   Command to delete: aws elbv2 delete-load-balancer --load-balancer-arn LB_ARN --region $REGION"
    fi
fi
echo ""

# 9. Check RDS Instances
echo "9. RDS Instances in VPC:"
RDS=$(aws rds describe-db-instances --region $REGION --query "DBInstances[?DBSubnetGroup.VpcId=='$VPC_ID'].[DBInstanceIdentifier,DBInstanceStatus]" --output text 2>/dev/null || echo "")
if [ -z "$RDS" ]; then
    echo "   ✅ No RDS instances found"
else
    echo "   ❌ Found RDS instances:"
    echo "$RDS" | while read line; do echo "      $line"; done
    echo "   Command to delete: aws rds delete-db-instance --db-instance-identifier DB_ID --skip-final-snapshot --region $REGION"
fi
echo ""

echo "=== SUMMARY ==="
echo "To delete VPC $VPC_ID, you must first remove all dependencies listed above."
echo "After removing all dependencies, delete the VPC with:"
echo "aws ec2 delete-vpc --vpc-id $VPC_ID --region $REGION"
echo ""
echo "=== QUICK CLEANUP COMMANDS ==="
echo "# Delete NAT Gateways first (to free Elastic IPs):"
echo "aws ec2 describe-nat-gateways --region $REGION --filter \"Name=vpc-id,Values=$VPC_ID\" --query 'NatGateways[?State!=\`deleted\`].NatGatewayId' --output text | xargs -I {} aws ec2 delete-nat-gateway --nat-gateway-id {} --region $REGION"
echo ""
echo "# Delete non-default security groups:"
echo "aws ec2 describe-security-groups --region $REGION --filters \"Name=vpc-id,Values=$VPC_ID\" --query 'SecurityGroups[?GroupName!=\`default\`].GroupId' --output text | xargs -I {} aws ec2 delete-security-group --group-id {} --region $REGION"
echo ""
echo "# Detach and delete Internet Gateway:"
echo "IGW_ID=\$(aws ec2 describe-internet-gateways --region $REGION --filters \"Name=attachment.vpc-id,Values=$VPC_ID\" --query 'InternetGateways[0].InternetGatewayId' --output text)"
echo "aws ec2 detach-internet-gateway --internet-gateway-id \$IGW_ID --vpc-id $VPC_ID --region $REGION"
echo "aws ec2 delete-internet-gateway --internet-gateway-id \$IGW_ID --region $REGION"
