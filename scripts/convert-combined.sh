#!/bin/bash
set -e

# Usage: ./scripts/convert-combined.sh <output_name> <layer1> <layer2> ...
# Or:    ./scripts/convert-combined.sh --app hazards
# Or:    ./scripts/convert-combined.sh --app hazards --styles-only
#
# Combines multiple layers into a single PMTiles file with all styles merged.
# Use --styles-only to regenerate just the style JSON without re-fetching data.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
CONFIG_DIR="$PROJECT_ROOT/config"
OUTPUT_DIR="$PROJECT_ROOT/output"
TEMP_DIR="$PROJECT_ROOT/temp"

# Check for --styles-only flag
STYLES_ONLY=false
for arg in "$@"; do
  if [ "$arg" = "--styles-only" ]; then
    STYLES_ONLY=true
  fi
done

# Parse arguments
if [ "$1" = "--app" ]; then
  APP_NAME="$2"
  OUTPUT_NAME="$APP_NAME"

  # Get all enabled layers that have this app in their apps array
  LAYERS=$(jq -r ".layers[] | select(.enabled == true) | select(.apps[]? == \"${APP_NAME}\") | .name" "$CONFIG_DIR/layers.json")

  if [ -z "$LAYERS" ]; then
    echo "Error: No enabled layers found for app '$APP_NAME'"
    echo "Available apps:"
    jq -r '[.layers[].apps[]?] | unique | .[]' "$CONFIG_DIR/layers.json"
    exit 1
  fi

  if [ "$STYLES_ONLY" = true ]; then
    echo "=== Regenerating styles only for app: $APP_NAME ==="
  else
    echo "=== Converting app: $APP_NAME ==="
  fi
  echo "Layers:"
  echo "$LAYERS" | while read -r layer; do echo "  - $layer"; done
else
  OUTPUT_NAME="$1"
  shift
  # Filter out --styles-only from LAYERS
  LAYERS=""
  for arg in "$@"; do
    if [ "$arg" != "--styles-only" ]; then
      LAYERS="$LAYERS $arg"
    fi
  done
  LAYERS=$(echo "$LAYERS" | xargs)  # trim whitespace

  if [ -z "$OUTPUT_NAME" ] || [ -z "$LAYERS" ]; then
    echo "Usage: $0 <output_name> <layer1> <layer2> ..."
    echo "   or: $0 --app <app_name> [--styles-only]"
    echo ""
    echo "Options:"
    echo "  --styles-only   Only regenerate styles, skip data fetch and PMTiles generation"
    echo ""
    echo "Examples:"
    echo "  $0 hazards quaternaryfaults_current liquefaction_current"
    echo "  $0 --app hazards"
    echo "  $0 --app hazards --styles-only"
    exit 1
  fi

  echo "=== Converting combined layers: $OUTPUT_NAME ==="
fi

# Create directories
mkdir -p "$OUTPUT_DIR" "$TEMP_DIR"

# Read datasource config
DATASOURCE_TYPE=$(jq -r '.type' "$CONFIG_DIR/datasource.json")
WFS_URL=$(jq -r '.wfs.url' "$CONFIG_DIR/datasource.json")

echo "Data source: $DATASOURCE_TYPE"
echo ""

# Arrays to collect tippecanoe inputs and style layers
TIPPECANOE_INPUTS=""
ALL_STYLE_LAYERS="[]"
MIN_ZOOM=14
MAX_ZOOM=5

