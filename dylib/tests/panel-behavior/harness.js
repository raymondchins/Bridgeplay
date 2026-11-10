// Runs the injected panel as a component, with the barrel and react stubbed, so the
// checks exercise the payload the gates actually write rather than a copy of it.
//
// Capture bytes stand in for names the page assigns, and expanding them to names no
// Steam build would pick keeps a check from passing only for the letters one build
// happened to use.
'use strict';
const fs = require('fs');
const { execFileSync } = require('child_process');

const expand = (s, caps) => s.replace(/[\u0001-\u0008\u0013-\u0016]/g, c => {
  if (!(c in caps)) throw new Error('payload uses unbound capture ' + c.charCodeAt(0));
  return caps[c];
});

const mk = (type, props) => ({ type, props });
const react = { jsx: mk, jsxs: mk, Fragment: 'Fragment' };
// Steam's SliderField, which the panel finds by the name its export's source carries rather
// than by the export's letters
function SliderField(props) { return { type: 'Slider', props }; }
SliderField.toString = () => 'Dt=>{const lr=(0,f.Zt)("SliderField",v);return(0,a.jsx)(lr,{...Dt})}';
const barrel = { XY: 'Section', m: 'Dropdown', Yh: 'Toggle', Kc: SliderField };
const barrelWithoutSlider = { XY: 'Section', m: 'Dropdown', Yh: 'Toggle' };

// The two shapes take the payload in different forms and bind different names, which
// is the whole of the difference between them.
const FORMS = {
  component: { react: '\u0004', barrel: '\u0005' },
  statement: { react: '\u0003', barrel: '\u0004' },
};

// `fallback` and `fexTools` stand in for what the hook sets before the transform. The
// stand-in global falls through to the real one, so a test's globalThis.MSCXFx still reaches the panel.
function panel(emit, form, globals = Object.assign(Object.create(globalThis),
                                                   { document: { documentElement: { lang: 'en' } } }),
               { fallback = 'bridgeplay-proton', fexTools = [], names = ['R0', 'B0'], slider = true } = {}) {
  const raw = execFileSync(emit, [form, fallback, ...fexTools], { encoding: 'utf8' }).trim();
  const f = FORMS[form];
  const body = expand(raw, { [f.react]: names[0], [f.barrel]: names[1] });
  const src = form === 'component' ? 'var ' + body.replace(/,$/, '') : body.replace(/;$/, '');
  const written = [];
  const SteamClient = {
    Apps: { SetAppLaunchOptions: (appid, opts) => written.push({ appid, opts }) },
  };
  const build = new Function(names[0], names[1], 'SteamClient', 'globalThis',
    src + '\nreturn { MSCXOpts, MSCXApply: typeof MSCXApply === "function" ? MSCXApply : null,' +
    ' MSCXTake: typeof MSCXTake === "function" ? MSCXTake : null,' +
    ' MSCXPick: typeof MSCXPick === "function" ? MSCXPick : null,' +
    ' MSCXToolQuery: typeof MSCXToolQuery === "function" ? MSCXToolQuery : null };');
  const { MSCXOpts, MSCXApply, MSCXTake, MSCXPick, MSCXToolQuery } =
    build(react, slider ? barrel : barrelWithoutSlider, SteamClient, globals);
  return { render: MSCXOpts, apply: MSCXApply, take: MSCXTake, pick: MSCXPick, toolQuery: MSCXToolQuery, written,
           globals };
}

// Function components are resolved rather than recorded, so a check sees the nodes the
// page ends up with and not the wrappers on the way there.
function walk(node, out = []) {
  if (!node || typeof node !== 'object') return out;
  if (Array.isArray(node)) { node.forEach(c => walk(c, out)); return out; }
  if (typeof node.type === 'function') return walk(node.type(node.props), out);
  if (node.type) out.push(node);
  if (node.props && node.props.children) walk(node.props.children, out);
  return out;
}

function details(launchOptions, over) {
  return Object.assign({
    unAppID: 287700,
    vecPlatforms: ['windows'],
    strCompatToolName: 'bridgeplay-proton',
    strLaunchOptions: launchOptions,
  }, over || {});
}

function runner(name) {
  let failed = 0;
  return {
    ok(cond, what) {
      if (!cond) failed++;
      console.log(`  ${cond ? 'PASS' : 'FAIL'}  [${name}] ${what}`);
    },
    get failed() { return failed; },
  };
}

// The Performance Overlay menu, which also carries Apple's Metal HUD.
const overlay = nodes => nodes.find(n => n.type === 'Dropdown' && n.props.rgOptions.some(o => o.data === 'hud'));

// The Metal HUD entry of that menu as an on/off switch, for the checks that drive launch
// options through MTL_HUD_ENABLED: on picks the HUD, off picks Off.
function hud(nodes) {
  const menu = overlay(nodes);
  if (!menu) return undefined;
  return { type: 'Dropdown', props: {
    checked: menu.props.selectedOption === 'hud',
    onChange: on => menu.props.onChange({ data: on ? 'hud' : '0' }),
  } };
}

// The Frame Rate Limit: Steam's slider (or the menu standing in for it) and the Enable frame
// limit switch, with what they show: the value, whether the limit is off, and whether the
// slider is dimmed.
function limit(nodes) {
  const value = nodes.find(n => n.props && n.props.npKey === 'BRIDGEPLAY_FPS_LIMIT');
  const sw = nodes.find(n => n.props && n.props.npKey === 'BRIDGEPLAY_FPS_LIMIT_OFF');
  if (!value || !sw) return undefined;
  const wrap = nodes.find(n => n.type === 'div' && n.props.children &&
                               n.props.children.props && n.props.children.props.npKey === 'BRIDGEPLAY_FPS_LIMIT');
  return {
    value, sw,
    v: value.type === 'Slider' ? value.props.value : value.props.selectedOption,
    off: !sw.props.checked,
    dimmed: !!wrap && wrap.props.className === 'MSCXDim',
    slide: x => value.type === 'Slider' ? value.props.onChange(x) : value.props.onChange({ data: x }),
    enable: on => sw.props.onChange(on),
  };
}

// The Scaling Filter menu.
const filter = nodes => nodes.find(n => n.type === 'Dropdown' && n.props.rgOptions.some(o => o.data === 'integer'));

module.exports = { panel, walk, details, runner, expand, FORMS, overlay, hud, limit, filter };
