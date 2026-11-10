// Changes from a game's in-game quick settings reach the launch options through the panel's
// own menus: the same text a pick in Steam Properties › Bridgeplay writes, in one write.
'use strict';
const { panel, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: quick-settings.js <emit>'); process.exit(2); }

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { apply, written } = panel(emit, form);
  const t = runner(form);
  const run = (opts, ch, over) => { written.length = 0; return apply(details(opts, over), ch); };

  t.ok(typeof apply === 'function', 'the payload defines MSCXApply');

  let r = run('', { BRIDGEPLAY_FPS_LIMIT: '30' });
  t.ok(r === 'BRIDGEPLAY_FPS_LIMIT=30 %command%' && written.length === 1 && written[0].appid === 287700,
       `a limit from the game is written (${JSON.stringify(written)})`);

  r = run('WINEDEBUG=-all %command% -novid', { BRIDGEPLAY_PERF_OVERLAY: 'summary', BRIDGEPLAY_FPS_LIMIT: '30',
                                               BRIDGEPLAY_SCALING_FILTER: 'linear' });
  t.ok(written.length === 1, `three changes make one write (${written.length})`);
  t.ok(/^.*BRIDGEPLAY_PERF_OVERLAY=summary/.test(r) && r.includes('BRIDGEPLAY_FPS_LIMIT=30') &&
       r.includes('BRIDGEPLAY_SCALING_FILTER=linear') && r.includes('WINEDEBUG=-all') && r.endsWith('%command% -novid'),
       `all three land and the rest of the line stays (${r})`);

  r = run('BRIDGEPLAY_FPS_LIMIT=30 BRIDGEPLAY_PERF_OVERLAY=detailed %command%', { BRIDGEPLAY_FPS_LIMIT_OFF: '1' });
  t.ok(/BRIDGEPLAY_FPS_LIMIT_OFF=1/.test(r) && r.includes('BRIDGEPLAY_FPS_LIMIT=30') &&
       r.includes('BRIDGEPLAY_PERF_OVERLAY=detailed'), `switching the limit off in the game keeps the value (${r})`);

  r = run('BRIDGEPLAY_FPS_LIMIT=30 BRIDGEPLAY_FPS_LIMIT_OFF=1 %command%', { BRIDGEPLAY_FPS_LIMIT: '47', BRIDGEPLAY_FPS_LIMIT_OFF: '0' });
  t.ok(r === 'BRIDGEPLAY_FPS_LIMIT=47 %command%' && written.length === 1,
       `a new value and the switch back on land together, the value first (${r})`);

  r = run('', { BRIDGEPLAY_FPS_LIMIT: '47', BRIDGEPLAY_FPS_LIMIT_OFF: '1' });
  t.ok(/BRIDGEPLAY_FPS_LIMIT=47/.test(r) && /BRIDGEPLAY_FPS_LIMIT_OFF=1/.test(r),
       `a value set and then switched off in the game keeps both (${r})`);

  r = run('BRIDGEPLAY_PERF_OVERLAY=fps %command%', { BRIDGEPLAY_PERF_OVERLAY: 'fps' });
  t.ok(written.length === 0 && r === 'BRIDGEPLAY_PERF_OVERLAY=fps %command%', 'an unchanged value writes nothing');

  r = run('', { BRIDGEPLAY_FPS_LIMIT: 'half', BRIDGEPLAY_PERF_OVERLAY: 'hud', MTL_HUD_ENABLED: '1', PATH: '/x',
                BRIDGEPLAY_FPS_LIMIT_OFF: 'yes' });
  t.ok(written.length === 0 && r === '', `values and keys the sidebar does not set are ignored (${r})`);
  r = run('', { BRIDGEPLAY_FPS_LIMIT: '90' });
  t.ok(r === 'BRIDGEPLAY_FPS_LIMIT=90 %command%',
       `90 from a game on a faster display than the page knows is kept, not cut to its 60 (${r})`);
  r = run('', { BRIDGEPLAY_FPS_LIMIT: '14' });
  t.ok(written.length === 0, `a limit under 15 is ignored (${r})`);

  r = run('MTL_HUD_ENABLED=1 %command%', { BRIDGEPLAY_PERF_OVERLAY: 'summary' });
  t.ok(r === 'BRIDGEPLAY_PERF_OVERLAY=summary %command%', `a level replaces the Metal HUD, as the menu does (${r})`);

  globalThis.MSCXFx = { g: { BRIDGEPLAY_FPS_LIMIT: '30' }, a: {}, e: {}, d: {} };
  r = run('BRIDGEPLAY_FPS_LIMIT=60 %command%', { BRIDGEPLAY_FPS_LIMIT: '30' });
  t.ok(r === '', `a pick matching Game Defaults drops the override (${JSON.stringify(r)})`);
  r = run('', { BRIDGEPLAY_FPS_LIMIT_OFF: '1' });
  t.ok(r === 'BRIDGEPLAY_FPS_LIMIT_OFF=1 %command%', `switching off a Game Defaults limit writes the switch (${r})`);
  delete globalThis.MSCXFx;

  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: {}, ng: {}, na: {}, h: '/Users/me' };
  r = run('-novid', { BRIDGEPLAY_FPS_LIMIT: '40' }, { vecPlatforms: ['osx'], strCompatToolName: '' });
  t.ok(r === '/Users/me/.bridgeplay/np-native BRIDGEPLAY_FPS_LIMIT=40 %command% -novid',
       `a native game gets the change under np-native (${r})`);
  delete globalThis.MSCXFx;

  failed += t.failed;
}

