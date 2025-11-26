#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# GCS bucket from environment variable
GCS_BUCKET=${GCS_BUCKET:-"gs://ugs-pmtiles"}

echo "=== UGS PMTiles Cloud Pipeline ==="
echo "GCS Bucket: $GCS_BUCKET"
echo ""

# Run conversion
"$SCRIPT_DIR/convert-all.sh"

# Upload to GCS
echo ""
echo "=== Uploading to GCS ==="

if [ -d "$PROJECT_ROOT/output" ]; then
  gsutil -m cp -r "$PROJECT_ROOT/output/*.pmtiles" "$GCS_BUCKET/"
  echo "Upload complete!"
else
  echo "No output directory found"
  exit 1
fi

# Optional: Set public access
# gsutil -m acl ch -u AllUsers:R "$GCS_BUCKET/*.pmtiles"

echo ""
echo "=== Pipeline complete ==="
