#!/bin/bash
set -e

# Upload PMTiles and style JSON files to Google Cloud Storage
# Usage: ./scripts/upload-to-gcs.sh [--dry-run] [--force] [file1] [file2] ...
#        ./scripts/upload-to-gcs.sh output/hazards.json
#        ./scripts/upload-to-gcs.sh output/hazards.pmtiles output/hazards.json

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
OUTPUT_DIR="$PROJECT_ROOT/output"

GCS_BUCKET="gs://ut-dnr-ugs-bucket-server-prod/pmtiles"
PUBLIC_URL="https://storage.googleapis.com/ut-dnr-ugs-bucket-server-prod/pmtiles"

DRY_RUN=false
FORCE=false
FILES_TO_UPLOAD=()

for arg in "$@"; do
  case $arg in
    --dry-run) DRY_RUN=true ;;
    --force) FORCE=true ;;
    *)
      # It's a file path
      if [ -f "$arg" ]; then
        FILES_TO_UPLOAD+=("$arg")
      elif [ -f "$OUTPUT_DIR/$(basename "$arg")" ]; then
        FILES_TO_UPLOAD+=("$OUTPUT_DIR/$(basename "$arg")")
      fi
      ;;
  esac
done

if [ "$DRY_RUN" = true ]; then
  echo "=== DRY RUN MODE ==="
fi

echo "=== Uploading to GCS ==="
echo "Destination: $GCS_BUCKET"
echo ""

# If no specific files provided, find all in output dir
if [ ${#FILES_TO_UPLOAD[@]} -eq 0 ]; then
  # Check if output directory exists
  if [ ! -d "$OUTPUT_DIR" ]; then
    echo "Error: Output directory does not exist: $OUTPUT_DIR"
    exit 1
  fi

  # Get list of local files
  while IFS= read -r -d '' file; do
    FILES_TO_UPLOAD+=("$file")
  done < <(find "$OUTPUT_DIR" -name "*.pmtiles" -print0 2>/dev/null)

  while IFS= read -r -d '' file; do
    FILES_TO_UPLOAD+=("$file")
  done < <(find "$OUTPUT_DIR" -name "*.json" -print0 2>/dev/null)

  if [ ${#FILES_TO_UPLOAD[@]} -eq 0 ]; then
    echo "Error: No PMTiles or JSON files found in $OUTPUT_DIR"
    exit 1
  fi

  echo "Source: $OUTPUT_DIR (all files)"
else
  echo "Source: ${#FILES_TO_UPLOAD[@]} specified file(s)"
fi

echo ""

# Get list of remote files
echo "Checking existing files in GCS..."
REMOTE_FILES=$(gsutil ls "$GCS_BUCKET/" 2>/dev/null || echo "")

# Compare local vs remote
echo ""
echo "Files to upload:"
echo "----------------"

WILL_REPLACE=()
WILL_ADD=()

for local_file in "${FILES_TO_UPLOAD[@]}"; do
  BASENAME=$(basename "$local_file")
  LOCAL_SIZE=$(du -h "$local_file" | cut -f1)
  REMOTE_PATH="$GCS_BUCKET/$BASENAME"

  if echo "$REMOTE_FILES" | grep -q "$BASENAME"; then
    # File exists remotely - get its size
    REMOTE_SIZE=$(gsutil ls -l "$REMOTE_PATH" 2>/dev/null | awk '{print $1}' | head -1)
    REMOTE_SIZE_H=$(numfmt --to=iec "$REMOTE_SIZE" 2>/dev/null || echo "$REMOTE_SIZE")
    echo "  [REPLACE] $BASENAME (local: $LOCAL_SIZE, remote: $REMOTE_SIZE_H)"
    WILL_REPLACE+=("$local_file")
  else
    echo "  [NEW]     $BASENAME ($LOCAL_SIZE)"
    WILL_ADD+=("$local_file")
  fi
done

echo ""
echo "Summary: ${#WILL_ADD[@]} new, ${#WILL_REPLACE[@]} replacements"
echo ""

if [ "$DRY_RUN" = true ]; then
  echo "Dry run complete. No files uploaded."
  exit 0
fi

# Confirm if replacing files (unless --force)
if [ ${#WILL_REPLACE[@]} -gt 0 ] && [ "$FORCE" != true ]; then
  read -p "Replace ${#WILL_REPLACE[@]} existing files? (y/N) " -n 1 -r
  echo
  if [[ ! $REPLY =~ ^[Yy]$ ]]; then
    echo "Aborted."
    exit 1
  fi
fi

# Upload files
echo "Uploading..."
for local_file in "${FILES_TO_UPLOAD[@]}"; do
  gsutil cp "$local_file" "$GCS_BUCKET/"
done

echo ""
echo "=== Upload complete ==="
echo ""
echo "Public URLs:"
for local_file in "${FILES_TO_UPLOAD[@]}"; do
  BASENAME=$(basename "$local_file")
  echo "  $PUBLIC_URL/$BASENAME"
done
