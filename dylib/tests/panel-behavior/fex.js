// On the FEX build the panel drops the controls that cannot take effect there, and
// the Rosetta build keeps every one of them.
'use strict';
const { panel, walk, details, runner, FORMS, hud } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: fex.js <emit>'); process.exit(2); }

const AVX = 'Advertise AVX2 to Rosetta';
const X87 = 'Reduced x87 Precision (Reducing precision improves game performance, is enabled by default in CrossOver Preview)';

// The hook passes only FEX tools; bridgeplay-proton-rosetta stands for a Rosetta tool next to it.
const FEX_TOOLS = ['bridgeplay-proton-fex'];

let failed = 0;
for (const form of Object.keys(FORMS)) {
  for (const fex of [false, true]) {
    const { render: P, written } = panel(emit, form, undefined, { fexTools: FEX_TOOLS });
    const t = runner(`${form}, ${fex ? 'FEX' : 'Rosetta'}`);
    const tool = fex ? 'bridgeplay-proton-fex' : 'bridgeplay-proton-rosetta';
    const nodes = opts =>
      walk(P({ details: details(opts + ' %command%', { strCompatToolName: tool }) }));
    const toggles = ns => ns.filter(x => x.type === 'Toggle').map(x => x.props.label);
    const backends = ns => ns.find(x => x.type === 'Dropdown').props.rgOptions.map(o => o.data);

    let r = nodes('');
    t.ok(backends(r).includes('d3dmetal') === !fex,
         `D3DMetal is ${fex ? 'not ' : ''}offered (${backends(r)})`);
    t.ok(toggles(r).includes(AVX) === !fex, `the AVX2 row is ${fex ? 'hidden' : 'shown'}`);
    t.ok(toggles(r).includes(X87) === fex, `the x87 row is ${fex ? 'shown' : 'hidden'}`);
    t.ok(r.some(x => x.type === 'Section' && x.props.label === 'FEX') === fex,
         `the FEX section is ${fex ? 'shown' : 'hidden'}`);
    if (!fex) {
      const avx = ns => ns.find(x => x.type === 'Toggle' && x.props.label === AVX);
      t.ok(avx(r).props.checked === true, 'the AVX2 row is on by default');
      written.length = 0;
      avx(r).props.onChange(false);
      t.ok(written[written.length - 1].opts.includes('ROSETTA_ADVERTISE_AVX=0'),
           `turning the AVX2 row off writes 0 (${written[written.length - 1].opts})`);
      const off = nodes('ROSETTA_ADVERTISE_AVX=0');
      t.ok(avx(off).props.checked === false, 'a game set to 0 shows the AVX2 row off');
      written.length = 0;
      avx(off).props.onChange(true);
      t.ok(!written[written.length - 1].opts.includes('ROSETTA_ADVERTISE_AVX'),
           `turning the AVX2 row on removes the entry (${written[written.length - 1].opts})`);
      t.ok(avx(nodes('ROSETTA_ADVERTISE_AVX=1')).props.checked === true, 'a game set to 1 shows the AVX2 row on');
    }
    if (fex) {
      const x87 = ns => ns.find(x => x.type === 'Toggle' && x.props.label === X87);
      t.ok(x87(r).props.checked === true, 'the x87 row is on by default');
      written.length = 0;
      x87(r).props.onChange(false);
      t.ok(written[written.length - 1].opts.includes('FEX_X87REDUCEDPRECISION=0'),
           `turning the x87 row off writes 0 (${written[written.length - 1].opts})`);
      const off = nodes('FEX_X87REDUCEDPRECISION=0');
      t.ok(x87(off).props.checked === false, 'a game set to 0 shows the x87 row off');
      written.length = 0;
      x87(off).props.onChange(true);
      t.ok(!written[written.length - 1].opts.includes('FEX_X87REDUCEDPRECISION'),
           `turning the x87 row on removes the entry (${written[written.length - 1].opts})`);
    }
    t.ok(toggles(r).includes('DLSS') === !fex,
         `automatic ${fex ? 'hides' : 'shows'} the D3DMetal DLSS row`);

    r = nodes('CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1');
    const picked = r.find(x => x.type === 'Dropdown').props.selectedOption;
    t.ok(backends(r).includes('d3dmetal') === !fex && picked === (fex ? '' : 'd3dmetal'),
         `a game set to D3DMetal shows ${fex ? 'Automatic' : 'D3DMetal'} (${picked})`);
    t.ok(toggles(r).includes('DLSS') === !fex,
         `D3DMetal ${fex ? 'hides' : 'shows'} its DLSS row`);

    r = nodes('CX_GRAPHICS_BACKEND=dxmt');
    t.ok(toggles(r).includes('DLSS') && r.some(x => x.type === 'Section' &&
         x.props.label.startsWith('MetalFX')), 'dxmt keeps its DLSS row and MetalFX');
    for (const l of ['MSync', 'High Resolution'])
      t.ok(toggles(r).includes(l), `${l} stays`);
    t.ok(!!hud(r), 'the performance overlay menu stays');

    written.length = 0;
    nodes('CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1').find(x => x.type === 'Dropdown')
      .props.onChange({ data: 'dxmt' });
    const opts = written[written.length - 1].opts;
    t.ok(opts.includes('CX_GRAPHICS_BACKEND=dxmt') && !opts.includes('D3DM_ENABLE_METALFX'),
         `switching off D3DMetal drops its flag (${opts})`);

    // Only picking a FEX tool clears hidden values.
    written.length = 0;
    const kept = 'ROSETTA_ADVERTISE_AVX=1 CX_GRAPHICS_BACKEND=dxvk';
    r = nodes(kept);
    hud(r).props.onChange(true);
    t.ok(written[written.length - 1].opts.includes('ROSETTA_ADVERTISE_AVX=1'),
         'editing another row keeps the AVX2 value');
    failed += t.failed;
  }

  // A game with no tool name runs under the fallback tool.
  for (const first of [false, true]) {
    const fallback = first ? 'bridgeplay-proton-fex' : 'bridgeplay-proton-rosetta';
    const { render: P } = panel(emit, form, undefined, { fallback, fexTools: FEX_TOOLS });
    const t = runner(`${form}, unmapped, fallback ${fallback}`);
    const r = walk(P({ details: details('', { strCompatToolName: '' }) }));
    const offered = r.find(x => x.type === 'Dropdown').props.rgOptions.map(o => o.data);
    t.ok(offered.includes('d3dmetal') === !first,
         `D3DMetal is ${first ? 'not ' : ''}offered (${offered})`);
    failed += t.failed;
  }

  const { render: L } = panel(emit, form, undefined, { fexTools: ['bridgeplay-proton-fex-41069'] });
  const tp = runner(`${form}, FEX tool name prefix`);
  const pr = walk(L({ details: details('', { strCompatToolName: 'bridgeplay-proton-fex' }) }));
  tp.ok(pr.find(x => x.type === 'Dropdown').props.rgOptions.some(o => o.data === 'd3dmetal'),
        'a tool whose name prefixes a FEX tool keeps the Rosetta options');
  failed += tp.failed;
}

