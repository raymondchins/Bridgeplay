'use strict';
const { execFileSync } = require('child_process');
const { runner } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: migration.js <emit>'); process.exit(2); }
const src = execFileSync(emit, ['migration'], { encoding: 'utf8' }).trim();

function steam(apps, opts) {
  opts = opts || {};
  const store = opts.storage || new Map();
  const written = [];
  const details = new Map(apps.map(a => [a.unAppID, a]));
  const window = {
    appStore: { m_mapApps: new Map(apps.map(a => [a.unAppID, { appid: a.unAppID, visible_in_game_list: !a.hidden }])
                                 .concat([[0, null]])) },
    appDetailsStore: {
      RequestAppDetails: id => opts.silent && opts.silent.includes(id)
        ? new Promise(() => {}) : Promise.resolve(details.get(id)),
    },
  };
  const localStorage = {
    getItem: k => store.has(k) ? store.get(k) : null,
    setItem: (k, v) => store.set(k, String(v)),
  };
  const SteamClient = { Apps: { SetAppLaunchOptions: (appid, o) => written.push({ appid, o }) } };
  const console = { log() {}, warn(...a) { written.push({ warn: a }); },
                   error(...a) { written.push({ error: a }); } };
  const setTimeout = f => { if (!opts.hang) f(); };
  const self = { m_cm: { steamid: { GetAccountID: () => opts.account || 1 } } };
  const run = new Function('window', 'localStorage', 'SteamClient', 'console', 'setTimeout',
                           'return ' + src + ';');
  return { go: () => run.call(self, window, localStorage, SteamClient, console, setTimeout),
           written, store };
}

const app = (id, o, over) => Object.assign(
  { unAppID: id, vecPlatforms: ['windows'], strCompatToolName: '', strLaunchOptions: o }, over || {});

