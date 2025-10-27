#!/bin/bash

# User data script for Matchmaker AMI creation
# This script configures an EC2 instance to run the Matchmaker

set -e

# Function to print status
print_status() {
    echo "[INFO] $1"
}

print_warning() {
    echo "[WARNING] $1"
}

# Update system
dnf update -y

# Install Node.js 18 (LTS)
curl -fsSL https://rpm.nodesource.com/setup_18.x | bash -
dnf install -y --allowerasing nodejs

# Install development tools
dnf groupinstall -y "Development Tools"
dnf install -y --allowerasing git wget curl

# Install Docker
dnf install -y --allowerasing docker
systemctl start docker
systemctl enable docker
usermod -a -G docker ec2-user

# Install AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o "awscliv2.zip"
unzip awscliv2.zip
./aws/install
rm -rf aws awscliv2.zip

# Create application directory
mkdir -p /usr/customapps/pixelstreaming
chown -R ec2-user:ec2-user /usr/customapps/pixelstreaming

# Download application code from S3 (much faster than SCP!)
if [[ -n "$S3_BUCKET" ]]; then
    print_status "Downloading Epic infrastructure from S3: $S3_BUCKET"
    aws s3 sync "s3://$S3_BUCKET/epic-infrastructure/" /usr/customapps/pixelstreaming/ --region "$AWS_REGION"
    chown -R ec2-user:ec2-user /usr/customapps/pixelstreaming/
    
    # Build Matchmaker
    if [[ -d "/usr/customapps/pixelstreaming/Matchmaker" ]]; then
        print_status "Building Matchmaker..."
        cd /usr/customapps/pixelstreaming/Matchmaker
        sudo -u ec2-user npm install
        cd -
    fi
    
    print_status "Matchmaker code downloaded and built from S3"
else
    print_warning "S3_BUCKET not set - application code must be deployed separately"
fi

# Install PM2 for process management
npm install -g pm2

# Create systemd service for Matchmaker
cat > /etc/systemd/system/matchmaker.service << 'EOF'
[Unit]
Description=Pixel Streaming Matchmaker
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/usr/customapps/pixelstreaming/Matchmaker
ExecStart=/usr/bin/node matchmaker.js --httpPort 90
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# Enable the service (but don't start it yet)
systemctl enable matchmaker.service

# Create log directory
mkdir -p /var/log/pixelstreaming
chown -R ec2-user:ec2-user /var/log/pixelstreaming

# Create startup script
cat > /usr/customapps/pixelstreaming/start-matchmaker.sh << 'EOF'
#!/bin/bash
cd /usr/customapps/pixelstreaming/Matchmaker
export NODE_ENV=production
node matchmaker.js --httpPort 90 > /var/log/pixelstreaming/matchmaker.log 2>&1 &
echo $! > /var/run/matchmaker.pid
EOF

chmod +x /usr/customapps/pixelstreaming/start-matchmaker.sh

# Create stop script
cat > /usr/customapps/pixelstreaming/stop-matchmaker.sh << 'EOF'
#!/bin/bash
if [ -f /var/run/matchmaker.pid ]; then
    kill $(cat /var/run/matchmaker.pid)
    rm /var/run/matchmaker.pid
fi
EOF

chmod +x /usr/customapps/pixelstreaming/stop-matchmaker.sh

# Install additional dependencies that might be needed
npm install -g typescript ts-node

# Set up log rotation
cat > /etc/logrotate.d/pixelstreaming-matchmaker << 'EOF'
/var/log/pixelstreaming/matchmaker.log {
    daily
    rotate 7
    compress
    delaycompress
    missingok
    notifempty
    create 0644 ec2-user ec2-user
}
EOF

# Create health check script
cat > /usr/customapps/pixelstreaming/health-check-matchmaker.sh << 'EOF'
#!/bin/bash
# Simple health check for Matchmaker
curl -f http://localhost:90/health || exit 1
EOF

chmod +x /usr/customapps/pixelstreaming/health-check-matchmaker.sh

# Configure firewall (if enabled)
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=90/tcp
    firewall-cmd --permanent --add-port=9999/tcp
    firewall-cmd --reload
fi

# Install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm
rm -f ./amazon-cloudwatch-agent.rpm

# Create CloudWatch agent config for Matchmaker
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
    "metrics": {
        "namespace": "PixelStreaming/Matchmaker",
        "metrics_collected": {
            "cpu": {
                "measurement": ["cpu_usage_idle", "cpu_usage_iowait", "cpu_usage_user", "cpu_usage_system"],
                "metrics_collection_interval": 60
            },
            "disk": {
                "measurement": ["used_percent"],
                "metrics_collection_interval": 60,
                "resources": ["*"]
            },
            "mem": {
                "measurement": ["mem_used_percent"],
                "metrics_collection_interval": 60
            }
        }
    },
    "logs": {
        "logs_collected": {
            "files": {
                "collect_list": [
                    {
                        "file_path": "/var/log/pixelstreaming/matchmaker.log",
                        "log_group_name": "/aws/pixelstreaming/matchmaker",
                        "log_stream_name": "{instance_id}"
                    }
                ]
            }
        }
    }
}
EOF

# Create initialization script for runtime configuration
cat > /usr/customapps/pixelstreaming/configure-matchmaker.sh << 'EOF'
#!/bin/bash

# This script configures the matchmaker at runtime with AWS-specific settings
# It should be run after the application code is deployed

CONFIG_FILE="/usr/customapps/pixelstreaming/Matchmaker/config.json"

# Get instance metadata
INSTANCE_ID=$(curl -s http://169.254.169.254/latest/meta-data/instance-id)
AVAILABILITY_ZONE=$(curl -s http://169.254.169.254/latest/meta-data/placement/availability-zone)
REGION=${AVAILABILITY_ZONE%?}

# Update config with runtime values
if [ -f "$CONFIG_FILE" ]; then
    # Backup original config
    cp "$CONFIG_FILE" "${CONFIG_FILE}.backup"
    
    # Update config with instance-specific values
    # This will be customized based on the actual config structure
    echo "Matchmaker configuration script executed on instance: $INSTANCE_ID"
fi
EOF

chmod +x /usr/customapps/pixelstreaming/configure-matchmaker.sh

echo "Matchmaker AMI setup complete"
