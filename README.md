# Pixel Streaming at Scale - Complete Deployment Solution

This repository provides a complete, automated deployment solution for Epic Games' Pixel Streaming infrastructure on AWS at scale. It includes all the scripts, configurations, and documentation needed to deploy a production-ready pixel streaming environment.

## 🚀 Quick Start

**Single Command Deployment:**
```bash
./deploy-all.sh
```

This will deploy everything automatically, including:
- Epic Games Pixel Streaming infrastructure setup
- Custom AMI creation for all components
- Complete AWS infrastructure via CloudFormation
- Lambda functions with proper code
- Test user creation
- Full configuration and monitoring

## 📋 Prerequisites

### Required Tools
- **AWS CLI v2** - [Installation Guide](https://aws.amazon.com/cli/)
- **jq** - JSON processor ([Download](https://stedolan.github.io/jq/))
- **Git** - Version control ([Download](https://git-scm.com/))
- **Node.js 18+** - JavaScript runtime ([Download](https://nodejs.org/))
- **SSH client** - Usually pre-installed on Linux/macOS

### AWS Requirements
- AWS account with administrative privileges
- AWS CLI configured with valid credentials
- Default VPC in your target region
- Sufficient service limits for EC2 instances

### System Requirements
- Linux or macOS (tested on Ubuntu 20.04+ and macOS 12+)
- 2GB+ available disk space
- Stable internet connection

## 🏗️ Architecture Overview

The solution deploys a scalable pixel streaming infrastructure with:

- **Frontend**: React-based web application with Cognito authentication
- **Matchmaker**: Session management and load balancing
- **Signalling Servers**: WebRTC signalling with auto-scaling
- **Lambda Functions**: Session orchestration and lifecycle management
- **CloudFormation**: Complete infrastructure as code
- **Monitoring**: CloudWatch logs and metrics

## 📖 Deployment Options

### Option 1: Complete Deployment (Recommended)
```bash
./deploy-all.sh
```

### Option 2: Step-by-Step Deployment
```bash
# 1. Setup Epic Games infrastructure
./setup-epic-infrastructure.sh

# 2. Create custom AMIs
./create-amis.sh

# 3. Deploy AWS infrastructure
./deploy-infrastructure.sh

# 4. Create test user
./create-user.sh
```

### Option 3: Custom Configuration
```bash
# Deploy to specific region with custom stack name
./deploy-all.sh --region us-west-2 --stack-name my-pixel-streaming

# Skip AMI creation (use existing AMIs)
./deploy-all.sh --skip-ami-creation

# Force update existing stack
./deploy-all.sh --force-update
```

## ⚙️ Configuration

The deployment is configured via `deployment-config.json`:

```json
{
  "deployment": {
    "stackName": "pixel-streaming-at-scale",
    "region": "us-east-1",
    "keyPairName": "pixel-streaming-keypair"
  },
  "infrastructure": {
    "instanceTypes": {
      "matchmaker": "t3.small",
      "frontend": "t3.small", 
      "signalling": "t3.small"
    }
  },
  "testUser": {
    "username": "testuser@example.com",
    "password": "TempPassword123!",
    "email": "testuser@example.com"
  }
}
```

## 📁 Project Structure

```
pixel-streaming-at-scale/
├── deploy-all.sh                 # Master deployment script
├── deployment-config.json        # Configuration file
├── setup-epic-infrastructure.sh  # Epic Games setup
├── create-amis.sh               # AMI creation script
├── deploy-infrastructure.sh     # CloudFormation deployment
├── create-user.sh              # User creation script
├── ami-userdata/               # EC2 user data scripts
│   ├── signalling-server-userdata.sh
│   ├── matchmaker-userdata.sh
│   └── frontend-userdata.sh
├── lambda-deployment/          # Lambda function packaging
│   └── package-lambda.sh
├── infra/                     # Infrastructure templates
│   └── create.yaml
├── Lambda/                    # Lambda function source code
├── Frontend/                  # React frontend application
├── Matchmaker/               # Matchmaker service
├── SignallingWebServer/      # Signalling server
└── docs/                     # Documentation
```

## 🎯 Usage

### After Deployment

1. **Access the Application:**
   - Open the Cognito Hosted UI URL (provided at end of deployment)
   - Use the test user credentials to log in

2. **Monitor the System:**
   - CloudWatch Logs: `/aws/pixelstreaming/*`
   - CloudFormation Console: View stack resources
   - EC2 Console: Monitor instance health

3. **Scale the System:**
   - Adjust instance types in `deployment-config.json`
   - Modify auto-scaling parameters in CloudFormation template

### Common Commands

```bash
# View deployment information
cat deployment-info.json

# Check user credentials
cat user-credentials.json

# View created AMIs
cat ami-ids.json

# Update only Lambda functions
./deploy-infrastructure.sh --skip-ami-check

# Create additional users
./create-user.sh --username user2@example.com --email user2@example.com
```

## 🔧 Customization

### Instance Types
Modify `deployment-config.json` to use different instance types:
```json
{
  "infrastructure": {
    "instanceTypes": {
      "matchmaker": "t3.medium",
      "frontend": "t3.medium", 
      "signalling": "t3.large"
    }
  }
}
```

### Regions
The solution supports deployment to multiple AWS regions:
```bash
./deploy-all.sh --region us-west-2
./deploy-all.sh --region eu-west-1
```

### SSL Certificates
For production use, add SSL certificates to AWS Certificate Manager and update the CloudFormation template to reference them.

## 📊 Monitoring and Logging

### CloudWatch Logs
- **Frontend**: `/aws/pixelstreaming/frontend`
- **Matchmaker**: `/aws/pixelstreaming/matchmaker`
- **Signalling**: `/aws/pixelstreaming/signalling`
- **Lambda Functions**: `/aws/lambda/function-name`

### CloudWatch Metrics
- **CPU Utilization**: Per instance monitoring
- **Memory Usage**: Custom metrics via CloudWatch agent
- **Network Traffic**: Instance-level metrics
- **Application Metrics**: Custom business metrics

### Health Checks
Each component includes health check endpoints:
- Frontend: `http://instance:8080/`
- Matchmaker: `http://instance:90/health`
- Signalling: `http://instance:80/health`

## 🚨 Troubleshooting

### Common Issues

**AMI Creation Fails:**
- Check EC2 service limits
- Verify default VPC exists
- Ensure AWS credentials have EC2 permissions

**CloudFormation Deployment Fails:**
- Check IAM permissions
- Verify AMI IDs are valid
- Review CloudFormation events in AWS Console

**Frontend Not Loading:**
- Check Cognito configuration
- Verify environment variables in webpack config
- Review CloudWatch logs for errors

**Signalling Server Issues:**
- Check security group rules
- Verify port 80/443 accessibility
- Review application logs

### Getting Help

1. Check the [Troubleshooting Guide](docs/TROUBLESHOOTING.md)
2. Review CloudWatch logs for error messages
3. Verify AWS service limits and quotas
4. Check Epic Games Pixel Streaming documentation

## 🧹 Cleanup

To remove all deployed resources:

```bash
# Delete CloudFormation stack
aws cloudformation delete-stack --stack-name pixel-streaming-at-scale --region us-east-1

# Delete created AMIs (optional)
# Note: This will also delete associated EBS snapshots
aws ec2 deregister-image --image-id ami-12345678 --region us-east-1

# Delete key pair (if created by scripts)
aws ec2 delete-key-pair --key-name pixel-streaming-keypair --region us-east-1
```

## 💰 Cost Considerations

### Estimated Monthly Costs (us-east-1)
- **EC2 Instances** (3x t3.small): ~$50-70
- **Application Load Balancers** (3x ALBs): ~$50-60
- **NAT Gateway**: ~$45
- **Lambda Functions**: <$10 (depends on usage)
- **CloudWatch Logs**: ~$5-15
- **Data Transfer**: Variable based on usage

**Total Estimated**: $150-200/month for basic deployment

### Cost Optimization
- Use scheduled scaling to stop instances during off-hours
- Implement auto-scaling based on demand
- Use Reserved Instances for predictable workloads
- Monitor and optimize data transfer costs

## 🤝 Contributing

This solution is based on the [AWS Pixel Streaming at Scale sample](https://github.com/aws-samples/pixel-streaming-at-scale) and Epic Games' [Pixel Streaming Infrastructure](https://github.com/EpicGames/PixelStreamingInfrastructure).

### Development
1. Fork the repository
2. Create a feature branch
3. Make changes and test thoroughly
4. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Related Resources

- [Epic Games Pixel Streaming Documentation](https://docs.unrealengine.com/5.2/en-US/pixel-streaming-in-unreal-engine/)
- [AWS Pixel Streaming at Scale](https://github.com/aws-samples/pixel-streaming-at-scale)
- [Unreal Engine Pixel Streaming Infrastructure](https://github.com/EpicGames/PixelStreamingInfrastructure)
- [AWS CloudFormation Documentation](https://docs.aws.amazon.com/cloudformation/)

## 📞 Support

For issues related to:
- **Deployment scripts**: Check troubleshooting guide or open an issue
- **Epic Games Pixel Streaming**: Refer to Epic Games documentation
- **AWS services**: Consult AWS documentation and support

---

**🎮 Happy Streaming!** 🚀
