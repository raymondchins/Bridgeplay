'use strict';
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { panel, walk, details, runner, FORMS, overlay, hud, limit, filter } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: shell.js <emit>'); process.exit(2); }

const TOGGLES = {
  'MSync': 'WINEMSYNC',
  'High Resolution': 'BRIDGEPLAY_RETINA',
  'Advertise AVX2 to Rosetta': 'ROSETTA_ADVERTISE_AVX',
  'Let games read controllers directly (Recommended on Mac. Turn off only for Steam Input remapping)': 'BRIDGEPLAY_RAW_CONTROLLERS',
  'Disable hidraw': 'BRIDGEPLAY_DISABLE_HIDRAW',
};
const ON_UNLESS_0 = { ROSETTA_ADVERTISE_AVX: true };
const PANEL_KEYS = ['CX_GRAPHICS_BACKEND', 'MTL_HUD_ENABLED', 'D3DM_ENABLE_METALFX', 'DXMT_ENABLE_NVEXT',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN', 'DXMT_CONFIG', 'ROSETTA_ADVERTISE_AVX', 'WINEMSYNC', 'BRIDGEPLAY_RETINA',
  'BRIDGEPLAY_RAW_CONTROLLERS', 'BRIDGEPLAY_DISABLE_HIDRAW', 'BRIDGEPLAY_PERF_OVERLAY', 'BRIDGEPLAY_FPS_LIMIT', 'BRIDGEPLAY_FPS_LIMIT_OFF',
  'BRIDGEPLAY_SCALING_FILTER'];
const OTHER_KEYS = ['WINEDEBUG', 'DXVK_HUD', 'FOO'];

const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'np-shell-'));
const probe = path.join(dir, 'probe');
// The game: appends one record per run, argc, the arguments, then a set flag and value
// per key, each field NUL-terminated. A shell script starts in milliseconds, node in ~80.
const KEYS = PANEL_KEYS.concat(OTHER_KEYS);
fs.writeFileSync(probe, '#!/bin/sh\n{\n' +
  `  printf '%s\\0' "$#"\n  for a in "$@"; do printf '%s\\0' "$a"; done\n` +
  KEYS.map(k => `  if [ "\${${k}+set}" ]; then printf '1\\0%s\\0' "$${k}"; else printf '0\\0'; fi\n`).join('') +
  '} >>"$NP_PROBE_OUT"\n', { mode: 0o755 });

function records(text) {
  const f = text.split('\0');
  const runs = [];
  for (let n = 0; n < f.length - 1;) {
    const argc = Number(f[n++]);
    const run = { argv: f.slice(n, n + argc), env: {} };
    n += argc;
    for (const k of KEYS) if (f[n++] === '1') run.env[k] = f[n++];
    runs.push(run);
  }
  return runs;
}
fs.writeFileSync(path.join(dir, 'gamemoderun'), '#!/bin/sh\nexec "$@"\n', { mode: 0o755 });

