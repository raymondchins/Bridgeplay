'use strict';
// Players' verdicts and anti-cheat notes, from compat-verdicts.tsv in a home laid out like a
// real install, through the transform Steam's chunk goes through, to the panel row and the
// warning on a game page that is not installed. A fake DOM stands in for the page.
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');
const { panel, walk, details, runner, FORMS, expand } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: verdict.js <emit>'); process.exit(2); }

class Node {
  constructor(doc, tag) {
    this.ownerDocument = doc; this.tag = tag; this.children = []; this.style = {}; this.className = '';
    this.textContent = ''; this.attrs = {};
  }
  append(...n) { this.children.push(...n); }
  appendChild(n) { this.children.push(n); }
  replaceChildren(...n) { this.children = n; }
  setAttribute(k, v) { this.attrs[k] = v; }
}
function documentFor(lang) {
  const doc = { documentElement: { lang }, ids: {} };
  doc.createElement = tag => new Node(doc, tag);
  doc.head = new Node(doc, 'head');
  doc.head.appendChild = n => { doc.head.children.push(n); if (n.id) doc.ids[n.id] = n; };
  doc.getElementById = id => doc.ids[id] || null;
  return doc;
}
const flat = n => [n].concat(...n.children.map(flat));
const texts = n => flat(n).filter(c => c.tag !== 'button' && !c.children.length && c.textContent).map(c => c.textContent);
const buttons = n => flat(n).filter(c => c.tag === 'button');

const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'np-verdict-'));
const DAY = 86400;
const now = Math.floor(Date.now() / 1000);
const map = '//# sourceMappingURL=file:///home/buildbot/steamui/sourcemaps/chunk~2dcc5aaf7.js.map';
const fixture = path.join(__dirname, '..', 'webpatch-fixtures', 'gates.selecttool.js');

function home(name, tsv, confs = {}) {
  const h = path.join(tmp, name);
  const np = path.join(h, 'Library', 'Application Support', 'bridgeplay');
  fs.mkdirSync(path.join(np, 'gamefixes-default'), { recursive: true });
  if (tsv !== null) fs.writeFileSync(path.join(np, 'compat-verdicts.tsv'), tsv);
  for (const [id, text] of Object.entries(confs)) fs.writeFileSync(path.join(np, 'gamefixes-default', id + '.conf'), text);
  return { h, np };
}
const chunk = path.join(tmp, 'chunk.js');
fs.writeFileSync(chunk, fs.readFileSync(fixture, 'utf8').replace(/\n$/, '') + map);

// The page as Steam would run it: the chunk's tail, which the transform appends to.
function page(h, extra = {}) {
  const out = execFileSync(emit, ['transform', chunk, 'bridgeplay-proton'],
                           { encoding: 'utf8', env: Object.assign({}, process.env, { HOME: h }) });
  const ctx = vm.createContext(Object.assign({ document: documentFor('en'), navigator: { language: 'en' } }, extra));
  vm.runInContext(out.slice(out.lastIndexOf(map)), ctx);
  return { ctx, out };
}
const tsv = (u, lines) => `bridgeplay-compat-verdicts\t1\t${u}\n` + lines.map(l => l.join('\t')).join('\n') + '\n';
const LINES = [
  ['1001', 'p', '11', '9', '1', '1', '-', '-'],
  ['1002', 'd', '6', '1', '0', '5', '-', '-'],
  ['1003', 'm', '7', '3', '2', '2', '-', 'eac'],
  ['1004', 'o', '1', '1', '0', '0', '-', '-'],
  ['1005', 's', '5', '3', '0', '2', '0.7.66', '-'],
  ['1006', '-', '0', '0', '0', '0', '-', 'ricochet'],
  ['1007', 'p', '4', '4', '0', '0', '-', 'ricochet,eac'],
  ['1008', '-', '0', '0', '0', '0', '-', 'vac'],
  ['1009', 's', '4', '2', '0', '2', 's1764000000', '-'],
  ['1011', 'o', '1', '0', '0', '1', '-', 'other'],
  // Each of these is skipped: an id this build does not know, page text, a label, appid 0,
  // a number too long, a field too many.
  ['2000', 'p', '3', '3', '0', '0', '-', 'unknownid'],
  ['2001', 'p', '3', '3', '0', '0', '"><img src=x>', '-'],
  ['2002', 'x', '3', '3', '0', '0', '-', '-'],
  ['0', 'p', '3', '3', '0', '0', '-', '-'],
  ['2003', 'p', '3333333', '3', '0', '0', '-', '-'],
  ['2004', 'p', '3', '3', '0', '0', '-', '-', 'extra'],
];

