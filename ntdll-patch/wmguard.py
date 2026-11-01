# Which register may carry the MODREF (wm) into an entry shim, shared by resolve.py and
# shimcheck.py. No capstone here, so the checks that import it run without it.

# What each shim overwrites before it reads WM_REG. shim32.S: pushad moves esp and
# `pop ecx` takes the load delta. ebx is fine only because WM_IN_EBX reads it before fp
# goes in. shim.S: the pushes move rsp, r10 keeps the unaligned rsp, rax and rcx carry
# the ctx table.
UNSAFE = {
    'i386': {'ecx': 'shim32.S pops the load delta into it first',
             'esp': 'pushad has already moved it'},
    'x86_64': {'rax': 'shim.S builds the ctx table in it first',
               'rcx': 'shim.S puts &ctx in it first',
               'r10': 'shim.S saves the unaligned rsp in it first',
               'rsp': 'the shim has pushed ten registers by then'},
}

GPR = {
    'i386': ['eax', 'ecx', 'edx', 'ebx', 'esp', 'ebp', 'esi', 'edi'],
    'x86_64': ['rax', 'rcx', 'rdx', 'rbx', 'rsp', 'rbp', 'rsi', 'rdi',
               'r8', 'r9', 'r10', 'r11', 'r12', 'r13', 'r14', 'r15'],
}

# Every name that writes part of a GPR, mapped to the GPR, so a write to bl or ebx counts
# as a write to ebx or rbx.
_PARTS = {}
for _n in 'abcd':
    _r = _n + 'x'
    for _p in (_n + 'l', _n + 'h', _r, 'e' + _r):
        _PARTS.setdefault('i386', {})[_p] = 'e' + _r
        _PARTS.setdefault('x86_64', {})[_p] = 'r' + _r
for _r in ('sp', 'bp', 'si', 'di'):
    for _p in (_r + 'l', _r, 'e' + _r):
        _PARTS['i386'][_p] = 'e' + _r
        _PARTS['x86_64'][_p] = 'r' + _r
for _n in range(8, 16):
    for _s in ('b', 'w', 'd', ''):
        _PARTS['x86_64'][f'r{_n}{_s}'] = f'r{_n}'
for _arch in GPR:
    for _r in GPR[_arch]:
        _PARTS[_arch][_r] = _r


def full(arch, name):
    """The GPR a register name is part of, or the name itself if it is no GPR."""
    return _PARTS[arch].get(name, name)


def refuse_unsafe(path, arch, wm):
    """Stop when the shim cannot read wm from this register."""
    if wm is None:
        raise SystemExit(f"{path}: no register holds the MODREF at the hook")
    if wm not in GPR[arch]:
        raise SystemExit(f"{path}: the MODREF is in {wm!r}, not a general register the shim can read")
    if wm in UNSAFE[arch]:
        raise SystemExit(f"{path}: the MODREF is in {wm}, but {UNSAFE[arch][wm]}, so the shim "
                         f"cannot hand it to the detour. Change the shim before patching this build")


def refuse_writes(path, arch, wm, window, where):
    """Stop when anything in window writes wm or leaves the straight line.

    window is (address, text, mnemonic, written register names) for every instruction
    between the point the shim reads wm and the point the resolver saw it, so wm must hold
    the same value at both.
    """
    for address, text, mnemonic, writes in window:
        if wm in {full(arch, w) for w in writes}:
            raise SystemExit(f"{path}: {wm} is written at {address:#x} ({text}), {where}, "
                             f"so the shim would read another value than the one found")
        if mnemonic in ('jmp', 'ljmp', 'call', 'lcall', 'ret', 'retf', 'int', 'syscall', 'sysenter'):
            raise SystemExit(f"{path}: {text} at {address:#x}, {where}, so the way from the "
                             f"hook to the MODREF is not a straight line")
