// Runs the patched library filter and Windows button from gatecheck's output.
'use strict';
const fs = require('fs');
const path = require('path');

const files = process.argv.slice(2);
if (!files.length) { console.error('usage: behavior.js <patched.js>...'); process.exit(2); }

let failed = 0;
const ok = (name, cond, what) => {
  if (!cond) failed++;
  if (!cond || process.env.VERBOSE) console.log(`  ${cond ? 'PASS' : 'FAIL'}  [${name}] ${what}`);
};

function grab(src, re, what) {
  const m = re.exec(src);
  if (!m) throw new Error(`no ${what}`);
  return m;
}

const english = () => { globalThis.document = { documentElement: { lang: 'en' } }; };

function filter(src) {
  const viteHead = /case"notprotonWindows":return ([\w$]+)\(\)&&\(window\.__NOTPROTON_NATIVE_PLATFORM__\.windows\.has\(([\w$]+)\.appid\)/.exec(src);
  if (viteHead) {
    const apple = grab(src.slice(viteHead.index), /;case 5:return /, 'Vite Apple case');
    const end = src.indexOf('.is_invalid_os_type;', viteHead.index + apple.index + apple[0].length);
    const stmt = src.slice(viteHead.index, end + '.is_invalid_os_type;'.length);
    const [, macFn, app] = viteHead;
    const tail = grab(stmt, /:([\w$]+)\(\)&&!([\w$]+)\(\)\?([\w$]+)\(\w+\):([\w$]+)\(\)\?!0:/, 'Vite platform calls');
    const [, ciFn, mpFn, devFn, tdFn] = tail;
    const run = new Function('window', macFn, ciFn, mpFn, tdFn, devFn, app, '__k',
                             `switch(__k){${stmt}}`);
    return {
      vite: true,
      run: (key, win, os, a) => run(win, os.Pr, os.CI, os.mP, os.td, () => 'device', a, key === 'Apple' ? 5 : key),
    };
  }
  const head = grab(src, /case"notprotonWindows":return\(0,([\w$]+)\.Pr\)\(\)&&\(window\.__NOTPROTON_NATIVE_PLATFORM__\.windows\.has\(([\w$]+)\.appid\)/,
                    'filter fix');
  const apple = grab(src.slice(head.index), /;case ([\w$]+)\.([\w$]+):return /, 'Apple case');
  const end = src.indexOf('.is_invalid_os_type;', head.index + apple.index + apple[0].length);
  const stmt = src.slice(head.index, end + '.is_invalid_os_type;'.length);
  const [, platform, app] = head;
  const [, group, option] = apple;
  const device = /\.mP\)\(\)\?([\w$]+)\(/.exec(stmt);
  const run = new Function('window', group, platform, app, device ? device[1] : '__device', '__k',
                           `switch(__k){${stmt}}`);
  return {
    vite: false,
    run: (key, win, os, a) => run(win, { [option]: 'Apple' }, os, a, () => 'device', key),
  };
}

function lists(src) {
  const win = {};
  const header = src.indexOf('\n', src.indexOf('\n') + 1) + 1;
  new Function('window', 'queueMicrotask', src.slice(0, header))(win, f => f());
  return win;
}

function check(file, name, t) {
  const src = fs.readFileSync(file, 'latin1');
  const win = lists(src);
  const { vite, run } = filter(src);
  const mac = { Pr: () => true, td: () => false, CI: () => false, mP: () => false };
  const windows = { Pr: () => false, td: () => true, CI: () => false, mP: () => false };
  const app = (appid, { old = false, available = true } = {}) =>
    ({ appid, is_available_on_current_platform: available, is_invalid_os_type: false,
       most_available_per_client_data: { is_invalid_os_type: old } });
  const apple = (a, os = mac) => run('Apple', win, os, a);
  const wonly = (a, os = mac) => run('notprotonWindows', win, os, a);

  t(apple(app(1)) && !wonly(app(1)), 'a Mac game is under Apple only');
  t(!apple(app(2)) && wonly(app(2)), 'a Windows game is under Windows only');
  t(apple(app(4)) && !wonly(app(4)), 'a game with both builds is under Apple only');
  t(!apple(app(4, { old: true })) && wonly(app(4, { old: true })),
    'a game whose Mac build is 32-bit is under Windows only');
  t(!apple(app(1, { old: true })) && !wonly(app(1, { old: true })),
    'a 32-bit Mac game with no Windows build is under neither');
  t(apple(app(3)) && !apple(app(3, { available: false })) && !wonly(app(3)),
    "a game missing from appinfo.vdf gets Steam's answer under Apple and is not under Windows");
  t(!apple(app(3, { old: true })) && !wonly(app(3, { old: true })),
    'a missing 32-bit Mac game stays excluded even though the top-level invalid flag is false');
  const otherPlatform = { ...mac, Pr: () => false };
  t(!apple({ ...app(3), is_invalid_os_type: true }, otherPlatform) && apple(app(3), otherPlatform),
    'the fallback on other platforms still uses the original invalid flag');
  t(apple(app(2), windows) && !wonly(app(2), windows), "on Windows the filter is Steam's");

  const registered = [];
  const entries = new Map();
  win.appDetailsStore = {
    m_mapAppData: entries,
    RegisterForAppData(id) {
      registered.push(id);
      const e = entries.get(id) || { cRegistered: 0 };
      e.cRegistered++;
      entries.set(id, e);
    },
  };
  const shortcut = appid => ({ ...app(appid), BIsShortcut: () => true });
  const target = (appid, exe) => { entries.get(appid).details = { strShortcutExe: exe }; };
  t(apple(app(3)) && !wonly(app(3)) && registered.length === 0,
    'a Steam game never asks for shortcut details');
  t(apple(shortcut(10)) && !wonly(shortcut(10)) && apple(shortcut(10)),
    "a shortcut gets Steam's answer until its details arrive");
  t(registered.join() === '10', 'a shortcut asks for its details once');
  target(10, '"/Users/me/Downloads/Setup.EXE"');
  t(!apple(shortcut(10)) && wonly(shortcut(10)), 'an .exe shortcut is under Windows only');
  t(apple(shortcut(10), windows) && !wonly(shortcut(10), windows), "on Windows an .exe shortcut is Steam's");
  apple(shortcut(11));
  target(11, '"/Applications/Game.app"');
  t(apple(shortcut(11)) && !wonly(shortcut(11)), 'an .app shortcut stays under Apple');
  target(10, '"/Users/me/Downloads/game.exe.app"');
  t(apple(shortcut(10)) && !wonly(shortcut(10)), 'a shortcut retargeted to an app moves back to Apple');
  t(registered.join() === '10,11', 'each shortcut asked for its details once');
  delete win.appDetailsStore;

  if (!src.includes('SelectCollectionsAppFilterOption("notprotonWindows"')) return;

  grab(src, /filterGroups:\[([\w$]+)\(!0,([\w$]+)&&\2\.filterGroups\[0\]\),\1\(!1,\2&&\2\.filterGroups\[1\]\)/,
       "Steam's default intersection for the state group");
  const checks = vite
    ? [...src.matchAll(/if\(!(.+?)\|\|!([\w$]+)\(([\w$]+)\[2\],/g)]
    : [...src.matchAll(/if\(!(.+?)\|\|!([\w$]+)\(([\w$]+)\[([\w$]+)\.sc\],/g)];
  t(checks.length === 2, 'both matching paths include the platform check');
  const appleOpt = vite ? 5 : 'Apple';
  for (const [, expr, match, groups, enums] of checks) {
    const [, predicate, argument] = grab(expr, /,([\w$]+)\(([\w$]+)\)\)\)*$/, 'platform predicate');
    const evaluate = vite
      ? new Function(match, groups, predicate, argument, `return ${expr}`)
      : new Function(match, groups, enums, predicate, argument, `return ${expr}`);
    const matches = (g, p) => !g.rgOptions.length || (g.bAcceptUnion ? g.rgOptions.some(p) : g.rgOptions.every(p));
    const test = (options, windowsOn, a, union = false) => {
      const state = [{ rgOptions: [], bAcceptUnion: true }, { rgOptions: options, bAcceptUnion: union }];
      const before = JSON.stringify(state);
      const pred = a => key => key === 'installed' ? !!a.installed : run(key === 5 ? 'Apple' : key, win, mac, a);
      const result = vite
        ? evaluate.call({ m_filterSpec: { notprotonWindows: windowsOn } }, matches, state, pred, a)
        : evaluate.call({ m_filterSpec: { notprotonWindows: windowsOn } }, matches, state,
                        { W6: 1, Pu: 'Apple' }, pred, a);
      t(JSON.stringify(state) === before, 'matching leaves the saved filter unchanged');
      return result;
    };
    for (const id of [1, 2, 4]) {
      t(test([], false, app(id)), 'neither platform button filters games');
      t(test([appleOpt], false, app(id)) === (id !== 2), 'Apple alone keeps its platform check');
      t(test([], true, app(id)) === (id === 2), 'Windows alone keeps its platform check');
      t(test([appleOpt], true, app(id)), 'both buttons show both platforms with the default intersection');
      t(test([appleOpt], true, app(id), true), 'both buttons show both platforms with a union');
      t(!test([appleOpt, 'installed'], true, app(id)) &&
        test([appleOpt, 'installed'], true, { ...app(id), installed: true }),
        'installed stays an intersection with the combined platforms');
    }
    t(!test([appleOpt], true, app(3, { available: false })), 'neither platform admits an unavailable unknown game');
    t(test(['installed'], true, { ...app(1), installed: true }, true), 'other union options still admit games');
  }

  const saved = grab(src, /notprotonWindows:(!!([\w$]+)\?\.notprotonWindows),/, 'saved flag');
  const restore = new Function(saved[2], `return ${saved[1]}`);
  t(restore(undefined) === false && restore({}) === false && restore({ notprotonWindows: true }) === true,
    'a saved filter brings the Windows button back');

  const select = grab(src, /SelectOption\(([\w$]+),([\w$]+),([\w$]+)\)\{(if\(\1==="notprotonWindows"\)\{this\.m_filterSpec\.notprotonWindows=!!\3;return\})/,
                      'option setter');
  const set = new Function(select[1], select[2], select[3], `${select[4]}return"steam"`);
  const self = { m_filterSpec: { notprotonWindows: false } };
  const r1 = set.call(self, 'notprotonWindows', null, true);
  const was = self.m_filterSpec.notprotonWindows;
  set.call(self, 'notprotonWindows', null, false);
  t(r1 === undefined && was === true && self.m_filterSpec.notprotonWindows === false &&
    set.call(self, 0, 'Apple', true) === 'steam', 'the Windows option toggles the flag and nothing else');

  t(/Reset\(\)\{this\.m_filterSpec\.notprotonWindows=!1,/.test(src), 'Reset turns the Windows button off');
  t(/get bIsEmpty\(\)\{return!this\.m_filterSpec\.notprotonWindows&&/.test(src),
    'a filter with only Windows on does not count as empty');

  english();
  const summary = grab(src, /if\(([\w$]+)==="notprotonWindows"\)return (.*?);if\(\1==/, 'summary');
  t(new Function(`return ${summary[2]}`)() === 'Runs on Windows, no Mac OS version',
    'the filter summary names the Windows filter');

  const same = (a, b) => JSON.stringify(a) === JSON.stringify(b);
  if (vite) {
    const button = grab(src, /children:\[(([\w$]+)&&!([\w$]+)&&\(0,([\w$]+)\.jsxs\)\(([\w$]+),\{.*?\}\)\]\}\)\]\}\)),\2&&\(0,\4\.jsxs\)\(\5,\{direction:`top`,nDelayShowMS:240,toolTipContent:[\w$]+\(\3\?`#GameList_View_Platform_Linux`:`#GameList_View_Platform_Apple`\)/,
                        'Vite Windows button before Apple');
    const [, expr, shown, linux, rt, tip] = button;
    const cls = grab(expr, /className:([\w$]+)\(`([\w$-]+)`,([\w$]+)&&`([\w$-]+)`,npWindows&&`([\w$-]+)`\)/, 'Vite classes');
    const [, clsFn, boxCls, disabledVar, offCls, onCls] = cls;
    const draw = new Function(shown, linux, rt, tip, clsFn, disabledVar, 'npWindows', 'npStore',
                              `return ${expr}`);
    const press = ({ visible = true, onLinux = false, disabled = false, active = false } = {}) => {
      const calls = [];
      const node = draw(visible, onLinux, { jsx: (type, p) => ({ type, p }), jsxs: (type, p) => ({ type, p }) },
                        'Tooltip', (...c) => c.filter(Boolean).join(' '), disabled, active,
                        { SelectCollectionsAppFilterOption: (...a) => calls.push(a) });
      if (node) node.p.onClick();
      return { node, calls };
    };
    const lit = press({ active: true });
    t(same(press().calls, [['notprotonWindows', null, true]]) && same(lit.calls, [['notprotonWindows', null, false]]),
      'a click toggles the Windows button');
    t(lit.node.p.className === `${boxCls} ${onCls}` && press().node.p.className === boxCls &&
      press({ disabled: true }).node.p.className === `${boxCls} ${offCls}` &&
      lit.node.p.children[1].type === 'svg' && lit.node.p.children[1].p.children.length === 4 &&
      lit.node.p.nDelayShowMS === 240 &&
      lit.node.p.children[0].type === 'style' &&
      lit.node.p.children[0].p.children === `.${boxCls} .SVGIcon_WindowsLogo{width:13px;height:13px}.${boxCls} .SVGIcon_WindowsLogo rect{fill:inherit}` &&
      lit.node.p.toolTipContent === 'Show only games that run on Windows and do not have a macOS version',
      "the Windows button looks and times like Steam's Apple button");
    t(press({ disabled: true }).calls.length === 0, 'a disabled Windows button does nothing');
    t(!press({ onLinux: true }).node && !press({ visible: false }).node,
      'no Windows button on Linux or when Steam hides the Apple one');
    return;
  }

  const button = grab(src, /children:\[(([\w$]+)&&!([\w$]+)&&([\w$]+)\.Xz0&&\(0,([\w$]+)\.jsxs\)\(([\w$]+)\.he,\{.*?\(0,\5\.jsx\)\(\4\.Xz0,\{\}\)\]\}\)),\2&&\(0,\5\.jsxs\)\(\6\.he,\{direction:"top",nDelayShowMS:240,toolTipContent:\3\?(?:\(0,[\w$]+\.we\)\()?"#GameList_View_Platform_Linux"/,
                      'Windows button before Apple');
  const [, expr, shown, linux, icons, rt, tip] = button;
  const cls = /className:\(0,([\w$]+)\.A\)\(([\w$]+)\(\)\.CheckboxWithImage,([\w$]+)&&/.exec(expr);
  const draw = new Function(shown, linux, icons, rt, tip, cls[1], cls[2], cls[3], 'npWindows', 'npStore',
                            `return ${expr}`);
  const press = ({ visible = true, onLinux = false, icon = true, disabled = false, active = false } = {}) => {
    const calls = [];
    const node = draw(visible, onLinux, icon ? { Xz0: 'Windows' } : {}, { jsx: (type, p) => ({ type, p }), jsxs: (type, p) => ({ type, p }) },
                      { he: 'Tooltip' }, { A: (...c) => c.filter(Boolean).join(' ') },
                      () => ({ CheckboxWithImage: 'box', Disabled: 'off', Active: 'on' }), disabled, active,
                      { SelectCollectionsAppFilterOption: (...a) => calls.push(a) });
    if (node) node.p.onClick();
    return { node, calls };
  };
  const lit = press({ active: true });
  t(same(press().calls, [['notprotonWindows', null, true]]) && same(lit.calls, [['notprotonWindows', null, false]]),
    'a click toggles the Windows button');
  t(lit.node.p.className === 'box on' && press().node.p.className === 'box' &&
    lit.node.p.children[1].type === 'Windows' && lit.node.p.nDelayShowMS === 240 &&
    lit.node.p.children[0].type === 'style' &&
    lit.node.p.children[0].p.children === '.box .SVGIcon_WindowsLogo{width:13px;height:13px}.box .SVGIcon_WindowsLogo rect{fill:inherit}' &&
    lit.node.p.toolTipContent === 'Show only games that run on Windows and do not have a macOS version',
    "the Windows button looks and times like Steam's Apple button");
  t(press({ disabled: true }).calls.length === 0, 'a disabled Windows button does nothing');
  t(!press({ onLinux: true }).node && !press({ icon: false }).node && !press({ visible: false }).node,
    'no Windows button on Linux, without the icon, or when Steam hides the Apple one');
}

for (const file of files) {
  const name = path.basename(file, '.out.js');
  const t = (cond, what) => ok(name, cond, what);
  try { check(file, name, t); } catch (e) { t(false, e.message); }
}
console.log(failed ? `\n${failed} failure(s)` : `==> library filter: ${files.length} patched files behave`);
process.exit(failed ? 1 : 0);
