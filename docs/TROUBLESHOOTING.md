# Troubleshooting Guide

This guide helps you diagnose and resolve common issues with the Pixel Streaming at Scale deployment.

## 🔍 General Diagnostic Steps

### 1. Check Prerequisites
```bash
# Verify AWS CLI
aws --version
aws sts get-caller-identity

# Verify required tools
jq --version
git --version
node --version
npm --version
ssh -V
```

### 2. Check AWS Permissions
Ensure your AWS user/role has the following permissions:
- EC2 full access (for AMI creation and instance management)
- CloudFormation full access
- Lambda full access
- Cognito full access
- IAM full access
- CloudWatch Logs full access
- SSM full access

### 3. Verify Region Settings
Check that all resources are being created in the same region:
```bash
# Check your default region
aws configure get region

# List resources in specific region
aws ec2 describe-instances --region us-east-1
aws cloudformation list-stacks --region us-east-1
```

## 🚨 Common Issues and Solutions

### Epic Games Infrastructure Setup Issues

#### Issue: Git clone fails
**Error:** `fatal: could not read Username for 'https://github.com'`
**Solution:**
```bash
# Ensure Git is configured
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"

# Or use SSH instead
git config --global url."git@github.com:".insteadOf "https://github.com/"
```

#### Issue: Node.js dependencies fail to install
**Error:** `npm ERR! peer dep missing`
**Solution:**
```bash
# Clear npm cache
npm cache clean --force

# Install with legacy peer deps
npm install --legacy-peer-deps

# Or use Node Version Manager
nvm use 18
npm install
```

### AMI Creation Issues

#### Issue: "No default VPC found"
**Error:** `No default VPC found. Please ensure you have a default VPC in the region.`
**Solution:**
```bash
# Create a default VPC
aws ec2 create-default-vpc --region us-east-1

# Or specify a custom VPC in the scripts
# Edit create-amis.sh and update VPC_ID variable
```

#### Issue: SSH connection timeout
**Error:** `Failed to establish SSH connection`
**Solution:**
1. Check security group rules allow SSH (port 22)
2. Verify key pair exists and has correct permissions
3. Check if instance is in public subnet
4. Wait longer - some instances take time to boot

```bash
# Check instance status
aws ec2 describe-instances --instance-ids i-1234567890abcdef0

# Check security group
aws ec2 describe-security-groups --group-id sg-1234567890abcdef0
```

#### Issue: AMI creation fails
**Error:** `An error occurred (InvalidAMIID.NotFound)`
**Solution:**
1. Check EC2 service limits
2. Ensure base AMI exists in target region
3. Verify instance is in "stopped" state before creating AMI

```bash
# Check service limits
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A

# Stop instance before creating AMI
aws ec2 stop-instances --instance-ids i-1234567890abcdef0
```

### CloudFormation Deployment Issues

#### Issue: Stack creation fails with permission errors
**Error:** `User: arn:aws:iam::123456789012:user/username is not authorized to perform: iam:CreateRole`
**Solution:**
1. Ensure your user has `iam:CreateRole`, `iam:AttachRolePolicy`, and `iam:PassRole` permissions
2. Use an admin user or role with full permissions
3. Check if there are SCPs (Service Control Policies) blocking the action

#### Issue: AMI not found during stack creation
**Error:** `The image id '[ami-12345678]' does not exist`
**Solution:**
```bash
# Verify AMI exists in target region
aws ec2 describe-images --image-ids ami-12345678 --region us-east-1

# Check if AMI is owned by your account
aws ec2 describe-images --owners self --region us-east-1

# Re-create AMIs if necessary
./create-amis.sh
```

#### Issue: Stack update fails
**Error:** `No updates are to be performed`
**Solution:**
```bash
# Force update with --force-update flag
./deploy-infrastructure.sh --force-update

# Or delete and recreate stack
aws cloudformation delete-stack --stack-name pixel-streaming-at-scale
# Wait for deletion to complete, then redeploy
```

### Lambda Function Issues

#### Issue: Lambda function code not updating
**Error:** Functions running old code after deployment
**Solution:**
```bash
# Manually update specific function
aws lambda update-function-code \
  --function-name functionName \
  --zip-file fileb://lambda-deployment/packages/functionName.zip

# Check function was updated
aws lambda get-function --function-name functionName
```

#### Issue: Lambda permissions errors
**Error:** `User is not authorized to perform: lambda:UpdateFunctionCode`
**Solution:**
1. Ensure Lambda permissions in IAM policy
2. Check function resource-based policy
3. Verify function exists before updating

### Frontend Configuration Issues

#### Issue: Frontend shows blank page
**Symptoms:** React app loads but shows white screen
**Solution:**
1. Check browser console for JavaScript errors
2. Verify environment variables in webpack config
3. Check if build process completed successfully

```bash
# SSH to frontend instance
ssh -i keypair.pem ec2-user@frontend-ip

# Check service status
sudo systemctl status frontend.service

# Check logs
sudo journalctl -u frontend.service -f

# Manually rebuild
cd /usr/customapps/pixelstreaming/Frontend/implementations/react
npm run build
```

#### Issue: Cognito authentication fails
**Error:** `Invalid client_id` or authentication redirects fail
**Solution:**
1. Verify client ID and secret are correct
2. Check callback URLs match exactly
3. Ensure user pool and client exist