for (const form of Object.keys(FORMS)) {
  const { pick, written } = panel(emit, form, undefined, { fexTools: FEX_TOOLS });
  const t = runner(`${form}, picking a tool`);
  const choose = (opts, tool) => {
    written.length = 0;
    pick(details(opts), tool);
    return written.length ? written[written.length - 1].opts : null;
  };
  const all = 'WINEDEBUG=-all CX_GRAPHICS_BACKEND=d3dmetal D3DM_ENABLE_METALFX=1 MTL_HUD_ENABLED=1 ' +
              "ROSETTA_ADVERTISE_AVX=0 FEX_X87REDUCEDPRECISION=0 DXMT_CONFIG='a;b' %command% -novid";
  const r = choose(all, 'bridgeplay-proton-fex');
  t.ok(r === "WINEDEBUG=-all MTL_HUD_ENABLED=1 FEX_X87REDUCEDPRECISION=0 DXMT_CONFIG='a;b' %command% -novid",
       `picking FEX drops only the D3DMetal and Rosetta entries (${r})`);
  t.ok(choose(all, 'bridgeplay-proton-rosetta') === null, 'picking a Rosetta tool writes nothing');
  t.ok(choose('D3DM_lower=1 %command%', 'bridgeplay-proton-fex') === null,
       'names the launch script does not forward are left alone');
  for (const o of ['>D3DM_LOG=1 %command%', "X=$'a\\'b D3DM_Y=1 c' %command%",
                   'wrapper <(x) D3DM_Y=1 %command%', 'D3DM_Y=1 \\\n%command%'])
    t.ok(choose(o, 'bridgeplay-proton-fex') === null, `text the parser does not model is left alone (${o})`);
  t.ok(choose('CX_GRAPHICS_BACKEND=dxmt %command%', 'bridgeplay-proton-fex') === null,
       'another backend is not a reason to write');
  t.ok(choose('-novid CX_GRAPHICS_BACKEND=d3dmetal', 'bridgeplay-proton-fex') === null,
       'text after the game, not set before %command%, is left alone');
  failed += t.failed;
}

