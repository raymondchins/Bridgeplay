// The expert settings sit in one Advanced group, closed unless one of them is set for the
// game, and nothing in it is lost: every control is still rendered and still writes.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: advanced.js <emit>'); process.exit(2); }

const AVX = 'AVX2';
const RAW = 'Direct input';
const HIDRAW = 'Disable hidraw';
const X87 = 'Reduced x87 precision';
const METALFX = 'MetalFX';
const FEX_TOOLS = ['bridgeplay-proton-fex'];

const globals = extra => Object.assign(Object.create(globalThis),
  { document: { documentElement: { lang: 'en' } } }, extra || {});
const labels = ns => ns.filter(n => n.props && typeof n.props.label === 'string').map(n => n.props.label);

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const t = runner(form);
  const make = (g, opts = {}) => panel(emit, form, g || globals(), opts);
  const view = (P, opts, over) => {
    const all = walk(P.render({ details: details(opts, over) }));
    const adv = all.find(n => n.type === 'details');
    const inside = adv ? walk(adv.props.children) : [];
    return { all, adv, inside, outside: all.filter(n => !inside.includes(n)) };
  };

  let P = make();
  let v = view(P, 'CX_GRAPHICS_BACKEND=dxmt %command%');
  t.ok(!!v.adv && v.adv.props.className === 'MSCXAdv', 'the Wine panel has one Advanced group');
  t.ok(v.inside.some(n => n.type === 'summary' && n.props.children === 'Advanced'), 'its summary reads Advanced');
  t.ok(v.adv.props.open === false, 'it starts closed when none of its settings is set');
  for (const l of [AVX, 'MSync', RAW, HIDRAW, METALFX]) {
    t.ok(labels(v.inside).includes(l) && !labels(v.outside).includes(l), `${l} is inside the group`);
  }
  for (const l of ['Graphics', 'High Resolution', 'DLSS']) {
    t.ok(labels(v.outside).includes(l), `${l} stays outside the group`);
  }
  // A control in the closed group still writes, the same as before.
  P.written.length = 0;
  v.inside.find(n => n.type === 'Toggle' && n.props.label === 'MSync').props.onChange(true);
  t.ok(P.written.at(-1).opts === 'WINEMSYNC=1 CX_GRAPHICS_BACKEND=dxmt %command%',
       `MSync still writes from inside the group (${P.written.at(-1).opts})`);

  for (const [opts, what] of [
    ['WINEMSYNC=0 %command%', 'MSync off in launch options'],
    ['ROSETTA_ADVERTISE_AVX=0 %command%', 'AVX2 off'],
    ['BRIDGEPLAY_RAW_CONTROLLERS=1 %command%', 'raw controllers'],
    ['NOTPROTON_DISABLE_HIDRAW=1 %command%', 'hidraw in its pre-3.0 spelling'],
    ['CX_GRAPHICS_BACKEND=dxmt DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=2.0" %command%', 'a MetalFX factor'],
    ['CX_GRAPHICS_BACKEND=dxmt DXMT_METALFX_SPATIAL_SWAPCHAIN=1 %command%', 'MetalFX upscaling on'],
  ]) {
    t.ok(view(make(), opts).adv.props.open === true, `it opens for ${what}`);
  }
  t.ok(view(make(), 'BRIDGEPLAY_RETINA=0 MTL_HUD_ENABLED=1 %command%').adv.props.open === false,
       'settings outside the group leave it closed');
  t.ok(view(make(), 'CX_GRAPHICS_BACKEND=d3dmetal DXMT_METALFX_SPATIAL_SWAPCHAIN=1 %command%').adv.props.open === false,
       'a MetalFX key the panel does not show (D3DMetal) leaves it closed');

  // The game's own conf sets one of them: shown open, so the value is never hidden.
  P = make(globals({ MSCXFx: { a: { 287700: { WINEMSYNC: '0' } } } }));
  v = view(P, '');
  t.ok(v.adv.props.open === true, 'it opens when the game\'s own conf sets one of its settings');
  t.ok(view(P, '', { unAppID: 400 }).adv.props.open === false, 'another game\'s conf leaves it closed');

  // The player's open or close holds for that game this session, and only that game.
  P = make();
  v = view(P, 'WINEMSYNC=0 %command%');
  v.adv.props.onToggle({ target: { open: false } });
  t.ok(view(P, 'WINEMSYNC=0 %command%').adv.props.open === false, 'closed by the player, it stays closed');
  view(P, '', { unAppID: 400 }).adv.props.onToggle({ target: { open: true } });
  t.ok(view(P, '', { unAppID: 400 }).adv.props.open === true, 'opened by the player, it stays open');
  t.ok(view(P, '', { unAppID: 500 }).adv.props.open === false, 'another game keeps its own state');

  // FEX: no AVX2, and x87 precision is inside the group.
  P = make(undefined, { fexTools: FEX_TOOLS });
  const fex = { strCompatToolName: 'bridgeplay-proton-fex' };
  v = view(P, '', fex);
  t.ok(!labels(v.all).includes(AVX), 'FEX shows no AVX2 row');
  t.ok(labels(v.inside).includes(X87) && labels(v.inside).includes('FEX'), 'FEX x87 precision is inside the group');
  t.ok(v.adv.props.open === false, 'FEX starts closed');
  t.ok(view(P, 'FEX_X87REDUCEDPRECISION=0 %command%', fex).adv.props.open === true, 'FEX opens for x87 set');
  t.ok(view(P, 'ROSETTA_ADVERTISE_AVX=0 %command%', fex).adv.props.open === false,
       'FEX ignores an AVX2 key it does not show');

  // Native Mac games have no expert group.
  v = view(make(), '', { vecPlatforms: ['osx'], strCompatToolName: '' });
  t.ok(!v.adv, 'the native panel has no Advanced group');

  failed += t.failed;
}

if (failed) { console.error(`advanced: ${failed} failed`); process.exit(1); }
console.log('advanced: expert settings grouped, open when set, nothing lost');
