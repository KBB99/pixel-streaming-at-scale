#!/bin/bash

# User data script for Frontend AMI creation
# This script configures an EC2 instance to run the React Frontend

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
dnf install -y --allowerasing git wget curl nginx

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
    
    # Build Frontend
    if [[ -d "/usr/customapps/pixelstreaming/Frontend/implementations/react" ]]; then
        print_status "Building Frontend..."
        cd /usr/customapps/pixelstreaming/Frontend/implementations/react
        sudo -u ec2-user npm install
        cd -
    fi
    
    print_status "Frontend code downloaded and built from S3"
else
    print_warning "S3_BUCKET not set - application code must be deployed separately"
fi

# Install PM2 for process management
npm install -g pm2
npm install -g webpack webpack-cli

# Install serve for serving built React apps
npm install -g serve

# Create systemd service for Frontend
cat > /etc/systemd/system/frontend.service << 'EOF'
[Unit]
Description=Pixel Streaming Frontend
After=network.target

[Service]
Type=simple
User=ec2-user
WorkingDirectory=/usr/customapps/pixelstreaming/Frontend/implementations/react
ExecStart=/usr/bin/serve -s dist -l 8080
Restart=always
RestartSec=5
Environment=NODE_ENV=production

[Install]
WantedBy=multi-user.target
EOF

# Enable the service (but don't start it yet)
systemctl enable frontend.service

# Create log directory
mkdir -p /var/log/pixelstreaming
chown -R ec2-user:ec2-user /var/log/pixelstreaming

# Create startup script for development mode
cat > /usr/customapps/pixelstreaming/start-frontend-dev.sh << 'EOF'
#!/bin/bash
cd /usr/customapps/pixelstreaming/Frontend/implementations/react
export NODE_ENV=development
npm run start > /var/log/pixelstreaming/frontend-dev.log 2>&1 &
echo $! > /var/run/frontend-dev.pid
EOF

chmod +x /usr/customapps/pixelstreaming/start-frontend-dev.sh

# Create startup script for production mode
cat > /usr/customapps/pixelstreaming/start-frontend.sh << 'EOF'
#!/bin/bash
cd /usr/customapps/pixelstreaming/Frontend/implementations/react

# Build the application if not already built
if [ ! -d "dist" ]; then
    echo "Building frontend application..."
    npm run build
fi

# Start serving the built application
export NODE_ENV=production
serve -s dist -l 8080 > /var/log/pixelstreaming/frontend.log 2>&1 &
echo $! > /var/run/frontend.pid
EOF

chmod +x /usr/customapps/pixelstreaming/start-frontend.sh

# Create stop script
cat > /usr/customapps/pixelstreaming/stop-frontend.sh << 'EOF'
#!/bin/bash
if [ -f /var/run/frontend.pid ]; then
    kill $(cat /var/run/frontend.pid)
    rm /var/run/frontend.pid
fi

if [ -f /var/run/frontend-dev.pid ]; then
    kill $(cat /var/run/frontend-dev.pid)
    rm /var/run/frontend-dev.pid
fi
EOF

chmod +x /usr/customapps/pixelstreaming/stop-frontend.sh

# Set up log rotation
cat > /etc/logrotate.d/pixelstreaming-frontend << 'EOF'
/var/log/pixelstreaming/frontend*.log {
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
cat > /usr/customapps/pixelstreaming/health-check-frontend.sh << 'EOF'
#!/bin/bash
# Simple health check for Frontend
curl -f http://localhost:8080/ || exit 1
EOF

chmod +x /usr/customapps/pixelstreaming/health-check-frontend.sh

# Configure firewall (if enabled)
if systemctl is-active --quiet firewalld; then
    firewall-cmd --permanent --add-port=8080/tcp
    firewall-cmd --permanent --add-port=3000/tcp
    firewall-cmd --reload
fi

# Install CloudWatch agent
wget https://s3.amazonaws.com/amazoncloudwatch-agent/amazon_linux/amd64/latest/amazon-cloudwatch-agent.rpm
rpm -U ./amazon-cloudwatch-agent.rpm
rm -f ./amazon-cloudwatch-agent.rpm

# Create CloudWatch agent config for Frontend
cat > /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json << 'EOF'
{
    "metrics": {
        "namespace": "PixelStreaming/Frontend",
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
                        "file_path": "/var/log/pixelstreaming/frontend.log",
                        "log_group_name": "/aws/pixelstreaming/frontend",
                        "log_stream_name": "{instance_id}"
                    },
                    {
                        "file_path": "/var/log/pixelstreaming/frontend-dev.log",
                        "log_group_name": "/aws/pixelstreaming/frontend-dev",
                        "log_stream_name": "{instance_id}"
                    }
                ]
            }
        }
    }
}
EOF