(async () => {
  const t = runner('migration');

  // A hung migration leaves a promise that never settles, and Node then exits 0 here.
  let finished = false;
  process.on('exit', () => {
    if (finished) return;
    console.error('migration: stopped before the last check');
    process.exitCode = 1;
  });

  const rule = [
    ['MTL_HUD_ENABLED=1 -dx11', 'MTL_HUD_ENABLED=1 %command% -dx11'],
    ['-dx11 WINEMSYNC=1', 'WINEMSYNC=1 %command% -dx11'],
    ['CX_GRAPHICS_BACKEND=dxmt DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2',
     'CX_GRAPHICS_BACKEND=dxmt DXMT_CONFIG=d3d11.metalSpatialUpscaleFactor=2 %command%'],
    ['WINEDLLOVERRIDES=d3d11=n;dxgi=n -novid', "WINEDLLOVERRIDES='d3d11=n;dxgi=n' %command% -novid"],
    ['WINEDEBUG="a b" -x "two words"', 'WINEDEBUG="a b" %command% -x "two words"'],
    ['  MTL_HUD_ENABLED=1   -a  ', 'MTL_HUD_ENABLED=1 %command% -a'],
    ['NOTPROTON_RETINA=1 -x', 'NOTPROTON_RETINA=1 %command% -x'],
    ['BRIDGEPLAY_RETINA=1 -x', 'BRIDGEPLAY_RETINA=1 %command% -x'],
  ];
  const kept = ['-novid', '', 'MTL_HUD_ENABLED=1 %command%', 'mtl_hud_enabled=1 %COMMAND%',
                'MTL_HUD_ENABLED=1 "unclosed', 'FOO=1 -x', '"WINEDEBUG=x" -y'];

  const apps = rule.map((r, i) => app(100 + i, r[0]))
    .concat(kept.map((o, i) => app(200 + i, o)));
  let s = steam(apps);
  await s.go();
  for (const [i, r] of rule.entries()) {
    const w = s.written.find(x => x.appid === 100 + i);
    t.ok(w && w.o === r[1], `rewrites ${JSON.stringify(r[0])}`);
  }
  for (const [i, o] of kept.entries())
    t.ok(!s.written.some(x => x.appid === 200 + i), `leaves ${JSON.stringify(o)} alone`);

  const out = s.written.find(x => x.appid === 103).o.replace('%command%', 'printenv WINEDLLOVERRIDES; echo');
  t.ok(execFileSync('/bin/sh', ['-c', out], { encoding: 'utf8' }) === 'd3d11=n;dxgi=n\n-novid\n',
       'the shell reads a moved value with a semicolon as one env var');

  s.written.length = 0;
  await s.go();
  t.ok(s.written.length === 0, 'a second start rewrites nothing');

  const later = steam([app(100, 'WINEMSYNC=1 -x')], { storage: s.store });
  await later.go();
  t.ok(later.written.length === 0, 'a finished account is not checked again');
  const other = steam([app(100, 'MTL_HUD_ENABLED=1 -x')], { storage: s.store, account: 2 });
  await other.go();
  t.ok(other.written.length === 1, 'another account gets its own pass');

  const native = steam([app(1, 'MTL_HUD_ENABLED=1', { vecPlatforms: ['windows', 'osx'] }),
                        app(2, 'MTL_HUD_ENABLED=1', { vecPlatforms: ['osx'], strCompatToolName: 'bridgeplay-proton' }),
                        app(2147483650, 'MTL_HUD_ENABLED=1', { vecPlatforms: ['osx'] })]);
  await native.go();
  t.ok(native.written.map(x => x.appid).join() === '2,2147483650',
       'skips native Mac games without a tool, as the panel does');

  const silent = steam([app(1, 'MTL_HUD_ENABLED=1'), app(2, 'MTL_HUD_ENABLED=1')], { silent: [1] });
  await silent.go();
  t.ok(silent.written.filter(x => x.appid).map(x => x.appid).join() === '2',
       'a game with no details does not hold up the rest');
  t.ok(silent.written.some(x => x.warn && String(x.warn[0]).includes('app 1,')),
       'a game with no details is named in the log');
  const retry = steam([app(1, 'MTL_HUD_ENABLED=1')], { storage: silent.store });
  await retry.go();
  t.ok(retry.written.length === 0, 'a game with no details is not retried once the pass finished');

  const cut = steam([app(1, 'MTL_HUD_ENABLED=1'), app(2, 'MTL_HUD_ENABLED=1')], { silent: [2], hang: true });
  cut.go();
  await new Promise(r => setImmediate(r));
  t.ok(cut.written.map(x => x.appid).join() === '1' && cut.store.size === 0,
       'a pass cut short does not mark the account');
  const again = steam([app(1, 'MTL_HUD_ENABLED=1 %command%'), app(2, 'MTL_HUD_ENABLED=1')], { storage: cut.store });
  await again.go();
  t.ok(again.written.map(x => x.appid).join() === '2' && again.store.size === 1,
       'the next start finishes the pass and leaves moved games alone');

  const bad = steam([app(1, 'MTL_HUD_ENABLED=1')]);
  bad.written.push = function (x) { if (x.appid) throw new Error('no'); return Array.prototype.push.call(this, x); };
  await bad.go();
  t.ok(bad.written.some(x => x.error) && bad.store.size === 0,
       'an error is logged, not thrown into Steam, and the account stays unmarked');

  const hidden = steam([app(1, 'MTL_HUD_ENABLED=1', { hidden: true })]);
  await hidden.go();
  t.ok(hidden.written.some(x => x.appid === 1), 'covers uninstalled demos that the library hides');

  const many = steam(Array.from({ length: 45 }, (_, i) => app(i + 1, 'WINEMSYNC=1')));
  await many.go();
  t.ok(many.written.filter(x => x.appid).length === 45 && many.store.size === 1,
       'checks every app when there are more than one batch');

  finished = true;
  if (t.failed) process.exit(1);
})();
