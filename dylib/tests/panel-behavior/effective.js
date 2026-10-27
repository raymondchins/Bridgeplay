// The conf defaults as the page receives them: the patched chunk is run the way Steam
// serves it, from a home laid out like a real install, and the panel then rendered
// against what that chunk defined.
'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const { execFileSync } = require('child_process');
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: effective.js <emit>'); process.exit(2); }

// A quote and a space in the home have to reach the page escaped and the launch options quoted.
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'np-effective-'));
const home = path.join(tmp, 'home "q" x');
const np = path.join(home, 'Library', 'Application Support', 'bridgeplay');
const put = (rel, text) => {
  fs.mkdirSync(path.dirname(path.join(np, rel)), { recursive: true });
  fs.writeFileSync(path.join(np, rel), text);
};
put('gamefixes/default.conf',
  '# Global defaults for every game (lowest precedence: per-game confs and Steam launch options win).\n' +
  'MTL_HUD_ENABLED=1\nRETINA=1\n' +
  '# Rosetta hides AVX/AVX2 unless asked; many games quit without it.\n' +
  'ROSETTA_ADVERTISE_AVX=1\n' +
  '# Exposes DLSS through MetalFX (D3DMetal); only takes effect when DLSS is switched on in the game.\n' +
  'D3DM_ENABLE_METALFX=1\n' +
  'FRAMEGEN=1\nFRAMEGEN_QUALITY=quality\nFRAMEGEN_UI=0\nFRAMEGEN_FALLBACK=0\nFRAMEGEN_ENGINE=metalfx\n');
put('gamefixes-default/1888930.conf', 'ROSETTA_ADVERTISE_AVX=1\n');
// Bridgeplay's shipped defaults for every game sit under the user's Game Defaults.
put('gamefixes-default/default.conf', 'MTL_HUD_ENABLED=0\nDXMT_ENABLE_NVEXT=1\nRETINA=0\n');
// The run script's short keys also take the BRIDGEPLAY_ name.
put('gamefixes/1778821.conf', 'BRIDGEPLAY_FRAMEGEN=0\n');
// np-native's own confs: raw variable names, export and quotes allowed, and the pre-3.0
// NOTPROTON_ spelling still read under the BRIDGEPLAY_ name.
put('gamefixes/native-default.conf', '# native\nexport MTL_HUD_ENABLED=1\nNP_PAD_MODE = "hid"\n' +
  'NOTPROTON_FRAMEGEN=3\nFRAMEGEN=2\nBRIDGEPLAY_RETINA=1\n');
put('gamefixes/native/1778820.conf', "NP_PAD_MODE='gc'\nBRIDGEPLAY_FRAMEGEN_ENGINE=metalfx\n");
// The first tool is the default one, and its name runs past the 16 characters a value may.
put('tools',
  'bridgeplay-proton-winecx-11.17\twinecx-11.17\trosetta\tWineCX 11.17 (msync, D3DMetal)\n' +
  'bridgeplay-proton-winecx\twinecx-11.15\trosetta\tWineCX 11.15 (msync, D3DMetal)\n' +
  'bridgeplay-proton-winehq\twinehq-11.15\trosetta\tWineHQ 11.15 - Rosetta\n');

// Steam's chunks end in a source map comment with no newline after it.
const chunk = path.join(home, 'chunk.js');
const fixture = path.join(__dirname, '..', 'webpatch-fixtures', 'gates.forcetool.js');
const map = '//# sourceMappingURL=file:///home/buildbot/steamui/sourcemaps/chunk~2dcc5aaf7.js.map';
fs.writeFileSync(chunk, fs.readFileSync(fixture, 'utf8').replace(/\n$/, '') + map);

let failed = 0;
const t0 = runner('chunk');
let fx, legacyFx;
try {
  const out = execFileSync(emit, ['transform', chunk, 'bridgeplay-proton-winecx-11.17'],
                           { encoding: 'utf8', env: Object.assign({}, process.env, { HOME: home }) });
  // Everything from the comment on is code the browser parses at the end of the chunk.
  const tail = out.slice(out.lastIndexOf(map));
  const ctx = vm.createContext({});
  vm.runInContext(tail, ctx);
  fx = ctx.MSCXFx;
  // A home the app has not moved over yet: only the pre-3.0 support folder exists.
  const legacyHome = path.join(tmp, 'legacy');
  const legacy = path.join(legacyHome, 'Library', 'Application Support', 'notproton', 'gamefixes');
  fs.mkdirSync(legacy, { recursive: true });
  fs.writeFileSync(path.join(legacy, 'default.conf'), 'RETINA=1\n');
  const legacyOut = execFileSync(emit, ['transform', chunk, 'notproton-winecx-11.17'],
                                 { encoding: 'utf8', env: Object.assign({}, process.env, { HOME: legacyHome }) });
  const lctx = vm.createContext({});
  vm.runInContext(legacyOut.slice(legacyOut.lastIndexOf(map)), lctx);
  legacyFx = lctx.MSCXFx;
} finally {
  fs.rmSync(tmp, { recursive: true, force: true });
}
t0.ok(fx !== undefined, 'the defaults survive the source map comment the chunk ends in');
t0.ok(!!(fx && fx.e && fx.e['bridgeplay-proton-winecx-11.17'] && fx.e['bridgeplay-proton-winecx-11.17'].WINEMSYNC === '1'),
      'a tool name longer than a value still reaches the engine map');