let failed = 0;
const t = runner('verdict');
try {
  const live = home('live', tsv(now - 3 * DAY, LINES), { 1010: 'ANTICHEAT=javelin\n' });
  const { ctx, out } = page(live.h);
  const V = ctx.MSCXVerdicts;
  t.ok(!!V && V.u === now - 3 * DAY, 'the export time reaches the page');
  t.ok(!!V && /^[0-9a-z.,:;+-]*$/.test(V.g), `only digits, ids and separators reach the page (${V && V.g})`);
  t.ok(!!V && V.g.split(';').length === 10 && !/20\d\d:/.test(V.g), 'every bad line is skipped');
  t.ok(!out.includes('<img'), 'text from the file never reaches the chunk');
  const F = ctx.MSCXVerdictFor;
  t.ok(F(1001).v === 'p' && F(1001).n === 11 && F(1001).days === 3, 'a playable game is found with its counts');
  t.ok(F(424242) === null && F(0) === null && F(3000000000) === null, 'an unknown game, no appid or a shortcut gives nothing');
  t.ok(F(1010) && F(1010).hard === 'javelin' && F(1010).conf, 'a maintainer-confirmed ANTICHEAT gamefix counts without a verdict');

  const row = (id, doc = documentFor('en')) => {
    const e = new Node(doc, 'div');
    ctx.MSCXVerdictRow(e, id);
    return e;
  };
  let e = row(1001);
  t.ok(e.style.display === '' && e.style.flexDirection === 'column', 'the row shows, stacked');
  t.ok(JSON.stringify(texts(e)) === JSON.stringify(['Players report', 'Ran well on 9 of 11 Macs',
       '9 ran well · 1 had issues · 1 did not run · updated 3 days ago']), `playable reads as counts per Mac (${texts(e)})`);
  t.ok(buttons(e).length === 0, 'a game that runs offers no other ways to play');
  t.ok(e.ownerDocument.getElementById('MSCXVerdictCSS') !== null, 'its style goes in once per document');
  ctx.MSCXVerdictRow(e, 1001);
  t.ok(e.ownerDocument.head.children.length === 1, 'rendering again for the same game changes nothing');
  t.ok(texts(row(1002))[1] === 'Did not run on 5 of 6 Macs', 'doesn’t run names the Macs it failed on');
  t.ok(texts(row(1003))[1] === 'Mixed: 3 ran well, 2 had issues, 2 did not run' &&
       texts(row(1003))[2] === 'updated 3 days ago', 'mixed spells out the three counts once');
  t.ok(texts(row(1003))[3] === 'Uses Easy Anti-Cheat: online play may fail.', 'a user-mode anti-cheat is a note');
  t.ok(texts(row(1004))[1] === 'One report so far: it ran well', 'one report says so');
  t.ok(texts(row(1011))[1] === 'One report so far: it did not run' &&
       texts(row(1011))[3] === 'Uses anti-cheat: online play may fail.', 'one failed report, with an unnamed anti-cheat');
  t.ok(texts(row(1005))[1] === 'Ran well before Bridgeplay 0.7.66, but not on newer builds', 'broken since names the build');
  t.ok(texts(row(1009))[1] === 'Ran well before Steam build 1764000000, but not on newer builds', 'or the Steam build');
  e = row(1006);
  t.ok(JSON.stringify(texts(e)) === JSON.stringify([
    'Uses Ricochet, anti-cheat that Wine on macOS can’t run, so the game will most likely not start.',
    'You may still play it through cloud gaming, if a service carries it, or Steam Remote Play from a Windows PC.']),
    `kernel anti-cheat with no verdict is a hard note with other ways to play (${texts(e)})`);
  t.ok(buttons(e).length === 0, 'without a way to open a browser there is no button');
  t.ok(texts(row(1007)).includes('Uses Ricochet: online play may fail.'),
       'kernel anti-cheat in a game players ran well is only a note');
  t.ok(texts(row(1008))[0] === 'Uses VAC: online matchmaking may not work.', 'VAC has its own note');
  t.ok(texts(row(1010))[0].endsWith('so the game will most likely not start. Bridgeplay asks before launching it.'),
       'a confirmed anti-cheat says the launch asks first');
  e = row(424242);
  t.ok(e.style.display === 'none' && e.children.length === 0, 'an unknown game hides the row');

  // A browser to open: one button, to Bridgeplay's own guide.
  const opened = [];
  ctx.SteamClient = { System: { OpenInSystemBrowser: u => opened.push(u) } };
  e = row(1006);
  t.ok(buttons(e).length === 1 && buttons(e)[0].textContent === 'Other Ways to Play' && buttons(e)[0].className === 'MSCXBtn',
       'the panel row gets an Other Ways to Play button');
  buttons(e)[0].onclick();
  t.ok(opened[0] === 'https://bridgeplay.dev/guides/anti-cheat-on-mac#alternatives', `it opens the guide (${opened[0]})`);
  t.ok(buttons(row(1002)).length === 1 && buttons(row(1005)).length === 0, 'doesn’t run offers it, broken since does not');

  // The warning on a game page that is not installed.
  const W = ctx.MSCXWarnFor;
  t.ok(W(1006) === 'a' && W(1010) === 'a' && W(1002) === 'd' && W(1005) === 's', 'anti-cheat, doesn’t run and broken since warn');
  t.ok(!W(1001) && !W(1003) && !W(1004) && !W(1007) && !W(1008) && !W(424242), 'nothing else does');
  // Steam's details: a game it runs as its Mac version gets no Wine warning.
  const mac = { 1002: { vecPlatforms: ['windows', 'osx'], strCompatToolName: '' },
                1006: { vecPlatforms: ['windows', 'osx'], strCompatToolName: 'bridgeplay-proton' },
                1005: { vecPlatforms: ['windows'], strCompatToolName: '' } };
  ctx.appDetailsStore = { GetAppDetails: id => mac[id] };
  t.ok(W(1002) === '' && W(1006) === 'a' && W(1005) === 's' && W(1010) === 'a',
       'a native Mac game does not warn; one forced to a compat tool or Windows-only still does');
  ctx.appDetailsStore = { GetAppDetails: () => { throw new Error('gone'); } };
  t.ok(W(1002) === 'd', 'a store that throws keeps the warning');
  delete ctx.appDetailsStore;
  const store = {};
  ctx.localStorage = { getItem: k => (k in store ? store[k] : null), setItem: (k, v) => { store[k] = String(v); } };
  const warn = (id, doc = documentFor('en')) => { const n = new Node(doc, 'div'); ctx.MSCXWarnRow(n, id); return n; };
  e = warn(1002);
  t.ok(e.className === 'MSCXWarn' && e.attrs.role === 'note', 'the warning is a note, not a dialog');
  t.ok(texts(e)[0] === 'Before you download' && texts(e)[1] === 'Players report it did not run on 5 of 6 Macs.',
       `it says why (${texts(e)})`);
  const close = buttons(e).find(b => b.className === 'MSCXWarnClose');
  t.ok(!!close && close.attrs['aria-label'] === 'Dismiss', 'it has a labelled dismiss button');
  t.ok(buttons(e).some(b => b.className === 'MSCXWarnBtn'), 'and Other Ways to Play');
  close.onclick();
  t.ok(e.style.display === 'none' && W(1002) === '' && JSON.parse(store.MSCXWarnDismissed)[1002] === 'd',
       'dismissed, it hides and stays hidden for that game');
  t.ok(W(1006) === 'a', 'other games still warn');
  t.ok(texts(warn(1005))[1] === 'Players report it ran well before Bridgeplay 0.7.66, but not on newer builds.' &&
       !buttons(warn(1005)).some(b => b.className === 'MSCXWarnBtn'), 'broken since warns without other ways to play');
  e = warn(1001);
  t.ok(e.style.display === 'none' && e.children.length === 0, 'a game that runs gets no warning');

  // The language Steam runs in, read from the page like the rest of the panel.
  ctx.document.documentElement.lang = 'zh-CN';
  t.ok(texts(row(1001))[1] === '在 11 台 Mac 中有 9 台运行良好', 'Chinese');
  ctx.document.documentElement.lang = 'it';
  t.ok(texts(row(1001))[1] === 'Funziona bene su 9 Mac su 11', 'Italian');
  t.ok(texts(warn(1006))[0] === 'Prima di scaricare', 'the warning too');
  ctx.document.documentElement.lang = 'ru';
  t.ok(texts(row(1001))[1] === 'Хорошо работает на 9 из 11 Mac', 'Russian');
  t.ok(texts(warn(1006))[0] === 'Перед загрузкой', 'the Russian warning too');
  ctx.document.documentElement.lang = 'en';

  // A verdict over 30 days old is dropped; anti-cheat names stay.
  const old = page(home('old', tsv(now - 40 * DAY, LINES)).h).ctx;
  t.ok(old.MSCXVerdictFor(1001) === null && old.MSCXVerdictFor(1006).hard === 'ricochet' && old.MSCXWarnFor(1002) === '',
       'an export over 30 days old shows no verdict, only anti-cheat');

  // Files the dylib refuses: none, a link, a foreign header, one over the size cap.
  const none = page(home('none', null).h).ctx;
  t.ok(none.MSCXVerdicts === undefined && none.MSCXVerdictFor(1001) === null && typeof none.MSCXWarnFor === 'function',
       'no file: the code is there and shows nothing');
  const linked = home('linked', null);
  fs.symlinkSync(path.join(live.np, 'compat-verdicts.tsv'), path.join(linked.np, 'compat-verdicts.tsv'));
  t.ok(page(linked.h).ctx.MSCXVerdicts === undefined, 'a symlink is not followed');
  t.ok(page(home('foreign', 'appid\tv\n1001\tp\t11\t9\t1\t1\t-\t-\n').h).ctx.MSCXVerdicts === undefined,
       'a file without the header is not read');
  t.ok(page(home('huge', tsv(now, LINES) + 'x'.repeat(2 * 1024 * 1024)).h).ctx.MSCXVerdicts === undefined,
       'a file over 2 MiB is not read');
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
failed += t.failed;

// The row in the panel: only for a Wine game the data knows, and outside every other control.
for (const form of Object.keys(FORMS)) {
  const tf = runner(form);
  const seen = [];
  globalThis.MSCXVerdictFor = id => (id === 287700 ? { v: 'p' } : null);
  globalThis.MSCXVerdictRow = (e, id) => seen.push(id);
  try {
    const { render: P } = panel(emit, form);
    const rows = over => walk(P({ details: details('', over) })).filter(n => n.type === 'div' && n.props.ref);
    const r = rows();
    tf.ok(r.length === 1 && r[0].props.className === 'MSCXRow', 'a known game gets one verdict row');
    r[0].props.ref({});
    tf.ok(seen[0] === 287700, 'the row is drawn for that game');
    tf.ok(rows({ unAppID: 287701 }).length === 0, 'an unknown game gets none');
    tf.ok(rows({ vecPlatforms: ['osx'], strCompatToolName: '' }).length === 0, 'a native game gets none');
    const nodes = walk(P({ details: details('') }));
    const adv = nodes.find(n => n.type === 'details');
    tf.ok(!walk(adv.props.children).some(n => n.type === 'div' && n.props.ref), 'it is not inside Advanced');
    tf.ok(nodes.filter(n => n.type === 'Toggle').length === 9 && nodes.filter(n => n.type === 'Section').length === 7,
          'the panel keeps its nine toggles in seven sections');
  } finally {
    delete globalThis.MSCXVerdictFor;
    delete globalThis.MSCXVerdictRow;
  }
  failed += tf.failed;
}

// The game page: Steam's 32-bit banner keeps its place, the warning takes it otherwise.
{
  const tb = runner('banner');
  const expr = expand(execFileSync(emit, ['install-banner'], { encoding: 'utf8' }),
                      { '\u0001': 'Ov', '\u0002': 'Rt', '\u0003': 'Banner' });
  const Rt = { jsx: (type, props) => ({ type, props }) };
  const run = (Ov, warnFor) => new Function('Ov', 'Rt', 'Banner', 'MSCXWarnFor', 'MSCXWarnRow', 'return ' + expr)(
    Ov, Rt, 'Banner', warnFor, (e, id) => { run.drawn = id; });
  const app = (installed, invalid) => ({ appid: 1002, local_per_client_data: { installed },
                                         most_available_per_client_data: { is_invalid_os_type: invalid } });
  tb.ok(!run(app(true, false), () => 'd') && !run(app(true, true), () => 'd'), 'an installed game shows neither');
  tb.ok(run(app(false, true), () => 'd').type === 'Banner', 'a 32-bit Mac game keeps Steam’s banner');
  const w = run(app(false, false), () => 'd');
  tb.ok(w && w.type === 'div', 'a game known not to run gets the warning');
  w.props.ref({});
  tb.ok(run.drawn === 1002, 'drawn for that game');
  tb.ok(run(app(false, false), () => '') === null, 'a game with nothing to say shows nothing');
  tb.ok(run(app(false, false), undefined) === null, 'nor does a page without the verdict code');
  failed += tb.failed;
}

if (failed) { console.error(`verdict: ${failed} check(s) failed`); process.exit(1); }
console.log('==> verdict: rows, warnings and refused files as expected');
