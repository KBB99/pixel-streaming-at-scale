#!/bin/bash

# Package Lambda functions for deployment
# This script packages the Lambda functions from the repository

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_LAMBDA_DIR="$(dirname "$SCRIPT_DIR")/Lambda"
OUTPUT_DIR="$SCRIPT_DIR/packages"

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

print_status "Packaging Lambda functions..."

# Create output directory
mkdir -p "$OUTPUT_DIR"

# List of Lambda functions to package
LAMBDA_FUNCTIONS=(
    "authorizeClient"
    "createInstances"
    "keepConnectionAlive"
    "poller"
    "registerInstances"
    "requestSession"
    "sendSessionDetails"
    "terminateInstance"
    "uploadToDDB"
)

# Package each Lambda function
for func in "${LAMBDA_FUNCTIONS[@]}"; do
    print_status "Packaging $func..."
    
    if [[ -f "$SOURCE_LAMBDA_DIR/$func.py" ]]; then
        # Create temporary directory
        temp_dir=$(mktemp -d)
        
        # Copy Python file
        cp "$SOURCE_LAMBDA_DIR/$func.py" "$temp_dir/lambda_function.py"
        
        # Create deployment package
        cd "$temp_dir"
        zip -r "$OUTPUT_DIR/$func.zip" lambda_function.py
        
        # Cleanup
        cd "$SCRIPT_DIR"
        rm -rf "$temp_dir"
        
        print_status "$func packaged successfully"
    else
        print_warning "$func.py not found in $SOURCE_LAMBDA_DIR"
    fi
done

print_status "Lambda packaging complete!"
echo ""
echo "Packaged functions saved to: $OUTPUT_DIR"
echo ""
