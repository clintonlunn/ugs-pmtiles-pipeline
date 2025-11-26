#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$PROJECT_ROOT/config"

echo "=== UGS PMTiles Conversion Pipeline ==="
echo ""

# Read enabled layers from config
ENABLED_LAYERS=$(jq -r '.layers[] | select(.enabled == true) | .fullName' "$CONFIG_DIR/layers.json")

LAYER_COUNT=$(echo "$ENABLED_LAYERS" | wc -l)
echo "Found $LAYER_COUNT enabled layers"
echo ""

CURRENT=0
for LAYER in $ENABLED_LAYERS; do
  CURRENT=$((CURRENT + 1))
  echo "[$CURRENT/$LAYER_COUNT] Processing $LAYER..."
  "$SCRIPT_DIR/convert-layer.sh" "$LAYER"
  echo ""
done

echo "=== All conversions complete ==="
echo "Output directory: $PROJECT_ROOT/output"

# Calculate total size
TOTAL_SIZE=$(du -sh "$PROJECT_ROOT/output" | cut -f1)
echo "Total size: $TOTAL_SIZE"
