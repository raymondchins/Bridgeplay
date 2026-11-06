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

  r = run('BRIDGEPLAY_FPS_LIMIT=30 BRIDGEPLAY_PERF_OVERLAY=detailed %command%', { BRIDGEPLAY_FPS_LIMIT: '0' });
  t.ok(r === 'BRIDGEPLAY_PERF_OVERLAY=detailed %command%', `Off from the game drops the limit only (${r})`);

  r = run('BRIDGEPLAY_PERF_OVERLAY=fps %command%', { BRIDGEPLAY_PERF_OVERLAY: 'fps' });
  t.ok(written.length === 0 && r === 'BRIDGEPLAY_PERF_OVERLAY=fps %command%', 'an unchanged value writes nothing');

  r = run('', { BRIDGEPLAY_FPS_LIMIT: '45', BRIDGEPLAY_PERF_OVERLAY: 'hud', MTL_HUD_ENABLED: '1', PATH: '/x' });
  t.ok(written.length === 0 && r === '', `values and keys the menus do not offer are ignored (${r})`);

  r = run('MTL_HUD_ENABLED=1 %command%', { BRIDGEPLAY_PERF_OVERLAY: 'summary' });
  t.ok(r === 'BRIDGEPLAY_PERF_OVERLAY=summary %command%', `a level replaces the Metal HUD, as the menu does (${r})`);

  globalThis.MSCXFx = { g: { BRIDGEPLAY_FPS_LIMIT: '30' }, a: {}, e: {}, d: {} };
  r = run('BRIDGEPLAY_FPS_LIMIT=60 %command%', { BRIDGEPLAY_FPS_LIMIT: '30' });
  t.ok(r === '', `a pick matching Game Defaults drops the override (${JSON.stringify(r)})`);
  r = run('', { BRIDGEPLAY_FPS_LIMIT: '0' });
  t.ok(r === 'BRIDGEPLAY_FPS_LIMIT=0 %command%', `Off over a Game Defaults limit writes 0 (${r})`);
  delete globalThis.MSCXFx;

  globalThis.MSCXFx = { g: {}, a: {}, e: {}, d: {}, ng: {}, na: {}, h: '/Users/me' };
  r = run('-novid', { BRIDGEPLAY_FPS_LIMIT: '40' }, { vecPlatforms: ['osx'], strCompatToolName: '' });
  t.ok(r === '/Users/me/.bridgeplay/np-native BRIDGEPLAY_FPS_LIMIT=40 %command% -novid',
       `a native game gets the change under np-native (${r})`);
  delete globalThis.MSCXFx;

  failed += t.failed;
}
if (failed) { console.log(`quick settings: ${failed} failed`); process.exit(1); }
console.log('quick settings: in-game changes are written as the panel writes them');
