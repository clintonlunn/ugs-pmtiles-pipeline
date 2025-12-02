#!/usr/bin/env node
/**
 * SLD to Mapbox GL Style converter
 * Fallback for when geostyler-cli fails on complex SLDs
 * Extracts polygon fill colors from PropertyIsEqualTo rules
 */

const fs = require('fs');

function parseSLD(sldContent) {
  const rules = [];
  
  // Match PropertyIsEqualTo rules with their fill colors
  const ruleRegex = /<sld:Rule>[\s\S]*?<\/sld:Rule>/g;
  const matches = sldContent.match(ruleRegex) || [];
  
  for (const rule of matches) {
    // Extract property name and value
    const propMatch = rule.match(/<ogc:PropertyIsEqualTo>[\s\S]*?<ogc:PropertyName>([^<]+)<\/ogc:PropertyName>[\s\S]*?<ogc:Literal>([^<]*)<\/ogc:Literal>/);
    
    // Extract fill color
    const fillMatch = rule.match(/<sld:CssParameter name="fill">([^<]+)<\/sld:CssParameter>/);
    
    // Extract stroke/outline color
    const strokeMatch = rule.match(/<sld:CssParameter name="stroke">([^<]+)<\/sld:CssParameter>/);
    
    if (propMatch && fillMatch) {
      rules.push({
        property: propMatch[1],
        value: propMatch[2],
        fill: fillMatch[1],
        stroke: strokeMatch ? strokeMatch[1] : null
      });
    }
  }
  
  return rules;
}

function createMapboxStyle(rules, layerName) {
  // Group by property name
  const byProperty = {};
  for (const rule of rules) {
    if (!byProperty[rule.property]) {
      byProperty[rule.property] = [];
    }
    byProperty[rule.property].push(rule);
  }
  
  // Use the property with most rules (likely the main symbology field)
  let mainProperty = Object.keys(byProperty)[0];
  let maxRules = 0;
  for (const [prop, propRules] of Object.entries(byProperty)) {
    if (propRules.length > maxRules) {
      maxRules = propRules.length;
      mainProperty = prop;
    }
  }
  
  const mainRules = byProperty[mainProperty] || [];
  
  // Build match expression for fill-color
  const fillMatch = ['match', ['get', mainProperty]];
  for (const rule of mainRules) {
    fillMatch.push(rule.value, rule.fill);
  }
  fillMatch.push('#cccccc'); // default color
  
  // Build match expression for outline if any rules have strokes
  const hasStrokes = mainRules.some(r => r.stroke);
  let strokeMatch = '#333333';
  if (hasStrokes) {
    strokeMatch = ['match', ['get', mainProperty]];
    for (const rule of mainRules) {
      strokeMatch.push(rule.value, rule.stroke || '#333333');
    }
    strokeMatch.push('#333333');
  }
  
  const style = {
    version: 8,
    name: layerName,
    sources: {
      [layerName]: {
        type: 'vector',
        url: `pmtiles://${layerName}.pmtiles`
      }
    },
    layers: [
      {
        id: `${layerName}-fill`,
        source: layerName,
        'source-layer': layerName,
        type: 'fill',
        paint: {
          'fill-color': fillMatch,
          'fill-opacity': 0.8
        }
      },
      {
        id: `${layerName}-outline`,
        source: layerName,
        'source-layer': layerName,
        type: 'line',
        paint: {
          'line-color': strokeMatch,
          'line-width': 0.5
        }
      }
    ]
  };
  
  return style;
}

// Main
const args = process.argv.slice(2);
if (args.length < 3) {
  console.error('Usage: sld-to-mapbox.js <input.sld> <output.json> <layer-name>');
  process.exit(1);
}

const [inputFile, outputFile, layerName] = args;

try {
  const sldContent = fs.readFileSync(inputFile, 'utf8');
  const rules = parseSLD(sldContent);
  
  if (rules.length === 0) {
    console.error('Warning: No fill rules found in SLD, creating default style');
  } else {
    console.log(`Extracted ${rules.length} fill rules from SLD`);
  }
  
  const style = createMapboxStyle(rules, layerName);
  fs.writeFileSync(outputFile, JSON.stringify(style, null, 2));
  console.log(`Wrote Mapbox GL style to ${outputFile}`);
  
} catch (err) {
  console.error('Error:', err.message);
  process.exit(1);
}
