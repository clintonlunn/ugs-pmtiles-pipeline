#!/bin/bash
set -e

# Usage: ./scripts/convert-layer.sh hazards:quaternaryfaults_current

LAYER_FULL_NAME=$1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$PROJECT_ROOT/config"
OUTPUT_DIR="$PROJECT_ROOT/output"
TEMP_DIR="$PROJECT_ROOT/temp"

if [ -z "$LAYER_FULL_NAME" ]; then
  echo "Usage: $0 <layer_name>"
  echo "Example: $0 hazards:quaternaryfaults_current"
  exit 1
fi

# Create directories
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

# Read datasource config
DATASOURCE_TYPE=$(jq -r '.type' "$CONFIG_DIR/datasource.json")

echo "=== Converting layer: $LAYER_FULL_NAME ==="
echo "Data source: $DATASOURCE_TYPE"

# Extract layer name for filenames
LAYER_SAFE_NAME=$(echo "$LAYER_FULL_NAME" | tr ':' '_')
GEOJSON_FILE="$TEMP_DIR/${LAYER_SAFE_NAME}.geojson"
PMTILES_FILE="$OUTPUT_DIR/${LAYER_SAFE_NAME}.pmtiles"

# Get layer config for zoom levels
LAYER_CONFIG=$(jq -r ".layers[] | select(.fullName == \"$LAYER_FULL_NAME\")" "$CONFIG_DIR/layers.json")
if [ -z "$LAYER_CONFIG" ]; then
  echo "Warning: Layer not found in config, using defaults"
  MIN_ZOOM=5
  MAX_ZOOM=14
else
  MIN_ZOOM=$(echo "$LAYER_CONFIG" | jq -r '.minZoom // 5')
  MAX_ZOOM=$(echo "$LAYER_CONFIG" | jq -r '.maxZoom // 14')
fi

echo "Zoom range: $MIN_ZOOM - $MAX_ZOOM"

# Step 1: Export to GeoJSON (data source abstraction)
echo "Step 1: Exporting to GeoJSON..."

