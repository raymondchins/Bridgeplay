'use strict';
// The rebuild row in the CrossOver panel, driven against a fake DOM, fake timers and a
// fake route. Each step answers the row's next request the way the dylib would.
const assert = require('node:assert/strict');
const { execFileSync } = require('node:child_process');

const emit = process.argv[2];
if (!emit) throw new Error('usage: prefix-row.js <emit>');
const src = execFileSync(emit, ['prefix-row'], { encoding: 'utf8' });

class Node {
  constructor(tag) { this.tag = tag; this.children = []; this.style = {}; this.className = ''; this.textContent = ''; }
  append(...n) { this.children.push(...n); }
  replaceChildren(...n) { this.children = n; }
}

function world(states, startReply = '{"started":true}') {
  const calls = [], timers = [], listeners = {};
  const doc = { createElement: tag => new Node(tag), documentElement: { lang: 'en' } };
  const g = {
    document: doc, navigator: { language: 'en' },
    setTimeout: (f, ms) => { timers.push({ f, ms }); return timers.length; }, clearTimeout: () => {},
    addEventListener: (n, f) => { listeners[n] = f; }, removeEventListener: n => { delete listeners[n]; },
    MSCXRoute: (route, id) => {
      calls.push(route);
      if (route === 'NotProton.PrefixState#1') {
        const state = states.shift() || {};
        if (state instanceof Error) return Promise.reject(state);
        if (state instanceof Promise) return state;
        return Promise.resolve(JSON.stringify(state));
      }
      return Promise.resolve(startReply);
    },
  };
  new Function('globalThis', 'document', 'navigator', 'setTimeout', 'clearTimeout', 'MSCXRoute', src)(
    g, doc, g.navigator, g.setTimeout, g.clearTimeout, g.MSCXRoute);
  const row = new Node('div');
  row.ownerDocument = doc;
  row.isConnected = true;
  const settle = () => new Promise(r => setImmediate(r));
  const tick = async () => { const t = timers.shift(); t && t.f(); await settle(); await settle(); return t; };
  const texts = () => row.children.filter(c => c.tag === 'div' && !c.children.length).map(c => c.textContent);
  const buttons = () => row.children.flatMap(c => c.children).filter(c => c.tag === 'button');
  return { g, row, calls, timers, listeners, settle, tick, texts, buttons };
}

const need = { needsRebuild: true, app: true, running: false, rebuild: '' };

