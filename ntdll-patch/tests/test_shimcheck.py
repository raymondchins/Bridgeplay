# shimcheck.py on the shipped payloads, on the 11.15 and 11.17 payloads from before their
# fixes, and on payloads for a wm the shim cannot read.
import hashlib, io, pathlib, shutil, sys, tempfile, unittest
from contextlib import redirect_stdout

HERE = pathlib.Path(__file__).resolve().parent
ROOT = HERE.parent.parent
sys.path.insert(0, str(HERE.parent))
import shimcheck  # noqa: E402

RES = ROOT / shimcheck.RESOURCES
PINS = shimcheck.pinned(ROOT / 'ntdll-patch/resolve.py')
BY_PAYLOAD = {v['payload']: v for v in PINS.values() if 'payload' in v}


def payload(name):
    data = (RES / name).read_bytes()
    return bytearray(data), BY_PAYLOAD[hashlib.sha256(data).hexdigest()]


def quiet(argv):
    out = io.StringIO()
    with redirect_stdout(out):
        rc = shimcheck.main(argv)
    return rc, out.getvalue()


class Shipped(unittest.TestCase):
    def test_every_shipped_payload_reads_its_pinned_wm(self):
        rc, out = quiet([])
        self.assertEqual(rc, 0, out)
        self.assertEqual(out.count('\nok   ') + out.startswith('ok   '), 20, out)


class BeforeTheFix(unittest.TestCase):
    # The pre-fix payloads differ from the shipped ones only in the order of the two moves
    # after `sub ecx, imm32`: mov ebx, ebp ran before mov esi, ebx.
    OLD = {'detour32-winecx-11.15.bin':
           '37daf5f795535df91bc8fcbd356f22f4fd1ab379ec4acc97ddff44037d265556',  # before 7af57dc
           'detour32-winecx-11.17.bin':
           '0676104e0bd56c4a1e8c473d9cbcd21fb2ba105fc7dc6cf5a70d37692c129e28'}  # before aa17158

    def test_old_payloads_fail(self):
        for name, old_sha in self.OLD.items():
            with self.subTest(name):
                data, pin = payload(name)
                self.assertEqual(data[13:17], bytes.fromhex('89de89eb'))
                data[13:17] = bytes.fromhex('89eb89de')
                self.assertEqual(hashlib.sha256(data).hexdigest(), old_sha,
                                 'not the byte stream that shipped before the fix')
                self.assertIsNone(shimcheck.check(bytes(payload(name)[0]), pin))
                problem = shimcheck.check(bytes(data), pin)
                self.assertIsNotNone(problem)
                self.assertIn('wm=ebp', problem)

    def test_old_payload_fails_the_whole_run(self):
        # A checkout where the old 11.17 payload ships with its old pins
        with tempfile.TemporaryDirectory() as d:
            d = pathlib.Path(d)
            shutil.copytree(ROOT / 'app/Sources', d / 'app/Sources')
            (d / 'ntdll-patch').mkdir()
            data, _ = payload('detour32-winecx-11.17.bin')
            new_sha = hashlib.sha256(data).hexdigest()
            data[13:17] = bytes.fromhex('89eb89de')
            old_sha = self.OLD['detour32-winecx-11.17.bin']
            (d / shimcheck.RESOURCES / 'detour32-winecx-11.17.bin').write_bytes(data)
            for rel in ('ntdll-patch/resolve.py', 'app/Sources/BridgeplayApp/Model/FreeEngineWinecx.swift'):
                src = (ROOT / rel).read_text()
                self.assertIn(new_sha, src)
                (d / rel).write_text(src.replace(new_sha, old_sha))
            rc, out = quiet(['--root', str(d)])
            self.assertEqual(rc, 1, out)
            self.assertIn('FAIL detour32-winecx-11.17.bin: for ntdll cc8a9035cea0, the detour call at +0x68 gets wm=ebp', out)
            self.assertIn('19 of 20', out)


