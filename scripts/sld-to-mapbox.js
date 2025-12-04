#!/usr/bin/env node
/**
 * SLD to Mapbox GL Style converter using geostyler library
 * Fallback for when geostyler-cli fails on complex SLDs
 */

const fs = require('fs');

async function convertSldToMapbox(sldContent, layerName) {
  // Dynamic import for ESM modules
  const { default: SldStyleParser } = await import('geostyler-sld-parser');
  const { default: MapboxStyleParser } = await import('geostyler-mapbox-parser');

  const sldParser = new SldStyleParser();
  const mapboxParser = new MapboxStyleParser();

  // Parse SLD to GeoStyler format
  const { output: geoStylerStyle, errors: sldErrors } = await sldParser.readStyle(sldContent);

  if (sldErrors && sldErrors.length > 0) {
    console.error('SLD parsing warnings:', sldErrors);
  }

  if (!geoStylerStyle) {
    throw new Error('Failed to parse SLD');
  }

  // Convert to Mapbox GL style
  const { output: mapboxStyle, errors: mapboxErrors } = await mapboxParser.writeStyle(geoStylerStyle);

  if (mapboxErrors && mapboxErrors.length > 0) {
    console.error('Mapbox conversion warnings:', mapboxErrors);
  }

  if (!mapboxStyle) {
    throw new Error('Failed to convert to Mapbox style');
  }

  // Add source and source-layer to each layer
  const layers = mapboxStyle.layers.map(layer => ({
    ...layer,
    source: layerName,
    'source-layer': layerName
  }));

  // Build final style with proper source
  return {
    version: 8,
    name: layerName,
    sources: {
      [layerName]: {
        type: 'vector',
        url: `pmtiles://${layerName}.pmtiles`
      }
    },
    layers
  };
}