# Process each layer
for LAYER_NAME in $LAYERS; do
  echo "--- Processing: $LAYER_NAME ---"

  # Get layer config
  LAYER_CONFIG=$(jq -r ".layers[] | select(.name == \"$LAYER_NAME\")" "$CONFIG_DIR/layers.json")
  if [ -z "$LAYER_CONFIG" ] || [ "$LAYER_CONFIG" = "null" ]; then
    echo "  Warning: Layer not found in config, skipping"
    continue
  fi

  # Extract config values
  LAYER_FULL_NAME=$(echo "$LAYER_CONFIG" | jq -r '.fullName')
  LAYER_MIN_ZOOM=$(echo "$LAYER_CONFIG" | jq -r '.minZoom // 5')
  LAYER_MAX_ZOOM=$(echo "$LAYER_CONFIG" | jq -r '.maxZoom // 14')
  SOURCE_CRS=$(echo "$LAYER_CONFIG" | jq -r '.sourceCrs // "EPSG:26912"')
  CQL_FILTER=$(echo "$LAYER_CONFIG" | jq -r '.cqlFilter // empty')

  # Track global zoom range
  if [ "$LAYER_MIN_ZOOM" -lt "$MIN_ZOOM" ]; then MIN_ZOOM=$LAYER_MIN_ZOOM; fi
  if [ "$LAYER_MAX_ZOOM" -gt "$MAX_ZOOM" ]; then MAX_ZOOM=$LAYER_MAX_ZOOM; fi

  GEOJSON_FILE="$TEMP_DIR/${LAYER_NAME}.geojson"

  # Skip data fetching if styles-only mode
  if [ "$STYLES_ONLY" = false ]; then
    # Fetch GeoJSON with pagination
    echo "  Fetching from WFS..."

    # Auto-detect sortable field
    DESCRIBE_URL="${WFS_URL}?service=WFS&version=2.0.0&request=DescribeFeatureType&typeNames=${LAYER_FULL_NAME}&outputFormat=application/json"
    FIELD_INFO=$(curl -sL "$DESCRIBE_URL")

    SORT_BY=""
    for CANDIDATE in ogc_fid gid fid id objectid; do
      if echo "$FIELD_INFO" | jq -e ".featureTypes[0].properties[] | select(.name == \"$CANDIDATE\")" > /dev/null 2>&1; then
        SORT_BY="$CANDIDATE"
        break
      fi
    done
    if [ -z "$SORT_BY" ]; then
      SORT_BY=$(echo "$FIELD_INFO" | jq -r '.featureTypes[0].properties[] | select(.localType == "int" or .localType == "long") | .name' | head -1)
    fi
    if [ -z "$SORT_BY" ]; then
      SORT_BY=$(echo "$FIELD_INFO" | jq -r '.featureTypes[0].properties[0].name')
    fi

    # Pagination
    PAGE_SIZE=100000
    START_INDEX=0
    TOTAL_FEATURES=0
    PAGE_NUM=1
    FEATURES_DIR="$TEMP_DIR/${LAYER_NAME}_pages"
    TEMP_GEOJSON="$TEMP_DIR/${LAYER_NAME}_temp.geojson"

    rm -rf "$FEATURES_DIR" "$TEMP_GEOJSON"
    mkdir -p "$FEATURES_DIR"

    while true; do
      PAGE_FILE="$FEATURES_DIR/page_${PAGE_NUM}.json"
      REQUEST_URL="${WFS_URL}?service=WFS&version=2.0.0&request=GetFeature&typeNames=${LAYER_FULL_NAME}&outputFormat=application/json&count=${PAGE_SIZE}&startIndex=${START_INDEX}&sortBy=${SORT_BY}"

      if [ -n "$CQL_FILTER" ]; then
        REQUEST_URL="${REQUEST_URL}&CQL_FILTER=${CQL_FILTER}"
      fi

      if ! curl -sL --max-time 600 -o "$PAGE_FILE" "$REQUEST_URL"; then
        echo "  Error: Failed to fetch page $PAGE_NUM"
        exit 1
      fi

      PAGE_FEATURES=$(jq '.features | length' "$PAGE_FILE" 2>/dev/null || echo "0")
      TOTAL_FEATURES=$((TOTAL_FEATURES + PAGE_FEATURES))

      if [ "$PAGE_FEATURES" -lt "$PAGE_SIZE" ]; then
        break
      fi

      START_INDEX=$((START_INDEX + PAGE_SIZE))
      PAGE_NUM=$((PAGE_NUM + 1))

      if [ "$TOTAL_FEATURES" -ge 1000000 ]; then
        echo "  Warning: Reached 1M feature limit"
        break
      fi
    done

    echo "  Fetched $TOTAL_FEATURES features"

    # Merge pages
    if [ "$PAGE_NUM" -eq 1 ]; then
      mv "$FEATURES_DIR/page_1.json" "$TEMP_GEOJSON"
    else
      echo '{"type":"FeatureCollection","features":[' > "$TEMP_GEOJSON"
      FIRST=true
      for PAGE_FILE in "$FEATURES_DIR"/page_*.json; do
        if [ "$FIRST" = true ]; then FIRST=false; else echo ',' >> "$TEMP_GEOJSON"; fi
        jq -c '.features[]' "$PAGE_FILE" | paste -sd ',' >> "$TEMP_GEOJSON"
      done
      echo ']}' >> "$TEMP_GEOJSON"
    fi
    rm -rf "$FEATURES_DIR"

    # Reproject
    echo "  Reprojecting from $SOURCE_CRS to EPSG:4326..."
    ogr2ogr -f GeoJSON "$GEOJSON_FILE" "$TEMP_GEOJSON" -t_srs EPSG:4326 -s_srs "$SOURCE_CRS"
    rm -f "$TEMP_GEOJSON"

    # Add to tippecanoe inputs
    TIPPECANOE_INPUTS="$TIPPECANOE_INPUTS -L ${LAYER_NAME}:${GEOJSON_FILE}"
  fi

  # Fetch and convert style
  echo "  Converting style..."
  SLD_FILE="$TEMP_DIR/${LAYER_NAME}.sld"
  STYLE_TEMP="$TEMP_DIR/${LAYER_NAME}_style.json"
  WMS_URL="${WFS_URL/wfs/wms}"

  curl -sL "${WMS_URL}?service=WMS&version=1.1.1&request=GetStyles&layers=${LAYER_FULL_NAME}" -o "$SLD_FILE"

  if grep -q "StyledLayerDescriptor" "$SLD_FILE"; then
    # Clean up SLD
    perl -0777 -pe 's/<sld:Rule>.*?<sld:Name>No Legend Provided<\/sld:Name>.*?<\/sld:Rule>//gs' "$SLD_FILE" > "$TEMP_DIR/sld_temp.xml"
    perl -0777 -pe 's/<sld:Rule>.*?<sld:Mark\/>.*?<\/sld:Rule>//gs' "$TEMP_DIR/sld_temp.xml" > "$SLD_FILE"
    rm -f "$TEMP_DIR/sld_temp.xml"

    if npx geostyler-cli -s sld -t mapbox -o "$STYLE_TEMP" "$SLD_FILE" 2>/dev/null; then
      # Add labels from SLD rule titles to the converted style (matches by filter, not index)
      node "$SCRIPT_DIR/add-labels-to-style.js" "$SLD_FILE" "$STYLE_TEMP" > "$STYLE_TEMP.labeled"
      mv "$STYLE_TEMP.labeled" "$STYLE_TEMP"

      # Extract layers and update source references
      LAYER_STYLES=$(jq --arg src "$OUTPUT_NAME" --arg srcLayer "$LAYER_NAME" '
        [.layers[] |
         select(.type != "fill" or .paint["fill-color"] != null) |
         . + {source: $src, "source-layer": $srcLayer}]
      ' "$STYLE_TEMP")

      # Merge into all styles
      ALL_STYLE_LAYERS=$(echo "$ALL_STYLE_LAYERS" "$LAYER_STYLES" | jq -s '.[0] + .[1]')
      rm -f "$STYLE_TEMP"
      echo "  Style converted"
    else
      echo "  Warning: Style conversion failed, using default"
      # Extract UserStyle title from SLD for label (first Title element is UserStyle title)
      SLD_TITLE=$(grep -oP '(?<=<sld:Title>)[^<]+' "$SLD_FILE" 2>/dev/null | head -1 | sed 's/&lt;/</g; s/&gt;/>/g; s/&amp;/\&/g; s/_/ /g')
      if [ -z "$SLD_TITLE" ]; then
        SLD_TITLE=$(echo "$LAYER_NAME" | sed 's/_current$//' | sed 's/_/ /g' | sed 's/\b\(.\)/\u\1/g')
      fi
      # Add default style with label from SLD title
      DEFAULT_STYLE=$(jq -n --arg name "$LAYER_NAME" --arg src "$OUTPUT_NAME" --arg label "$SLD_TITLE" '[
        {id: ($name + "-fill"), source: $src, "source-layer": $name, type: "fill", paint: {"fill-color": "#088", "fill-opacity": 0.6}, metadata: {label: $label}},
        {id: ($name + "-outline"), source: $src, "source-layer": $name, type: "line", paint: {"line-color": "#000", "line-width": 0.5}, metadata: {label: $label}}
      ]')
      ALL_STYLE_LAYERS=$(echo "$ALL_STYLE_LAYERS" "$DEFAULT_STYLE" | jq -s '.[0] + .[1]')
    fi
  else
    echo "  Warning: No SLD found, using default style"
    # Format layer name as label
    FORMATTED_NAME=$(echo "$LAYER_NAME" | sed 's/_current$//' | sed 's/_/ /g' | sed 's/\b\(.\)/\u\1/g')
    DEFAULT_STYLE=$(jq -n --arg name "$LAYER_NAME" --arg src "$OUTPUT_NAME" --arg label "$FORMATTED_NAME" '[
      {id: ($name + "-fill"), source: $src, "source-layer": $name, type: "fill", paint: {"fill-color": "#088", "fill-opacity": 0.6}, metadata: {label: $label}},
      {id: ($name + "-outline"), source: $src, "source-layer": $name, type: "line", paint: {"line-color": "#000", "line-width": 0.5}, metadata: {label: $label}}
    ]')
    ALL_STYLE_LAYERS=$(echo "$ALL_STYLE_LAYERS" "$DEFAULT_STYLE" | jq -s '.[0] + .[1]')
  fi
  rm -f "$SLD_FILE"

  echo ""
done

# Generate combined PMTiles (skip if styles-only)
PMTILES_FILE="$OUTPUT_DIR/${OUTPUT_NAME}.pmtiles"

if [ "$STYLES_ONLY" = false ]; then
  echo "=== Generating combined PMTiles ==="
  echo "Zoom range: $MIN_ZOOM - $MAX_ZOOM"
  echo "Running tippecanoe..."

  eval tippecanoe -o "$PMTILES_FILE" \
    -Z"$MIN_ZOOM" \
    -z"$MAX_ZOOM" \
    --drop-densest-as-needed \
    --extend-zooms-if-still-dropping \
    --force \
    $TIPPECANOE_INPUTS
else
  echo "=== Skipping PMTiles generation (styles-only mode) ==="
fi

# Generate combined style JSON
echo "Generating combined style..."
STYLE_FILE="$OUTPUT_DIR/${OUTPUT_NAME}.json"

jq -n --arg name "$OUTPUT_NAME" --argjson layers "$ALL_STYLE_LAYERS" '{
  version: 8,
  name: $name,
  sources: {
    ($name): {
      type: "vector",
      url: ("pmtiles://" + $name + ".pmtiles")
    }
  },
  layers: $layers
}' > "$STYLE_FILE"