class Unreadable(unittest.TestCase):
    def test_i386_wm_in_ecx_fails_in_either_order(self):
        data, pin = payload('detour32-cx26.bin')
        self.assertEqual(data[13:17], bytes.fromhex('89eb89f6'))   # mov ebx, ebp ; mov esi, esi
        pin = dict(pin, wm='ecx')
        for order in ('89eb89ce', '89ce89eb'):                    # mov esi, ecx before or after
            with self.subTest(order):
                data[13:17] = bytes.fromhex(order)
                problem = shimcheck.check(bytes(data), pin)
                self.assertIsNotNone(problem)
                self.assertNotIn('gets wm=ecx', problem)

    def test_x86_64_wm_the_shim_overwrites_fails(self):
        data, pin = payload('detour2.bin')
        at = 0x4f
        self.assertEqual(data[at:at + 3], bytes.fromhex('4889f2'))  # mov rdx, rsi
        for reg, insn in (('rax', '4889c2'), ('rcx', '4889ca'), ('r10', '4c89d2')):
            with self.subTest(reg):
                data[at:at + 3] = bytes.fromhex(insn)
                problem = shimcheck.check(bytes(data), dict(pin, wm=reg))
                self.assertIsNotNone(problem)
                self.assertNotIn(f'gets wm={reg} ', problem)
        # rbx is this payload's scratch register, so it carries load_path by then
        data[at:at + 3] = bytes.fromhex('4889da')                  # mov rdx, rbx
        self.assertIn('gets wm=[entry+0xd0]', shimcheck.check(bytes(data), dict(pin, wm='rbx')))
        data[at:at + 3] = bytes.fromhex('4889fa')                  # mov rdx, rdi
        self.assertIsNone(shimcheck.check(bytes(data), dict(pin, wm='rdi')))

    def test_wrong_pin_fails(self):
        data, pin = payload('detour32-41069.bin')
        self.assertIsNone(shimcheck.check(bytes(data), pin))
        self.assertIn('wm=edi', shimcheck.check(bytes(data), dict(pin, wm='esi')))
        data, pin = payload('detour2-winehq-11.15.bin')
        self.assertIsNone(shimcheck.check(bytes(data), pin))
        self.assertIn('load_path', shimcheck.check(bytes(data), dict(pin, load_path=0x58)))

    def test_unknown_instruction_fails(self):
        data, pin = payload('detour32.bin')
        data[13] = 0x0f
        self.assertIn('cannot follow the shim', shimcheck.check(bytes(data), pin))