if [ "$DATASOURCE_TYPE" = "wfs" ]; then
  # WFS approach - fetch JSON with pagination and reproject
  WFS_URL=$(jq -r '.wfs.url' "$CONFIG_DIR/datasource.json")

  echo "Fetching GeoJSON from WFS with pagination..."

  # Auto-detect sortable field for pagination
  echo "Detecting sortable field..."
  DESCRIBE_URL="${WFS_URL}?service=WFS&version=2.0.0&request=DescribeFeatureType&typeNames=${LAYER_FULL_NAME}&outputFormat=application/json"
  FIELD_INFO=$(curl -sL "$DESCRIBE_URL")

  # Try common primary key names first, then fall back to first integer field
  SORT_BY=""
  for CANDIDATE in ogc_fid gid fid id objectid; do
    if echo "$FIELD_INFO" | jq -e ".featureTypes[0].properties[] | select(.name == \"$CANDIDATE\")" > /dev/null 2>&1; then
      SORT_BY="$CANDIDATE"
      break
    fi
  done

  # If no PK found, try first int field, or first field as fallback
  if [ -z "$SORT_BY" ]; then
    SORT_BY=$(echo "$FIELD_INFO" | jq -r '.featureTypes[0].properties[] | select(.localType == "int" or .localType == "long") | .name' | head -1)
  fi
  if [ -z "$SORT_BY" ]; then
    SORT_BY=$(echo "$FIELD_INFO" | jq -r '.featureTypes[0].properties[0].name')
  fi

  echo "Using sortBy=$SORT_BY"

  # Pagination settings (1M = single request for most layers)
  PAGE_SIZE=1000000
  START_INDEX=0
  TOTAL_FEATURES=0
  PAGE_NUM=1

  # Temp files for pagination
  TEMP_GEOJSON="$TEMP_DIR/${LAYER_SAFE_NAME}_temp.geojson"
  MERGED_GEOJSON="$TEMP_DIR/${LAYER_SAFE_NAME}_merged.geojson"
  FEATURES_DIR="$TEMP_DIR/${LAYER_SAFE_NAME}_pages"

  # Clean up any previous run
  rm -rf "$FEATURES_DIR" "$MERGED_GEOJSON" "$TEMP_GEOJSON"
  mkdir -p "$FEATURES_DIR"

  echo "Page size: $PAGE_SIZE features per request"

  while true; do
    PAGE_FILE="$FEATURES_DIR/page_${PAGE_NUM}.json"
    REQUEST_URL="${WFS_URL}?service=WFS&version=2.0.0&request=GetFeature&typeNames=${LAYER_FULL_NAME}&outputFormat=application/json&count=${PAGE_SIZE}&startIndex=${START_INDEX}&sortBy=${SORT_BY}"

    echo -n "  Page $PAGE_NUM (startIndex=$START_INDEX)... "

    if ! curl -sL --max-time 120 -o "$PAGE_FILE" "$REQUEST_URL"; then
      echo "FAILED"
      echo "Error: Failed to fetch page $PAGE_NUM from WFS"
      exit 1
    fi

    # Check if valid GeoJSON
    if ! jq -e '.type == "FeatureCollection"' "$PAGE_FILE" > /dev/null 2>&1; then
      echo "INVALID"
      echo "Error: Invalid GeoJSON received on page $PAGE_NUM"
      head -50 "$PAGE_FILE"
      exit 1
    fi

    # Count features in this page
    PAGE_FEATURES=$(jq '.features | length' "$PAGE_FILE")
    echo "$PAGE_FEATURES features"

    TOTAL_FEATURES=$((TOTAL_FEATURES + PAGE_FEATURES))

    # If we got fewer than PAGE_SIZE, we've reached the end
    if [ "$PAGE_FEATURES" -lt "$PAGE_SIZE" ]; then
      echo "  Reached end of data"
      break
    fi

    START_INDEX=$((START_INDEX + PAGE_SIZE))
    PAGE_NUM=$((PAGE_NUM + 1))

    # Safety limit - don't fetch more than 1M features
    if [ "$TOTAL_FEATURES" -ge 1000000 ]; then
      echo "  Warning: Reached 1M feature safety limit"
      break
    fi
  done

  echo "Total fetched: $TOTAL_FEATURES features in $PAGE_NUM pages"

  # Merge all pages into single GeoJSON
  echo "Merging pages..."

  if [ "$PAGE_NUM" -eq 1 ]; then
    # Single page, just use it directly
    mv "$FEATURES_DIR/page_1.json" "$TEMP_GEOJSON"
  else
    # Multiple pages - merge features arrays
    echo '{"type":"FeatureCollection","features":[' > "$MERGED_GEOJSON"

    FIRST=true
    for PAGE_FILE in "$FEATURES_DIR"/page_*.json; do
      if [ "$FIRST" = true ]; then
        FIRST=false
      else
        echo ',' >> "$MERGED_GEOJSON"
      fi
      # Extract features array content (without brackets)
      jq -c '.features[]' "$PAGE_FILE" | paste -sd ',' >> "$MERGED_GEOJSON"
    done

    echo ']}' >> "$MERGED_GEOJSON"
    mv "$MERGED_GEOJSON" "$TEMP_GEOJSON"
  fi

  # Clean up page files
  rm -rf "$FEATURES_DIR"

  # Reproject to WGS84 (EPSG:4326) for PMTiles
  echo "Reprojecting to EPSG:4326..."
  ogr2ogr -f GeoJSON "$GEOJSON_FILE" \
    "$TEMP_GEOJSON" \
    -t_srs EPSG:4326 \
    -s_srs EPSG:26912

  rm "$TEMP_GEOJSON"

elif [ "$DATASOURCE_TYPE" = "postgis" ]; then
  # PostGIS approach (future - direct connection, much faster)
  PG_HOST=$(jq -r '.postgis.host' "$CONFIG_DIR/datasource.json")
  PG_PORT=$(jq -r '.postgis.port' "$CONFIG_DIR/datasource.json")
  PG_DB=$(jq -r '.postgis.database' "$CONFIG_DIR/datasource.json")
  PG_USER=$(jq -r '.postgis.user' "$CONFIG_DIR/datasource.json")
  PG_TABLE=$(echo "$LAYER_CONFIG" | jq -r '.postgisTable')

  ogr2ogr -f GeoJSON "$GEOJSON_FILE" \
    PG:"host=$PG_HOST port=$PG_PORT dbname=$PG_DB user=$PG_USER" \
    -sql "SELECT * FROM $PG_TABLE" \
    -progress
else
  echo "Error: Unknown datasource type: $DATASOURCE_TYPE"
  exit 1
fi

# Step 2: Convert to PMTiles
echo "Step 2: Converting to PMTiles..."

tippecanoe -o "$PMTILES_FILE" \
  -Z"$MIN_ZOOM" \
  -z"$MAX_ZOOM" \
  --drop-densest-as-needed \
  --extend-zooms-if-still-dropping \
  --force \
  "$GEOJSON_FILE"

# Cleanup temp files
echo "Step 3: Cleaning up..."
rm "$GEOJSON_FILE"

# Get file size
FILE_SIZE=$(du -h "$PMTILES_FILE" | cut -f1)

echo "=== Conversion complete ==="
echo "Output: $PMTILES_FILE"
echo "Size: $FILE_SIZE"
