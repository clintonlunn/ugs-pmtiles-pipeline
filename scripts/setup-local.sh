#!/bin/bash

echo "=== UGS PMTiles Pipeline - Local Setup ==="
echo ""

# Check for required commands
check_command() {
  if command -v $1 &> /dev/null; then
    echo "✓ $1 found"
    return 0
  else
    echo "✗ $1 not found"
    return 1
  fi
}

MISSING=0

echo "Checking dependencies..."
echo ""

# Check GDAL/OGR
if check_command "ogr2ogr"; then
  OGR_VERSION=$(ogr2ogr --version | head -1)
  echo "  Version: $OGR_VERSION"
else
  MISSING=1
  echo "  Install: brew install gdal (macOS) or sudo apt-get install gdal-bin (Ubuntu)"
fi
echo ""

# Check jq
if check_command "jq"; then
  JQ_VERSION=$(jq --version)
  echo "  Version: $JQ_VERSION"
else
  MISSING=1
  echo "  Install: brew install jq (macOS) or sudo apt-get install jq (Ubuntu)"
fi
echo ""

# Check tippecanoe
if check_command "tippecanoe"; then
  TIPPECANOE_VERSION=$(tippecanoe --version 2>&1 | head -1 || echo "installed")
  echo "  Version: $TIPPECANOE_VERSION"
else
  MISSING=1
  echo "  Install: brew install tippecanoe (macOS)"
  echo "  Or build from source: https://github.com/felt/tippecanoe"
fi
echo ""

# Check gsutil (optional)
if check_command "gsutil"; then
  echo "  (optional for GCS uploads)"
else
  echo "  (optional - only needed for GCS uploads)"
  echo "  Install: https://cloud.google.com/sdk/docs/install"
fi
echo ""

# Check development tools
echo "Development tools (optional):"
echo ""

if check_command "shellcheck"; then
  SHELLCHECK_VERSION=$(shellcheck --version | grep version: | awk '{print $2}')
  echo "  Version: $SHELLCHECK_VERSION"
else
  echo "  (optional - for linting bash scripts)"
  echo "  Install: brew install shellcheck (macOS) or sudo apt-get install shellcheck (Ubuntu)"
fi
echo ""

if check_command "npm"; then
  NPM_VERSION=$(npm --version)
  echo "  Version: npm $NPM_VERSION"
  echo ""
  echo "Installing Node.js dependencies..."
  npm install
else
  echo "  (optional - for prettier formatting and pre-commit hooks)"
  echo "  Install: https://nodejs.org/"
fi
echo ""

if [ $MISSING -eq 0 ]; then
  echo "=== Setup complete! All required dependencies installed ==="
  echo ""
  echo "Try running:"
  echo "  ./scripts/convert-layer.sh hazards:quaternaryfaults_current"
  echo ""
  echo "Or run linting:"
  echo "  npm run lint"
else
  echo "=== Missing dependencies - please install the above ==="
  exit 1
fi