# Cleanup temp GeoJSON files (only if not styles-only)
if [ "$STYLES_ONLY" = false ]; then
  echo "Cleaning up..."
  for LAYER_NAME in $LAYERS; do
    rm -f "$TEMP_DIR/${LAYER_NAME}.geojson"
    rm -f "$TEMP_DIR/${LAYER_NAME}_temp.geojson"
    rm -rf "$TEMP_DIR/${LAYER_NAME}_pages"
  done
fi

# Summary
LAYER_COUNT=$(echo "$LAYERS" | wc -w | tr -d ' ')

echo ""
if [ "$STYLES_ONLY" = true ]; then
  echo "=== Style regeneration complete ==="
  echo "Style:   $STYLE_FILE"
  echo "Layers:  $LAYER_COUNT"
  echo ""
  echo "Upload with: ./scripts/upload-to-gcs.sh $STYLE_FILE"
else
  PMTILES_SIZE=$(du -h "$PMTILES_FILE" | cut -f1)
  echo "=== Combined conversion complete ==="
  echo "PMTiles: $PMTILES_FILE ($PMTILES_SIZE)"
  echo "Style:   $STYLE_FILE"
  echo "Layers:  $LAYER_COUNT"

  # List layers in the PMTiles
  echo ""
  echo "Layers in PMTiles:"
  if command -v pmtiles &> /dev/null; then
    pmtiles show "$PMTILES_FILE" 2>/dev/null | grep -A 100 "vector_layers" | head -30 || true
  else
    echo "  (install pmtiles CLI to inspect: go install github.com/protomaps/go-pmtiles/cmd/pmtiles@latest)"
  fi
fi
