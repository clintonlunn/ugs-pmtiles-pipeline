# Quick Start Guide

## Setup (One-time)

```bash
cd ugs-pmtiles-pipeline

# Check dependencies
./scripts/setup-local.sh

# If all required dependencies are installed, you're ready!
```

## Convert a Single Layer

```bash
./scripts/convert-layer.sh hazards:quaternaryfaults_current
```

Output: `output/hazards_quaternaryfaults_current.pmtiles`

## Convert All Enabled Layers

```bash
./scripts/convert-all.sh
```

## Test in MapLibre

```javascript
import { Protocol } from 'pmtiles';

// Register PMTiles protocol
const protocol = new Protocol();
maplibregl.addProtocol('pmtiles', protocol.tile);

// Add your layer
map.addSource('quaternary-faults', {
  type: 'vector',
  url: 'pmtiles://https://storage.googleapis.com/ugs-pmtiles/hazards_quaternaryfaults_current.pmtiles'
});

map.addLayer({
  id: 'faults',
  type: 'line',
  source: 'quaternary-faults',
  'source-layer': 'hazards_quaternaryfaults_current',
  paint: {
    'line-color': '#ff0000',
    'line-width': 2
  }
});
```

## Configure Layers

Edit `config/layers.json`:
- Set `enabled: true` for layers you want to convert
- Adjust `minZoom` and `maxZoom` as needed

## Switch to PostGIS (when you have credentials)

Edit `config/datasource.json`:

```json
{
  "type": "postgis",
  "postgis": {
    "host": "your-host",
    "port": 5432,
    "database": "ugs_gis",
    "user": "readonly",
    "password": "${PGPASSWORD}",
    "enabled": true
  }
}
```

Then run conversions as normal - they'll use PostGIS (much faster!).

## Development

```bash
# Lint code
npm run lint

# Format files
npm run format
```

## Troubleshooting

### "GDAL doesn't support GML"
The script now uses GeoJSON directly from WFS, so this shouldn't happen.

### "Projection warning"
The script automatically reprojects from EPSG:26912 (Utah UTM) to EPSG:4326 (WGS84).

### "Can't represent non-numeric feature ID"
This is just a warning - tippecanoe handles it automatically.
