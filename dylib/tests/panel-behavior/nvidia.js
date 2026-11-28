// Report an NVIDIA GPU: a per-game switch for the NVAPI conf key, shown only where it acts
// (D3DMetal), on by the shipped default, and written as BRIDGEPLAY_NVAPI only when it
// differs from the confs.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: nvidia.js <emit>'); process.exit(2); }

const LABEL = 'Report an NVIDIA GPU (Needed for DLSS. Turn off if the game crashes or looks wrong)';
const SHIPPED = { g: { BRIDGEPLAY_NVAPI: '1' }, a: {}, e: {}, d: {} };

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  const nodes = (o, over) => walk(P({ details: details(o, over) }));
  const row = ns => ns.find(x => x.type === 'Toggle' && x.props.label === LABEL);
  const last = () => written.length ? written[written.length - 1].opts : '';

  globalThis.MSCXFx = SHIPPED;
  t.ok(!!row(nodes('')) && row(nodes('')).props.checked, 'automatic on D3DMetal shows the row, on by the shipped default');
  t.ok(!!row(nodes('CX_GRAPHICS_BACKEND=d3dmetal %command%')), 'D3DMetal shows the row');
  for (const b of ['dxmt', 'dxvk', 'wined3d'])
    t.ok(!row(nodes(`CX_GRAPHICS_BACKEND=${b} %command%`)), `${b} hides the row, NVAPI does nothing there`);
  t.ok(!row(nodes('', { vecPlatforms: ['osx'], strCompatToolName: '' })), 'a native Mac game has no such row');

  written.length = 0;
  row(nodes('')).props.onChange(false);
  t.ok(last().trim() === 'BRIDGEPLAY_NVAPI=0 %command%', `off writes BRIDGEPLAY_NVAPI=0 (${last()})`);
  const off = nodes('BRIDGEPLAY_NVAPI=0 %command%');
  t.ok(row(off).props.checked === false, 'a game set to 0 shows the row off');
  t.ok(row(nodes('NOTPROTON_NVAPI=0 %command%')).props.checked === false, 'the pre-3.0 spelling is read');
  written.length = 0;
  row(off).props.onChange(true);
  t.ok(last() === '', `on again drops the argument, the default is on (${JSON.stringify(last())})`);

  // A game whose own conf turns nvapi off (Diablo IV) shows off, and on writes 1 over it.
  globalThis.MSCXFx = { g: { BRIDGEPLAY_NVAPI: '1' }, a: { 287700: { BRIDGEPLAY_NVAPI: '0' } }, e: {}, d: {} };
  t.ok(row(nodes('')).props.checked === false, "the game's own NVAPI=0 conf shows off");
  written.length = 0;
  row(nodes('')).props.onChange(true);
  t.ok(last().trim() === 'BRIDGEPLAY_NVAPI=1 %command%', `on over that conf writes 1 (${last()})`);

  // Without any conf the run script treats NVAPI as 0.
  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: {} };
  t.ok(row(nodes('')).props.checked === false, 'no conf reads as off, as in the run script');

  globalThis.MSCXFx = SHIPPED;
  written.length = 0;
  nodes('CX_GRAPHICS_BACKEND=d3dmetal BRIDGEPLAY_NVAPI=0 %command%').find(x => x.type === 'Dropdown')
    .props.onChange({ data: 'dxmt' });
  t.ok(last().includes('CX_GRAPHICS_BACKEND=dxmt') && !last().includes('NVAPI'),
       `leaving D3DMetal drops the hidden switch (${last()})`);
  written.length = 0;
  nodes('CX_GRAPHICS_BACKEND=d3dmetal BRIDGEPLAY_NVAPI=0 %command%').find(x => x.type === 'Dropdown')
    .props.onChange({ data: '' });
  t.ok(last().includes('BRIDGEPLAY_NVAPI=0'), `automatic keeps it, D3DMetal is still the default there (${last()})`);

  const btn = nodes('BRIDGEPLAY_NVAPI=0 %command%').find(x => x.type === 'button');
  written.length = 0;
  btn && btn.props.onClick();
  t.ok(!!btn && !last().includes('NVAPI'), `Use Bridgeplay defaults drops it (${last()})`);
  delete globalThis.MSCXFx;
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nReport an NVIDIA GPU: shown on D3DMetal, written only when it differs');
process.exit(failed ? 1 : 0);
