// An option belongs to the backend that reads it, and the control for it goes away
// with that backend. An argument left behind is one the page can no longer switch
// off, so changing the backend has to take it along.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: switching.js <emit>'); process.exit(2); }

const DXMT = ['DXMT_METALFX_SPATIAL_SWAPCHAIN', 'DXMT_CONFIG'];
const D3DM = ['D3DM_ENABLE_METALFX'];
const NVEXT = ['DXMT_ENABLE_NVEXT'];
const DLSS_ON = 'CX_GRAPHICS_BACKEND=dxmt DXMT_ENABLE_NVEXT=1';
const UPSCALED = 'CX_GRAPHICS_BACKEND=dxmt DXMT_METALFX_SPATIAL_SWAPCHAIN=1'
               + ' DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2.0';

// Whichever backend is chosen, the arguments the others own have to be gone and the
// arguments no backend owns have to survive.
const CASES = [
  { to: 'd3dmetal', from: UPSCALED, gone: DXMT, kept: [] },
  { to: 'dxvk',     from: UPSCALED, gone: DXMT, kept: [] },
  { to: 'wined3d',  from: UPSCALED, gone: DXMT, kept: [] },
  { to: 'dxmt',     from: 'CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1', gone: D3DM, kept: [] },
  { to: 'dxvk',     from: 'CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1', gone: D3DM, kept: [] },
  // Automatic resolves to either backend, so neither one's arguments are stale.
  { to: '',         from: UPSCALED, gone: [], kept: DXMT },
  { to: '',         from: 'CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1', gone: [], kept: D3DM },
  // The dxmt DLSS row is the exception: it shows under dxmt alone, so automatic has
  // nowhere to switch the flag off and has to take it along.
  { to: '',         from: DLSS_ON, gone: NVEXT, kept: [] },
  { to: 'd3dmetal', from: DLSS_ON, gone: NVEXT, kept: [] },
  { to: 'dxvk',     from: DLSS_ON, gone: NVEXT, kept: [] },
  { to: 'wined3d',  from: DLSS_ON, gone: NVEXT, kept: [] },
  { to: 'dxmt',     from: DLSS_ON, gone: [], kept: NVEXT },
  // Switching into dxmt drops the other backend's DLSS rather than leaving both set.
  { to: 'dxmt',
    from: 'CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1 DXMT_ENABLE_NVEXT=1',
    gone: D3DM, kept: NVEXT },
  // Stripping arguments by name is the kind of thing that takes neighbours with it.
  { to: 'dxvk',
    from: 'MTL_HUD_ENABLED=1 WINEMSYNC=1 BRIDGEPLAY_RETINA=1 ' + UPSCALED + ' %command% -novid',
    gone: DXMT,
    kept: ['-novid', 'MTL_HUD_ENABLED=1', 'WINEMSYNC=1', 'BRIDGEPLAY_RETINA=1', '%command%'] },
];

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  for (const c of CASES) {
    written.length = 0;
    const from = c.from.includes('%command%') ? c.from : c.from + ' %command%';
    const nodes = walk(P({ details: details(from) }));
    const backend = nodes.find(x => x.type === 'Dropdown' &&
      (x.props.rgOptions || []).some(o => o.data === 'dxmt'));
    backend.props.onChange({ data: c.to });
    const opts = written.length ? written[written.length - 1].opts : '';
    const stale = c.gone.filter(k => opts.indexOf(k + '=') >= 0);
    const lost = c.kept.filter(k => opts.indexOf(k) < 0);
    const to = c.to || 'automatic';
    t.ok(stale.length === 0 && lost.length === 0,
         `switching to ${to} drops ${c.gone.length} and keeps ${c.kept.length}`
         + (stale.length ? ` [stale: ${stale}]` : '') + (lost.length ? ` [lost: ${lost}]` : ''));
  }
  // %command% has to stay last or Steam runs the game before the arguments.
  written.length = 0;
  const nodes = walk(P({ details: details(UPSCALED + ' %command%') }));
  nodes.find(x => x.type === 'Dropdown' &&
    (x.props.rgOptions || []).some(o => o.data === 'dxmt')).props.onChange({ data: 'dxvk' });
  const opts = written[written.length - 1].opts;
  t.ok(opts.trim().endsWith('%command%'), `%command% stays last (${opts})`);
  // The run script takes a valid BRIDGEPLAY_BACKEND (NOTPROTON_BACKEND winning) over
  // CX_GRAPHICS_BACKEND, so the menu shows what runs, and a pick has to drop it.
  const menu = o => walk(P({ details: details(o + ' %command%') })).find(x => x.type === 'Dropdown' &&
    (x.props.rgOptions || []).some(d => d.data === 'dxmt'));
  for (const [o, want] of [['BRIDGEPLAY_BACKEND=dxvk', 'dxvk'],
                           ['CX_GRAPHICS_BACKEND=dxmt BRIDGEPLAY_BACKEND=wined3d', 'wined3d'],
                           ['NOTPROTON_BACKEND=dxmt BRIDGEPLAY_BACKEND=dxvk', 'dxmt'],
                           ['CX_GRAPHICS_BACKEND=dxmt BRIDGEPLAY_BACKEND=bogus', 'dxmt']]) {
    const got = menu(o).props.selectedOption;
    t.ok(got === want, `${o} shows ${want} (${got})`);
  }
  for (const to of ['dxmt', '']) {
    written.length = 0;
    menu('BRIDGEPLAY_BACKEND=dxvk NOTPROTON_BACKEND=dxvk').props.onChange({ data: to });
    const w = written.length ? written[written.length - 1].opts : '';
    t.ok(!/(BRIDGEPLAY|NOTPROTON)_BACKEND=/.test(w) && menu(w.replace(/ ?%command%.*/, '')).props.selectedOption === to,
         `picking ${to || 'automatic'} drops BRIDGEPLAY_BACKEND (${w})`);
  }
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nno stale arguments, nothing lost');
process.exit(failed ? 1 : 0);
