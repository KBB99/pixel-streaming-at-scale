#!/bin/bash

# User data script for SignallingWebServer AMI creation
# This script configures an EC2 instance to run the SignallingWebServer

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
    
    # Build SignallingWebServer
    if [[ -d "/usr/customapps/pixelstreaming/SignallingWebServer" ]]; then
        print_status "Building SignallingWebServer..."
        cd /usr/customapps/pixelstreaming/SignallingWebServer
        sudo -u ec2-user npm install
        cd -
    fi
    
    print_status "SignallingWebServer code downloaded and built from S3"
else
    print_warning "S3_BUCKET not set - application code must be deployed separately"
fi

# Install PM2 for process management
npm install -g pm2

# Create systemd service for SignallingWebServer
cat > /etc/systemd/system/signalling.service << 'EOF'
[Unit]
Description=Pixel Streaming Signalling Server
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/usr/customapps/pixelstreaming/SignallingWebServer
ExecStart=/usr/bin/node cirrus.js
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# Enable the service (but don't start it yet)
systemctl enable signalling.service

# Create log directory
mkdir -p /var/log/pixelstreaming
chown -R ec2-user:ec2-user /var/log/pixelstreaming

# Create startup script
cat > /usr/customapps/pixelstreaming/start-signalling.sh << 'EOF'
#!/bin/bash
cd /usr/customapps/pixelstreaming/SignallingWebServer
export NODE_ENV=production
node cirrus.js > /var/log/pixelstreaming/signalling.log 2>&1 &
echo $! > /var/run/signalling.pid
EOF

chmod +x /usr/customapps/pixelstreaming/start-signalling.sh

# Create stop script
cat > /usr/customapps/pixelstreaming/stop-signalling.sh << 'EOF'
#!/bin/bash
if [ -f /var/run/signalling.pid ]; then
    kill $(cat /var/run/signalling.pid)
    rm /var/run/signalling.pid
fi
EOF

chmod +x /usr/customapps/pixelstreaming/stop-signalling.sh

# Install additional dependencies that might be needed
npm install -g typescript ts-node

# Set up log rotation
cat > /etc/logrotate.d/pixelstreaming << 'EOF'
/var/log/pixelstreaming/*.log {
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
cat > /usr/customapps/pixelstreaming/health-check.sh << 'EOF'
#!/bin/bash
# Simple health check for SignallingWebServer
curl -f http://localhost:80/health || exit 1
EOF

chmod +x /usr/customapps/pixelstreaming/health-check.sh

# Configure firewall (if enabled)
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=80/tcp
    firewall-cmd --permanent --add-port=443/tcp
    firewall-cmd --permanent --add-port=8888/tcp
    firewall-cmd --reload
fi

# Install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm
rm -f ./amazon-cloudwatch-agent.rpm

# Create CloudWatch agent config
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
    "metrics": {
        "namespace": "PixelStreaming/SignallingServer",
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
                        "file_path": "/var/log/pixelstreaming/signalling.log",
                        "log_group_name": "/aws/pixelstreaming/signalling",
                        "log_stream_name": "{instance_id}"
                    }
                ]
            }
        }
    }
}
EOF

echo "SignallingWebServer AMI setup complete"