const quote = s => "'" + s.replace(/'/g, "'\\''") + "'";
const COMMAND = quote(probe) + " 'game.exe'";

function steamLine(options) {
  const o = options.trim();
  return /%command%/i.test(o) ? o.replace(/%command%/gi, () => COMMAND) : COMMAND + (o ? ' ' + o : '');
}

const shells = ['/bin/sh', '/bin/dash'].filter(s => fs.existsSync(s));

function launch(shell, options) {
  const out = path.join(dir, 'runs');
  fs.rmSync(out, { force: true });
  spawnSync(shell, ['-c', steamLine(options)], {
    env: { PATH: dir + ':/usr/bin:/bin', HOME: process.env.HOME, NP_PROBE_OUT: out },
    cwd: dir, timeout: 10000, stdio: 'ignore',
  });
  return fs.existsSync(out) ? records(fs.readFileSync(out, 'utf8')) : [];
}

function view(form, options) {
  const P = panel(emit, form);
  const nodes = walk(P.render({ details: details(options) }));
  const toggles = {};
  nodes.filter(n => n.type === 'Toggle' && n.props.label in TOGGLES)
       .forEach(n => { toggles[TOGGLES[n.props.label]] = n; });
  // The Metal HUD is an entry of the Performance Overlay menu
  toggles.MTL_HUD_ENABLED = hud(nodes);
  const backend = nodes.find(n => n.type === 'Dropdown' && n.props.rgOptions.some(o => o.data === 'dxvk'));
  const upscale = nodes.find(n => n.type === 'Dropdown' && n.props.rgOptions.some(o => o.data === '1.5'));
  return { toggles, backend, upscale, overlay: overlay(nodes), limit: limit(nodes), filter: filter(nodes), written: P.written };
}

function dxmt(conf) {
  const out = {};
  for (const line of (conf || '').split(';')) {
    let n = 0;
    const ws = () => { while (n < line.length && ' \t\r'.includes(line[n])) n++; };
    ws();
    let key = '';
    while (n < line.length && /[0-9A-Za-z._]/.test(line[n])) key += line[n++];
    ws();
    if (line[n] !== '=') continue;
    n++; ws();
    let value = '', str = false;
    for (; n < line.length; n++) {
      if (!str && ' \t\r'.includes(line[n])) break;
      if (line[n] === '"') str = !str; else value += line[n];
    }
    out[key] = value;
  }
  return out;
}
const FACTOR = 'd3d11.metalSpatialUpscaleFactor';
const userDxmt = env => { const c = dxmt(env.DXMT_CONFIG); delete c[FACTOR]; return JSON.stringify(c); };

function agrees(t, v, env, what) {
  if (v.upscale) {
    const f = Math.max(parseFloat(dxmt(env.DXMT_CONFIG)[FACTOR] || '2'), 1);
    const want = env.DXMT_METALFX_SPATIAL_SWAPCHAIN === '1' ? f : '';
    const got = v.upscale.props.selectedOption;
    t.ok(got === '' ? want === '' : parseFloat(got) === want,
         `${what}: upscale shows "${got}", DXMT uses ${want}`);
  }
  for (const [key, node] of Object.entries(v.toggles)) {
    const on = key in ON_UNLESS_0 ? env[key] !== '0' : env[key] === '1';
    t.ok(node.props.checked === on, `${what}: ${key} shows ${node.props.checked}, game gets ${env[key]}`);
  }
  const level = env.MTL_HUD_ENABLED === '1' ? 'hud' :
    /^(fps|summary|detailed)$/.test(env.BRIDGEPLAY_PERF_OVERLAY || '') ? env.BRIDGEPLAY_PERF_OVERLAY : '0';
  t.ok(v.overlay.props.selectedOption === level,
       `${what}: overlay shows "${v.overlay.props.selectedOption}", the shim shows ${level}`);
  // As overlay-shim reads it on the panel's 60 Hz: display and half from the display, a
  // number held to 15..60, anything else no limit; the switch turns it off and keeps it.
  // 10 to 14 still read (as 15) because launch options from earlier releases carry them; only
  // the in-game sidebar's route requires 15 or more, since it never writes less.
  const raw = (env.BRIDGEPLAY_FPS_LIMIT || '').toLowerCase();
  const set = raw === 'display' ? 60 : raw === 'half' ? 30 :
    /^\d+$/.test(raw) && +raw >= 10 && +raw <= 360 ? Math.min(60, Math.max(15, +raw)) : 0;
  const capped = set && env.BRIDGEPLAY_FPS_LIMIT_OFF !== '1';
  t.ok(v.limit.v === (set || 60) && v.limit.off === !capped,
       `${what}: limit shows ${v.limit.v}${v.limit.off ? ' off' : ''}, the shim limits to ${capped ? set : 'nothing'}`);
  const sfw = /^(linear|nearest|integer)$/i.test(env.BRIDGEPLAY_SCALING_FILTER || '') ? env.BRIDGEPLAY_SCALING_FILTER.toLowerCase() : '0';
  t.ok(v.filter.props.selectedOption === sfw,
       `${what}: filter shows "${v.filter.props.selectedOption}", the shim uses ${sfw}`);
  t.ok(v.backend.props.selectedOption === (env.CX_GRAPHICS_BACKEND || ''),
       `${what}: backend shows "${v.backend.props.selectedOption}", game gets ${env.CX_GRAPHICS_BACKEND}`);
}

const ACTIONS = [
  { name: 'Metal HUD', run: v => v.toggles.MTL_HUD_ENABLED.props.onChange(!v.toggles.MTL_HUD_ENABLED.props.checked),
    want: (v0, v1) => v1.toggles.MTL_HUD_ENABLED.props.checked === !v0.toggles.MTL_HUD_ENABLED.props.checked },
  { name: 'overlay summary', run: v => v.overlay.props.onChange({ data: 'summary' }),
    want: (v0, v1) => v1.overlay.props.selectedOption === 'summary' },
  { name: 'overlay off', run: v => v.overlay.props.onChange({ data: '0' }),
    want: (v0, v1) => v1.overlay.props.selectedOption === '0' },
  { name: 'filter nearest', run: v => v.filter.props.onChange({ data: 'nearest' }),
    want: (v0, v1) => v1.filter.props.selectedOption === 'nearest' },
  { name: 'filter automatic', run: v => v.filter.props.onChange({ data: '0' }),
    want: (v0, v1) => v1.filter.props.selectedOption === '0' },
  { name: 'limit 30', run: v => v.limit.slide(30),
    want: (v0, v1) => v0.limit.off ? v1.limit.v === v0.limit.v && v1.limit.off : v1.limit.v === 30 },
  { name: 'limit switched off', run: v => v.limit.enable(false),
    want: (v0, v1) => v1.limit.off && v1.limit.v === v0.limit.v },
  { name: 'limit switched on', run: v => v.limit.enable(true),
    want: (v0, v1) => !v1.limit.off && v1.limit.v === v0.limit.v },
  { name: 'MSync', run: v => v.toggles.WINEMSYNC.props.onChange(!v.toggles.WINEMSYNC.props.checked),
    want: (v0, v1) => v1.toggles.WINEMSYNC.props.checked === !v0.toggles.WINEMSYNC.props.checked },
  { name: 'AVX2', run: v => v.toggles.ROSETTA_ADVERTISE_AVX.props.onChange(!v.toggles.ROSETTA_ADVERTISE_AVX.props.checked),
    want: (v0, v1) => v1.toggles.ROSETTA_ADVERTISE_AVX.props.checked === !v0.toggles.ROSETTA_ADVERTISE_AVX.props.checked },
  { name: 'raw controllers', run: v => v.toggles.BRIDGEPLAY_RAW_CONTROLLERS.props.onChange(!v.toggles.BRIDGEPLAY_RAW_CONTROLLERS.props.checked),
    want: (v0, v1) => v1.toggles.BRIDGEPLAY_RAW_CONTROLLERS.props.checked === !v0.toggles.BRIDGEPLAY_RAW_CONTROLLERS.props.checked },
  { name: 'backend dxvk', run: v => v.backend.props.onChange({ data: 'dxvk' }),
    want: (v0, v1) => v1.backend.props.selectedOption === 'dxvk' },
  { name: 'backend automatic', run: v => v.backend.props.onChange({ data: '' }),
    want: (v0, v1) => v1.backend.props.selectedOption === '' },
  { name: 'upscale 1.5', run: v => v.upscale && v.upscale.props.onChange({ data: '1.5' }),
    want: (v0, v1) => !v0.upscale || v1.upscale.props.selectedOption === '1.5' },
  { name: 'upscale off', run: v => v.upscale && v.upscale.props.onChange({ data: '' }),
    want: (v0, v1) => !v0.upscale || v1.upscale.props.selectedOption === '' },
];

const CASES = [
  "CX_GRAPHICS_BACKEND=dxmt DXMT_CONFIG='d3d11.preferredMaxFrameRate=60' %command%",
  'CX_GRAPHICS_BACKEND=dxmt DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG="d3d11.preferredMaxFrameRate=60;" %command%',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor = 1.5 ; d3d11.preferredMaxFrameRate=30" %command%',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=3.0;d3d11.metalSpatialUpscaleFactor=1.5" %command%',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=0.5 %command%',
  'DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG="d3d11.metalSpatialUpscaleFactor=2" %command% --offline',
  "DXMT_CONFIG='d3d11.preferredMaxFrameRate=60' %command% --offline",
  '',
  '--offline',
  '%command%',
  '%command% --offline',
  'MTL_HUD_ENABLED=1 %command%',
  'MTL_HUD_ENABLED="1" %command% --offline',
  "MTL_HUD_ENABLED='1' WINEMSYNC=0 %command%",
  'MTL_HUD_ENABLED=1 %COMMAND%',
  'MTL_HUD_ENABLED=1 %Command% -windowed',
  'MTL_HUD_ENABLED=1 %command%%command%',
  'DXVK_HUD=1 %command% --offline',
  'WINEDEBUG="err+all, trace+seh" MTL_HUD_ENABLED=1 %command% --name "two words"',
  "DXMT_CONFIG='d3d11.foo=1 d3d11.bar=2' %command% --name 'two words'",
  'WINEDEBUG=err+all,\\ trace+seh %command% --name two\\ words',
  '%command% --title MTL_HUD_ENABLED=1',
  'MTL_HUD_ENABLED_EXTRA=1 %command% --title "MTL_HUD_ENABLED=0 extra"',
  'MTL_HUD_ENABLED=1\tMTL_HUD_ENABLED="0" %command%',
  'MTL_HUD_ENABLED=1 MTL_HUD_ENABLED="" %command%',
  'MTL_HUD_ENABLED=1 -windowed',
  'MTL_HUD_ENABLED=1 CX_GRAPHICS_BACKEND=dxmt',
  '-windowed MTL_HUD_ENABLED=1',
  'MTL_HUD_ENABLED=1 gamemoderun %command%',
  'gamemoderun MTL_HUD_ENABLED=1 %command%',
  'gamemoderun %command% --offline',
  'MTL_HUD_ENABLED=1; %command%',
  'MTL_HUD_ENABLED=1 true && %command%',
  'true && MTL_HUD_ENABLED=1 %command% --offline',
  'true; CX_GRAPHICS_BACKEND=dxmt %command%',
  'MTL_HUD_ENABLED=1 %command% | cat',
  'MTL_HUD_ENABLED=1 %command% > /dev/null 2>&1',
  'MTL_HUD_ENABLED=1 2>/dev/null %command%',
  'MTL_HUD_ENABLED=1>/dev/null %command%',
  'MTL_HUD_ENABLED=1 %command% # MTL_HUD_ENABLED=0',
  '( MTL_HUD_ENABLED=1 %command% )',
  '{ MTL_HUD_ENABLED=1 %command%; }',
  'if true; then MTL_HUD_ENABLED=1 %command%; fi',
  'FOO=$(echo a b) MTL_HUD_ENABLED=1 %command%',
  'FOO="$(echo "a)b")" MTL_HUD_ENABLED=1 %command%',
  'FOO=`echo a b` MTL_HUD_ENABLED=1 %command%',
  'FOO=${HOME:-a b} MTL_HUD_ENABLED=1 %command%',
  'CX_GRAPHICS_BACKEND=dxmt DXMT_METALFX_SPATIAL_SWAPCHAIN=1 DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2.0 %command%',
  'MTL_HUD_ENABLED="1 %command%',
  'MTL_HUD_ENABLED=1 "%command%"',
  'MTL_HUD_ENABLED=1 \\%command%',
  '  MTL_HUD_ENABLED=1   %command%  --offline  ',
];

let failed = 0;
for (const shell of shells) {
  for (const form of Object.keys(FORMS)) {
    const t = runner(`${path.basename(shell)} ${form}`);
    for (const options of CASES) {
      const before = launch(shell, options);
      const v0 = view(form, options);
      const label = JSON.stringify(options);
      if (before.length) agrees(t, v0, before[0].env, label);
      for (const a of ACTIONS) {
        const v = view(form, options);
        a.run(v);
        const next = v.written.length ? v.written[v.written.length - 1].opts : options;
        const after = launch(shell, next);
        const what = `${label} ${a.name} -> ${JSON.stringify(next)}`;
        t.ok(after.length === before.length, `${what}: game runs ${after.length}x, was ${before.length}x`);
        const v1 = view(form, next);
        t.ok(a.want(v0, v1), `${what}: panel shows the change`);
        if (!after.length || after.length !== before.length) continue;
        agrees(t, v1, after[0].env, what);
        before.forEach((run, n) => {
          t.ok(JSON.stringify(after[n].argv) === JSON.stringify(run.argv),
               `${what}: game arguments kept ${JSON.stringify(after[n].argv)}`);
          for (const k of OTHER_KEYS)
            t.ok(after[n].env[k] === run.env[k], `${what}: ${k} kept`);
          t.ok(userDxmt(after[n].env) === userDxmt(run.env),
               `${what}: DXMT_CONFIG entries kept ${userDxmt(after[n].env)}`);
        });
      }
    }
    failed += t.failed;
  }
}
fs.rmSync(dir, { recursive: true, force: true });
console.log(failed ? `\n${failed} failure(s)` : `\npanel agrees with ${shells.join(' and ')}`);
process.exit(failed ? 1 : 0);
