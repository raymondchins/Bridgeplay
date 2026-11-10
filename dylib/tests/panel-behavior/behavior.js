// What the panel renders, checked against both forms of the one payload.
'use strict';
const { panel, walk, details, runner, FORMS, overlay, hud, limit, filter } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: behavior.js <emit>'); process.exit(2); }

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  const nodes = opts => walk(P({ details: details(opts + ' %command%') }));
  const toggles = ns => ns.filter(x => x.type === 'Toggle').map(x => x.props.label);
  const sections = ns => ns.filter(x => x.type === 'Section').map(x => x.props.label.split(' ')[0]);
  const last = () => (written.length ? written[written.length - 1].opts : '');

  t.ok(P({ details: details('', { unAppID: 3420702832, vecPlatforms: ['osx'],
                                  strCompatToolName: '' }) }) !== null,
       'a shortcut renders the panel before a tool name reaches the page');

  let r = nodes('');
  t.ok(toggles(r).length === 7 && sections(r).length === 7, 'automatic shows seven toggles in seven sections');
  t.ok(r.filter(x => x.type === 'Dropdown').length === 5 && r.filter(x => x.type === 'Slider').length === 1,
       'five dropdowns and the limit slider');
  t.ok(!('label' in r.find(x => x.type === 'Dropdown').props), 'the backend dropdown carries no label column');

  r = nodes('CX_GRAPHICS_BACKEND=dxmt');
  t.ok(toggles(r).filter(l => l === 'DLSS').length === 1 && sections(r).includes('MetalFX'),
       'dxmt keeps one DLSS and keeps MetalFX');
  r = nodes('CX_GRAPHICS_BACKEND=d3dmetal');
  t.ok(toggles(r).filter(l => l === 'DLSS').length === 1 && !sections(r).includes('MetalFX'),
       'd3dmetal keeps one DLSS and hides MetalFX');
  // Both flags are labeled DLSS, so a backend showing its own and its neighbor's
  // would put the same word on two rows.
  for (const b of ['', 'd3dmetal', 'dxmt', 'dxvk', 'wined3d']) {
    const ls = toggles(nodes(b ? 'CX_GRAPHICS_BACKEND=' + b : ''));
    t.ok(ls.filter(l => l === 'DLSS').length === (b === 'dxvk' || b === 'wined3d' ? 0 : 1),
         `${b || 'automatic'} shows DLSS at most once (${ls.join(',')})`);
  }
  // The row that writes the flag the chosen backend actually reads.
  const dlss = (b, key) => {
    written.length = 0;
    nodes('CX_GRAPHICS_BACKEND=' + b).find(x => x.props.label === 'DLSS').props.onChange(true);
    t.ok(last().includes(key + '=1'), `${b} DLSS writes ${key} (${last()})`);
  };
  dlss('d3dmetal', 'D3DM_ENABLE_METALFX');
  dlss('dxmt', 'DXMT_ENABLE_NVEXT');
  t.ok(nodes('CX_GRAPHICS_BACKEND=dxmt DXMT_ENABLE_NVEXT=1')
         .find(x => x.props.label === 'DLSS').props.checked === true,
       'the dxmt DLSS toggle reads as on from its argument');

  t.ok(nodes('CX_GRAPHICS_BACKEND=dxmt').find(x => x.type === 'Dropdown').props.selectedOption === 'dxmt',
       'the backend dropdown reflects the current value');
  t.ok(hud(nodes('MTL_HUD_ENABLED=1')).props.checked === true,
       'the Metal HUD reads as on from its argument');

  nodes('CX_GRAPHICS_BACKEND=dxmt').find(x => x.type === 'Dropdown' && x.props.rgOptions.some(o => o.data === '1.5'))
    .props.onChange({ data: '2.0' });
  t.ok(last().includes('metalSpatialUpscaleFactor=2.0'), 'the upscaler writes its factor');

  // The section names the factor, so a label promising a resolution to go and set in
  // the game is the wording this replaced.
  const upscaler = nodes('CX_GRAPHICS_BACKEND=dxmt').find(x => x.type === 'Section' &&
    x.props.label.indexOf('MetalFX') === 0);
  t.ok(/Samples from the resolution the game is set to/.test(upscaler.props.label),
       'the upscaler section says where it samples from');
  const factors = nodes('CX_GRAPHICS_BACKEND=dxmt').find(x => x.type === 'Dropdown' && x.props.rgOptions.some(o => o.data === '1.5'))
    .props.rgOptions.map(o => o.label);
  t.ok(factors.join(',') === 'Off,1.5x,1.72x,2x,3x', `the factors name themselves (${factors.join(',')})`);

  // The value is the name wine gives the library, which is lower case, and the label is
  // the name in a list of four the reader picks from.
  const backends = nodes('').find(x => x.type === 'Dropdown').props.rgOptions;
  t.ok(backends.map(o => o.label).join(',') === 'Automatic,D3DMetal,DXMT,DXVK,WineD3D',
       `the backends name themselves (${backends.map(o => o.label).join(',')})`);
  t.ok(backends.map(o => o.data).join(',') === ',d3dmetal,dxmt,dxvk,wined3d',
       'the backend values stay as the tool reads them');

  const root = P({ details: details('') });
  t.ok(root.props.className === 'MSCXPanel', 'the panel root carries its own class');
  const classes = nodes('').filter(x => x.type === 'Toggle').map(x => x.props.className);
  t.ok(classes.length === 7 && classes.every(c => c === 'MSCXRow'), 'every checkbox carries the row class');

  // Performance Overlay: Bridgeplay's own levels and the Metal HUD in one menu, off by default.
  const po = o => overlay(nodes(o));
  const POL = 'Off:0,FPS:fps,Summary (FPS, frame time, CPU, GPU, memory, battery):summary,' +
              'Detailed (adds a frame-time graph):detailed,Apple Metal HUD:hud';
  t.ok(po('').props.rgOptions.map(x => x.label + ':' + x.data).join(',') === POL, 'the overlay levels name themselves');
  t.ok(nodes('').some(x => x.type === 'Section' && x.props.label === 'Performance Overlay (In game, ⌥⌘P opens quick settings for these controls)'),
       'the overlay has a section of its own');
  t.ok(po('').props.selectedOption === '0', 'the overlay is off by default');
  t.ok(po('BRIDGEPLAY_PERF_OVERLAY=summary').props.selectedOption === 'summary', 'a level reads from its argument');
  t.ok(po('NOTPROTON_PERF_OVERLAY=detailed').props.selectedOption === 'detailed', 'the pre-3.0 spelling reads too');
  t.ok(po('BRIDGEPLAY_PERF_OVERLAY=1').props.selectedOption === 'fps', '1 reads as FPS, as the shim takes it');
  t.ok(po('BRIDGEPLAY_PERF_OVERLAY=bogus').props.selectedOption === '0', 'a value the shim refuses reads as off');
  t.ok(po('MTL_HUD_ENABLED=1 BRIDGEPLAY_PERF_OVERLAY=fps').props.selectedOption === 'hud',
       'the Metal HUD shows over a level, as the shim lets it');
  written.length = 0;
  po('').props.onChange({ data: 'summary' });
  t.ok(last().trim() === 'BRIDGEPLAY_PERF_OVERLAY=summary %command%', `picking a level writes it (${last()})`);
  written.length = 0;
  po('WINEDEBUG=-all BRIDGEPLAY_PERF_OVERLAY=summary').props.onChange({ data: '0' });
  t.ok(last().trim() === 'WINEDEBUG=-all %command%', `Off drops it (${last()})`);
  written.length = 0;
  po('BRIDGEPLAY_PERF_OVERLAY=detailed').props.onChange({ data: 'hud' });
  t.ok(last().trim() === 'MTL_HUD_ENABLED=1 %command%', `the Metal HUD replaces a level (${last()})`);
  written.length = 0;
  po('MTL_HUD_ENABLED=1').props.onChange({ data: 'fps' });
  t.ok(last().trim() === 'BRIDGEPLAY_PERF_OVERLAY=fps %command%', `a level replaces the Metal HUD (${last()})`);
  written.length = 0;
  po('NOTPROTON_PERF_OVERLAY=fps').props.onChange({ data: 'detailed' });
  t.ok(last().trim() === 'BRIDGEPLAY_PERF_OVERLAY=detailed %command%', `the pre-3.0 spelling is rewritten (${last()})`);

  // Over Game Defaults: the conf's level shows, and the menu writes only what differs from it.
  globalThis.MSCXFx = { g: { BRIDGEPLAY_PERF_OVERLAY: 'detailed' }, a: {}, e: {}, d: {} };
  t.ok(po('').props.selectedOption === 'detailed', 'the Game Defaults level shows');
  written.length = 0;
  po('').props.onChange({ data: '0' });
  t.ok(last().trim() === 'BRIDGEPLAY_PERF_OVERLAY=0 %command%', `Off over a default level writes 0 (${last()})`);
  written.length = 0;
  po('BRIDGEPLAY_PERF_OVERLAY=fps').props.onChange({ data: 'detailed' });
  t.ok(last() === '', `the default level drops the override (${JSON.stringify(last())})`);
  globalThis.MSCXFx = { g: { MTL_HUD_ENABLED: '1' }, a: {}, e: {}, d: {} };
  t.ok(po('').props.selectedOption === 'hud', 'a Metal HUD default shows');
  written.length = 0;
  po('').props.onChange({ data: 'fps' });
  t.ok(last().trim() === 'BRIDGEPLAY_PERF_OVERLAY=fps MTL_HUD_ENABLED=0 %command%',
       `a level over a Metal HUD default turns that off (${last()})`);
  globalThis.MSCXFx = { g: {}, a: { 287700: { BRIDGEPLAY_PERF_OVERLAY: 'summary' } }, e: {}, d: {} };
  t.ok(po('').props.selectedOption === 'summary', "the game's own conf level shows");
  delete globalThis.MSCXFx;
  // Frame Rate Limit: a slider from 15 to the fastest display's rate and a switch that turns it
  // off and keeps its value, as on Steam Deck. Off, with the slider at the top, by default.
  const fl = o => limit(nodes(o));
  t.ok(nodes('').some(x => x.type === 'Section' && typeof x.props.label === 'string' &&
       x.props.label.startsWith('Frame Rate Limit (') && x.props.label.includes('refresh rate stays')),
       'the limit says it does not change the refresh rate');
  let L = fl('');
  t.ok(L.value.type === 'Slider' && L.value.props.min === 15 && L.value.props.max === 60 &&
       L.value.props.showValue === true && L.value.props.valueSuffix === ' FPS', "Steam's own slider, 15 to 60 FPS");
  t.ok(L.sw.type === 'Toggle' && L.sw.props.label === 'Enable frame limit' && L.sw.props.className === 'MSCXRow',
       'the switch is a row of its own');
  t.ok(L.off && L.dimmed && L.v === 60, 'no limit by default: switched off, the slider dimmed at the display rate');
  L = fl('BRIDGEPLAY_FPS_LIMIT=30');
  t.ok(!L.off && !L.dimmed && L.v === 30, 'a number reads from its argument and switches the limit on');
  t.ok(fl('BRIDGEPLAY_FPS_LIMIT=Half').v === 30 && !fl('BRIDGEPLAY_FPS_LIMIT=Half').off,
       'half from an earlier release shows as half the display rate');
  t.ok(fl('NOTPROTON_FPS_LIMIT=display').v === 60, 'display, in the pre-3.0 spelling too, shows as the display rate');
  t.ok(fl('BRIDGEPLAY_FPS_LIMIT=12').v === 15, 'a limit under 15 from an earlier release shows as 15');
  t.ok(fl('BRIDGEPLAY_FPS_LIMIT=90').v === 60, 'a limit over the display rate shows clamped to it');
  t.ok(fl('BRIDGEPLAY_FPS_LIMIT=5').off && fl('BRIDGEPLAY_FPS_LIMIT=0').off, 'a refused number or 0 reads as no limit');
  L = fl('BRIDGEPLAY_FPS_LIMIT=45 BRIDGEPLAY_FPS_LIMIT_OFF=1');
  t.ok(L.off && L.dimmed && L.v === 45, 'switched off, the slider keeps 45, dimmed');
  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: {}, fm: 120 };
  L = fl('BRIDGEPLAY_FPS_LIMIT=90');
  t.ok(L.value.props.max === 120 && L.v === 90, 'on a 120 Hz display the slider runs to 120 and 90 holds');
  delete globalThis.MSCXFx;
  written.length = 0;
  fl('BRIDGEPLAY_FPS_LIMIT=30').slide(42);
  t.ok(last().trim() === 'BRIDGEPLAY_FPS_LIMIT=42 %command%', `the slider writes its whole number (${last()})`);
  written.length = 0;
  fl('BRIDGEPLAY_FPS_LIMIT=30').slide(41.6);
  t.ok(last().trim() === 'BRIDGEPLAY_FPS_LIMIT=42 %command%', `a value between steps rounds (${last()})`);
  written.length = 0;
  fl('').slide(42);
  fl('BRIDGEPLAY_FPS_LIMIT=45 BRIDGEPLAY_FPS_LIMIT_OFF=1').slide(30);
  t.ok(written.length === 0, 'a dimmed slider writes nothing');
  written.length = 0;
  fl('WINEDEBUG=-all BRIDGEPLAY_FPS_LIMIT=30 BRIDGEPLAY_PERF_OVERLAY=summary').enable(false);
  t.ok(/BRIDGEPLAY_FPS_LIMIT_OFF=1/.test(last()) && /BRIDGEPLAY_FPS_LIMIT=30 /.test(last()) &&
       last().includes('WINEDEBUG=-all') && last().includes('BRIDGEPLAY_PERF_OVERLAY=summary'),
       `switching the limit off keeps the value and the rest of the line (${last()})`);
  written.length = 0;
  fl('BRIDGEPLAY_FPS_LIMIT=45 BRIDGEPLAY_FPS_LIMIT_OFF=1').enable(true);
  t.ok(last().trim() === 'BRIDGEPLAY_FPS_LIMIT=45 %command%', `switching it back on keeps 45 (${last()})`);
  written.length = 0;
  fl('').enable(true);
  t.ok(last().trim() === 'BRIDGEPLAY_FPS_LIMIT=60 %command%', `switching on with no value takes the slider's (${last()})`);
  globalThis.MSCXFx = { g: { BRIDGEPLAY_FPS_LIMIT: '40' }, a: {}, e: {}, d: {} };
  L = fl('');
  t.ok(!L.off && L.v === 40, 'the Game Defaults limit shows');
  written.length = 0;
  L.enable(false);
  t.ok(last().trim() === 'BRIDGEPLAY_FPS_LIMIT_OFF=1 %command%', `switching a default limit off writes the switch (${last()})`);
  written.length = 0;
  fl('BRIDGEPLAY_FPS_LIMIT=30').slide(40);
  t.ok(last() === '', `the default limit drops the override (${JSON.stringify(last())})`);
  globalThis.MSCXFx = { g: { BRIDGEPLAY_FPS_LIMIT: '40', BRIDGEPLAY_FPS_LIMIT_OFF: '1' }, a: {}, e: {}, d: {} };
  L = fl('');
  t.ok(L.off && L.v === 40, 'a limit switched off in Game Defaults shows off at its value');
  written.length = 0;
  L.enable(true);
  t.ok(last().trim() === 'BRIDGEPLAY_FPS_LIMIT_OFF=0 %command%', `switching it on for this game writes 0 (${last()})`);
  globalThis.MSCXFx = { g: {}, a: { 287700: { BRIDGEPLAY_FPS_LIMIT: '40' } }, e: {}, d: {} };
  t.ok(fl('').v === 40, "the game's own conf limit shows");
  delete globalThis.MSCXFx;
  written.length = 0;
  nodes('WINEDEBUG=-all BRIDGEPLAY_FPS_LIMIT=30 BRIDGEPLAY_FPS_LIMIT_OFF=1').find(x => x.type === 'button').props.onClick();
  t.ok(last().trim() === 'WINEDEBUG=-all %command%', `Use Bridgeplay defaults drops the limit and its switch (${last()})`);
  {
    // Without Steam's slider, a menu in steps of 5 stands in, with the value it reads
    const { render } = panel(emit, form, undefined, { slider: false });
    const M = limit(walk(render({ details: details('BRIDGEPLAY_FPS_LIMIT=42 %command%') })));
    t.ok(M.value.type === 'Dropdown' && M.v === 42 &&
         M.value.props.rgOptions.map(o => o.data).join(',') === '15,20,25,30,35,40,42,45,50,55,60',
         `a menu stands in for a missing slider (${M.value.props.rgOptions.map(o => o.data)})`);
  }

  // Scaling Filter: linear unless set, nearest or integer written only when they differ.
  const sf = o => filter(nodes(o));
  t.ok(sf('').props.rgOptions.map(x => x.label + ':' + x.data).join(',') ===
       'Automatic (Wine keeps pixels sharp with High Resolution off):0,Linear (smooth):linear,' +
       'Nearest (sharp pixels at any scale):nearest,' +
       'Integer (sharp at exact 2x or 3x, smooth otherwise):integer', 'the filters name themselves');
  t.ok(nodes('').some(x => x.type === 'Section' && typeof x.props.label === 'string' &&
       x.props.label.startsWith('Scaling Filter (When the game draws fewer pixels than the screen')),
       'the filter says when it applies');
  t.ok(sf('').props.selectedOption === '0', 'automatic by default');
  t.ok(sf('BRIDGEPLAY_SCALING_FILTER=Nearest').props.selectedOption === 'nearest', 'nearest reads in any case');
  t.ok(sf('BRIDGEPLAY_SCALING_FILTER=linear').props.selectedOption === 'linear', 'linear is its own choice, not the default');
  t.ok(sf('NOTPROTON_SCALING_FILTER=integer').props.selectedOption === 'integer', 'the pre-3.0 spelling reads too');
  t.ok(sf('BRIDGEPLAY_SCALING_FILTER=fsr').props.selectedOption === '0', 'a filter the shim refuses reads as automatic');
  written.length = 0;
  sf('').props.onChange({ data: 'linear' });
  t.ok(last().trim() === 'BRIDGEPLAY_SCALING_FILTER=linear %command%', `Linear is written (${last()})`);

  written.length = 0;
  sf('').props.onChange({ data: 'integer' });
  t.ok(last().trim() === 'BRIDGEPLAY_SCALING_FILTER=integer %command%', `picking a filter writes it (${last()})`);
  written.length = 0;
  sf('BRIDGEPLAY_SCALING_FILTER=nearest BRIDGEPLAY_FPS_LIMIT=30 DXMT_METALFX_SPATIAL_SWAPCHAIN=1').props.onChange({ data: '0' });
  t.ok(last().trim() === 'BRIDGEPLAY_FPS_LIMIT=30 DXMT_METALFX_SPATIAL_SWAPCHAIN=1 %command%',
       `Automatic drops only the filter, MetalFX and the limit stay (${last()})`);
  globalThis.MSCXFx = { g: { BRIDGEPLAY_SCALING_FILTER: 'nearest' }, a: {}, e: {}, d: {} };
  t.ok(sf('').props.selectedOption === 'nearest', 'the Game Defaults filter shows');
  written.length = 0;
  sf('').props.onChange({ data: '0' });
  t.ok(last().trim() === 'BRIDGEPLAY_SCALING_FILTER=0 %command%', `Automatic over a default filter writes 0 (${last()})`);
  written.length = 0;
  sf('BRIDGEPLAY_SCALING_FILTER=integer').props.onChange({ data: 'nearest' });
  t.ok(last() === '', `the default filter drops the override (${JSON.stringify(last())})`);
  delete globalThis.MSCXFx;
  written.length = 0;
  nodes('WINEDEBUG=-all BRIDGEPLAY_SCALING_FILTER=nearest').find(x => x.type === 'button').props.onClick();
  t.ok(last().trim() === 'WINEDEBUG=-all %command%', `Use Bridgeplay defaults drops the filter (${last()})`);

  const def = o => nodes(o).find(x => x.type === 'button');
  written.length = 0;
  def('WINEDEBUG=-all BRIDGEPLAY_PERF_OVERLAY=summary').props.onClick();
  t.ok(last().trim() === 'WINEDEBUG=-all %command%', `Use Bridgeplay defaults drops the overlay (${last()})`);
  const raw = o => nodes(o).find(x => x.props.label === 'Let games read controllers directly (Recommended on Mac. Turn off only for Steam Input remapping)');
  t.ok(sections(nodes('')).includes('Controllers') && raw('').props.checked === false,
       'controller hiding is on unless the game says otherwise');
  written.length = 0;
  nodes('').find(x => x.props.label === 'Disable hidraw').props.onChange(true);
  t.ok(last().trim() === 'BRIDGEPLAY_DISABLE_HIDRAW=1 %command%', `hidraw (${last()})`);
  written.length = 0;
  raw('').props.onChange(true);
  t.ok(last().trim() === 'BRIDGEPLAY_RAW_CONTROLLERS=1 %command%', `the controller row writes its flag (${last()})`);
  t.ok(raw('BRIDGEPLAY_RAW_CONTROLLERS=1').props.checked === true, 'the controller row reads its flag');
  written.length = 0;
  raw('BRIDGEPLAY_RAW_CONTROLLERS=1 WINEMSYNC=1').props.onChange(false);
  t.ok(last().trim() === 'WINEMSYNC=1 %command%', `turning the controller row off removes its flag (${last()})`);
  // Settings that come from the gamefix confs or the engine show as they will apply.
  globalThis.MSCXFx = {
    g: { MTL_HUD_ENABLED: '1', BRIDGEPLAY_RETINA: '1' },
    a: { 287700: { BRIDGEPLAY_RETINA: '0' } },
    e: { 'bridgeplay-proton': { WINEMSYNC: '1' }, '': { WINEMSYNC: '0' } },
    d: { BRIDGEPLAY_RAW_CONTROLLERS: '1' },
  };
  const row = (o, l) => l === 'Metal HUD' ? hud(nodes(o)) :
    nodes(o).find(x => x.props.label === l || (typeof x.props.label === 'string' && x.props.label.startsWith(l + ' (')));
  t.ok(row('', 'Metal HUD').props.checked === true, 'a global conf value reads as on');
  t.ok(row('', 'High Resolution').props.checked === false, 'the per-app conf beats the global conf');
  t.ok(row('', 'MSync').props.checked === true, 'the engine default reads as on');
  t.ok(row('', 'Let games read controllers directly').props.checked === true, 'the run script default reads as on');
  t.ok(row('MTL_HUD_ENABLED=0', 'Metal HUD').props.checked === false, 'the launch options beat the confs');
  written.length = 0;
  row('', 'Metal HUD').props.onChange(false);
  t.ok(last().trim() === 'MTL_HUD_ENABLED=0 %command%', `turning a default off writes 0 (${last()})`);
  written.length = 0;
  row('MTL_HUD_ENABLED=0', 'Metal HUD').props.onChange(true);
  t.ok(last() === '', `turning it back on drops the override (${JSON.stringify(last())})`);
  written.length = 0;
  row('', 'High Resolution').props.onChange(true);
  t.ok(last().trim() === 'BRIDGEPLAY_RETINA=1 %command%', `turning on what a conf turns off writes 1 (${last()})`);
  written.length = 0;
  row('', 'Let games read controllers directly').props.onChange(false);
  t.ok(last().trim() === 'BRIDGEPLAY_RAW_CONTROLLERS=0 %command%', `opting out of raw controllers writes 0 (${last()})`);
  delete globalThis.MSCXFx;

  // Frame generation: a mode for every backend, and the rest of its rows only once it is on.
  const FGL = 'Frame Generation (Experimental. Adds input lag)';
  const fgRows = o => {
    const sec = nodes(o).find(x => x.type === 'Section' && x.props.label === FGL);
    return sec ? walk(sec.props.children) : [];
  };
  const FGT = { ui: 'Protect UI (keeps static HUD and menus sharp)',
                fb: 'Fast-motion fallback (skips frames that would smear)' };
  const fgrow = (o, l) => fgRows(o).find(x => x.props.label === l || (typeof x.props.label === 'string' && x.props.label.startsWith(l + ' (')));
  for (const b of ['', 'd3dmetal', 'dxmt', 'dxvk', 'wined3d']) {
    t.ok(fgrow(b ? 'CX_GRAPHICS_BACKEND=' + b : '', 'Mode') !== undefined,
         `${b || 'automatic'} shows the frame generation mode`);
  }
  t.ok(nodes('').some(x => x.type === 'Section' && x.props.label === FGL),
       'the frame generation section warns about latency');
  const mode = fgrow('', 'Mode');
  t.ok(mode.type === 'Dropdown' && mode.props.className === undefined && mode.props.strClassName === 'MSCXDrop',
       'the mode is a dropdown with its label above it');
  t.ok(mode.props.rgOptions.map(x => x.label).join(',') === 'Off,2x,3x,Adaptive (fills to display refresh)' &&
       mode.props.rgOptions.map(x => x.data).join(',') === '0,2,3,adaptive',
       `the modes name themselves (${mode.props.rgOptions.map(x => x.label).join(',')})`);
  t.ok(mode.props.selectedOption === '0', 'frame generation is off by default');
  t.ok(fgRows('').length === 1, 'off hides every other frame generation row');
  t.ok(fgrow('BRIDGEPLAY_FRAMEGEN=0', 'Quality') === undefined, 'an explicit 0 hides them too');
  t.ok(fgrow('BRIDGEPLAY_FRAMEGEN=off', 'Mode').props.selectedOption === '0', 'off reads as Off');
  const ordered = fgRows('BRIDGEPLAY_FRAMEGEN=2').map(x => x.props.label);
  t.ok(ordered.join('|') === ['Mode', 'Quality', FGT.ui, FGT.fb, 'Engine'].join('|'),
       `on shows five rows in order (${ordered.join('|')})`);
  t.ok(fgRows('BRIDGEPLAY_FRAMEGEN=2').every(x => x.type === 'Dropdown' ? x.props.strClassName === 'MSCXDrop'
       : x.props.className === 'MSCXRow'),
       'frame generation toggles are rows and its dropdowns stack their label above');
  for (const [v, want] of [['1', '2'], ['2', '2'], ['3', '3'], ['adaptive', 'adaptive'], ['Adaptive', 'adaptive']]) {
    t.ok(fgrow('BRIDGEPLAY_FRAMEGEN=' + v, 'Mode').props.selectedOption === want, `${v} reads as ${want}`);
  }
  for (const [v, want] of [['2', 'BRIDGEPLAY_FRAMEGEN=2 %command%'], ['3', 'BRIDGEPLAY_FRAMEGEN=3 %command%'],
                           ['adaptive', 'BRIDGEPLAY_FRAMEGEN=adaptive %command%']]) {
    written.length = 0;
    fgrow('', 'Mode').props.onChange({ data: v });
    t.ok(last().trim() === want, `picking ${v} writes it (${last()})`);
  }
  written.length = 0;
  fgrow('BRIDGEPLAY_FRAMEGEN=1 WINEMSYNC=1', 'Mode').props.onChange({ data: '0' });
  t.ok(last().trim() === 'WINEMSYNC=1 %command%', `turning frame generation off removes its flag (${last()})`);
  written.length = 0;
  fgrow('BRIDGEPLAY_FRAMEGEN=1', 'Mode').props.onChange({ data: '3' });
  t.ok(last().trim() === 'BRIDGEPLAY_FRAMEGEN=3 %command%', `a legacy 1 is replaced, not kept (${last()})`);
  written.length = 0;
  fgrow('BRIDGEPLAY_FRAMEGEN=2 BRIDGEPLAY_FRAMEGEN_QUALITY=quality', 'Mode').props.onChange({ data: '0' });
  t.ok(last().trim() === 'BRIDGEPLAY_FRAMEGEN_QUALITY=quality %command%',
       `turning it off keeps the sub-settings for the next time (${last()})`);

  const on = 'BRIDGEPLAY_FRAMEGEN=2';
  const quality = fgrow(on, 'Quality');
  t.ok(quality.type === 'Dropdown' && quality.props.selectedOption === 'balanced', 'quality is balanced by default');
  t.ok(quality.props.rgOptions.map(x => x.label + ':' + x.data).join(',') ===
       'Performance:performance,Balanced:balanced,Quality:quality', 'the qualities name themselves');
  t.ok(fgrow(on + ' BRIDGEPLAY_FRAMEGEN_QUALITY=performance', 'Quality').props.selectedOption === 'performance',
       'quality reads its flag');
  written.length = 0;
  fgrow(on, 'Quality').props.onChange({ data: 'quality' });
  t.ok(last().trim() === 'BRIDGEPLAY_FRAMEGEN_QUALITY=quality BRIDGEPLAY_FRAMEGEN=2 %command%',
       `quality writes its flag (${last()})`);
  written.length = 0;
  fgrow(on + ' BRIDGEPLAY_FRAMEGEN_QUALITY=quality', 'Quality').props.onChange({ data: 'balanced' });
  t.ok(last().trim() === on + ' %command%', `balanced drops the flag (${last()})`);

  const engine = fgrow(on, 'Engine');
  t.ok(engine.type === 'Dropdown' && engine.props.selectedOption === 'own', 'the engine is the built-in one by default');
  t.ok(engine.props.rgOptions.map(x => x.label + ':' + x.data).join(',') ===
       'Built-in optical flow:own,MetalFX:metalfx', 'the engines name themselves');
  t.ok(fgrow(on + ' BRIDGEPLAY_FRAMEGEN_ENGINE=metalfx', 'Engine').props.selectedOption === 'metalfx',
       'the engine reads its flag');
  written.length = 0;
  fgrow(on, 'Engine').props.onChange({ data: 'metalfx' });
  t.ok(last().includes('BRIDGEPLAY_FRAMEGEN_ENGINE=metalfx '), `the engine writes its flag (${last()})`);
  written.length = 0;
  fgrow(on + ' BRIDGEPLAY_FRAMEGEN_ENGINE=metalfx', 'Engine').props.onChange({ data: 'own' });
  t.ok(last().trim() === on + ' %command%', `own drops the flag (${last()})`);

  // Both toggles are on unless told otherwise, which only the run script defaults say.
  globalThis.MSCXFx = { g: {}, a: {}, e: {},
                        d: { BRIDGEPLAY_FRAMEGEN_UI: '1', BRIDGEPLAY_FRAMEGEN_FALLBACK: '1' } };
  for (const [k, l] of [['BRIDGEPLAY_FRAMEGEN_UI', FGT.ui], ['BRIDGEPLAY_FRAMEGEN_FALLBACK', FGT.fb]]) {
    t.ok(fgrow(on, l).type === 'Toggle' && fgrow(on, l).props.checked === true, `${k} is on by default`);
    t.ok(fgrow(on + ` ${k}=0`, l).props.checked === false, `${k} reads 0 as off`);
    written.length = 0;
    fgrow(on, l).props.onChange(false);
    t.ok(last().trim() === `${k}=0 ${on} %command%`, `turning ${k} off writes 0 (${last()})`);
    written.length = 0;
    fgrow(on + ` ${k}=0`, l).props.onChange(true);
    t.ok(last().trim() === `${on} %command%`, `turning ${k} back on drops it (${last()})`);
  }
  // A conf that turns frame generation on: Off has to say so, picking the conf's mode says nothing.
  globalThis.MSCXFx = { g: { BRIDGEPLAY_FRAMEGEN: '1', BRIDGEPLAY_FRAMEGEN_QUALITY: 'performance',
                             BRIDGEPLAY_FRAMEGEN_ENGINE: 'metalfx', BRIDGEPLAY_FRAMEGEN_UI: '0' },
                        a: {}, e: {}, d: { BRIDGEPLAY_FRAMEGEN_UI: '1', BRIDGEPLAY_FRAMEGEN_FALLBACK: '1' } };
  t.ok(fgrow('', 'Mode').props.selectedOption === '2', 'a global conf 1 reads frame generation as 2x');
  t.ok(fgRows('').length === 5, 'a conf that turns it on shows every row');
  t.ok(fgrow('', 'Quality').props.selectedOption === 'performance', 'quality reads the conf');
  t.ok(fgrow('', 'Engine').props.selectedOption === 'metalfx', 'the engine reads the conf');
  t.ok(fgrow('', FGT.ui).props.checked === false, 'the conf beats the run script default');
  written.length = 0;
  fgrow('', 'Mode').props.onChange({ data: '0' });
  t.ok(last().trim() === 'BRIDGEPLAY_FRAMEGEN=0 %command%', `off over a conf default writes 0 (${last()})`);
  written.length = 0;
  fgrow('BRIDGEPLAY_FRAMEGEN=0', 'Mode').props.onChange({ data: '2' });
  t.ok(last() === '', `the conf's own mode drops the override (${JSON.stringify(last())})`);
  written.length = 0;
  fgrow('', 'Quality').props.onChange({ data: 'balanced' });
  t.ok(last().trim() === 'BRIDGEPLAY_FRAMEGEN_QUALITY=balanced %command%',
       `balanced over a conf default writes it (${last()})`);
  delete globalThis.MSCXFx;

  // Native macOS builds with nothing pinned run through np-native: HUD, frame generation, pads.
  const HOME = '/Users/some one';
  const NAT = "'/Users/some one/.bridgeplay/np-native'";
  const mac = (o, over) => details(o, Object.assign({ vecPlatforms: ['osx'], strCompatToolName: '' }, over || {}));
  const nnodes = o => walk(P({ details: mac(o) }));
  const nrow = (o, l) => l === 'Metal HUD' ? hud(nnodes(o)) :
    nnodes(o).find(x => x.props.label === l || (typeof x.props.label === 'string' && x.props.label.startsWith(l + ' (')));
  globalThis.MSCXFx = { g: { MTL_HUD_ENABLED: '1', BRIDGEPLAY_FRAMEGEN: '2' }, a: { 287700: { WINEMSYNC: '1' } },
                        e: {}, d: { BRIDGEPLAY_FRAMEGEN_UI: '1', BRIDGEPLAY_FRAMEGEN_FALLBACK: '1' },
                        ng: {}, na: {}, h: HOME };
  let n = nnodes('');
  t.ok(P({ details: mac('') }) !== null && P({ details: mac('') }).props.className === 'MSCXPanel',
       'a mac build with nothing pinned renders the native panel');
  t.ok(toggles(n).join(',') === 'Enable frame limit' && sections(n).join(',') === 'Performance,Frame,Scaling,Frame,Controllers',
       `the native panel has the overlay, the limit, the filter, frame generation and controllers only (${toggles(n)} / ${sections(n)})`);
  t.ok(n.filter(x => x.type === 'Dropdown').map(x => x === overlay(n) ? 'overlay' :
        x === filter(n) ? 'filter' : x.props.label).join(',') === 'overlay,filter,Mode,Controller layer' &&
       limit(n).value.type === 'Slider',
       'native dropdowns: the overlay, the filter, the mode and the controller layer; the limit is a slider');
  written.length = 0;
  filter(nnodes('-novid')).props.onChange({ data: 'nearest' });
  t.ok(last() === NAT + ' BRIDGEPLAY_SCALING_FILTER=nearest %command% -novid',
       `a native game gets the filter under np-native (${last()})`);
  t.ok(filter(nnodes('')).props.rgOptions[0].label === 'Automatic (as the game sets it)',
       'a native game is not told about Wine');
  written.length = 0;
  limit(nnodes('-novid')).enable(true);
  t.ok(last() === NAT + ' BRIDGEPLAY_FPS_LIMIT=60 %command% -novid', `a native game gets the limit under np-native (${last()})`);
  written.length = 0;
  limit(nnodes(NAT + ' BRIDGEPLAY_FPS_LIMIT=60 %command% -novid')).slide(30);
  t.ok(last() === NAT + ' BRIDGEPLAY_FPS_LIMIT=30 %command% -novid', `and its slider writes there too (${last()})`);
  written.length = 0;
  overlay(nnodes('-novid')).props.onChange({ data: 'summary' });
  t.ok(last() === NAT + ' BRIDGEPLAY_PERF_OVERLAY=summary %command% -novid',
       `a native game gets the overlay under np-native (${last()})`);
  written.length = 0;
  overlay(nnodes(NAT + ' BRIDGEPLAY_PERF_OVERLAY=summary %command% -novid')).props.onChange({ data: 'hud' });
  t.ok(last() === NAT + ' MTL_HUD_ENABLED=1 %command% -novid', `and the Metal HUD in its place (${last()})`);
  t.ok(nrow('', 'Metal HUD').props.checked === false && nrow('', 'Mode').props.selectedOption === '0',
       'the Wine confs do not reach a native game');
  t.ok(nnodes('BRIDGEPLAY_FRAMEGEN=3 %command%').filter(x => x.props.label === 'Quality').length === 1,
       'the native panel carries the same frame generation rows');
  const pad = nrow('', 'Controller layer');
  t.ok(pad.props.rgOptions.map(x => x.label + ':' + x.data).join(',') ===
       'Automatic:,Raw HID (Unity, SDL, Unreal):hid,GameController:gc,Off:off', 'the controller layers name themselves');
  t.ok(pad.props.selectedOption === '', 'Automatic is selected when NP_PAD_MODE is unset everywhere');
  t.ok(nrow(NAT + ' MTL_HUD_ENABLED=1 %command%', 'Controller layer').props.selectedOption === '',
       'Automatic stays selected when other variables are set');
  t.ok(pad.props.strClassName === 'MSCXDrop', 'the controller layer is a stacked dropdown');
  t.ok(nnodes('').some(x => x.type === 'Section' && x.props.label === 'Controllers'), 'the native controller section');
  t.ok(P({ details: mac('', { unAppID: 3420702832 }) }).props.children.props.children.length > 4,
       'a mac shortcut still gets the full panel');
  t.ok(P({ details: mac('', { strCompatToolName: 'bridgeplay-proton' }) }).props.children.props.children.length > 4,
       'a mac build with a tool pinned still gets the full panel');

  const ARCH = '/usr/bin/arch -arm64 -x86_64 -e "DYLD_INSERT_LIBRARIES=/Users/x/Library/Application Support/a.dylib"' +
               ' -e NP_PAD_MODE=hid -e MTL_HUD_ENABLED=1 %command% -novid';
  const NEW = '/Users/someone/.bridgeplay/np-native NP_PAD_MODE=hid MTL_HUD_ENABLED=1 %command% -novid';
  for (const [name, o] of [['arch', ARCH], ['np-native', NEW]]) {
    t.ok(nrow(o, 'Metal HUD').props.checked === true, `${name}: the HUD reads from -e/VAR pairs`);
    t.ok(nrow(o, 'Controller layer').props.selectedOption === 'hid', `${name}: the controller layer reads hid`);
    written.length = 0;
    nrow(o, 'Controller layer').props.onChange({ data: 'gc' });
    t.ok(last() === NAT + ' NP_PAD_MODE=gc MTL_HUD_ENABLED=1 %command% -novid',
         `${name}: rewritten under the launcher, -novid kept (${last()})`);
    written.length = 0;
    nrow(o, 'Mode').props.onChange({ data: 'adaptive' });
    t.ok(last() === NAT + ' NP_PAD_MODE=hid MTL_HUD_ENABLED=1 BRIDGEPLAY_FRAMEGEN=adaptive %command% -novid',
         `${name}: a new variable goes before %command% (${last()})`);
    written.length = 0;
    nrow(o, 'Metal HUD').props.onChange(false);
    t.ok(last() === NAT + ' NP_PAD_MODE=hid %command% -novid', `${name}: turning the HUD off drops it (${last()})`);
  }
  for (const [name, o] of [['arch', ARCH], ['np-native', NEW]]) {
    written.length = 0;
    nrow(o, 'Controller layer').props.onChange({ data: '' });
    t.ok(last() === NAT + ' MTL_HUD_ENABLED=1 %command% -novid',
         `${name}: Automatic from hid drops NP_PAD_MODE, keeps np-native and -novid (${last()})`);
  }
  written.length = 0;
  nrow(NAT + ' NP_PAD_MODE=gc %command% -novid +map x', 'Controller layer').props.onChange({ data: '' });
  t.ok(last() === NAT + ' %command% -novid +map x', `Automatic as the last variable keeps the launcher (${last()})`);
  written.length = 0;
  nrow('/x/.bridgeplay/np-native MTL_HUD_ENABLED=1 %command% -novid', 'Metal HUD').props.onChange(false);
  t.ok(last() === NAT + ' %command% -novid', `no variable left keeps the launcher and the arguments (${last()})`);
  written.length = 0;
  nrow('', 'Controller layer').props.onChange({ data: 'off' });
  t.ok(last() === NAT + ' NP_PAD_MODE=off %command%', `empty options get the launcher (${last()})`);
  written.length = 0;
  nrow('-novid', 'Mode').props.onChange({ data: '3' });
  t.ok(last() === NAT + ' BRIDGEPLAY_FRAMEGEN=3 %command% -novid', `bare game arguments follow %command% (${last()})`);

  // Native defaults come from np-native's confs, the per-app one first.
  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: { BRIDGEPLAY_FRAMEGEN_UI: '1', BRIDGEPLAY_FRAMEGEN_FALLBACK: '1' },
                        ng: { MTL_HUD_ENABLED: '1', NP_PAD_MODE: 'hid', BRIDGEPLAY_FRAMEGEN: 'adaptive' },
                        na: { 287700: { NP_PAD_MODE: 'gc' } }, h: '/Users/me' };
  t.ok(nrow('', 'Metal HUD').props.checked === true, 'native-default.conf reads the HUD as on');
  t.ok(nrow('', 'Mode').props.selectedOption === 'adaptive', 'native-default.conf sets the mode');
  t.ok(nrow('', 'Controller layer').props.selectedOption === 'gc', 'the per-app native conf beats the default');
  t.ok(nrow('', FGT.ui).props.checked === true, 'the shim defaults hold for native games');
  written.length = 0;
  nrow('', 'Metal HUD').props.onChange(false);
  t.ok(last() === '/Users/me/.bridgeplay/np-native MTL_HUD_ENABLED=0 %command%',
       `turning a native default off writes 0 under the home from the page (${last()})`);
  written.length = 0;
  nrow('NP_PAD_MODE=hid %command%', 'Controller layer').props.onChange({ data: 'gc' });
  t.ok(last() === '/Users/me/.bridgeplay/np-native %command%', `the conf's own layer drops the override (${last()})`);
  // Without a home from the page the launcher already there is reused, and nothing is guessed.
  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: {} };
  written.length = 0;
  nrow(NEW, 'Mode').props.onChange({ data: '2' });
  t.ok(last() === '/Users/someone/.bridgeplay/np-native NP_PAD_MODE=hid MTL_HUD_ENABLED=1 BRIDGEPLAY_FRAMEGEN=2 %command% -novid',
       `no home: the existing launcher path is kept (${last()})`);
  written.length = 0;
  nrow(ARCH, 'Mode').props.onChange({ data: '2' });
  t.ok(written.length === 0, 'no home and no launcher: nothing is written');
  delete globalThis.MSCXFx;

  // Launch options written before 3.0: NOTPROTON_<X> and ~/.notproton/np-native still read,
  // NOTPROTON_<X> winning as in the run script, and a write moves the line to the new names.
  t.ok(raw('NOTPROTON_RAW_CONTROLLERS=1').props.checked === true, 'a NOTPROTON_ flag still reads');
  t.ok(raw('NOTPROTON_RAW_CONTROLLERS=1 BRIDGEPLAY_RAW_CONTROLLERS=0').props.checked === true,
       'NOTPROTON_ wins over BRIDGEPLAY_ when a line has both');
  t.ok(fgrow('NOTPROTON_FRAMEGEN=3', 'Mode').props.selectedOption === '3', 'a NOTPROTON_ value still reads');
  written.length = 0;
  raw('NOTPROTON_RAW_CONTROLLERS=1 WINEMSYNC=1').props.onChange(false);
  t.ok(last().trim() === 'WINEMSYNC=1 %command%', `turning a NOTPROTON_ flag off removes it (${last()})`);
  written.length = 0;
  nodes('NOTPROTON_RETINA=0 WINEMSYNC=1').find(x => x.props.label === 'High Resolution').props.onChange(true);
  t.ok(last().trim() === 'BRIDGEPLAY_RETINA=1 WINEMSYNC=1 %command%', `a write replaces the NOTPROTON_ name (${last()})`);
  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: {}, ng: {}, na: {}, h: '/Users/me' };
  t.ok(nrow('/Users/me/.notproton/np-native NOTPROTON_FRAMEGEN=2 %command% -novid', 'Mode').props.selectedOption === '2',
       'a native line under the old launcher reads');
  written.length = 0;
  nrow('/Users/me/.notproton/np-native NOTPROTON_FRAMEGEN=2 %command% -novid', 'Mode').props.onChange({ data: '3' });
  t.ok(last() === '/Users/me/.bridgeplay/np-native BRIDGEPLAY_FRAMEGEN=3 %command% -novid',
       `a native write moves the launcher and the name (${last()})`);
  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: {} };
  written.length = 0;
  nrow('/Users/someone/.notproton/np-native MTL_HUD_ENABLED=1 %command%', 'Mode').props.onChange({ data: '2' });
  t.ok(last() === '/Users/someone/.notproton/np-native MTL_HUD_ENABLED=1 BRIDGEPLAY_FRAMEGEN=2 %command%',
       `no home: the old launcher is found and kept (${last()})`);
  delete globalThis.MSCXFx;

  // Use Bridgeplay defaults: only for a game that sets one of them, and it drops just those.
  const reset = ns => ns.find(x => x.type === 'button' && x.props.className === 'MSCXBtn');
  t.ok(!reset(nodes('')) && !reset(nodes('FOO=1 BRIDGEPLAY_RAW_CONTROLLERS=1')),
       'no Use Bridgeplay defaults button when the game sets none of them');
  written.length = 0;
  reset(nodes('CX_GRAPHICS_BACKEND=dxvk FOO=bar NOTPROTON_RETINA=1 BRIDGEPLAY_FRAMEGEN=3 BRIDGEPLAY_RAW_CONTROLLERS=1')
        ).props.onClick();
  t.ok(last().trim() === 'FOO=bar BRIDGEPLAY_RAW_CONTROLLERS=1 %command%',
       `Use Bridgeplay defaults drops only those settings, either spelling (${last()})`);
  written.length = 0;
  reset(nodes('NOTPROTON_VSYNC=1 FOO=bar BRIDGEPLAY_BACKEND=dxvk')).props.onClick();
  t.ok(last().trim() === 'FOO=bar %command%',
       `Use Bridgeplay defaults also drops vsync and the backend's own spelling (${last()})`);
  written.length = 0;
  reset(nodes('CX_GRAPHICS_BACKEND=dxmt DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=2.0;dxgi.x=1"')).props.onClick();
  t.ok(last().trim() === 'DXMT_CONFIG=dxgi.x=1 %command%',
       `Use Bridgeplay defaults keeps other DXMT_CONFIG entries (${last()})`);
  written.length = 0;
  reset(nodes('MTL_HUD_ENABLED=1')).props.onClick();
  t.ok(last() === '', `a line left with only %command% is cleared (${JSON.stringify(last())})`);

  const css = nodes('').filter(x => x.type === 'style');
  t.ok(css.length === 1 && css[0].props.children.includes('.MSCXPanel .MSCXRow{'),
       'the panel carries one stylesheet defining the row rule');

  const { render: S } = panel(emit, form, undefined, { names: ['o', 't'] });
  const shadowed = walk(S({ details: details('CX_GRAPHICS_BACKEND=dxmt %command%') }));
  t.ok(JSON.stringify(shadowed) === JSON.stringify(nodes('CX_GRAPHICS_BACKEND=dxmt')),
       'a page naming its runtime and barrel o and t renders the same panel');

  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nboth shapes pass');
process.exit(failed ? 1 : 0);
