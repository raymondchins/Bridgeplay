# The resolver's refusals: a wm register the shim overwrites, and a wm register written
# between the hook and the place the resolver found it.
import pathlib, sys, unittest

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))
import wmguard  # noqa: E402

try:
    import capstone
except ImportError:
    capstone = None


def refused(fn, *args):
    try:
        fn(*args)
    except SystemExit as e:
        return str(e)
    return None


class Unsafe(unittest.TestCase):
    def test_registers_the_shims_overwrite(self):
        for arch, regs in (('i386', ('ecx', 'esp')), ('x86_64', ('rax', 'rcx', 'r10', 'rsp'))):
            for r in regs:
                with self.subTest(r):
                    self.assertIn(f'MODREF is in {r}', refused(wmguard.refuse_unsafe, 'nt', arch, r))

    def test_registers_the_shims_read(self):
        for arch, regs in (('i386', ('eax', 'edx', 'ebx', 'ebp', 'esi', 'edi')),
                           ('x86_64', ('rbx', 'rsi', 'rdi', 'rdx', 'r8', 'r9', 'r11', 'r14'))):
            for r in regs:
                with self.subTest(r):
                    self.assertIsNone(refused(wmguard.refuse_unsafe, 'nt', arch, r))

    def test_no_register(self):
        self.assertIn('no register', refused(wmguard.refuse_unsafe, 'nt', 'x86_64', None))
        self.assertIn('not a general register',
                      refused(wmguard.refuse_unsafe, 'nt', 'x86_64', 'qword ptr [rsp + 0x20]'))
        self.assertIn('not a general register', refused(wmguard.refuse_unsafe, 'nt', 'i386', 'rbx'))


class Writes(unittest.TestCase):
    def test_partial_names(self):
        for arch, wm, names in (
                ('i386', 'eax', ('al', 'ah', 'ax', 'eax')), ('i386', 'ebx', ('bl', 'bh', 'bx', 'ebx')),
                ('i386', 'ecx', ('cl', 'ch', 'cx', 'ecx')), ('i386', 'edx', ('dl', 'dh', 'dx', 'edx')),
                ('i386', 'esi', ('si', 'esi')), ('i386', 'edi', ('di', 'edi')),
                ('i386', 'ebp', ('bp', 'ebp')),
                ('x86_64', 'rbx', ('bl', 'bh', 'bx', 'ebx', 'rbx')),
                ('x86_64', 'rsi', ('sil', 'si', 'esi', 'rsi')),
                ('x86_64', 'r14', ('r14b', 'r14w', 'r14d', 'r14'))):
            for n in names:
                self.assertEqual(wmguard.full(arch, n), wm, n)
        self.assertEqual(wmguard.full('i386', 'eflags'), 'eflags')

    def test_write_in_the_window(self):
        win = [(0x10, 'test byte ptr [ebp - 0x4c], 2', 'test', ['eflags']),
               (0x14, 'jne 0x40', 'jne', []),
               (0x16, 'mov eax, dword ptr [ebp - 0x20]', 'mov', ['eax'])]
        self.assertIsNone(refused(wmguard.refuse_writes, 'nt', 'i386', 'ebx', win, 'here'))
        for name in ('bl', 'bh', 'ebx'):
            got = refused(wmguard.refuse_writes, 'nt', 'i386', 'ebx',
                          win + [(0x19, f'mov {name}, 1', 'mov', [name])], 'here')
            self.assertIn('ebx is written at 0x19', got)
        got = refused(wmguard.refuse_writes, 'nt', 'x86_64', 'r14',
                      [(0x20, 'xor r14d, r14d', 'xor', ['r14d', 'rflags'])], 'here')
        self.assertIn('r14 is written at 0x20', got)

    def test_leaving_the_line(self):
        for m in ('jmp', 'call', 'ret'):
            got = refused(wmguard.refuse_writes, 'nt', 'i386', 'ebx',
                          [(0x30, f'{m} 0x50', m, ['esp'])], 'here')
            self.assertIn('not a straight line', got)


@unittest.skipIf(capstone is None, 'capstone not installed (pip3 install capstone)')
class WithCapstone(unittest.TestCase):
    # resolve.window turns capstone's write sets into what refuse_writes reads. The bytes are
    # WineCX 11.17's i386 hook up to its MODREF test.
    HOOK = bytes.fromhex('f645b402' '7529' '8b45e0' 'f6401720' '0f842d020000')

    def window(self, code):
        import resolve
        md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        md.detail = True
        return resolve.window(list(md.disasm(code, 0x4f880)))

    def test_real_hook_passes(self):
        self.assertIsNone(refused(wmguard.refuse_writes, 'nt', 'i386', 'ebx',
                                  self.window(self.HOOK), 'here'))

    def test_reload_is_refused(self):
        for insn in ('8b5de0', '8a5de0', '8a7de0', '31db'):   # mov ebx / bl / bh, xor ebx
            code = self.HOOK[:6] + bytes.fromhex(insn) + self.HOOK[9:]
            with self.subTest(insn):
                self.assertIn('ebx is written at 0x4f886',
                              refused(wmguard.refuse_writes, 'nt', 'i386', 'ebx',
                                      self.window(code), 'here'))


if __name__ == '__main__':
    unittest.main()
