#!/bin/bash
set -e

# Upload PMTiles and style JSON files to Google Cloud Storage
# Usage: ./scripts/upload-to-gcs.sh [--dry-run]

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/output"

GCS_BUCKET="gs://ut-dnr-ugs-bucket-server-prod/pmtiles"

DRY_RUN=false
if [ "$1" = "--dry-run" ]; then
  DRY_RUN=true
  echo "=== DRY RUN MODE ==="
fi

echo "=== Uploading to GCS ==="
echo "Source: $OUTPUT_DIR"
echo "Destination: $GCS_BUCKET"

# Check if output directory exists and has files
if [ ! -d "$OUTPUT_DIR" ]; then
  echo "Error: Output directory does not exist: $OUTPUT_DIR"
  exit 1
fi

PMTILES_COUNT=$(find "$OUTPUT_DIR" -name "*.pmtiles" 2>/dev/null | wc -l | tr -d ' ')
JSON_COUNT=$(find "$OUTPUT_DIR" -name "*.json" 2>/dev/null | wc -l | tr -d ' ')

echo "Found $PMTILES_COUNT PMTiles files"
echo "Found $JSON_COUNT JSON style files"

if [ "$PMTILES_COUNT" -eq 0 ]; then
  echo "Error: No PMTiles files found in $OUTPUT_DIR"
  exit 1
fi

# List files to upload
echo ""
echo "Files to upload:"
ls -lh "$OUTPUT_DIR"/*.pmtiles "$OUTPUT_DIR"/*.json 2>/dev/null || true
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "Would run: gsutil -m cp $OUTPUT_DIR/*.pmtiles $OUTPUT_DIR/*.json $GCS_BUCKET/"
  exit 0
fi

# Upload with parallel transfers
echo "Uploading..."
gsutil -m cp "$OUTPUT_DIR"/*.pmtiles "$OUTPUT_DIR"/*.json "$GCS_BUCKET/"

echo ""
echo "=== Upload complete ==="
echo "Verifying..."
gsutil ls -l "$GCS_BUCKET/" | head -20

echo ""
echo "Public URLs:"
for f in "$OUTPUT_DIR"/*.pmtiles; do
  BASENAME=$(basename "$f")
  echo "  https://storage.googleapis.com/ut-dnr-ugs-bucket-server-prod/pmtiles/$BASENAME"
done