{
  const opts = 'CX_GRAPHICS_BACKEND=d3dmetal MTL_HUD_ENABLED=1 %command%';
  const globals = { document: { documentElement: { lang: 'en' } },
                    appDetailsStore: { GetAppDetails: id => id === 287700 ? details(opts) : undefined } };
  const { toolQuery, written } = panel(emit, 'statement', globals,
                                       { fallback: 'bridgeplay-proton-fex', fexTools: FEX_TOOLS });
  const t = runner('statement, the new tool picker');
  const data = { default_tool_identifier: 'bridgeplay-proton-fex',
                 aliases: [{ alias: 'np-latest', current_tool_name: 'bridgeplay-proton-fex' },
                           { alias: 'np-rosetta', current_tool_name: 'bridgeplay-proton-rosetta' }] };
  const choose = (value, id = 287700, d = data) => {
    const saved = [];
    written.length = 0;
    const [query, set] = toolQuery([{ data: d }, v => saved.push(v)], id);
    set(value);
    return { query, saved, opts: written.length ? written[written.length - 1].opts : null };
  };
  let r = choose('bridgeplay-proton-fex');
  t.ok(r.saved[0] === 'bridgeplay-proton-fex' && r.query.data === data, 'the query and the pick still reach Steam');
  t.ok(r.opts === 'MTL_HUD_ENABLED=1 %command%', `picking FEX drops the D3DMetal entry (${r.opts})`);
  t.ok(choose('').opts === 'MTL_HUD_ENABLED=1 %command%', 'the default entry counts as the default tool');
  t.ok(choose('', 287700, { ...data, default_tool_identifier: '' }).opts === 'MTL_HUD_ENABLED=1 %command%',
       'with no default saved, the default entry counts as the fallback tool');
  t.ok(choose('', 287700, { ...data, default_tool_identifier: 'bridgeplay-proton-rosetta' }).opts === null,
       'a Rosetta default wins over a FEX fallback');
  t.ok(choose('np-latest').opts === 'MTL_HUD_ENABLED=1 %command%', 'an alias counts as its current tool');
  t.ok(choose('np-rosetta').opts === null, 'an alias for a Rosetta tool writes nothing');
  t.ok(choose('bridgeplay-proton-rosetta').opts === null, 'picking a Rosetta tool writes nothing');
  r = choose('bridgeplay-proton-fex', null);
  t.ok(r.saved[0] === 'bridgeplay-proton-fex' && r.opts === null, 'the settings page picker has no game to edit');
  t.ok(choose('bridgeplay-proton-fex', 4000).opts === null, 'a game with no loaded details is left alone');
  t.ok(choose('bridgeplay-proton-fex', 287700, null).opts === null, 'a picker with no tool list writes nothing');
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nFEX hides what it cannot run, Rosetta keeps everything');
process.exit(failed ? 1 : 0);
