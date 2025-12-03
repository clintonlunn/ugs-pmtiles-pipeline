#!/bin/bash
set -e

# Usage: ./scripts/convert-layer.sh <layer_name>
# layer_name: The 'name' field from config/layers.json (e.g., quaternaryfaults_current, seamlessgeolunits_500k)

LAYER_FULL_NAME=$1
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$PROJECT_ROOT/config"
OUTPUT_DIR="$PROJECT_ROOT/output"
TEMP_DIR="$PROJECT_ROOT/temp"

if [ -z "$LAYER_FULL_NAME" ]; then
  echo "Usage: $0 <layer_name>"
  echo "Example: $0 quaternaryfaults_current"
  echo "Example: $0 seamlessgeolunits_500k"
  exit 1
fi

# Create directories
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

# Read datasource config
DATASOURCE_TYPE=$(jq -r '.type' "$CONFIG_DIR/datasource.json")

echo "=== Converting layer: $LAYER_FULL_NAME ==="
echo "Data source: $DATASOURCE_TYPE"

# Extract layer name for filenames (can be overridden by outputName in config)
LAYER_SAFE_NAME=$(echo "$LAYER_FULL_NAME" | tr ':' '_')

# Get layer config for zoom levels and source CRS
# First try to match by name, then fall back to fullName
LAYER_CONFIG=$(jq -r ".layers[] | select(.name == \"$LAYER_FULL_NAME\")" "$CONFIG_DIR/layers.json")
if [ -z "$LAYER_CONFIG" ] || [ "$LAYER_CONFIG" = "null" ]; then
  LAYER_CONFIG=$(jq -r ".layers[] | select(.fullName == \"$LAYER_FULL_NAME\")" "$CONFIG_DIR/layers.json")
fi
if [ -z "$LAYER_CONFIG" ] || [ "$LAYER_CONFIG" = "null" ]; then
  echo "Warning: Layer not found in config, using defaults"
  MIN_ZOOM=5
  MAX_ZOOM=14
  SOURCE_CRS="EPSG:26912"
else
  MIN_ZOOM=$(echo "$LAYER_CONFIG" | jq -r '.minZoom // 5')
  MAX_ZOOM=$(echo "$LAYER_CONFIG" | jq -r '.maxZoom // 14')
  # Get source CRS from config, default to EPSG:26912 if not specified
  SOURCE_CRS=$(echo "$LAYER_CONFIG" | jq -r '.sourceCrs // "EPSG:26912"')
  # Get optional CQL filter for subsetting data
  CQL_FILTER=$(echo "$LAYER_CONFIG" | jq -r '.cqlFilter // empty')
  # Get optional output name override (for filtered subsets)
  OUTPUT_NAME=$(echo "$LAYER_CONFIG" | jq -r '.outputName // empty')
  # Get fullName from config (needed when looking up by name)
  CONFIG_FULL_NAME=$(echo "$LAYER_CONFIG" | jq -r '.fullName // empty')
  if [ -n "$CONFIG_FULL_NAME" ]; then
    LAYER_FULL_NAME="$CONFIG_FULL_NAME"
  fi
fi

echo "Zoom range: $MIN_ZOOM - $MAX_ZOOM"
echo "Source CRS: $SOURCE_CRS"
if [ -n "$CQL_FILTER" ]; then
  echo "CQL Filter: $CQL_FILTER"
fi

# Use output name override if provided (for filtered subsets like 500k)
if [ -n "$OUTPUT_NAME" ]; then
  LAYER_SAFE_NAME="$OUTPUT_NAME"
  echo "Output name: $LAYER_SAFE_NAME"
fi

GEOJSON_FILE="$TEMP_DIR/${LAYER_SAFE_NAME}.geojson"
PMTILES_FILE="$OUTPUT_DIR/${LAYER_SAFE_NAME}.pmtiles"

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

  # Pagination settings (100k per request to avoid timeouts)
  PAGE_SIZE=100000
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

    # Append CQL filter if specified
    if [ -n "$CQL_FILTER" ]; then
      REQUEST_URL="${REQUEST_URL}&CQL_FILTER=${CQL_FILTER}"
    fi

    echo -n "  Page $PAGE_NUM (startIndex=$START_INDEX)... "

    if ! curl -sL --max-time 600 -o "$PAGE_FILE" "$REQUEST_URL"; then
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
  echo "Reprojecting from $SOURCE_CRS to EPSG:4326..."
  ogr2ogr -f GeoJSON "$GEOJSON_FILE" \
    "$TEMP_GEOJSON" \
    -t_srs EPSG:4326 \
    -s_srs "$SOURCE_CRS"

  rm "$TEMP_GEOJSON"