```bash
# List user pools
aws cognito-idp list-user-pools --max-items 10

# Get client details
aws cognito-idp describe-user-pool-client \
  --user-pool-id us-east-1_XXXXXXXXX \
  --client-id 1234567890abcdefghijklmnop
```

### Signalling Server Issues

#### Issue: WebSocket connections fail
**Error:** `WebSocket connection failed`
**Solution:**
1. Check security group allows WebSocket ports
2. Verify ALB health checks are passing
3. Check signalling server logs

```bash
# Check ALB target health
aws elbv2 describe-target-health --target-group-arn arn:aws:elasticloadbalancing:...

# SSH to signalling server
ssh -i keypair.pem ec2-user@instance-ip

# Check service status
sudo systemctl status signalling.service

# Check logs
tail -f /var/log/pixelstreaming/signalling.log
```

#### Issue: Signalling server won't start
**Error:** `Port already in use` or service fails to start
**Solution:**
```bash
# Check what's using port 80
sudo netstat -tlnp | grep :80
sudo lsof -i :80

# Kill conflicting process
sudo pkill -f "process-name"

# Restart service
sudo systemctl restart signalling.service
```

## 📊 Monitoring and Debugging

### CloudWatch Logs
Check these log groups for detailed error information:
- `/aws/pixelstreaming/frontend`
- `/aws/pixelstreaming/matchmaker`
- `/aws/pixelstreaming/signalling`
- `/aws/lambda/functionName`

### Useful AWS CLI Commands

```bash
# Check EC2 instances
aws ec2 describe-instances --filters "Name=tag:Name,Values=*pixel*"

# Check CloudFormation stack events
aws cloudformation describe-stack-events --stack-name pixel-streaming-at-scale

# Check Lambda function logs
aws logs describe-log-groups --log-group-name-prefix "/aws/lambda/"

# Check Cognito user pools
aws cognito-idp list-user-pools --max-items 10

# Check ALB target groups
aws elbv2 describe-target-groups
```

### Health Check URLs
Test these endpoints to verify services are running:
- Frontend: `http://frontend-alb-dns/`
- Matchmaker: `http://matchmaker-alb-dns:90/health`
- Signalling: `http://signalling-alb-dns/health`

## 🔧 Advanced Debugging

### Enable Debug Logging
Add debug flags to service startup scripts:

```bash
# For Node.js services
export DEBUG=*
export NODE_ENV=development

# For frontend development
npm run start  # instead of serve -s dist
```

### Manual Service Testing

```bash
# Test signalling server manually
cd /usr/customapps/pixelstreaming/SignallingWebServer
node cirrus.js --help

# Test matchmaker manually
cd /usr/customapps/pixelstreaming/Matchmaker
node matchmaker.js --httpPort 90

# Test frontend manually
cd /usr/customapps/pixelstreaming/Frontend/implementations/react
npm run start
```

### Database Debugging
Check DynamoDB tables for session data:

```bash
# List tables
aws dynamodb list-tables

# Scan instance mapping table
aws dynamodb scan --table-name instanceMapping

# Check specific item
aws dynamodb get-item \
  --table-name instanceMapping \
  --key '{"TargetGroup":{"S":"SignallingTargetGroup01"}}'
```

## 🆘 Getting Additional Help

### Before Seeking Help
1. Check this troubleshooting guide
2. Review CloudWatch logs for error messages
3. Verify all prerequisites are met
4. Try the manual testing steps above

### What to Include in Support Requests
- Exact error messages (copy-paste, don't paraphrase)
- AWS region and account ID (mask if sensitive)
- Output of `./deploy-all.sh --help`
- Relevant CloudWatch log excerpts
- Output of diagnostic commands above

### Useful Log Commands
```bash
# Export CloudWatch logs
aws logs create-export-task \
  --log-group-name "/aws/pixelstreaming/frontend" \
  --from 1609459200000 \
  --to 1609545600000 \
  --destination "your-s3-bucket"

# Tail live logs
aws logs tail /aws/pixelstreaming/frontend --follow
```

## 🧹 Recovery Procedures

### Complete Cleanup and Redeploy
```bash
# Delete CloudFormation stack
aws cloudformation delete-stack --stack-name pixel-streaming-at-scale

# Wait for completion
aws cloudformation wait stack-delete-complete --stack-name pixel-streaming-at-scale

# Clean up AMIs (optional)
# List your AMIs
aws ec2 describe-images --owners self

# Delete specific AMI
aws ec2 deregister-image --image-id ami-12345678

# Delete key pair if created by script
aws ec2 delete-key-pair --key-name pixel-streaming-keypair

# Remove local files
rm -f ami-ids.json deployment-info.json user-credentials.json
rm -rf epic-infrastructure/

# Start fresh deployment
./deploy-all.sh
```

### Partial Recovery
```bash
# Re-run specific steps
./setup-epic-infrastructure.sh      # Re-setup Epic infrastructure
./create-amis.sh                    # Re-create AMIs
./deploy-infrastructure.sh          # Re-deploy infrastructure
./create-user.sh                    # Re-create user
```

---

If you're still experiencing issues after following this guide, please check the project's issue tracker or consult the Epic Games Pixel Streaming documentation for more specific guidance.