(async () => {
  {
    const w = world([{ ...need, rebuild: 'copy' }, new Error('transport'), { rebuild: 'done' }]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle();
    await w.tick();
    assert.equal(w.texts()[0], 'Copying your files\u2026');
    await w.tick();
    assert.equal(w.texts()[0], 'Prefix rebuilt.');
  }
  {
    const w = world([new Error('no transport')]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    assert.equal(w.row.style.display, 'none', 'a route that cannot answer hides the row');
    assert.equal(w.timers.length, 0, 'and nothing keeps asking');
  }
  {
    let answer;
    const pending = new Promise(resolve => { answer = resolve; });
    const w = world([pending, { needsRebuild: false }]);
    w.g.MSCXPrefixRow(w.row, 480);
    w.g.MSCXPrefixRow(w.row, 481); await w.settle();
    answer(JSON.stringify(need)); await w.settle();
    assert.equal(w.row.style.display, 'none', 'an old answer cannot rebuild the wrong game');
  }
  {
    const w = world([{ needsRebuild: false, app: true, rebuild: '' }]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    assert.equal(w.row.style.display, 'none', 'no rebuild needed keeps the row hidden');
    w.g.MSCXPrefixRow(w.row, 480); await w.settle();
    assert.equal(w.calls.length, 1, 'rendering again for the same app does not ask again');
  }
  {
    const w = world([need, { ...need, rebuild: 'setup' }, { ...need, rebuild: 'copy' },
      { ...need, rebuild: 'finish' }, { needsRebuild: false, app: true, rebuild: 'done-backup' }]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    assert.equal(w.row.style.display, '');
    assert.deepEqual(w.texts(), ['Switching to this compatibility tool requires a prefix rebuild. Rebuild now?']);
    assert.deepEqual(w.buttons().map(b => b.textContent), ['Backup & Rebuild Prefix', 'Rebuild Prefix']);
    assert.equal(w.buttons()[0].className, 'MSCXBtn MSCXMain', 'Backup & Rebuild is the main button');
    w.buttons()[0].onclick(); await w.settle(); await w.settle(); await w.settle();
    assert(w.calls.includes('NotProton.BackupAndRebuildPrefix#1'), 'backup rebuild is asked for');
    assert.equal(w.texts()[0], 'Rebuilding prefix\u2026');
    assert(w.row.children.some(c => c.className === 'MSCXBar'), 'a bar shows while it runs');
    const delay = parseInt(w.row.children.find(c => c.className === 'MSCXBar').children[0].style.animationDelay);
    assert(delay <= 0 && delay > -200, `the bar starts from the left when the rebuild starts (${delay}ms)`);
    await w.tick(); assert.equal(w.texts()[0], 'Copying your files\u2026');
    const now = Date.now, base = now();
    Date.now = () => base + 1800;
    try {
      await w.tick(); assert.equal(w.texts()[0], 'Finishing\u2026');
    } finally { Date.now = now; }
    const later = parseInt(w.row.children.find(c => c.className === 'MSCXBar').children[0].style.animationDelay);
    assert(later <= -1800 && later > -2400,
      `a redraw keeps the bar's place in the 2.4s Reduce Motion fade (${later}ms)`);
    assert.equal(w.timers.at(-1).ms, 500, 'it asks again every half second');
    await w.tick();
    assert.deepEqual(w.texts(), ["Prefix rebuilt. A backup of the original is in Bridgeplay's Prefixes view."]);
    const left = w.timers.length;
    w.g.MSCXPrefixRow(w.row, 480);
    assert.equal(w.timers.length, left, 'nothing polls once it is done');
    // The dylib reports done once, so the next answer is empty, and the row keeps saying done.
    w.listeners.mscxstate({ detail: 481 }); await w.settle();
    assert.deepEqual(w.texts(), ["Prefix rebuilt. A backup of the original is in Bridgeplay's Prefixes view."]);
  }
  {
    const w = world([need, { ...need, rebuild: 'setup' }, { needsRebuild: false, app: true, rebuild: 'done' },
      { ...need, rebuild: 'done' }]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    w.buttons()[1].onclick(); await w.settle(); await w.settle(); await w.settle();
    await w.tick();
    assert.deepEqual(w.texts(), ['Prefix rebuilt.']);
    w.listeners.mscxstate({ detail: 480 }); await w.settle(); await w.settle();
    assert.deepEqual(w.texts(), ['Switching to this compatibility tool requires a prefix rebuild. Rebuild now?'],
      'switching away again right after a rebuild offers another one');
    assert.deepEqual(w.buttons().map(b => b.textContent), ['Backup & Rebuild Prefix', 'Rebuild Prefix']);
  }
  {
    const w = world([need, { ...need, rebuild: 'failed' }, need]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    w.buttons()[1].onclick(); await w.settle(); await w.settle(); await w.settle();
    assert(w.calls.includes('NotProton.RebuildPrefix#1'), 'a plain rebuild is asked for');
    await w.tick();
    assert.deepEqual(w.texts(), ['Could not rebuild the prefix.']);
    assert.deepEqual(w.buttons().map(b => b.textContent), ['Open Log', 'Backup & Rebuild Prefix', 'Rebuild Prefix'],
      'a failure offers the log and another try');
    w.buttons()[0].onclick(); await w.settle();
    assert(w.calls.includes('NotProton.OpenPrefixLog#1'));
  }
  {
    const w = world([{ ...need, running: true }, need]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    assert.deepEqual(w.texts(), ['Quit the game to rebuild.']);
    assert(w.buttons().every(b => b.disabled), 'nothing can start while the game runs');
    assert.equal(w.timers.at(-1).ms, 3000, 'it checks again for the game quitting');
    await w.tick();
    assert(w.buttons().every(b => !b.disabled), 'quitting the game enables the buttons');
  }
  {
    const w = world([{ ...need, app: false }]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    assert.deepEqual(w.texts(), ["Could not find the Bridgeplay app. Move Bridgeplay to Applications, open it and click Install again."]);
    assert.equal(w.buttons().length, 0);
  }
  {
    const w = world([need, need], '{"error":"spawn"}');
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    w.buttons()[1].onclick(); await w.settle(); await w.settle(); await w.settle();
    assert.deepEqual(w.texts(), ['Could not rebuild the prefix.'], 'a rebuild that cannot start says so');
  }
  {
    const w = world([need, { needsRebuild: false, app: true, rebuild: '' }]);
    w.g.MSCXPrefixRow(w.row, 480); await w.settle(); await w.settle();
    w.listeners.mscxstate({ detail: 480 }); await w.settle(); await w.settle();
    assert.equal(w.row.style.display, 'none', 'picking a matching tool hides the row');
    w.row.isConnected = false;
    w.listeners.mscxstate({ detail: 480 });
    assert(!w.listeners.mscxstate, 'a row that left the page stops listening');
  }
  console.log('PASS: rebuild row hides, offers, progresses, finishes, fails, waits for the game and finds no app');
})().catch(e => { console.error(e); process.exit(1); });
