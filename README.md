# UGS PMTiles Pipeline

Pipeline for converting Utah Geological Survey GeoServer layers to PMTiles format for performant web mapping.

## Architecture

```
Data Source (configurable)
  ├─ WFS (current - no credentials needed)
  └─ PostGIS (future - direct connection, faster)
    ↓
ogr2ogr → GeoJSON
    ↓
tippecanoe → PMTiles
    ↓
GCS Bucket (static hosting)
    ↓
MapLibre GL JS (client)
```

## Quick Start

```bash
# Install dependencies
npm install

# Convert a single layer
./scripts/convert-layer.sh hazards:quaternaryfaults_current

# Convert all layers
./scripts/convert-all.sh
```

## Cost Estimate

- **Storage**: ~1.5 GB for 36 layers = $0.03/month
- **Egress**: Free tier covers typical usage
- **Total**: Less than $1/year

## Configuration

Edit `config/layers.json` to configure which layers to convert.
Edit `config/datasource.json` to switch between WFS and PostGIS.