// The route has removed a change's file before the page asks Steam for the app, so a change
// Steam cannot place yet waits in the page and is tried again on the next polls.
async function takeChecks(form) {
  const { take, written, globals } = panel(emit, form);
  const t = runner(form);
  t.ok(typeof take === 'function', 'the payload defines MSCXTake');
  const known = new Set();
  globals.window = { appDetailsStore: { RequestAppDetails: async id => {
    if (id === 7) return null;
    if (!known.has(id)) throw new Error('no details yet');
    return details('', { unAppID: id });
  } } };
  // The payload's own "Bridgeplay: …" lines stay out of the test output
  const log = console.log, warn = console.warn;
  const quiet = f => (...a) => { if (!String(a[0]).startsWith('Bridgeplay:')) f(...a); };
  console.log = quiet(log);
  console.warn = quiet(warn);
  try {
    await take({ 287700: { BRIDGEPLAY_FPS_LIMIT: '30' } });
    t.ok(written.length === 0 && globals.MSCXSyncWait['287700'], 'a change waits while Steam has no details');
    await take({ 287700: { BRIDGEPLAY_PERF_OVERLAY: 'fps' }, 300: { BRIDGEPLAY_SCALING_FILTER: 'linear' } });
    known.add(287700);
    await take({});
    const o = written.length === 1 ? written[0].opts : '';
    t.ok(o.includes('BRIDGEPLAY_FPS_LIMIT=30') && o.includes('BRIDGEPLAY_PERF_OVERLAY=fps'),
         `it is written once Steam has the app, with the picks made meanwhile (${JSON.stringify(written)})`);
    t.ok(!globals.MSCXSyncWait['287700'] && globals.MSCXSyncWait['300'],
         'an app Steam refuses does not hold back another');
    await take({ 7: { BRIDGEPLAY_FPS_LIMIT: '30' } });
    t.ok(globals.MSCXSyncWait['7'], 'no details at all waits too');
    for (let i = 0; i < 40; i++) await take({});
    t.ok(Object.keys(globals.MSCXSyncWait).length === 0, 'and after about a minute the change is dropped');
  } finally {
    console.log = log;
    console.warn = warn;
  }
  return t.failed;
}

(async () => {
  for (const form of Object.keys(FORMS)) failed += await takeChecks(form);
  if (failed) { console.log(`quick settings: ${failed} failed`); process.exit(1); }
  console.log('quick settings: in-game changes are written as the panel writes them, and wait for Steam');
})();
