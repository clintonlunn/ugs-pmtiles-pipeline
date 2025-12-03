#!/usr/bin/env node
/**
 * Add labels to Mapbox style layers from SLD rule titles
 * Matches layers to rules by filter expression (robust, not index-based)
 *
 * Usage: node add-labels-to-style.js <sld_file> <style_json_file>
 * Requires: npm install fast-xml-parser
 */

const fs = require('fs');
const { XMLParser } = require('fast-xml-parser');

// Parse command line args
const [, , sldFile, styleFile] = process.argv;

if (!sldFile || !styleFile) {
  console.error('Usage: node add-labels-to-style.js <sld_file> <style_json_file>');
  process.exit(1);
}

// Read files
const sldXml = fs.readFileSync(sldFile, 'utf-8');
const styleJson = JSON.parse(fs.readFileSync(styleFile, 'utf-8'));

// Parse SLD XML
const parser = new XMLParser({
  ignoreAttributes: false,
  attributeNamePrefix: '@_',
  removeNSPrefix: true, // Remove namespace prefixes like sld:, ogc:
});
const sld = parser.parse(sldXml);

/**
 * Extract rules from SLD with their filters and titles
 * Returns: [{ title, filters: [{ property, value }] }]
 */
function extractRulesFromSLD(sld) {
  const rules = [];

  try {
    // Navigate to rules - handle different SLD structures
    const namedLayer = sld.StyledLayerDescriptor?.NamedLayer;
    if (!namedLayer) return rules;

    const userStyle = namedLayer.UserStyle;
    if (!userStyle) return rules;

    // Get style-level title as fallback
    const styleTitle = userStyle.Title || userStyle.Name || null;

    const featureTypeStyle = userStyle.FeatureTypeStyle;
    if (!featureTypeStyle) return rules;

    // Rules can be an array or single object
    let sldRules = featureTypeStyle.Rule;
    if (!sldRules) return rules;
    if (!Array.isArray(sldRules)) sldRules = [sldRules];

    for (const rule of sldRules) {
      // Use rule title, fall back to rule name, then style title
      let title = rule.Title || rule.Name || null;

      // Skip empty string titles, fall back to style title
      if (!title || (typeof title === 'string' && title.trim() === '')) {
        title = styleTitle;
      }

      if (!title) continue;

      // Extract filter conditions
      const filters = extractFilters(rule.Filter);

      rules.push({ title, filters });
    }
  } catch (e) {
    console.error('Error parsing SLD:', e.message);
  }

  return rules;
}

/**
 * Extract filter conditions from SLD Filter element
 * Handles PropertyIsEqualTo and And/Or combinations
 */
function extractFilters(filter) {
  const conditions = [];

  if (!filter) return conditions;

  // Simple PropertyIsEqualTo
  if (filter.PropertyIsEqualTo) {
    const eq = filter.PropertyIsEqualTo;
    const eqList = Array.isArray(eq) ? eq : [eq];
    for (const e of eqList) {
      if (e.PropertyName && e.Literal !== undefined) {
        conditions.push({
          property: e.PropertyName,
          value: String(e.Literal),
        });
      }
    }
  }

  // And combination
  if (filter.And) {
    const andFilters = filter.And;
    if (andFilters.PropertyIsEqualTo) {
      const eq = andFilters.PropertyIsEqualTo;
      const eqList = Array.isArray(eq) ? eq : [eq];
      for (const e of eqList) {
        if (e.PropertyName && e.Literal !== undefined) {
          conditions.push({
            property: e.PropertyName,
            value: String(e.Literal),
          });
        }
      }
    }
  }

  // Or combination (recurse)
  if (filter.Or) {
    // For Or, we just take the first branch for labeling purposes
    const orFilters = filter.Or;
    if (orFilters.PropertyIsEqualTo) {
      const eq = orFilters.PropertyIsEqualTo;
      const eqList = Array.isArray(eq) ? eq : [eq];
      for (const e of eqList) {
        if (e.PropertyName && e.Literal !== undefined) {
          conditions.push({
            property: e.PropertyName,
            value: String(e.Literal),
          });
          break; // Just take first for Or
        }
      }
    }
  }

  return conditions;
}

/**
 * Extract filter conditions from Mapbox style layer filter
 * Returns: [{ property, value }]
 */
function extractMapboxFilter(filter) {
  const conditions = [];

  if (!filter || !Array.isArray(filter)) return conditions;

  const op = filter[0];

  // Simple equality: ["==", "property", "value"]
  if (op === '==' && filter.length >= 3) {
    const prop = filter[1];
    const val = filter[2];
    if (typeof prop === 'string' && (typeof val === 'string' || typeof val === 'number')) {
      conditions.push({ property: prop, value: String(val) });
    }
  }

  // All combinator: ["all", [...], [...]]
  if (op === 'all') {
    for (let i = 1; i < filter.length; i++) {
      const sub = filter[i];
      if (Array.isArray(sub) && sub[0] === '==' && sub.length >= 3) {
        const prop = sub[1];
        const val = sub[2];
        if (typeof prop === 'string' && (typeof val === 'string' || typeof val === 'number')) {
          conditions.push({ property: prop, value: String(val) });
        }
      }
    }
  }

  // Any combinator: ["any", [...], [...]]
  if (op === 'any') {
    for (let i = 1; i < filter.length; i++) {
      const sub = filter[i];
      if (Array.isArray(sub) && sub[0] === '==' && sub.length >= 3) {
        const prop = sub[1];
        const val = sub[2];
        if (typeof prop === 'string' && (typeof val === 'string' || typeof val === 'number')) {
          conditions.push({ property: prop, value: String(val) });
          break; // Just take first for any
        }
      }
    }
  }

  return conditions;
}

/**
 * Check if two filter condition sets match
 */
function filtersMatch(sldFilters, mapboxFilters) {
  // Both have no filters - they match (rule applies to all features)
  if (sldFilters.length === 0 && mapboxFilters.length === 0) {
    return true;
  }

  // One has filters, the other doesn't - no match
  if (sldFilters.length === 0 || mapboxFilters.length === 0) {
    return false;
  }

  // All SLD conditions must be present in Mapbox filters
  for (const sldCond of sldFilters) {
    const found = mapboxFilters.some(
      (mbCond) => mbCond.property === sldCond.property && mbCond.value === sldCond.value
    );
    if (!found) return false;
  }

  return true;
}

/**
 * Find matching SLD rule for a Mapbox layer
 */
function findMatchingRule(layer, rules) {
  const mapboxFilters = extractMapboxFilter(layer.filter);

  for (const rule of rules) {
    if (filtersMatch(rule.filters, mapboxFilters)) {
      return rule;
    }
  }

  return null;
}

// Extract rules from SLD
const sldRules = extractRulesFromSLD(sld);

// Add labels to style layers
for (const layer of styleJson.layers || []) {
  const matchingRule = findMatchingRule(layer, sldRules);

  if (matchingRule) {
    // Decode HTML entities in title
    const label = matchingRule.title
      .replace(/&lt;/g, '<')
      .replace(/&gt;/g, '>')
      .replace(/&amp;/g, '&')
      .replace(/&quot;/g, '"')
      .replace(/&#39;/g, "'");

    layer.metadata = layer.metadata || {};
    layer.metadata.label = label;
  }
}

// Output updated style JSON
console.log(JSON.stringify(styleJson, null, 2));
