// Info tips: every label that needs more than its words carries an info button, described by
// its tip text, that opens on click, closes on Escape and a second click, and resets on blur.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: tips.js <emit>'); process.exit(2); }

const WINE = ['Graphics', 'DLSS', 'NVIDIA GPU for DLSS', 'High Resolution', 'Performance Overlay', 'FPS Limit',
  'Enable', 'Lower FPS when the Mac runs hot', 'Scaling Filter', 'Frame Generation', 'Mode', 'Quality',
  'Keep HUD and menus sharp', 'Skip blurry frames in fast motion', 'Engine', 'AVX2', 'MSync',
  'Direct input', 'Disable hidraw'];
const NATIVE = ['Performance Overlay', 'FPS Limit', 'Enable', 'Scaling Filter', 'Frame Generation', 'Mode',
  'Controller layer'];

// The tip's parts: its button and text, found by role in the label node.
function parts(tip) {
  const w = tip.props.children[1];
  const [button, text] = w.props.children;
  return { w, button, text };
}

// Enough of an element for the handlers: attributes, a parent, a window to place the tip in.
function fakeDom() {
  const attrs = {};
  const box = { left: 100, top: 50, bottom: 70 };
  const view = { innerWidth: 800, innerHeight: 600 };
  const text = { offsetWidth: 280, offsetHeight: 60, style: {},
    getBoundingClientRect() { return { left: parseFloat(this.style.left), top: parseFloat(this.style.top) }; } };
  const w = {
    ownerDocument: { defaultView: view },
    getAttribute: k => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v); },
    removeAttribute: k => { delete attrs[k]; },
  };
  w.firstChild = { getBoundingClientRect: () => box };
  w.lastChild = text;
  const ev = (extra = {}) => Object.assign({ currentTarget: w.firstChild, preventDefault() { this.prevented = true; },
    stopPropagation() { this.stopped = true; } }, extra);
  w.firstChild.parentNode = w;
  return { w, attrs, text, ev };
}

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const t = runner(form);
  const fex = panel(emit, form, undefined, { fexTools: ['fex-tool'] });
  const { render } = panel(emit, form);
  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: {} };
  const labelled = ns => ns.filter(n => n.props && n.props.tip);
  const wine = [
    ...walk(render({ details: details('BRIDGEPLAY_FRAMEGEN=2 %command%') })),
    ...walk(render({ details: details('CX_GRAPHICS_BACKEND=dxmt %command%') })),
  ];
  const fx = walk(fex.render({ details: details('', { strCompatToolName: 'fex-tool' }) }));
  const nat = walk(render({ details: details('BRIDGEPLAY_FRAMEGEN=2 %command%', { vecPlatforms: ['osx'], strCompatToolName: '' }) }));

  for (const [name, ns, want] of [['Wine', wine, WINE], ['native', nat, NATIVE], ['FEX', fx, ['Reduced x87 precision']]]) {
    const have = new Set(labelled(ns).map(n => n.props.label));
    const missing = want.filter(l => !have.has(l));
    t.ok(!missing.length, `${name} panel: every listed label has a tip${missing.length ? ' (missing ' + missing.join(', ') + ')' : ''}`);
  }
  t.ok(labelled(wine).some(n => n.props.label === 'MetalFX'), 'DXMT\'s MetalFX menu has a tip');

  const tips = labelled(wine).concat(labelled(nat), labelled(fx));
  const ok = tips.every(n => {
    const { button, text } = parts(n.props.tip);
    return button.type === 'button' && button.props.type === 'button' &&
      button.props['aria-label'] === 'About ' + n.props.label &&
      button.props['aria-describedby'] === text.props.id && text.props.role === 'tooltip' &&
      typeof text.props.children === 'string' && text.props.children.length > 20;
  });
  t.ok(ok, 'each tip is a labelled button described by its tooltip text');
  t.ok(!tips.some(n => /[–—]/.test(parts(n.props.tip).text.props.children)), 'no tip uses a dash');
  const one = walk(render({ details: details('') }));
  const ids = labelled(one).map(n => parts(n.props.tip).text.props.id);
  t.ok(new Set(ids).size === ids.length && ids.length > 5, `ids are unique in a panel (${ids.length})`);

  const cool = tips.find(n => n.props.label === 'Lower FPS when the Mac runs hot');
  const coolText = cool && parts(cool.props.tip).text.props.children;
  t.ok(!!coolText && /3\/4/.test(coolText) && /1\/2/.test(coolText) && /30 FPS/.test(coolText) && /30 seconds/.test(coolText),
    'the heat tip states the steps, the floor and the 30 second hold');

  // Click opens, a second click closes, Escape closes, blur and leaving reset.
  const { button, w: wrap } = parts(cool.props.tip);
  const d = fakeDom();
  let e = d.ev();
  button.props.onClick(e);
  t.ok(d.attrs['data-open'] === 'y' && e.prevented && e.stopped, 'a click opens it and does not reach the row');
  t.ok(d.text.style.left === '100px' && d.text.style.top === '76px', `it is placed under the button (${d.text.style.left}, ${d.text.style.top})`);
  button.props.onClick(d.ev());
  t.ok(d.attrs['data-open'] === 'n', 'a second click closes it');
  wrap.props.onMouseLeave({ currentTarget: d.w });
  t.ok(!('data-open' in d.attrs), 'leaving resets it, so hover shows it again');
  button.props.onClick(d.ev());
  e = d.ev({ key: 'Escape' });
  button.props.onKeyDown(e);
  t.ok(d.attrs['data-open'] === 'n' && e.stopped, 'Escape closes it and is kept from the dialog');
  e = d.ev({ key: 'Escape' });
  button.props.onKeyDown(e);
  t.ok(!e.stopped, 'a second Escape goes on to the dialog');
  button.props.onClick(d.ev());
  button.props.onBlur(d.ev());
  t.ok(!('data-open' in d.attrs), 'blur closes it');

  // Russian, as one of the panel's languages
  const ru = panel(emit, form, Object.assign(Object.create(globalThis), { document: { documentElement: { lang: 'ru' } } }));
  const rcool = walk(ru.render({ details: details('') })).find(n => n.props.label === 'Снижать FPS при перегреве Mac');
  t.ok(!!rcool && /^Когда macOS/.test(parts(rcool.props.tip).text.props.children) &&
       parts(rcool.props.tip).button.props['aria-label'] === 'Подробнее: Снижать FPS при перегреве Mac', 'the tips follow the panel\'s language');
  delete globalThis.MSCXFx;
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\ninfo tips: on every listed label, labelled, described, and they open and close');
process.exit(failed ? 1 : 0);