class Pins(unittest.TestCase):
    def test_swift_pin_for_another_ntdll_fails(self):
        with tempfile.TemporaryDirectory() as d:
            d = pathlib.Path(d)
            shutil.copytree(ROOT / 'app/Sources', d / 'app/Sources')
            (d / 'ntdll-patch').mkdir()
            shutil.copy(ROOT / 'ntdll-patch/resolve.py', d / 'ntdll-patch/resolve.py')
            swift = d / 'app/Sources/BridgeplayApp/Model/FreeEngineWinecx.swift'
            text = swift.read_text()
            self.assertIn('NtdllHook(rva: 0x4f880,', text)
            swift.write_text(text.replace('NtdllHook(rva: 0x4f880,', 'NtdllHook(rva: 0x4f7c0,'))
            rc, out = quiet(['--root', str(d)])
            self.assertEqual(rc, 1, out)
            self.assertIn('FAIL detour32-winecx-11.17.bin: FreeEngineWinecx.swift (winecx-11.17) hooks 0x4f7c0', out)

    def test_bumped_engine_with_the_old_payload_fails(self):
        # A new ntdll keeps the hook and cave RVAs, but the old payload and patch are kept
        # for it: the payload still matches the old ntdll's pin, not the engine's.
        with tempfile.TemporaryDirectory() as d:
            d = pathlib.Path(d)
            shutil.copytree(ROOT / 'app/Sources', d / 'app/Sources')
            (d / 'ntdll-patch').mkdir()
            shutil.copy(ROOT / 'ntdll-patch/resolve.py', d / 'ntdll-patch/resolve.py')
            swift = d / 'app/Sources/BridgeplayApp/Model/FreeEngineWinecx.swift'
            old = 'cc8a9035cea0e26c5d333ef220f1becefc27ae44d2cdcdaea3278e8739d26fd9'
            text = swift.read_text()
            self.assertEqual(text.count(old), 1)
            swift.write_text(text.replace(old, 'ab' * 32))
            rc, out = quiet(['--root', str(d)])
            self.assertEqual(rc, 1, out)
            self.assertIn('FAIL detour32-winecx-11.17.bin: FreeEngineWinecx.swift (winecx-11.17) '
                          'patches the i386Windows ntdll abababababab, but this payload was built '
                          'for cc8a9035cea0', out)
            self.assertIn('19 of 20', out)

    def test_commented_out_clean_hash_is_not_read(self):
        old = 'cc8a9035cea0e26c5d333ef220f1becefc27ae44d2cdcdaea3278e8739d26fd9'
        for keep in ('// .i386Windows: "{old}",\n', '/* .i386Windows: "{old}", /* nested */ */\n'):
            with self.subTest(keep[:2]), tempfile.TemporaryDirectory() as d:
                d = pathlib.Path(d)
                shutil.copytree(ROOT / 'app/Sources', d / 'app/Sources')
                (d / 'ntdll-patch').mkdir()
                shutil.copy(ROOT / 'ntdll-patch/resolve.py', d / 'ntdll-patch/resolve.py')
                swift = d / 'app/Sources/BridgeplayApp/Model/FreeEngineWinecx.swift'
                text = swift.read_text()
                line = f'.i386Windows: "{old}",\n'
                self.assertEqual(text.count(line), 1)
                swift.write_text(text.replace(line, keep.format(old=old) + f'.i386Windows: "{"ab" * 32}",\n'))
                rc, out = quiet(['--root', str(d)])
                self.assertEqual(rc, 1, out)
                self.assertIn('patches the i386Windows ntdll abababababab, but this payload', out)

    def test_swift_lexing(self):
        src = ('a("x\\(f("y)"))z", #"q"z\\("#, """\nm "" \\(g(")"))\n""") // c )\n'
               '/* a /* b */ ) */ b ]')
        self.assertEqual(shimcheck.closing(src, 1), src.index('""")') + 3)
        self.assertNotIn('// c', shimcheck.uncommented(src))
        self.assertNotIn('/* a', shimcheck.uncommented(src))
        self.assertIn('"x\\(f("y)"))z"', shimcheck.uncommented(src))
        self.assertEqual(shimcheck.uncommented('x = "// not a comment" // one'), 'x = "// not a comment"  ')
        for f in (ROOT / 'app/Sources').rglob('*.swift'):
            shimcheck.uncommented(f.read_text())

    def test_every_pinned_ntdll_the_payload_serves_is_checked(self):
        # The 26.3 China rebuild's i386 ntdll pinned with the cx26 payload, but keeping wm in
        # ebx: the payload hands over esi, so it is wrong for that ntdll.
        rebuild = '21e7d0a6d6868f1853489f5a9798e706509a20a65ee370f50b37ab7b1cdcaae3'
        cx26 = '2c60ee6b00dd13b7f6cb11017778a041ba6a321eaea194f1fa0dca7eab8403e2'
        for wm, rc_want in (('esi', 0), ('ebx', 1)):
            with self.subTest(wm), tempfile.TemporaryDirectory() as d:
                d = pathlib.Path(d)
                shutil.copytree(ROOT / 'app/Sources', d / 'app/Sources')
                (d / 'ntdll-patch').mkdir()
                src = (ROOT / 'ntdll-patch/resolve.py').read_text()
                entry = dict(PINS[cx26], wm=wm)
                (d / 'ntdll-patch/resolve.py').write_text(
                    src.replace('PINNED = {\n', f'PINNED = {{\n    {rebuild!r}: {entry!r},\n', 1))
                rc, out = quiet(['--root', str(d)])
                self.assertEqual(rc, rc_want, out)
                if rc_want:
                    self.assertIn(f'FAIL detour32-cx26.bin: for ntdll {rebuild[:12]}, the detour '
                                  f'call at +0x68 gets wm=esi', out)
                else:
                    self.assertIn(f'ntdll {rebuild[:12]} keeps wm in esi', out)

    def test_every_payload_has_its_build(self):
        patches, builds = shimcheck.swift_pins(ROOT / 'app/Sources')
        for f in RES.glob('detour*.bin'):
            with self.subTest(f.name):
                ships = patches.get(f.stem)
                self.assertTrue(ships)
                for s in ships:
                    self.assertIn(s['arch'], builds[s['build']])

    def test_unpinned_payload_fails(self):
        with tempfile.TemporaryDirectory() as d:
            f = pathlib.Path(d) / 'detour32-x.bin'
            f.write_bytes(b'\x90' * 16)
            rc, out = quiet([str(f)])
            self.assertEqual(rc, 1, out)
            self.assertIn('no PINNED ntdll', out)


if __name__ == '__main__':
    unittest.main()