elif [ "$DATASOURCE_TYPE" = "postgis" ]; then
  # PostGIS approach (future - direct connection, much faster)
  PG_HOST=$(jq -r '.postgis.host' "$CONFIG_DIR/datasource.json")
  PG_PORT=$(jq -r '.postgis.port' "$CONFIG_DIR/datasource.json")
  PG_DB=$(jq -r '.postgis.database' "$CONFIG_DIR/datasource.json")
  PG_USER=$(jq -r '.postgis.user' "$CONFIG_DIR/datasource.json")
  PG_TABLE=$(echo "$LAYER_CONFIG" | jq -r '.postgisTable')

  # Build SQL query with optional filter (CQL syntax works for simple filters)
  SQL_QUERY="SELECT * FROM $PG_TABLE"
  if [ -n "$CQL_FILTER" ]; then
    SQL_QUERY="$SQL_QUERY WHERE $CQL_FILTER"
  fi

  ogr2ogr -f GeoJSON "$GEOJSON_FILE" \
    PG:"host=$PG_HOST port=$PG_PORT dbname=$PG_DB user=$PG_USER" \
    -sql "$SQL_QUERY" \
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

# Step 3: Convert to GeoParquet using DuckDB
PARQUET_FILE="$OUTPUT_DIR/${LAYER_SAFE_NAME}.parquet"
echo "Step 3: Converting to GeoParquet..."

# Use DuckDB for reliable GeoParquet conversion (ogr2ogr often lacks Parquet driver)
DUCKDB_CMD="${DUCKDB_PATH:-$HOME/bin/duckdb}"
if [ -x "$DUCKDB_CMD" ]; then
  "$DUCKDB_CMD" -c "
    INSTALL spatial;
    LOAD spatial;
    COPY (SELECT * FROM ST_Read('$GEOJSON_FILE'))
    TO '$PARQUET_FILE' (FORMAT PARQUET);
  "
  echo "  Converted with DuckDB"
elif command -v ogr2ogr &> /dev/null && ogr2ogr --formats | grep -q Parquet; then
  # Fallback to ogr2ogr if it has Parquet support
  ogr2ogr -f Parquet "$PARQUET_FILE" "$GEOJSON_FILE"
  echo "  Converted with ogr2ogr"
else
  echo "  Warning: No GeoParquet converter available (need DuckDB or ogr2ogr with Parquet)"
  echo "  Skipping GeoParquet output"
  PARQUET_FILE=""
fi

# Step 4: Fetch and convert SLD style to Mapbox GL JSON
STYLE_FILE="$OUTPUT_DIR/${LAYER_SAFE_NAME}.json"
SLD_FILE="$TEMP_DIR/${LAYER_SAFE_NAME}.sld"
STYLE_TEMP="$TEMP_DIR/${LAYER_SAFE_NAME}_style_temp.json"
echo "Step 4: Fetching SLD style..."

WMS_URL="${WFS_URL/wfs/wms}"
curl -sL "${WMS_URL}?service=WMS&version=1.1.1&request=GetStyles&layers=${LAYER_FULL_NAME}" -o "$SLD_FILE"

