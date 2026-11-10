'use strict';
const { panel, walk, details, runner, FORMS, hud: hudOf } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: launch-options.js <emit>'); process.exit(2); }

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  const nodes = opts => walk(P({ details: details(opts) }));
  const last = () => written[written.length - 1].opts;
  const hud = opts => hudOf(nodes(opts));

  for (const assignment of ['MTL_HUD_ENABLED="1"', "MTL_HUD_ENABLED='1'",
                            'MTL_HUD_ENABLED=\\1']) {
    t.ok(hud(assignment + ' %command%').props.checked, `reads ${assignment}`);
    written.length = 0;
    hud(assignment + ' %command%').props.onChange(false);
    t.ok(last() === '', `removes the whole token ${assignment}`);
  }

  for (const tail of [
    'WINEDEBUG="err+all, trace+seh" %command% --name "two words"',
    "DXMT_CONFIG='d3d11.foo=1 d3d11.bar=2' %command% --name 'two words'",
    'WINEDEBUG=err+all,\\ trace+seh %command% --name two\\ words',
    'MTL_HUD_ENABLED_EXTRA=1 %command% --title "MTL_HUD_ENABLED=0 extra"',
    'DXMT_CONFIG="literal \\"quote\\" and \\\\slash" %command%',
    'WINEDEBUG="$(touch /tmp/bridgeplay-panel-must-not-run)" %command%',
    '\tWINEDEBUG="a b"\t%command%\t--name "two words"  ',
  ]) {
    written.length = 0;
    hud(tail).props.onChange(true);
    t.ok(last() === tail.replace(/^[ \t]*/, m => m + 'MTL_HUD_ENABLED=1 '),
         `preserves unrelated text exactly: ${JSON.stringify(tail)}`);
  }

  t.ok(!hud('"MTL_HUD_ENABLED=1" %command%').props.checked, 'a quoted name is not an assignment');
  written.length = 0;
  hud('"MTL_HUD_ENABLED=0" %command%').props.onChange(true);
  t.ok(last() === 'MTL_HUD_ENABLED=1 "MTL_HUD_ENABLED=0" %command%', 'a quoted name is left alone');
  t.ok(!hud('%command% --title "MTL_HUD_ENABLED=1"').props.checked,
       'game arguments do not set the toggle');
  written.length = 0;
  hud('').props.onChange(true);
  let repeated = last();
  for (let i = 0; i < 3; i++) {
    hud(repeated).props.onChange(false);
    repeated = last();
    t.ok(repeated === '', 'removing the only assignment leaves empty options');
    hud(repeated).props.onChange(true);
    repeated = last();
    t.ok(repeated === 'MTL_HUD_ENABLED=1 %command%',
         'repeated edits do not accumulate whitespace');
  }
  written.length = 0;
  hud('WINEDEBUG=x MTL_HUD_ENABLED=1 %command%').props.onChange(false);
  t.ok(last() === 'WINEDEBUG=x %command%', 'removing an assignment leaves one separator');

  const duplicates = 'MTL_HUD_ENABLED=1\tMTL_HUD_ENABLED="0" %command%';
  t.ok(!hud(duplicates).props.checked, 'the last assignment determines the toggle');
  written.length = 0;
  hud(duplicates).props.onChange(true);
  t.ok(last() === 'MTL_HUD_ENABLED=1 %command%', 'replaces all duplicate assignments');
  t.ok(!hud('MTL_HUD_ENABLED=1 MTL_HUD_ENABLED="" %command%').props.checked,
       'an empty final assignment overrides earlier values');

  const backendOptions = 'CX_GRAPHICS_BACKEND="dxmt" DXMT_CONFIG="a=1 b=2" '
                       + 'DXMT_METALFX_SPATIAL_SWAPCHAIN="1" %command% --title "a b"';
  written.length = 0;
  const backend = nodes(backendOptions).find(x => x.type === 'Dropdown');
  t.ok(backend.props.selectedOption === 'dxmt', 'reads a quoted backend');
  backend.props.onChange({ data: 'dxvk' });
  t.ok(last() === `CX_GRAPHICS_BACKEND=dxvk DXMT_CONFIG='a=1 b=2' %command% --title "a b"`,
       'switching keeps DXMT_CONFIG entries the panel did not set and keeps game arguments');

  const upscaled = 'CX_GRAPHICS_BACKEND=dxmt DXMT_METALFX_SPATIAL_SWAPCHAIN="1" '
                 + 'DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=1.5" %command%';
  t.ok(nodes(upscaled).find(x => x.type === 'Dropdown' && x.props.rgOptions.some(o => o.data === '1.5'))
         .props.selectedOption === '1.5',
       'reads the factor from quoted DXMT_CONFIG');

  t.ok(!hud('MTL_HUD_ENABLED=1 -windowed').props.checked,
       'assignments without %command% do not set the toggle');
  for (const [before, after] of [
    ['-windowed', 'MTL_HUD_ENABLED=1 %command% -windowed'],
    ['MTL_HUD_ENABLED=0 -windowed', 'MTL_HUD_ENABLED=1 %command% MTL_HUD_ENABLED=0 -windowed'],
    ['-windowed MTL_HUD_ENABLED=0', 'MTL_HUD_ENABLED=1 %command% -windowed MTL_HUD_ENABLED=0'],
  ]) {
    written.length = 0;
    hud(before).props.onChange(true);
    t.ok(last() === after, `adds %command% to ${JSON.stringify(before)}`);
  }
  written.length = 0;
  hud('MTL_HUD_ENABLED=1 -windowed').props.onChange(false);
  t.ok(written.length === 0, 'keeps game arguments written without %command%');
  t.ok(hud('MTL_HUD_ENABLED=1 gamemoderun %command%').props.checked, 'reads assignments before a wrapper');
  written.length = 0;
  hud('gamemoderun %command%').props.onChange(true);
  t.ok(last() === 'MTL_HUD_ENABLED=1 gamemoderun %command%', 'adds assignments before a wrapper');
  written.length = 0;
  hud('MTL_HUD_ENABLED=1 gamemoderun %command%').props.onChange(false);
  t.ok(last() === 'gamemoderun %command%', 'removes assignments before a wrapper');
  written.length = 0;
  hud('env FOO=1 %command%').props.onChange(true);
  t.ok(last() === 'MTL_HUD_ENABLED=1 env FOO=1 %command%', 'other wrapper assignments stay editable');

  for (const odd of ['WINEDEBUG="unfinished', "--title 'unfinished", '--title trailing\\',
                     'WINEDEBUG=1; %command%', 'WINEDEBUG=1 %command% | tee log',
                     'WINEDEBUG=1\n%command%',
                     'WINEDEBUG=`id` %command%', 'WINEDEBUG=1 %command% >log',
                     'MTL_HUD_ENABLED=0 %COMMAND%', 'MTL_HUD_ENABLED=0 %command%%command%',
                     'MTL_HUD_ENABLED=0 "%command%"', 'gamemoderun MTL_HUD_ENABLED=1 %command%',
                     'nice -n 5 CX_GRAPHICS_BACKEND=dxmt %command%']) {
    written.length = 0;
    const ns = nodes(odd);
    // The limit slider is disabled while its switch turns the limit off, which says nothing about the line
    t.ok(ns.every(x => (!x.props.disabled || x.props.npKey === 'BRIDGEPLAY_FPS_LIMIT') && x.props.role !== 'status'),
         `edits ${JSON.stringify(odd)}`);
    hud(odd).props.onChange(true);
    t.ok(written.length === 1 && hud(last()).props.checked, `turns the HUD on in ${JSON.stringify(odd)}`);
    t.ok((last().match(/%command%/gi) || []).length === Math.max(1, (odd.match(/%command%/gi) || []).length),
         `writes no extra %command% into ${JSON.stringify(odd)}`);
  }
  t.ok(hud('MTL_HUD_ENABLED=1 %command% %COMMAND%').props.checked,
       'reads assignments before the first %command%');
  written.length = 0;
  hud('MTL_HUD_ENABLED=1 %command% %COMMAND%').props.onChange(false);
  t.ok(last() === '%command% %COMMAND%', 'leaves later %command% text alone');
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nquoted launch options pass in both shapes');
process.exit(failed ? 1 : 0);
