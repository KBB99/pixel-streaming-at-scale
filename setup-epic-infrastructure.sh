#!/bin/bash

# Setup Epic Games Pixel Streaming Infrastructure and merge with this repository
# This script downloads Epic's base infrastructure and merges the AWS scaling modifications

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/deployment-config.json"
WORK_DIR="$SCRIPT_DIR/epic-infrastructure"
CURRENT_REPO_DIR="$SCRIPT_DIR"

# Load configuration
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo -e "${RED}Error: Configuration file not found at $CONFIG_FILE${NC}"
    exit 1
fi

EPIC_REPO_URL=$(jq -r '.infrastructure.epicRepoUrl' "$CONFIG_FILE")
EPIC_BRANCH=$(jq -r '.infrastructure.epicRepoBranch' "$CONFIG_FILE")

echo -e "${BLUE}=== Epic Games Pixel Streaming Infrastructure Setup ===${NC}"
echo -e "${YELLOW}Repository: $EPIC_REPO_URL${NC}"
echo -e "${YELLOW}Branch: $EPIC_BRANCH${NC}"
echo ""

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

# Check prerequisites
print_status "Checking prerequisites..."

if ! command -v git &> /dev/null; then
    print_error "git is required but not installed"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    print_error "jq is required but not installed. Please install: sudo apt-get install jq (Ubuntu/Debian) or brew install jq (macOS)"
    exit 1
fi

if ! command -v node &> /dev/null; then
    print_error "Node.js is required but not installed"
    exit 1
fi

if ! command -v npm &> /dev/null; then
    print_error "npm is required but not installed"
    exit 1
fi

print_status "Prerequisites check passed"

# Clean up existing directory if it exists
if [[ -d "$WORK_DIR" ]]; then
    print_warning "Removing existing Epic infrastructure directory..."
    rm -rf "$WORK_DIR"
fi

# Clone Epic's repository
print_status "Cloning Epic Games Pixel Streaming Infrastructure..."
git clone "$EPIC_REPO_URL" "$WORK_DIR"

cd "$WORK_DIR"
git checkout "$EPIC_BRANCH"

print_status "Successfully cloned Epic's infrastructure (branch: $EPIC_BRANCH)"

# Merge SignallingWebServer changes
print_status "Merging SignallingWebServer modifications..."
if [[ -d "$CURRENT_REPO_DIR/SignallingWebServer" ]]; then
    cp -r "$CURRENT_REPO_DIR/SignallingWebServer/"* "$WORK_DIR/SignallingWebServer/"
    print_status "SignallingWebServer files merged"
else
    print_warning "No SignallingWebServer directory found in current repository"
fi

# Merge Matchmaker changes
print_status "Merging Matchmaker modifications..."
if [[ -d "$CURRENT_REPO_DIR/Matchmaker" ]]; then
    cp -r "$CURRENT_REPO_DIR/Matchmaker/"* "$WORK_DIR/Matchmaker/"
    print_status "Matchmaker files merged"
else
    print_warning "No Matchmaker directory found in current repository"
fi

# Copy Frontend (this appears to be a complete React implementation)
print_status "Copying Frontend implementation..."
if [[ -d "$CURRENT_REPO_DIR/Frontend" ]]; then
    cp -r "$CURRENT_REPO_DIR/Frontend" "$WORK_DIR/"
    print_status "Frontend copied"
else
    print_warning "No Frontend directory found in current repository"
fi

# Install dependencies for each component
print_status "Installing dependencies..."

# SignallingWebServer dependencies
if [[ -f "$WORK_DIR/SignallingWebServer/package.json" ]]; then
    print_status "Installing SignallingWebServer dependencies..."
    cd "$WORK_DIR/SignallingWebServer"
    npm install
fi

# Matchmaker dependencies
if [[ -f "$WORK_DIR/Matchmaker/package.json" ]]; then
    print_status "Installing Matchmaker dependencies..."
    cd "$WORK_DIR/Matchmaker"
    npm install
fi

# Frontend dependencies
if [[ -f "$WORK_DIR/Frontend/implementations/react/package.json" ]]; then
    print_status "Installing Frontend dependencies..."
    cd "$WORK_DIR/Frontend/implementations/react"
    npm install
fi

# Create build scripts
print_status "Creating build scripts..."

# SignallingWebServer build script
cat > "$WORK_DIR/SignallingWebServer/build.sh" << 'EOF'
#!/bin/bash
set -e
echo "Building SignallingWebServer..."
npm install
echo "SignallingWebServer build complete"
EOF

# Matchmaker build script  
cat > "$WORK_DIR/Matchmaker/build.sh" << 'EOF'
#!/bin/bash
set -e
echo "Building Matchmaker..."
npm install
echo "Matchmaker build complete"
EOF

# Frontend build script
cat > "$WORK_DIR/Frontend/implementations/react/build.sh" << 'EOF'
#!/bin/bash
set -e
echo "Building Frontend..."
npm install
npm run build
echo "Frontend build complete"
EOF

# Make build scripts executable
chmod +x "$WORK_DIR/SignallingWebServer/build.sh"
chmod +x "$WORK_DIR/Matchmaker/build.sh"
chmod +x "$WORK_DIR/Frontend/implementations/react/build.sh"

# Create deployment info file
cat > "$WORK_DIR/deployment-info.json" << EOF
{
  "setup_date": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "epic_repo": "$EPIC_REPO_URL",
  "epic_branch": "$EPIC_BRANCH",
  "epic_commit": "$(git rev-parse HEAD)",
  "components": {
    "signalling_server": {
      "path": "SignallingWebServer",
      "build_script": "build.sh"
    },
    "matchmaker": {
      "path": "Matchmaker", 
      "build_script": "build.sh"
    },
    "frontend": {
      "path": "Frontend/implementations/react",
      "build_script": "build.sh"
    }
  }
}
EOF

cd "$SCRIPT_DIR"

print_status "Epic Games infrastructure setup complete!"
echo ""
echo -e "${GREEN}=== Setup Summary ===${NC}"
echo -e "Epic infrastructure location: ${BLUE}$WORK_DIR${NC}"
echo -e "Components merged:"
echo -e "  ${GREEN}✓${NC} SignallingWebServer"
echo -e "  ${GREEN}✓${NC} Matchmaker"
echo -e "  ${GREEN}✓${NC} Frontend"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo -e "1. Run ${BLUE}./create-amis.sh${NC} to build and create AMIs"
echo -e "2. Run ${BLUE}./deploy-infrastructure.sh${NC} to deploy to AWS"
echo ""