t0.ok(!!(fx && fx.e && fx.e[''] && fx.e[''].WINEMSYNC === '1'), 'the default tool stands in for an unpinned game');
t0.ok(!!fx && fx.h === home, `the home reaches the page escaped (${fx && JSON.stringify(fx.h)})`);
t0.ok(!!fx && JSON.stringify(fx.g).includes('"BRIDGEPLAY_FRAMEGEN":"1"') &&
      fx.g.BRIDGEPLAY_FRAMEGEN_QUALITY === 'quality' && fx.g.BRIDGEPLAY_FRAMEGEN_UI === '0' &&
      fx.g.BRIDGEPLAY_FRAMEGEN_FALLBACK === '0' && fx.g.BRIDGEPLAY_FRAMEGEN_ENGINE === 'metalfx',
      'the FRAMEGEN conf keys map to their variables');
t0.ok(!!fx && fx.g.DXMT_ENABLE_NVEXT === '1' && fx.g.MTL_HUD_ENABLED === '1' && fx.g.BRIDGEPLAY_RETINA === '1',
      `the shipped global conf is read under the user's (${fx && JSON.stringify(fx.g)})`);
t0.ok(!!fx && !Object.prototype.hasOwnProperty.call(fx.a, 'default'),
      'the shipped default.conf is not taken for a game');
t0.ok(!!fx && fx.d.BRIDGEPLAY_FRAMEGEN_UI === '1' && fx.d.BRIDGEPLAY_FRAMEGEN_FALLBACK === '1',
      'Protect UI and the fast-motion fallback default on');
t0.ok(!!fx && JSON.stringify(fx.ng) === '{"MTL_HUD_ENABLED":"1","NP_PAD_MODE":"hid","BRIDGEPLAY_FRAMEGEN":"3"}',
      `native-default.conf is read the way np-native reads it (${fx && JSON.stringify(fx.ng)})`);
t0.ok(!!fx && JSON.stringify(fx.na) === '{"1778820":{"NP_PAD_MODE":"gc","BRIDGEPLAY_FRAMEGEN_ENGINE":"metalfx"}}',
      `native/<appid>.conf lands per app (${fx && JSON.stringify(fx.na)})`);
t0.ok(!!legacyFx && legacyFx.g.BRIDGEPLAY_RETINA === '1',
      `a home with only the pre-3.0 support folder is still read (${legacyFx && JSON.stringify(legacyFx.g)})`);
failed += t0.failed;

const LABELS = ['Metal HUD', 'DLSS', 'Advertise AVX2 to Rosetta', 'MSync', 'High Resolution',
                'Let games read controllers directly (Recommended on Mac. Turn off only for Steam Input remapping)'];
globalThis.MSCXFx = fx;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  const rows = over => walk(P({ details: details('', Object.assign({ unAppID: 1778820 }, over)) }))
    .filter(x => x.type === 'Toggle');
  const checked = over => rows(over).filter(x => x.props.checked).map(x => x.props.label);
  const on = checked({ strCompatToolName: '' });
  t.ok(LABELS.every(l => on.includes(l)),
       `a game on the default tool shows every conf and engine default on (${on.join(',')})`);
  t.ok(checked({ strCompatToolName: 'bridgeplay-proton-winecx-11.17' }).includes('MSync'),
       'the default tool named outright reads MSync as on');
  t.ok(!checked({ strCompatToolName: 'bridgeplay-proton-winehq' }).includes('MSync'),
       'a tool without msync reads MSync as off');
  // Frame generation as the confs set it up.
  const fg = (id, o, os) => walk(P({ details: details(o || '', Object.assign({ unAppID: id }, os || {})) }));
  const lab = (ns, l) => ns.find(x => x.props.label === l);
  let ns = fg(1778820);
  t.ok(lab(ns, 'Mode').props.selectedOption === '2' && lab(ns, 'Quality').props.selectedOption === 'quality' &&
       lab(ns, 'Engine').props.selectedOption === 'metalfx' &&
       lab(ns, 'Protect UI (keeps static HUD and menus sharp)').props.checked === false &&
       lab(ns, 'Fast-motion fallback (skips frames that would smear)').props.checked === false,
       'the global FRAMEGEN keys show through, 1 as 2x');
  t.ok(lab(fg(1778821), 'Mode').props.selectedOption === '0' && !lab(fg(1778821), 'Quality'),
       'a per-app FRAMEGEN=0 turns it off and hides the rest');
  // A native build reads np-native's confs and writes under the escaped home.
  const mac = { vecPlatforms: ['osx'], strCompatToolName: '' };
  ns = fg(1778820, '', mac);
  t.ok(lab(ns, 'Metal HUD').props.checked === true && lab(ns, 'Mode').props.selectedOption === '3' &&
       lab(ns, 'Controller layer').props.selectedOption === 'gc' && lab(ns, 'Engine').props.selectedOption === 'metalfx',
       'a native game shows the native confs, per app over default');
  t.ok(lab(fg(999, '', mac), 'Controller layer').props.selectedOption === 'hid', 'another native game gets the default');
  written.length = 0;
  lab(fg(999, '-novid', mac), 'Metal HUD').props.onChange(false);
  const want = "'" + home.replace(/'/g, "'\\''") + "/.bridgeplay/np-native' MTL_HUD_ENABLED=0 %command% -novid";
  t.ok(written.length === 1 && written[0].opts === want, `the launcher path is the user's home (${written[0] && written[0].opts})`);
  failed += t.failed;
}
delete globalThis.MSCXFx;

if (failed) { console.error(`effective: ${failed} check(s) failed`); process.exit(1); }