// Fallback regex-based parser for when geostyler also fails
function fallbackConvert(sldContent, layerName) {
  const rules = [];

  // Detect geometry type
  const isPoint = sldContent.includes('<sld:PointSymbolizer>') || sldContent.includes('<PointSymbolizer>');

  // Extract fill colors from rules
  const ruleRegex = /<sld:Rule>([\s\S]*?)<\/sld:Rule>/g;
  let match;

  while ((match = ruleRegex.exec(sldContent)) !== null) {
    const ruleContent = match[1];

    // Skip empty/hidden rules
    if (ruleContent.includes('<sld:Mark/>') || ruleContent.includes('No Legend Provided')) {
      continue;
    }

    // Check for legend-only rules (MaxScaleDenominator <= 1 means never render on map)
    const maxScaleMatch = ruleContent.match(/<sld:MaxScaleDenominator>([^<]+)<\/sld:MaxScaleDenominator>/);
    const isLegendOnly = maxScaleMatch && parseFloat(maxScaleMatch[1]) <= 10;

    // Extract label
    const titleMatch = ruleContent.match(/<sld:Title>([^<]+)<\/sld:Title>/) ||
                       ruleContent.match(/<sld:Name>([^<]+)<\/sld:Name>/);
    const label = titleMatch ? titleMatch[1] : null;

    // Extract fill color
    const fillMatch = ruleContent.match(/<sld:CssParameter name="fill">([^<]+)<\/sld:CssParameter>/);
    const color = fillMatch ? fillMatch[1] : '#888888';

    // Extract PropertyIsEqualTo filter
    const propMatch = ruleContent.match(/<ogc:PropertyIsEqualTo>[\s\S]*?<ogc:PropertyName>([^<]+)<\/ogc:PropertyName>[\s\S]*?<ogc:Literal>([^<]*)<\/ogc:Literal>/);

    // Extract range filters
    const rangeFilters = [];
    const gteMatches = ruleContent.matchAll(/<ogc:PropertyIsGreaterThanOrEqualTo>[\s\S]*?<ogc:PropertyName>([^<]+)<\/ogc:PropertyName>[\s\S]*?<ogc:Literal>([^<]+)<\/ogc:Literal>[\s\S]*?<\/ogc:PropertyIsGreaterThanOrEqualTo>/g);
    for (const m of gteMatches) {
      rangeFilters.push(['>=', m[1], parseFloat(m[2])]);
    }
    const ltMatches = ruleContent.matchAll(/<ogc:PropertyIsLessThan>[\s\S]*?<ogc:PropertyName>([^<]+)<\/ogc:PropertyName>[\s\S]*?<ogc:Literal>([^<]+)<\/ogc:Literal>[\s\S]*?<\/ogc:PropertyIsLessThan>/g);
    for (const m of ltMatches) {
      rangeFilters.push(['<', m[1], parseFloat(m[2])]);
    }
    const lteMatches = ruleContent.matchAll(/<ogc:PropertyIsLessThanOrEqualTo>[\s\S]*?<ogc:PropertyName>([^<]+)<\/ogc:PropertyName>[\s\S]*?<ogc:Literal>([^<]+)<\/ogc:Literal>[\s\S]*?<\/ogc:PropertyIsLessThanOrEqualTo>/g);
    for (const m of lteMatches) {
      rangeFilters.push(['<=', m[1], parseFloat(m[2])]);
    }

    // Extract Interpolate function for circle size
    let circleRadius = 6;
    const interpolateMatch = ruleContent.match(/<ogc:Function name="Interpolate">([\s\S]*?)<\/ogc:Function>/);
    if (interpolateMatch) {
      const funcContent = interpolateMatch[1];
      const propName = funcContent.match(/<ogc:PropertyName>([^<]+)<\/ogc:PropertyName>/);
      const literals = [...funcContent.matchAll(/<ogc:Literal>([^<]+)<\/ogc:Literal>/g)].map(m => parseFloat(m[1]));

      if (propName && literals.length >= 4) {
        circleRadius = [
          'interpolate', ['linear'], ['get', propName[1]],
          literals[0], literals[1],
          literals[2], literals[3]
        ];
      }
    }

    if (fillMatch || propMatch || rangeFilters.length > 0) {
      rules.push({
        label,
        color,
        property: propMatch ? propMatch[1] : null,
        value: propMatch ? propMatch[2] : null,
        rangeFilters,
        circleRadius,
        isPoint,
        isLegendOnly
      });
    }
  }

  if (rules.length === 0) {
    // Default style
    return {
      version: 8,
      name: layerName,
      sources: { [layerName]: { type: 'vector', url: `pmtiles://${layerName}.pmtiles` } },
      layers: isPoint ? [
        { id: `${layerName}-circle`, source: layerName, 'source-layer': layerName, type: 'circle',
          paint: { 'circle-radius': 6, 'circle-color': '#088', 'circle-opacity': 0.8 } }
      ] : [
        { id: `${layerName}-fill`, source: layerName, 'source-layer': layerName, type: 'fill',
          paint: { 'fill-color': '#088', 'fill-opacity': 0.6 } },
        { id: `${layerName}-outline`, source: layerName, 'source-layer': layerName, type: 'line',
          paint: { 'line-color': '#000', 'line-width': 0.5 } }
      ]
    };
  }

  // Build layers from rules
  const layers = [];

  // Collect legend-only items for metadata
  const legendOnlyItems = rules.filter(r => r.isLegendOnly).map(r => ({
    label: r.label,
    color: r.color
  }));

  if (isPoint) {
    // Point/circle layers - skip legend-only rules
    const renderableRules = rules.filter(r => !r.isLegendOnly);
    renderableRules.forEach((rule, i) => {
      const layer = {
        id: `${layerName}-circle-${i}`,
        source: layerName,
        'source-layer': layerName,
        type: 'circle',
        paint: {
          'circle-radius': rule.circleRadius,
          'circle-color': rule.color,
          'circle-opacity': 0.8,
          'circle-stroke-width': 1,
          'circle-stroke-color': '#333333'
        }
      };

      if (rule.rangeFilters.length > 0) {
        layer.filter = rule.rangeFilters.length === 1 ? rule.rangeFilters[0] : ['all', ...rule.rangeFilters];
      }

      if (rule.label) {
        layer.metadata = { label: rule.label, legendOnlyItems };
      }

      layers.push(layer);
    });
  } else {
    // Polygon layers - group by property
    const byProperty = {};
    for (const rule of rules) {
      if (rule.property) {
        if (!byProperty[rule.property]) byProperty[rule.property] = [];
        byProperty[rule.property].push(rule);
      }
    }

    // Find main property
    let mainProperty = Object.keys(byProperty)[0];
    let maxRules = 0;
    for (const [prop, propRules] of Object.entries(byProperty)) {
      if (propRules.length > maxRules) {
        maxRules = propRules.length;
        mainProperty = prop;
      }
    }

    const mainRules = byProperty[mainProperty] || rules;

    // Build match expression
    const fillMatch = ['match', ['get', mainProperty]];
    for (const rule of mainRules) {
      if (rule.value !== null) {
        fillMatch.push(rule.value, rule.color);
      }
    }
    fillMatch.push('#cccccc');

    layers.push({
      id: `${layerName}-fill`,
      source: layerName,
      'source-layer': layerName,
      type: 'fill',
      paint: { 'fill-color': fillMatch, 'fill-opacity': 0.8 },
      metadata: mainRules[0]?.label ? { label: mainRules[0].label } : undefined
    });

    layers.push({
      id: `${layerName}-outline`,
      source: layerName,
      'source-layer': layerName,
      type: 'line',
      paint: { 'line-color': '#333333', 'line-width': 0.5 }
    });
  }

  return {
    version: 8,
    name: layerName,
    sources: { [layerName]: { type: 'vector', url: `pmtiles://${layerName}.pmtiles` } },
    layers
  };
}

// Main
async function main() {
  const args = process.argv.slice(2);
  if (args.length < 3) {
    console.error('Usage: sld-to-mapbox.js <input.sld> <output.json> <layer-name>');
    process.exit(1);
  }

  const [inputFile, outputFile, layerName] = args;

  try {
    const sldContent = fs.readFileSync(inputFile, 'utf8');

    let style;

    try {
      // Try geostyler first
      style = await convertSldToMapbox(sldContent, layerName);
      console.log(`Converted with geostyler library (${style.layers.length} layers)`);
    } catch (geostylerError) {
      console.error('geostyler failed:', geostylerError.message);
      console.log('Using fallback regex parser...');

      // Fall back to regex parser
      style = fallbackConvert(sldContent, layerName);
      console.log(`Converted with fallback parser (${style.layers.length} layers)`);
    }

    fs.writeFileSync(outputFile, JSON.stringify(style, null, 2));
    console.log(`Wrote Mapbox GL style to ${outputFile}`);

  } catch (err) {
    console.error('Error:', err.message);
    process.exit(1);
  }
}

main();
