// Cool and steady: a per-game switch for the SUSTAINED conf key, under the frame rate limit's
// own switch in the Wine panel, off by default, written as BRIDGEPLAY_SUSTAINED only when it
// differs from the confs.
'use strict';
const { panel, walk, details, runner, FORMS } = require('./harness');

const emit = process.argv[2];
if (!emit) { console.error('usage: sustained.js <emit>'); process.exit(2); }

const LABEL = 'Lower FPS when the Mac runs hot';
const NONE = { g: {}, a: {}, e: {}, d: {} };

let failed = 0;
for (const form of Object.keys(FORMS)) {
  const { render: P, written } = panel(emit, form);
  const t = runner(form);
  const nodes = (o, over) => walk(P({ details: details(o, over) }));
  const row = ns => ns.find(x => x.type === 'Toggle' && x.props.label === LABEL);
  const last = () => written.length ? written[written.length - 1].opts : '';

  globalThis.MSCXFx = NONE;
  const r = nodes('');
  t.ok(!!row(r) && row(r).props.checked === false, 'a Wine game shows the switch, off by default');
  const limit = r.find(x => x.type === 'Section' && walk(x.props.children).includes(row(r)));
  t.ok(!!limit && /^FPS Limit/.test(limit.props.label), 'it sits in the frame rate limit section');
  t.ok(!r.some(x => x.type === 'details' && walk(x.props.children).includes(row(r))), 'it is not in the Advanced group');
  t.ok(!row(nodes('', { vecPlatforms: ['osx'], strCompatToolName: '' })), 'a native Mac game has no such switch');

  written.length = 0;
  row(r).props.onChange(true);
  t.ok(last().trim() === 'BRIDGEPLAY_SUSTAINED=1 %command%', `on writes BRIDGEPLAY_SUSTAINED=1 (${last()})`);
  const on = nodes('BRIDGEPLAY_SUSTAINED=1 %command%');
  t.ok(row(on).props.checked === true, 'a game set to 1 shows the switch on');
  t.ok(row(nodes('NOTPROTON_SUSTAINED=1 %command%')).props.checked === true, 'the NOTPROTON_ spelling is read');
  written.length = 0;
  row(on).props.onChange(false);
  t.ok(last() === '', `off again drops the argument, the default is off (${JSON.stringify(last())})`);

  // A tier or Game Defaults conf that turns it on shows on, and off writes 0 over it.
  globalThis.MSCXFx = { g: { BRIDGEPLAY_SUSTAINED: '1' }, a: {}, e: {}, d: {} };
  t.ok(row(nodes('')).props.checked === true, 'a conf with SUSTAINED=1 shows on');
  written.length = 0;
  row(nodes('')).props.onChange(false);
  t.ok(last().trim() === 'BRIDGEPLAY_SUSTAINED=0 %command%', `off over that conf writes 0 (${last()})`);

  globalThis.MSCXFx = NONE;
  const btn = nodes('BRIDGEPLAY_SUSTAINED=1 %command%').find(x => x.type === 'button');
  written.length = 0;
  btn && btn.props.onClick();
  t.ok(!!btn && !last().includes('SUSTAINED'), `Use Bridgeplay defaults drops it (${last()})`);
  delete globalThis.MSCXFx;
  failed += t.failed;
}
console.log(failed ? `\n${failed} failure(s)` : '\nCool and steady: under the frame limit, off by default, written only when it differs');
process.exit(failed ? 1 : 0);