# Create environment configuration script
cat > /usr/customapps/pixelstreaming/configure-frontend-env.sh << 'EOF'
#!/bin/bash

# This script updates the frontend environment variables
# It should be run after CloudFormation deployment to set correct endpoints

WEBPACK_CONFIG="/usr/customapps/pixelstreaming/Frontend/implementations/react/webpack.dev.js"

# Function to update webpack config with environment variables
update_webpack_config() {
    local config_file="$1"
    local client_id="$2"
    local cognito_domain="$3"
    local client_secret="$4"
    local callback_uri="$5"
    local api_ws="$6"
    local sig_ws="$7"
    local sec_token="$8"
    
    if [ -f "$config_file" ]; then
        # Backup original config
        cp "$config_file" "${config_file}.backup"
        
        # Replace environment variables in webpack config
        sed -i "s|'process.env.client_id_cog': JSON.stringify('')|'process.env.client_id_cog': JSON.stringify('${client_id}')|g" "$config_file"
        sed -i "s|'process.env.cognito_domain': JSON.stringify('')|'process.env.cognito_domain': JSON.stringify('${cognito_domain}')|g" "$config_file"
        sed -i "s|'process.env.client_secret_cog': JSON.stringify('')|'process.env.client_secret_cog': JSON.stringify('${client_secret}')|g" "$config_file"
        sed -i "s|'process.env.callback_uri_cog': JSON.stringify('')|'process.env.callback_uri_cog': JSON.stringify('${callback_uri}')|g" "$config_file"
        sed -i "s|'process.env.api_ws': JSON.stringify('')|'process.env.api_ws': JSON.stringify('${api_ws}')|g" "$config_file"
        sed -i "s|'process.env.sig_ws': JSON.stringify('')|'process.env.sig_ws': JSON.stringify('${sig_ws}')|g" "$config_file"
        sed -i "s|'process.env.sec_token': JSON.stringify('')|'process.env.sec_token': JSON.stringify('${sec_token}')|g" "$config_file"
        
        echo "Webpack configuration updated successfully"
    else
        echo "ERROR: Webpack config file not found at $config_file"
        exit 1
    fi
}

# Check if all required parameters are provided
if [ $# -eq 7 ]; then
    update_webpack_config "$WEBPACK_CONFIG" "$1" "$2" "$3" "$4" "$5" "$6" "$7"
    
    # Rebuild the application with new configuration
    cd /usr/customapps/pixelstreaming/Frontend/implementations/react
    npm run build
    
    # Restart the frontend service
    systemctl restart frontend.service
    
    echo "Frontend configuration and restart complete"
else
    echo "Usage: $0 <client_id> <cognito_domain> <client_secret> <callback_uri> <api_ws> <sig_ws> <sec_token>"
    exit 1
fi
EOF

chmod +x /usr/customapps/pixelstreaming/configure-frontend-env.sh

# Create nginx reverse proxy config (alternative to direct serve)
cat > /etc/nginx/conf.d/frontend.conf << 'EOF'
server {
    listen 80;
    server_name _;
    
    location / {
        proxy_pass http://localhost:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF

# Enable nginx but don't start it (optional reverse proxy)
systemctl enable nginx

echo "Frontend AMI setup complete"
