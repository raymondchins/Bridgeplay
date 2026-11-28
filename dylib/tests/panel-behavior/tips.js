// Info tips: every label that needs more than its words carries an info button, described by
// its tip text. One tip is open at a time: hover shows it, a click pins it, and Escape, a second
// click, blur or a press elsewhere hides it.
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
// Tips made with the same doc share it, as they do in one panel.
function fakeDoc() {
  const doc = { defaultView: { innerWidth: 800, innerHeight: 600 }, listeners: {},
    addEventListener(type, fn) { (this.listeners[type] = this.listeners[type] || []).push(fn); } };
  return doc;
}
function fakeDom(doc = fakeDoc()) {
  const attrs = {};
  const box = { left: 100, top: 50, bottom: 70 };
  const text = { offsetWidth: 280, offsetHeight: 60, style: {},
    getBoundingClientRect() { return { left: parseFloat(this.style.left), top: parseFloat(this.style.top) }; } };
  const w = {
    ownerDocument: doc,
    getAttribute: k => (k in attrs ? attrs[k] : null),
    setAttribute: (k, v) => { attrs[k] = String(v); },
    removeAttribute: k => { delete attrs[k]; },
    contains: n => n === w || n === w.firstChild,
  };
  w.firstChild = { getBoundingClientRect: () => box, matches: () => false };
  w.lastChild = text;
  const ev = (extra = {}) => Object.assign({ currentTarget: w.firstChild, preventDefault() { this.prevented = true; },
    stopPropagation() { this.stopped = true; } }, extra);
  w.firstChild.parentNode = w;
  return { w, attrs, text, ev, doc };
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

  // Hover shows it, a click pins it, a second click, Escape, blur or a press elsewhere hides it,
  // and only one tip is open at a time.
  const { button, w: wrap } = parts(cool.props.tip);
  const d = fakeDom();
  const open = x => x.attrs['data-open'] || null;
  wrap.props.onMouseEnter({ currentTarget: d.w });
  t.ok(open(d) === 'y', 'hover shows it');
  wrap.props.onMouseLeave({ currentTarget: d.w });
  t.ok(open(d) === null, 'leaving hides it');
  let e = d.ev();
  button.props.onClick(e);
  t.ok(open(d) === 'p' && e.prevented && e.stopped, 'a click pins it and does not reach the row');
  t.ok(d.text.style.left === '100px' && d.text.style.top === '76px', `it is placed under the button (${d.text.style.left}, ${d.text.style.top})`);
  wrap.props.onMouseLeave({ currentTarget: d.w });
  t.ok(open(d) === 'p', 'a pinned tip stays when the pointer leaves');
  button.props.onClick(d.ev());
  t.ok(open(d) === null, 'a second click hides it');
  const d2 = fakeDom(d.doc);
  button.props.onClick(d.ev());
  wrap.props.onMouseEnter({ currentTarget: d2.w });
  t.ok(open(d) === null && open(d2) === 'y', 'showing another tip hides the open one');
  wrap.props.onMouseLeave({ currentTarget: d2.w });
  button.props.onClick(d.ev());
  (d.doc.listeners.pointerdown || []).forEach(fn => fn({ target: {} }));
  t.ok(open(d) === null, 'a press outside hides it');
  button.props.onClick(d.ev());
  e = d.ev({ key: 'Escape' });
  (d.doc.listeners.keydown || []).forEach(fn => fn(e));
  t.ok(open(d) === null && e.stopped, 'Escape anywhere hides it and is kept from the dialog');
  button.props.onClick(d.ev());
  d.w.isConnected = false;
  e = d.ev({ key: 'Escape' });
  (d.doc.listeners.keydown || []).forEach(fn => fn(e));
  t.ok(!e.stopped && !d.doc.__mscxTip, 'a tip whose panel is gone lets Escape reach the dialog');
  delete d.w.isConnected;
  delete d.attrs['data-open'];
  button.props.onClick(d.ev());
  e = d.ev({ key: 'Escape' });
  button.props.onKeyDown(e);
  t.ok(open(d) === null && e.stopped, 'Escape hides it and is kept from the dialog');
  e = d.ev({ key: 'Escape' });
  button.props.onKeyDown(e);
  t.ok(!e.stopped, 'a second Escape goes on to the dialog');
  button.props.onFocus(d.ev());
  t.ok(open(d) === null, 'a focus that is not from the keyboard shows nothing');
  button.props.onClick(d.ev());
  button.props.onBlur(d.ev());
  t.ok(open(d) === null, 'blur hides it');

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