if grep -q "StyledLayerDescriptor" "$SLD_FILE"; then
  echo "Converting SLD to Mapbox GL style..."

  # Preprocess SLD: Remove "No Legend Provided" rules with empty Mark elements
  # These are GeoServer vendor tricks to hide legend entries that break geostyler-cli
  # Using perl for cross-platform compatibility (Mac BSD sed has different syntax)
  perl -0777 -pe 's/<sld:Rule>.*?<sld:Name>No Legend Provided<\/sld:Name>.*?<\/sld:Rule>//gs' "$SLD_FILE" > "$TEMP_DIR/sld_temp.xml"
  # Also remove rules with empty <sld:Mark/> elements
  perl -0777 -pe 's/<sld:Rule>.*?<sld:Mark\/>.*?<\/sld:Rule>//gs' "$TEMP_DIR/sld_temp.xml" > "$SLD_FILE"
  rm -f "$TEMP_DIR/sld_temp.xml"

  # Try geostyler-cli first
  if npx geostyler-cli -s sld -t mapbox -o "$STYLE_TEMP" "$SLD_FILE" 2>/dev/null; then
    # Add source and source-layer to each layer, and remove fill layers without fill-color
    # (GeoStyler creates empty fill layers as part of composite symbolizers for polygon strokes)
    jq --arg src "$LAYER_SAFE_NAME" '
      .layers = [
        .layers[] |
        select(.type != "fill" or .paint["fill-color"] != null) |
        . + {source: $src, "source-layer": $src}
      ]
    ' "$STYLE_TEMP" > "$STYLE_FILE"
    rm -f "$STYLE_TEMP"
    echo "  Converted with geostyler-cli"
  # Fallback to custom SLD parser for complex styles
  elif [ -f "$SCRIPT_DIR/sld-to-mapbox.js" ]; then
    echo "  geostyler-cli failed, using fallback parser..."
    if node "$SCRIPT_DIR/sld-to-mapbox.js" "$SLD_FILE" "$STYLE_FILE" "$LAYER_SAFE_NAME"; then
      echo "  Converted with sld-to-mapbox.js"
    else
      echo "  Warning: Fallback parser also failed, creating default style"
      cat > "$STYLE_FILE" << DEFAULTSTYLE
{"version":8,"name":"${LAYER_SAFE_NAME}","sources":{"${LAYER_SAFE_NAME}":{"type":"vector","url":"pmtiles://${LAYER_SAFE_NAME}.pmtiles"}},"layers":[{"id":"${LAYER_SAFE_NAME}-fill","source":"${LAYER_SAFE_NAME}","source-layer":"${LAYER_SAFE_NAME}","type":"fill","paint":{"fill-color":"#088","fill-opacity":0.6}},{"id":"${LAYER_SAFE_NAME}-outline","source":"${LAYER_SAFE_NAME}","source-layer":"${LAYER_SAFE_NAME}","type":"line","paint":{"line-color":"#000","line-width":0.5}}]}
DEFAULTSTYLE
    fi
  else
    echo "  Warning: geostyler-cli failed, no fallback available"
    cat > "$STYLE_FILE" << DEFAULTSTYLE
{"version":8,"name":"${LAYER_SAFE_NAME}","sources":{"${LAYER_SAFE_NAME}":{"type":"vector","url":"pmtiles://${LAYER_SAFE_NAME}.pmtiles"}},"layers":[{"id":"${LAYER_SAFE_NAME}-fill","source":"${LAYER_SAFE_NAME}","source-layer":"${LAYER_SAFE_NAME}","type":"fill","paint":{"fill-color":"#088","fill-opacity":0.6}},{"id":"${LAYER_SAFE_NAME}-outline","source":"${LAYER_SAFE_NAME}","source-layer":"${LAYER_SAFE_NAME}","type":"line","paint":{"line-color":"#000","line-width":0.5}}]}
DEFAULTSTYLE
  fi
else
  echo "  Warning: No SLD found, creating default style"
  cat > "$STYLE_FILE" << DEFAULTSTYLE
{"version":8,"name":"${LAYER_SAFE_NAME}","sources":{"${LAYER_SAFE_NAME}":{"type":"vector","url":"pmtiles://${LAYER_SAFE_NAME}.pmtiles"}},"layers":[{"id":"${LAYER_SAFE_NAME}-fill","source":"${LAYER_SAFE_NAME}","source-layer":"${LAYER_SAFE_NAME}","type":"fill","paint":{"fill-color":"#088","fill-opacity":0.6}},{"id":"${LAYER_SAFE_NAME}-outline","source":"${LAYER_SAFE_NAME}","source-layer":"${LAYER_SAFE_NAME}","type":"line","paint":{"line-color":"#000","line-width":0.5}}]}
DEFAULTSTYLE
fi
rm -f "$SLD_FILE"

# Cleanup temp files
echo "Step 5: Cleaning up..."
rm "$GEOJSON_FILE"

# Get file sizes
PMTILES_SIZE=$(du -h "$PMTILES_FILE" | cut -f1)

echo "=== Conversion complete ==="
echo "PMTiles: $PMTILES_FILE ($PMTILES_SIZE)"
if [ -n "$PARQUET_FILE" ] && [ -f "$PARQUET_FILE" ]; then
  PARQUET_SIZE=$(du -h "$PARQUET_FILE" | cut -f1)
  echo "Parquet: $PARQUET_FILE ($PARQUET_SIZE)"
fi
echo "Style:   $STYLE_FILE"
