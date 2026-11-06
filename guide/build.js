// Erzeugt Anleitung.html: Overlay-Vorschaubilder direkt aus dem Lua-Skript + Vorlage
const fs = require('fs');
const path = require('path');
const [, , luaPath, tplPath, outPath] = process.argv;

const lua = fs.readFileSync(luaPath, 'utf8');
const html = lua.match(/HTML = \[=====\[([\s\S]*?)\]=====\]/)[1];
let css = html.match(/<style>([\s\S]*?)<\/style>/)[1];
const svg = html.match(/<svg[\s\S]*?<\/svg>/)[0];

// CSS auf das eigenständige SVG umschreiben
css = css
  .replace(/:root\[data-theme="white"\]/g, 'svg.white')
  .replace(/:root/g, 'svg')
  .replace(/html, body \{[^}]*\}/, '')
  .replace(/body \{[^}]*\}/, '')
  .replace(/svg \{ width: 100vw;[^}]*\}/, '')
  .replace(/\.layout \{ display: none; \}/, '')
  + ' svg { font-family: "Segoe UI", system-ui, sans-serif; }';

const iX = svg.indexOf('<g id="xbox"');
const iP = svg.indexOf('<g id="ps"');
const iN = svg.indexOf('<g id="ns"');
const iH = svg.indexOf('<text id="hint"');
const head = svg.slice(0, iX).replace(/<!-- =+ XBOX =+ -->\s*$/, '');
const groups = {
  xbox: svg.slice(iX, svg.lastIndexOf('<!--', iP)),
  ps: svg.slice(iP, svg.lastIndexOf('<!--', iN)),
  ns: svg.slice(iN, iH),
};

function variant({ layout, theme = 'carbon', accent = '#00e5ff', on = [], lt = 0, rt = 0, ls = [0, 0], rs = [0, 0], touch = [] }) {
  let g = groups[layout];
  for (const i of on) g = g.replace(new RegExp(`class="btn([^"]*)" data-i="${i}"`), `class="btn$1 on" data-i="${i}"`);
  const trig = (cls, x, v) => {
    if (!v) return;
    const h = Math.round(58 * v);
    g = g.replace(`class="shoulder trig ${cls}"`, `class="shoulder trig ${cls} on"`)
         .replace(`<rect class="trigfill" x="${x}" y="76" width="130" height="0"`, `<rect class="trigfill" x="${x}" y="${76 - h}" width="130" height="${h}"`);
  };
  trig('lt', 150, lt); trig('rt', 520, rt);
  g = g.replace('<g class="ls">', `<g class="ls" transform="translate(${ls[0] * 18} ${ls[1] * 18})">`)
       .replace('<g class="rs">', `<g class="rs" transform="translate(${rs[0] * 18} ${rs[1] * 18})">`);
  let k = 0;
  g = g.replace(/<circle class="touchpt" r="10" cx="0" cy="0"\/>/g, m => {
    const t = touch[k++];
    return t ? `<circle class="touchpt" r="10" cx="${292 + t[0] * 216}" cy="${143 + t[1] * 104}" style="display:inline"/>` : m;
  });
  const s = head.replace('<svg viewBox="0 0 800 560" xmlns="http://www.w3.org/2000/svg">',
    `<svg viewBox="0 0 800 560" xmlns="http://www.w3.org/2000/svg" class="${theme === 'white' ? 'white' : ''}" style="--accent:${accent}"><style>${css}</style>`)
    + g + '</svg>';
  return 'data:image/svg+xml;base64,' + Buffer.from(s, 'utf8').toString('base64');
}

const imgs = {
  XBOX_DARK: variant({ layout: 'xbox', on: [0, 5, 15], rt: 0.7, ls: [0.8, -0.4] }),
  XBOX_WHITE: variant({ layout: 'xbox', theme: 'white', accent: '#ff3366', on: [3, 4], lt: 0.5, rs: [-0.6, 0.6] }),
  PS_DARK: variant({ layout: 'ps', on: [1, 12], lt: 0.8, rs: [0.7, 0.3], touch: [[0.3, 0.45]] }),
  PS_WHITE: variant({ layout: 'ps', theme: 'white', accent: '#3cff49', on: [3, 5], rt: 1, ls: [-0.5, -0.7], touch: [[0.25, 0.4], [0.72, 0.62]] }),
  NS_DARK: variant({ layout: 'ns', on: [1, 16, 19], rt: 1, ls: [0.7, 0.5] }),
  NS_WHITE: variant({ layout: 'ns', theme: 'white', accent: '#ff8a00', on: [3, 4, 14], lt: 1, rs: [-0.6, -0.6] }),
  HERO: variant({ layout: 'xbox', on: [0, 4], rt: 0.85, ls: [0.6, -0.6] }),
  SCENE: variant({ layout: 'ps', on: [0], rt: 0.6, ls: [0.5, 0.2] }),
  PROP_PREVIEW: variant({ layout: 'xbox' }),
};

let out = fs.readFileSync(tplPath, 'utf8');
for (const [k, v] of Object.entries(imgs)) out = out.split(`{{${k}}}`).join(v);
fs.writeFileSync(outPath, out);
console.log('geschrieben:', outPath, Math.round(out.length / 1024) + ' KB');
