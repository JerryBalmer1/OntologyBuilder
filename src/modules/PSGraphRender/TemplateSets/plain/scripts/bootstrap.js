const DATA = /*__DATA__*/ null;
const META = /*__META__*/ null;
const CONFIG = /*__CONFIG__*/ null;
const STRINGS = /*__STRINGS__*/ null;

// Theme values arrive as configuration like any other setting, so this backend
// reads the same four data files the reference one does.
for (const [key, value] of Object.entries(CONFIG || {})) {
  if (typeof value === 'string' && value.startsWith('#')) {
    document.documentElement.style.setProperty('--' + key, value);
  }
}
for (const [key, fallback] of Object.entries({
  BodyFont: 'system-ui, sans-serif',
  PageBackground: '#ffffff',
  BodyColor: '#111111',
  RuleColor: '#dddddd',
  RowHoverBackground: '#f3f3f3',
})) {
  const existing = getComputedStyle(document.documentElement).getPropertyValue('--' + key);
  if (!existing.trim()) {
    document.documentElement.style.setProperty('--' + key, (CONFIG && CONFIG[key]) || fallback);
  }
}

function str(key, fallback) {
  const value = STRINGS && STRINGS[key];
  return typeof value === 'string' ? value : (fallback !== undefined ? fallback : key);
}

// A token nobody filled stays as written rather than collapsing to nothing, so
// the gap shows up. Same rule as the reference backend.
function fmt(key, values, fallback) {
  let text = str(key, fallback);
  for (const [name, value] of Object.entries(values || {})) {
    text = text.split('{' + name + '}').join(String(value));
  }
  return text;
}

function cell(value) {
  const td = document.createElement('td');
  if (typeof value === 'number') { td.className = 'numeric'; }
  // textContent, never innerHTML. A label carrying markup is data, not markup.
  td.textContent = value === null || value === undefined ? '' : String(value);
  return td;
}

// Columns are whatever the rows actually carry, in first-seen order. Nothing
// here names a field, so a payload describing something that is not code
// renders without this file knowing anything about it.
function columnsOf(rows) {
  const seen = [];
  for (const row of rows) {
    for (const key of Object.keys(row || {})) {
      if (!seen.includes(key) && typeof row[key] !== 'object') { seen.push(key); }
    }
  }
  return seen;
}

function fill(tableId, headingId, headingKey, rows) {
  const table = document.getElementById(tableId);
  const columns = columnsOf(rows);

  const head = document.getElementById(tableId + '-head');
  for (const name of columns) {
    const th = document.createElement('th');
    th.textContent = name;
    head.appendChild(th);
  }

  const body = table.querySelector('tbody');
  for (const row of rows) {
    const tr = document.createElement('tr');
    for (const name of columns) { tr.appendChild(cell(row ? row[name] : null)); }
    body.appendChild(tr);
  }

  document.getElementById(headingId).textContent =
    fmt(headingKey, { count: rows.length }, headingKey + ' ({count})');
}

const nodes = (DATA && DATA.nodes) || [];
const links = (DATA && DATA.links) || [];

fill('nodes', 'nodes-heading', 'PlainNodesHeading', nodes);
fill('links', 'links-heading', 'PlainLinksHeading', links);

if (META) {
  document.getElementById('provenance').textContent =
    fmt('PlainProvenance', { generatedAt: META.generatedAt || '' }, 'Generated {generatedAt}');
}