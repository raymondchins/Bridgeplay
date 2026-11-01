#!/usr/bin/env python3
# Reads every per-build constant the ntdll detours need out of the binary, for
# all archs. Internal development tool, ugly
import hashlib, pathlib, struct, sys, re, bisect, capstone
from capstone import x86 as X86, arm64 as A64
from wmguard import refuse_unsafe, refuse_writes

ARCH = {0x8664: 'x86_64-windows', 0x14c: 'i386-windows', 0xaa64: 'aarch64-windows'}

PAYLOAD = {0x8664: 864, 0x14c: 1376, 0xaa64: 868}  # detour2.bin, detour32.bin, detour64-fex.bin

# Keyed by input sha256 so the comparison only runs against the build the tree pins, so a
# new build will report derived values rather than a wall of expected mismatches
PINNED = {
    '04c7200b6645decb7c2d1ba6b0195abc9af83257072558d11aa72cc067ac3377':
        {'hookRVA': 0x51f15, 'stolen': '4883bc24f000000000', 'caveRVA': 0x80be0, 'wm': 'rsi',
         'resume': 0x51f1e, 'load_path': 0xd0,
         'payload': '8504714bba0195439cb5b44c89f25c68dbb7f01bae6f72ca0a258a0daec3e244',
         'exports': {'LdrGetDllHandle': 0x1700176d0, 'LdrLoadDll': 0x1700181f0,
                     'NtProtectVirtualMemory': 0x17000f640}},
    '94cc7c14c1e9dcf58ef501015c115f8405c73b2a65cefe31faa5d9e47f36e58b':
        {'hookRVA': 0x4d828, 'stolen': 'f645bc027526', 'caveRVA': 0x7c830, 'caveSize': 2000,
         'resume': 0x4d82e, 'wm': 'edi', 'load_path': -0x54,
         'payload': '2758d4f6783c853c460187f83f4fb9b1105380d194126ef83fc85e2596d3036a',
         'exports': {'LdrGetDllHandle': 0x7bc125b0, 'LdrLoadDll': 0x7bc130a0,
                     'NtProtectVirtualMemory': 0x7bc0d764, 'NtOpenFile': 0x7bc0d594,
                     'NtReadFile': 0x7bc0d2c4, 'NtClose': 0x7bc0d354}},
    'f4fa556a3dc20f6e966a803f5de554359227a61a24cd5b5a2ad88a427ceeec58':
        {'hookRVA': 0x34b2e, 'stolen': '488b842410010000', 'caveRVA': 0x79394, 'wm': 'rbx',
         'resume': 0x34b36, 'load_path': 0x98,
         'payload': '6af3f36658907cc94c096e432006807d6997bd970560f2579df748d6fd6e2bc6',
         'exports': {'LdrGetDllHandle': 0x17002f530, 'LdrLoadDll': 0x17002ce70,
                     'NtProtectVirtualMemory': 0x17005549c}},
    '09474795d6f306163cebab6429819999fcff50e07dbc4b067a90ec4f74a3a7d7':
        {'hookRVA': 0x2ee12, 'stolen': '8b4514a802', 'caveRVA': 0x6b2fe, 'caveSize': 3330,
         'resume': 0x2ee17, 'wm': 'esi', 'load_path': -0x3c,
         'payload': 'b4c697ba396ecb59125c505666ad3465d1208b8a1e3e53a0c457657b341376b9',
         'exports': {'LdrGetDllHandle': 0x7bc2a6b0, 'LdrLoadDll': 0x7bc286d0,
                     'NtProtectVirtualMemory': 0x7bc4d020, 'NtOpenFile': 0x7bc4ce50,
                     'NtReadFile': 0x7bc4cb80, 'NtClose': 0x7bc4cc10}},
    '6dff64c00793ce92124f1316985c63783f539f26b392975c70f57637458d2387':
        {'hookRVA': 0x44972, 'stolen': '4883bc24f000000000', 'caveRVA': 0xae000, 'caveSize': 4096,
         'wm': 'r14', 'resume': 0x4497b, 'load_path': 0xd0,
         'payload': 'e35b834408599c45f30b23a6d2bf38acfa5c3df4d15206617c471e23a4a01bfb',
         'exports': {'LdrGetDllHandle': 0x170014bc0, 'LdrLoadDll': 0x170015680,
                     'NtProtectVirtualMemory': 0x17000f380}},
    '2c60ee6b00dd13b7f6cb11017778a041ba6a321eaea194f1fa0dca7eab8403e2':
        {'hookRVA': 0x43b40, 'stolen': 'f645c0017526', 'caveRVA': 0xaa000, 'caveSize': 4096,
         'resume': 0x43b46, 'wm': 'esi', 'load_path': -0x54,
         'payload': 'be465bc936cafafae4aa1b4c41f668e08848492d9858c2cf2ad483a9f1ab25e5',
         'exports': {'LdrGetDllHandle': 0x7bc12c60, 'LdrLoadDll': 0x7bc13750,
                     'NtProtectVirtualMemory': 0x7bc0d584, 'NtOpenFile': 0x7bc0d3b4,
                     'NtReadFile': 0x7bc0d0e4, 'NtClose': 0x7bc0d174}},
    '7823d71fbce6c9947163bf8b96beb299eabb02878245bcaf6759f2a22e81f071':
        {'caveRVA': 0xf1185, 'caveSize': 61051,
         # This image carries the loader twice, once for the native side and once for the
         # emulated guest, and the detour has to divert both....
         'sites': [{'hookRVA': 0x48004, 'stolen': '1f2003d5', 'resume': 0x48008,
                    'wm': 'x27', 'load_path': -0x98},
                   {'hookRVA': 0xa71bc, 'stolen': '1f2003d5', 'resume': 0xa71c0,
                    'wm': 'x22', 'load_path': -0x88}],
         # What link64.ld resolves, and the reason it is not the exports below: from the
         # guest loader the exported LdrLoadDll takes a lock it does not hold, and the
         # exported NtProtectVirtualMemory is a syscall thunk whose dispatcher is null.
         'guest': {'LdrLoadDll': 0x9f698, 'LdrGetDllHandle': 0x9f698,
                   'NtProtectVirtualMemory': 0xea8cc},
         'payload': '68a458ec9c32041c79fdd622d18e91cfbe825a5292cae362d310930e34dd598e',
         'exports': {'LdrGetDllHandle': 0x180043328, 'LdrLoadDll': 0x180040e94,
                     'NtProtectVirtualMemory': 0x180065db0}},
    '5b388fd48823e905616432fba627eb48f68dc14383963bb213d55db3f691b1b9':
        {'hookRVA': 0x52055, 'stolen': '4883bc24f000000000', 'caveRVA': 0x815e0, 'caveSize': 2592,
         'resume': 0x5205e, 'wm': 'rsi', 'load_path': 0xd0,
         'payload': '660ea7c935620e620a45a46e552c0a3de9292e031bf93ef676968154d45e78d5',
         'exports': {'LdrGetDllHandle': 0x170017710, 'LdrLoadDll': 0x170018230,
                     'NtProtectVirtualMemory': 0x17000f690, 'NtOpenFile': 0x17000f2f0,
                     'NtReadFile': 0x17000ed50, 'NtClose': 0x17000ee70}},
    'e7da2a712870222942ef27a80b3bf4fa70fc8545dd1a64bdc7f2fa24a38debc3':
        {'hookRVA': 0x4d848, 'stolen': 'f645bc027526', 'caveRVA': 0x7d1f0, 'caveSize': 3600,
         'resume': 0x4d84e, 'wm': 'edi', 'load_path': -0x54,
         'payload': '3eaa5021add0c8e30e324d6b1a6392a32720f5f73596418a2086b7f8081eb1bd',
         'exports': {'LdrGetDllHandle': 0x7bc125f0, 'LdrLoadDll': 0x7bc130e0,
                     'NtProtectVirtualMemory': 0x7bc0d7a4, 'NtOpenFile': 0x7bc0d5d4,
                     'NtReadFile': 0x7bc0d304, 'NtClose': 0x7bc0d394}},
    '1b02dcf6ad9d9490870f1127a421c4c0d1471c65ec1574e1e84c05d69801ac7e':
        {'hookRVA': 0x34aae, 'stolen': '488b842410010000', 'caveRVA': 0xb5000, 'caveSize': 4096,
         'resume': 0x34ab6, 'wm': 'rbx', 'load_path': 0x98,
         'payload': '0084bba1d7399e749d918dba4f313f1dc1825d2a487f3169b469b57c5b161ca5',
         'exports': {'LdrGetDllHandle': 0x17002f4e0, 'LdrLoadDll': 0x17002ce20,
                     'NtProtectVirtualMemory': 0x170055dbc, 'NtOpenFile': 0x170055a1c,
                     'NtReadFile': 0x17005547c, 'NtClose': 0x17005559c}},
    '66b1a244a611795c59a93a9491d17f36c98cd8db9be495004a37864e0e5ed4a5':
        {'hookRVA': 0x2ede2, 'stolen': '8b4514a802', 'caveRVA': 0xa4000, 'caveSize': 4096,
         'resume': 0x2ede7, 'wm': 'esi', 'load_path': -0x3c,
         'payload': '6ff6c7289e639c4caad85c2670bfa849d9f36baa24152b6979896caede5e249b',
         'exports': {'LdrGetDllHandle': 0x7bc2a670, 'LdrLoadDll': 0x7bc28660,
                     'NtProtectVirtualMemory': 0x7bc4d800, 'NtOpenFile': 0x7bc4d630,
                     'NtReadFile': 0x7bc4d360, 'NtClose': 0x7bc4d3f0}},
    '77ca83b2e1a3a1242f9d2d8868328262b2bcfc3f59bacf8b9389ea7e797ea852':
        {'caveRVA': 0xf3185, 'caveSize': 52859,
         'sites': [{'hookRVA': 0x48738, 'stolen': '1f2003d5', 'resume': 0x4873c,
                    'wm': 'x27', 'load_path': -0x98},
                   {'hookRVA': 0xa883c, 'stolen': '1f2003d5', 'resume': 0xa8840,
                    'wm': 'x22', 'load_path': -0x88}],
         'guest': {'LdrLoadDll': 0xa0aa0, 'LdrGetDllHandle': 0xa0aa0,
                   'NtProtectVirtualMemory': 0xecf9c},
         'payload': 'b27484eaed592366ddd3a5b3c565c2dc05e8fa255fbd7e19d9d8eb619ff57c23',
         'exports': {'LdrGetDllHandle': 0x18004390c, 'LdrLoadDll': 0x180041344,
                     'NtProtectVirtualMemory': 0x180067050, 'NtOpenFile': 0x180066cb0,
                     'NtReadFile': 0x180066710, 'NtClose': 0x180066830}},
    # WineCX 11.15 (dappermint winecx-gptk runtime 4.5.125)
    '5710d16382c7a822ed8b1cba58d95fd86fe01905f039c296ca7224abff8f98e8':
        {'hookRVA': 0x52e43, 'stolen': '4883bc24f000000000', 'caveRVA': 0x82b20, 'caveSize': 1248,
         'resume': 0x52e4c, 'wm': 'rbx', 'load_path': 0xd0,
         'payload': 'fde56854b9a7a32da19babe2427d19ff6a6b83de1917fe8d32aaddd2991fc6b9',
         'exports': {'LdrGetDllHandle': 0x170017910, 'LdrLoadDll': 0x170018480,
                     'NtProtectVirtualMemory': 0x17000f640, 'NtOpenFile': 0x17000f2a0,
                     'NtReadFile': 0x17000ed00, 'NtClose': 0x17000ee20}},
    'e1b208073c804a443e64ada577899d96a5c8eaee435813e4a30e0d143bca6e3c':
        {'hookRVA': 0x4f7c0, 'stolen': 'f645b4027529', 'caveRVA': 0xb9000, 'caveSize': 4096,
         'resume': 0x4f7c6, 'wm': 'ebx', 'load_path': -0x5c,
         'payload': 'b8363acbaeedeb5f22379e0ec6394cf721c384f484b80e1f51a08fb74e41d13b',
         'exports': {'LdrGetDllHandle': 0x7bc12a60, 'LdrLoadDll': 0x7bc13600,
                     'NtProtectVirtualMemory': 0x7bc0d764, 'NtOpenFile': 0x7bc0d594,
                     'NtReadFile': 0x7bc0d2c4, 'NtClose': 0x7bc0d354}},
    # WineCX 11.17 (dappermint winecx-gptk runtime 4.7.3)
    '8b32c9f6f71b4f15fcaccb19b0f2adab9391ae73ad539cae9e136f8ee7d24128':
        {'hookRVA': 0x52de3, 'stolen': '4883bc24f000000000', 'caveRVA': 0x83360, 'caveSize': 3232,
         'resume': 0x52dec, 'wm': 'rbx', 'load_path': 0xd0,
         'payload': 'e1bbd185b19de3e23d627ae3a8bf25ed1b767bff5690102c5312a5ed3813e736',
         'exports': {'LdrGetDllHandle': 0x170017950, 'LdrLoadDll': 0x1700184c0,
                     'NtProtectVirtualMemory': 0x17000f690, 'NtOpenFile': 0x17000f2f0,
                     'NtReadFile': 0x17000ed50, 'NtClose': 0x17000ee70}},
    'cc8a9035cea0e26c5d333ef220f1becefc27ae44d2cdcdaea3278e8739d26fd9':
        {'hookRVA': 0x4f880, 'stolen': 'f645b4027529', 'caveRVA': 0x808a0, 'caveSize': 1888,
         'resume': 0x4f886, 'wm': 'ebx', 'load_path': -0x5c,
         'payload': '085df281ffe81c2803f44dd30df885248e5510c8560f0f20a5ae36e8446f7559',
         'exports': {'LdrGetDllHandle': 0x7bc12aa0, 'LdrLoadDll': 0x7bc13640,
                     'NtProtectVirtualMemory': 0x7bc0d7a4, 'NtOpenFile': 0x7bc0d5d4,
                     'NtReadFile': 0x7bc0d304, 'NtClose': 0x7bc0d394}},
    'f489347e59d4e8b43c2b0d2abbff9ee31e2059d45fd75fc04e2f4c0d8b04464a':
        {'hookRVA': 0x51f15, 'stolen': '4883bc24f000000000', 'caveRVA': 0x814a0, 'caveSize': 2912,
         'resume': 0x51f1e, 'wm': 'rsi', 'load_path': 0xd0,
         'payload': '971c9c8c0f5a9fc7338fb5012a88f8a5297924e48cadb0aa0fa827cce0984a6e',
         'exports': {'LdrGetDllHandle': 0x170017710, 'LdrLoadDll': 0x170018230,
                     'NtProtectVirtualMemory': 0x17000f690, 'NtOpenFile': 0x17000f2f0,
                     'NtReadFile': 0x17000ed50, 'NtClose': 0x17000ee70}},
    '5249b95eea6df765257b2e5212831f511d8f66134abe3c231b8e73d8f5b4707e':
        {'hookRVA': 0x4d6c8, 'stolen': 'f645bc027526', 'caveRVA': 0x7d070, 'caveSize': 3984,
         'resume': 0x4d6ce, 'wm': 'edi', 'load_path': -0x54,
         'payload': '693d6b8ac801c5697dc7d86aeb4f23fbfb1fd08bb3f949ad3e4b2311cd28348a',
         'exports': {'LdrGetDllHandle': 0x7bc125f0, 'LdrLoadDll': 0x7bc130e0,
                     'NtProtectVirtualMemory': 0x7bc0d7a4, 'NtOpenFile': 0x7bc0d5d4,
                     'NtReadFile': 0x7bc0d304, 'NtClose': 0x7bc0d394}},
    '3d24426735defd222fd9518b094b738dc1c12afd13efc41a855013ed0f825129':
        {'hookRVA': 0x3499e, 'stolen': '488b842410010000', 'caveRVA': 0x79ba4, 'caveSize': 1116,
         'resume': 0x349a6, 'wm': 'rbx', 'load_path': 0x98,
         'payload': 'd3b922ad4eae11d9a95cdab1276546af08bd3b28e041427ea0ebc557b094ad32',
         'exports': {'LdrGetDllHandle': 0x17002f3d0, 'LdrLoadDll': 0x17002ce20,
                     'NtProtectVirtualMemory': 0x170055cac, 'NtOpenFile': 0x17005590c,
                     'NtReadFile': 0x17005536c, 'NtClose': 0x17005548c}},
    '3ee764335e50709285361e2542731385f0b06e593a76aa84a3c328c278164c4f':
        {'hookRVA': 0x2ecf2, 'stolen': '8b4514a802', 'caveRVA': 0xa4000, 'caveSize': 4096,
         'resume': 0x2ecf7, 'wm': 'esi', 'load_path': -0x3c,
         'payload': 'e0b3a73bb287ecdebe7a9516a732b60e8de95fa0a756ae5ea4c5bd46e4a807c2',
         'exports': {'LdrGetDllHandle': 0x7bc2a580, 'LdrLoadDll': 0x7bc28660,
                     'NtProtectVirtualMemory': 0x7bc4d710, 'NtOpenFile': 0x7bc4d540,
                     'NtReadFile': 0x7bc4d270, 'NtClose': 0x7bc4d300}},
    'a6678f9d0818e1cdb325e1ce8a07a540433f544b6f756c52a6ab1cfd3f632408':
        {'caveRVA': 0xf3185, 'caveSize': 52859,
         'sites': [{'hookRVA': 0x48644, 'stolen': '1f2003d5', 'resume': 0x48648,
                    'wm': 'x27', 'load_path': -0x98},
                   {'hookRVA': 0xa8734, 'stolen': '1f2003d5', 'resume': 0xa8738,
                    'wm': 'x22', 'load_path': -0x88}],
         'guest': {'LdrLoadDll': 0xa0aa0, 'LdrGetDllHandle': 0xa0aa0,
                   'NtProtectVirtualMemory': 0xece9c},
         'payload': '8a6fe80587815393059cb2cecfdc542b666c158e147560875ff19f37221726d2',
         'exports': {'LdrGetDllHandle': 0x180043818, 'LdrLoadDll': 0x180041344,
                     'NtProtectVirtualMemory': 0x180066f60, 'NtOpenFile': 0x180066bc0,
                     'NtReadFile': 0x180066620, 'NtClose': 0x180066740}},
    # WineHQ 11.15 (wine-devel-11.15-osx64.tar.xz)
    # CEILING: the shipped x86_64 payload is built from detour.c before 160968c (it still jumps
    # to lsteamclient's DllMain), so build.sh's fresh 832-byte payload (dc4d86de...) differs.
    # Rebuilding changes WineHQ game behaviour; do it with a WineHQ x86_64 game test.
    '682181234a55f5b7eed5b2ffa691fbdef1b488734337ef67ea7b5ce17adf43a2':
        {'hookRVA': 0x3512c, 'stolen': '488b8590000000', 'caveRVA': 0xb3000, 'caveSize': 4096,
         'resume': 0x35133, 'wm': 'r14', 'load_path': 0x50,
         'payload': 'd394a6b7f4c55e2bb8b99aeb51cd4555527f8e10fa49339e95a8156486c5e2e5',
         'exports': {'LdrGetDllHandle': 0x17002fa80, 'LdrLoadDll': 0x17002d4e0,
                     'NtProtectVirtualMemory': 0x170055944, 'NtOpenFile': 0x1700555a4,
                     'NtReadFile': 0x170055004, 'NtClose': 0x170055124}},
    '49396e7ad804a5345b1b968d02fdb6697ddbb7428e61e20e62806c50c37589d1':
        {'hookRVA': 0x2edcd, 'stolen': '8b4514a802', 'caveRVA': 0x6a075, 'caveSize': 3979,
         'resume': 0x2edd2, 'wm': 'edi', 'load_path': -0x3c,
         'payload': '527431a3a74e9dff7bc3582277ddfa7b44bcac6fba285c028fd2c94fd9202418',
         'exports': {'LdrGetDllHandle': 0x7bc2a670, 'LdrLoadDll': 0x7bc28800,
                     'NtProtectVirtualMemory': 0x7bc4c874, 'NtOpenFile': 0x7bc4c6a4,
                     'NtReadFile': 0x7bc4c3d4, 'NtClose': 0x7bc4c464}},
}
EXPORTS = ['LdrGetDllHandle', 'LdrLoadDll', 'NtProtectVirtualMemory',
           'NtOpenFile', 'NtReadFile', 'NtClose']
SECTION_NAME, SECTION_SIZE, SECTION_FLAGS = b'.npdet', 0x1000, 0x60000020
PROLOGUES = [rb'\x55\x89\xe5', rb'\x55\x8b\xec']
NOP64 = bytes.fromhex('1f2003d5')

# A byte test on a register has to be traced back to the dword that loaded it, so the two
# names have to compare equal.
SUBREG = {'al': 'eax', 'ah': 'eax', 'ax': 'eax', 'bl': 'ebx', 'bh': 'ebx', 'bx': 'ebx',
          'cl': 'ecx', 'ch': 'ecx', 'cx': 'ecx', 'dl': 'edx', 'dh': 'edx', 'dx': 'edx',
          'si': 'esi', 'di': 'edi', 'bp': 'ebp', 'sp': 'esp'}


class PE:
    def __init__(self, path):
        self.path = path
        self.d = open(path, 'rb').read()
        e = struct.unpack_from('<I', self.d, 0x3c)[0]
        self.machine = struct.unpack_from('<H', self.d, e + 4)[0]
        nsec = struct.unpack_from('<H', self.d, e + 6)[0]
        optsz = struct.unpack_from('<H', self.d, e + 20)[0]
        self.opt = e + 24
        self.magic = struct.unpack_from('<H', self.d, self.opt)[0]
        wide = self.magic == 0x20b
        self.imagebase = (struct.unpack_from('<Q', self.d, self.opt + 24)[0] if wide
                          else struct.unpack_from('<I', self.d, self.opt + 28)[0])
        self.secs = []
        for i in range(nsec):
            o = e + 24 + optsz + i * 40
            name = self.d[o:o + 8].rstrip(b'\0').decode('latin1')
            vsize, vrva, rsize, roff = struct.unpack_from('<IIII', self.d, o + 8)
            if roff:
                self.secs.append((name, vrva, vsize, roff, rsize))
        self.dirs = self.opt + (112 if wide else 96)
        self.table_end = e + 24 + optsz + nsec * 40
        self.sect_align, self.file_align = struct.unpack_from('<II', self.d, self.opt + 32)
        self.size_of_image, self.size_of_headers = struct.unpack_from('<II', self.d, self.opt + 56)

    def sec(self, prefix):
        for s in self.secs:
            if s[0].startswith(prefix):
                return s
        raise SystemExit(f"{self.path}: no {prefix} section")

    def off(self, rva):
        for _, vrva, vsize, roff, rsize in self.secs:
            if vrva <= rva < vrva + max(vsize, rsize):
                return roff + (rva - vrva)
        raise SystemExit(f"{self.path}: rva {rva:#x} not mapped")

    def text(self):
        _, vrva, _, roff, rsize = self.sec('.text')
        return vrva, self.d[roff:roff + rsize]

    def cs(self):
        if self.machine == 0xaa64:
            md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
        else:
            md = capstone.Cs(capstone.CS_ARCH_X86,
                             capstone.CS_MODE_64 if self.machine == 0x8664 else capstone.CS_MODE_32)
        md.detail = True
        return md

    def pdata_starts(self):
        """Function entry RVAs from the exception directory, ascending."""
        # aarch64 RUNTIME_FUNCTION is 8 bytes and its length is either packed into the second
        # word or parked in .xdata, so bounds come from the next entry
        _, _, _, proff, prsize = self.sec('.pdata')
        stride = 8 if self.machine == 0xaa64 else 12
        out = {struct.unpack_from('<I', self.d, o)[0] for o in range(proff, proff + prsize, stride)}
        return sorted(out - {0})

    def exports(self):
        edir = struct.unpack_from('<I', self.d, self.dirs)[0]
        o = self.off(edir)
        nnames = struct.unpack_from('<I', self.d, o + 0x18)[0]
        afun, anam, aord = struct.unpack_from('<III', self.d, o + 0x1c)
        fo, no, oo = self.off(afun), self.off(anam), self.off(aord)
        out = {}
        for i in range(nnames):
            nrva = struct.unpack_from('<I', self.d, no + 4 * i)[0]
            ordn = struct.unpack_from('<H', self.d, oo + 2 * i)[0]
            frva = struct.unpack_from('<I', self.d, fo + 4 * ordn)[0]
            s = self.off(nrva)
            out[self.d[s:self.d.index(b'\0', s)].decode('latin1')] = frva
        return out

    def cave(self):
        # PE sections are padded out to the file alignment, so there's dead space
        # at the end that the loader maps but nothing touches. Detour goes there.
        _, vrva, vsize, roff, rsize = self.sec('.text')
        end = vrva + vsize
        return {'caveRVA': end, 'caveSize': (vrva + rsize) - end, 'fill': self.d[roff + vsize],
                'placement': 'padding'}

    def appended(self):
        # The section is mapped at SizeOfImage, and its raw data goes after everything else in
        # the file, the certificate included.
        if self.table_end + 40 > self.size_of_headers or any(self.d[self.table_end:self.table_end + 40]):
            raise SystemExit(f"{self.path}: no free section header slot after the table")
        raw = (len(self.d) + self.file_align - 1) & ~(self.file_align - 1)
        return {'caveRVA': self.size_of_image, 'caveSize': SECTION_SIZE, 'fill': 0,
                'placement': 'section', 'rawOffset': raw}

    def string_refs(self, name):
        """RVAs of instructions referencing a .rdata C string, however the arch addresses it."""
        _, rvrva, _, rroff, rrsize = self.sec('.rdata')
        k = self.d[rroff:rroff + rrsize].find(name.encode() + b'\0')
        if k == -1:
            raise SystemExit(f"{self.path}: no {name} string; not a traced wine build")
        srva = rvrva + k
        tvrva, text = self.text()
        if self.machine == 0x14c:
            # No EIP-relative addressing, so the absolute VA appears as a literal.
            pat = re.escape(struct.pack('<I', self.imagebase + srva))
            return srva, [tvrva + m.start() for m in re.finditer(pat, text)]
        hits = []
        for i in self.cs().disasm(text, tvrva):
            for op in i.operands:
                if op.type == X86.X86_OP_MEM and op.mem.base == X86.X86_REG_RIP:
                    if i.address + i.size + op.mem.disp == srva:
                        hits.append(i.address)
        return srva, hits

    def func_start(self, before):
        """Nearest frame-pointer prologue at or before an address."""
        tvrva, text = self.text()
        best = None
        for pat in PROLOGUES:
            for m in re.finditer(pat, text[:before - tvrva]):
                if best is None or m.start() > best:
                    best = m.start()
        if best is None:
            raise SystemExit(f"{self.path}: no prologue before {before:#x}")
        return tvrva + best


def steal(insns, k, need=5):
    """Whole instructions from insns[k] totalling at least `need` bytes."""
    taken, total = [], 0
    while total < need:
        taken.append(insns[k + len(taken)])
        total += taken[-1].size
    return taken, total


def window(insns):
    """What wmguard.refuse_writes needs from each capstone instruction."""
    return [(i.address, f"{i.mnemonic} {i.op_str}".strip(), i.mnemonic,
             [i.reg_name(r) for r in i.regs_access()[1]]) for i in insns]


def resolve_amd64(pe):
    md = pe.cs()
    tvrva, text = pe.text()
    insns = list(md.disasm(text, tvrva))

    _, pvrva, pvsize, proff, _ = pe.sec('.pdata')
    funcs = []
    for o in range(proff, proff + pvsize, 12):
        begin, end, _ = struct.unpack_from('<III', pe.d, o)
        if begin:
            funcs.append((begin, end))

    owner = {}
    for name in ('build_module', 'alloc_module'):
        _, refs = pe.string_refs(name)
        for r in refs:
            for begin, end in funcs:
                if begin <= r < end:
                    owner.setdefault(name, (begin, end))
    bm = owner['build_module']
    am = owner['alloc_module'][0]

    body = [i for i in insns if bm[0] <= i.address < bm[1]]
    calls = [k for k, i in enumerate(body) if i.mnemonic == 'call' and i.op_str == hex(am)]
    if len(calls) != 1:
        raise SystemExit(f"{pe.path}: {len(calls)} alloc_module calls in build_module, want 1")

    k, wm, wm_k = calls[0] + 1, None, None
    while True:
        i = body[k]
        if i.mnemonic == 'test' and i.op_str == 'rax, rax':
            k += 1
        elif i.mnemonic == 'mov' and i.op_str.endswith(', rax'):
            wm, wm_k = i.op_str.split(',')[0].strip(), k
            k += 1
        elif i.mnemonic in ('je', 'jz'):
            k += 1
        else:
            break
    hook = body[k]
    refuse_unsafe(pe.path, 'x86_64', wm)
    refuse_writes(pe.path, 'x86_64', wm, window(body[wm_k + 1:k]),
                  f"between the move at {body[wm_k].address:#x} and the hook at {hook.address:#x}")
    slot = amd64_load_path(pe, body, hook.address)
    return {'build_module': bm, 'alloc_module': am, 'wm': wm, 'load_path': slot,
            'hookRVA': hook.address, 'stolen': hook.bytes.hex(), 'insn': f"{hook.mnemonic} {hook.op_str}"}


def amd64_load_path(pe, body, hook):
    """Frame slot holding the load_path argument, read as [rsp+N] at the hook."""
    # Neither build keeps the argument in rcx. One spills it to the stack right away,
    # the other stashes it in a callee-saved register and reuses that a few instructions
    # later.
    # WineHQ builds spill it rbp-relative instead, with rbp pinned to rsp+N by the
    # prologue, so the slot is translated back to rsp.
    src, slot, stored_at, rbp_off = 'rcx', None, None, None
    for i in body:
        if i.address >= hook:
            break
        m = re.fullmatch(r'rbp, \[rsp \+ (0x[0-9a-f]+)\]', i.op_str)
        if i.mnemonic == 'lea' and m:
            rbp_off = int(m.group(1), 16)
            continue
        if i.mnemonic != 'mov' or ',' not in i.op_str:
            continue
        dst, rhs = (x.strip() for x in i.op_str.split(',', 1))
        if rhs != src:
            continue
        if dst.startswith('qword ptr [rsp'):
            slot = 0 if '+' not in dst else int(dst.split('+')[1].strip().rstrip(']'), 16)
            stored_at = i.address
            break
        m = re.fullmatch(r'qword ptr \[rbp(?: ([+-]) (0x[0-9a-f]+))?\]', dst)
        if m and rbp_off is not None:
            disp = int(m.group(2), 16) * (-1 if m.group(1) == '-' else 1) if m.group(2) else 0
            slot = rbp_off + disp
            stored_at = i.address
            break
        if re.fullmatch(r'r[a-z0-9]+', dst):
            src = dst
    if slot is None:
        raise SystemExit(f"{pe.path}: load_path never reaches the frame in build_module")

    # The shim reads the slot off rsp, so anything moving rsp in between would shift it, and
    # a second write to it would mean the slot is reused for something else.
    for i in body:
        if not stored_at < i.address < hook:
            continue
        if i.mnemonic in ('push', 'pop') or (i.mnemonic in ('sub', 'add') and i.op_str.startswith('rsp,')):
            raise SystemExit(f"{pe.path}: rsp moves at {i.address:#x}, load_path slot not rsp-stable")
        aliases = [f'qword ptr [rsp + {slot:#x}],']
        if rbp_off is not None:
            d = slot - rbp_off
            aliases.append(f'qword ptr [rbp {"-" if d < 0 else "+"} {abs(d):#x}],' if d else 'qword ptr [rbp],')
        if i.mnemonic == 'mov' and any(i.op_str.startswith(a) for a in aliases):
            raise SystemExit(f"{pe.path}: load_path slot rewritten at {i.address:#x}")
    return slot


def resolve_i386(pe):
    md = pe.cs()
    tvrva, _ = pe.text()
    _, refs = pe.string_refs('build_module')
    start = pe.func_start(min(refs))
    body = list(md.disasm(pe.d[pe.off(start):pe.off(start) + 0x1400], start))

    # LDR_DATA_TABLE_ENTRY.Flags is at +0x34, so byte 3 of that field is at +0x37.
    # The fixup_imports gate tests bit 0 of that byte, and the register being
    # dereferenced is the MODREF.
    anchor = None
    for k, i in enumerate(body):
        if i.mnemonic == 'test' and re.match(r'^byte ptr \[e\w\w \+ 0x37\], 1$', i.op_str):
            anchor = k
            break
    if anchor is None:
        raise SystemExit(f"{pe.path}: no MODREF flag test in build_module")
    wm = re.search(r'\[(e\w\w) \+ 0x37\]', body[anchor].op_str).group(1)

    # The module flags are tested just above, with bit 2 in Wine 11.15 and bit 1 in 11.0.
    # Either the value is still in memory or the compiler loaded it first, in which case that
    # load starts the hook.
    gate = None
    for k in range(anchor - 1, max(anchor - 24, 0), -1):
        i = body[k]
        if i.mnemonic == 'test' and i.operands and i.operands[-1].type == X86.X86_OP_IMM \
                and i.operands[-1].imm in (1, 2):
            gate = k
            break
    if gate is None:
        raise SystemExit(f"{pe.path}: no module-flags gate above the MODREF flag test")
    # If the test uses a register, the flags were already loaded before the hook site.
    # Stealing just the test wouldn't work, the detour would replay a read from a
    # register it never set up....
    hook_k = gate
    tested = body[gate].operands[0]
    if tested.type == X86.X86_OP_REG:
        want = SUBREG.get(body[gate].reg_name(tested.reg), body[gate].reg_name(tested.reg))
        for k in range(gate - 1, max(gate - 8, -1), -1):
            i = body[k]
            if i.mnemonic != 'mov' or i.operands[0].type != X86.X86_OP_REG:
                continue
            if SUBREG.get(i.reg_name(i.operands[0].reg), i.reg_name(i.operands[0].reg)) == want:
                hook_k = k
                break
        else:
            raise SystemExit(f"{pe.path}: {want} tested at {body[gate].address:#x} with no load above")
    # build_module's flags live in a frame slot. The gate either reads the slot
    # directly or loads it into a register first. Whichever instruction has the
    # memory operand tells us which slot it is.
    holder = body[gate] if tested.type != X86.X86_OP_REG else body[hook_k]
    mem = [o for o in holder.operands if o.type == X86.X86_OP_MEM]
    if len(mem) != 1:
        raise SystemExit(f"{pe.path}: {holder.address:#x} does not read the flags from memory")
    flags_slot = mem[0].mem.disp

    taken, total = steal(body, hook_k)
    # The shim reads wm at the hook, but it is found at the MODREF test below it.
    refuse_unsafe(pe.path, 'i386', wm)
    refuse_writes(pe.path, 'i386', wm, window(body[hook_k:anchor]),
                  f"between the hook at {body[hook_k].address:#x} and the MODREF test at "
                  f"{body[anchor].address:#x}")

    jk = None
    for k in range(gate + 1, min(gate + 8, len(body))):
        if body[k].mnemonic in ('jne', 'jnz'):
            jk = k
            break
        if X86.X86_REG_EFLAGS in body[k].regs_access()[1]:
            break
    if jk is None:
        raise SystemExit(f"{pe.path}: no branch on the module-flags gate at {body[gate].address:#x}")
    skip = body[jk].operands[0].imm
    stole_branch = taken[-1].address == body[jk].address

    load_path = None
    for i in body[anchor:anchor + 12]:
        if i.mnemonic == 'mov' and i.op_str.startswith('edx, dword ptr [ebp'):
            m = re.search(r'ebp ([-+]) (0x[0-9a-f]+)', i.op_str)
            load_path = int(m.group(2), 16) * (-1 if m.group(1) == '-' else 1)
        if i.mnemonic == 'call':
            break
    return {'build_module': (start, None), 'wm': wm, 'hookRVA': taken[0].address,
            'stolen': b''.join(i.bytes for i in taken).hex(), 'stolen_len': total,
            'insn': ' ; '.join(f"{i.mnemonic} {i.op_str}" for i in taken),
            'load_path': load_path, 'skip': skip, 'stole_branch': stole_branch,
            'stolen_head': b''.join(i.bytes for i in (taken[:-1] if stole_branch else taken)).hex(),
            'flags_slot': flags_slot, 'flags_bit': body[gate].operands[-1].imm}


def aarch64_walk(md, text, tv):

    off = 0
    while off < len(text):
        last = None
        for i in md.disasm(text[off:], tv + off):
            last = i
            yield i
        off = (last.address + last.size - tv + 4) if last else off + 4


def aarch64_literal_refs(pe, names):
    _, rvrva, _, rroff, rrsize = pe.sec('.rdata')
    blob = pe.d[rroff:rroff + rrsize]
    want = {}
    for name in names:
        pat = name.encode() + b'\0'
        k = blob.find(pat)
        while k != -1:
            if k == 0 or blob[k - 1] == 0:
                want[rvrva + k] = name
            k = blob.find(pat, k + 1)
    tv, text = pe.text()
    out, pages = {}, {}
    for i in aarch64_walk(pe.cs(), text, tv):
        if i.mnemonic == 'adrp':
            pages[i.operands[0].reg] = i.operands[1].imm
        elif i.mnemonic == 'add' and len(i.operands) == 3 \
                and i.operands[2].type == A64.ARM64_OP_IMM:
            page = pages.get(i.operands[1].reg)
            srva = None if page is None else page + i.operands[2].imm
            if srva in want:
                out.setdefault(srva, (want[srva], []))[1].append(i.address)
    return out


def aarch64_body(pe, md, lo, hi):
    tv, text = pe.text()
    lo, hi = max(tv, lo) & ~3, min(tv + len(text), hi)
    return list(aarch64_walk(md, text[lo - tv:hi - tv], lo))


def aarch64_open(pe, md, inside):
    """Prologue RVA of the function containing `inside`."""
    body = aarch64_body(pe, md, inside - 0x4000, inside + 4)
    for k in range(len(body) - 1, -1, -1):
        i = body[k]
        if i.mnemonic == 'sub' and i.op_str.startswith('sp, sp, #') \
                and any(n.mnemonic == 'add' and n.op_str.startswith('x29, sp, #')
                        for n in body[k + 1:k + 13]):
            return i.address
    raise SystemExit(f"{pe.path}: no frame prologue above {inside:#x}")


def aarch64_hook(pe, md, ref, allocs):
    start = aarch64_open(pe, md, ref)
    body = aarch64_body(pe, md, start, start + 0x2000)

    def name(i, n):
        return i.reg_name(i.operands[n].reg)

    call = next((k for k, i in enumerate(body)
                 if i.mnemonic == 'bl' and i.operands[0].imm in allocs), None)
    if call is None:
        raise SystemExit(f"{pe.path}: build_module at {start:#x} never calls alloc_module")
    if body[call + 1].mnemonic != 'cbz' or name(body[call + 1], 0) != 'x0':
        raise SystemExit(f"{pe.path}: alloc_module at {body[call].address:#x} is not null-checked")
    join = next((i.operands[1].imm for i in body[call + 2:call + 10] if i.mnemonic == 'cbz'), None)
    if join is None:
        raise SystemExit(f"{pe.path}: no id test below alloc_module at {body[call].address:#x}")
    k = next((k for k, i in enumerate(body) if i.address == join), None)
    if k is None or body[k].bytes != NOP64:
        raise SystemExit(f"{pe.path}: the id block from {body[call].address:#x} joins on "
                         f"{join:#x}, which is not a nop")

    # The shim takes the MODREF from x0 rather than from whichever register this copy moved it
    # into, which only holds while nothing on the way to the join writes x0.
    for i in body[call + 1:k]:
        if 'x0' in {i.reg_name(w).replace('w', 'x', 1) for w in i.regs_access()[1]}:
            raise SystemExit(f"{pe.path}: x0 no longer the MODREF at {i.address:#x}")
    wm = next((name(i, 0) for i in body[call + 1:k] if i.mnemonic == 'mov'
               and i.operands[1].type == A64.ARM64_OP_REG and name(i, 1) == 'x0'), None)
    if wm is None or not any(i.mnemonic == 'add' and i.op_str.endswith('#0x118')
                             and name(i, 1) == wm for i in body[call:k]):
        raise SystemExit(f"{pe.path}: nothing below {body[call].address:#x} treats the result "
                         f"as a MODREF")

    def spill(src):
        """The frame slot build_module parks an incoming argument in."""
        for i in body[:24]:
            if i.mnemonic == 'stur' and name(i, 0) == src \
                    and i.operands[1].type == A64.ARM64_OP_MEM \
                    and i.reg_name(i.operands[1].mem.base) == 'fp':
                return i.operands[1].mem.disp
        raise SystemExit(f"{pe.path}: build_module at {start:#x} never spills {src}")

    return {'build_module': start, 'hookRVA': join, 'stolen': NOP64.hex(), 'stolen_len': 4,
            'insn': f"{body[k].mnemonic} {body[k].op_str}".strip(), 'resume': join + 4,
            'wm': wm, 'load_path': spill('x0'), 'flags_slot': spill('w5')}


def aarch64_guest_syscall(pe, md, native):
    num = next((int(i.op_str.split('#')[1], 0)
                for i in aarch64_body(pe, md, native, native + 8)
                if i.mnemonic == 'mov' and i.op_str.startswith('x8, #')), None)
    if num is None:
        raise SystemExit(f"{pe.path}: no syscall number at {native:#x}")
    tv, text = pe.text()
    pat = b'\x4c\x8b\xd1\xb8' + num.to_bytes(4, 'little')    # mov r10, rcx ; mov eax, num
    k = text.find(pat)
    if k < 0 or text.find(pat, k + 1) >= 0:
        raise SystemExit(f"{pe.path}: guest stub for syscall {num:#x} is "
                         f"{'missing' if k < 0 else 'not unique'}")
    stub = tv + k
    body = list(aarch64_walk(md, text, tv))
    found = set()
    for n, i in enumerate(body[:-1]):
        nx = body[n + 1]
        if i.mnemonic != 'adrp' or not i.op_str.startswith('x11, '):
            continue
        if nx.mnemonic != 'add' or not nx.op_str.startswith('x11, x11, #'):
            continue
        if int(i.op_str.split('#')[1], 0) + int(nx.op_str.split('#')[1], 0) != stub:
            continue
        entry = i.address - 8
        head = aarch64_body(pe, md, entry, entry + 4)
        if head and head[0].mnemonic == 'str' and head[0].op_str.startswith('x30, [sp, #-'):
            found.add(entry)
    if not found:
        raise SystemExit(f"{pe.path}: no guest thunk tail branching to {stub:#x}")
    return found


def aarch64_twin(pe, md, native, span):
    """RVA of the copy of the function at `native` that was compiled into `span`.

    Both copies come from the same source, so the mnemonic sequence is identical even though
    register numbers and call targets are not.
    """
    want = [i.mnemonic for i in aarch64_body(pe, md, native, native + 0x100)]
    tv, text = pe.text()
    lo, hi = span
    opener = text[native - tv:native - tv + 4]
    hits, k = [], text.find(opener, lo - tv, hi - tv)
    while k != -1:
        f = tv + k
        if f != native and [i.mnemonic for i in aarch64_body(pe, md, f, f + 0x100)] == want:
            hits.append(f)
        k = text.find(opener, k + 4, hi - tv)
    if len(hits) != 1:
        raise SystemExit(f"{pe.path}: {len(hits)} twins of {native:#x} in {lo:#x}..{hi:#x}")
    return hits[0]


def resolve_aarch64(pe):
    md = pe.cs()
    refs = aarch64_literal_refs(pe, ('build_module', 'alloc_module'))
    allocs = {aarch64_open(pe, md, a[0]) for n, a in refs.values() if n == 'alloc_module'}
    sites = sorted((aarch64_hook(pe, md, a[0], allocs)
                    for n, a in refs.values() if n == 'build_module'),
                   key=lambda s: s['hookRVA'])
    if len(sites) != 2:
        raise SystemExit(f"{pe.path}: {len(sites)} build_module copies, shim64.S hooks two")

    ex = pe.exports()
    thunks = aarch64_guest_syscall(pe, md, ex['NtProtectVirtualMemory'])

    def calls(s):
        bm = s['build_module']
        return {int(i.op_str.lstrip('#'), 0)
                for i in aarch64_body(pe, md, bm, bm + 0x1000) if i.mnemonic == 'bl'}

    reach = [calls(s) for s in sites]
    guest = [(s, c & thunks) for s, c in zip(sites, reach)
             if c & thunks and ex['NtProtectVirtualMemory'] not in c]
    native = [s for s, c in zip(sites, reach)
              if ex['NtProtectVirtualMemory'] in c and not c & thunks]
    if len(guest) != 1 or len(native) != 1 or guest[0][0] is native[0]:
        raise SystemExit(f"{pe.path}: cannot tell the two build_module copies apart by their "
                         f"route to NtProtectVirtualMemory")
    if len(guest[0][1]) != 1:
        raise SystemExit(f"{pe.path}: guest build_module reaches {len(guest[0][1])} protect thunks")
    thunk = guest[0][1].pop()

    bm = guest[0][0]['build_module']
    tv, text = pe.text()
    span = (max(tv, bm - 0x10000), min(tv + len(text), bm + 0x10000))
    # A detour running under the guest loader has to stay inside it, obviously
    load = aarch64_twin(pe, md, ex['LdrLoadDll'], span)
    return dict(sites[0], sites=sites,
                guest={'LdrLoadDll': load, 'LdrGetDllHandle': load,
                       'NtProtectVirtualMemory': thunk})


def resolve(path):
    pe = PE(path)
    r = (resolve_aarch64(pe) if pe.machine == 0xaa64 else
         resolve_amd64(pe) if pe.machine == 0x8664 else resolve_i386(pe))
    r.update(pe.cave())
    if r['caveSize'] < PAYLOAD[pe.machine]:
        r.update(pe.appended())
    r['machine'], r['magic'], r['imageBase'] = pe.machine, pe.magic, pe.imagebase
    ex = pe.exports()
    r['exports'] = {n: pe.imagebase + ex[n] for n in EXPORTS if n in ex}
    r['resume'] = r['hookRVA'] + len(r['stolen']) // 2
    r['sha256'] = hashlib.sha256(pe.d).hexdigest()
    return r


def report(path):
    machine = PE(path).machine
    if machine not in ARCH:
        print(f"{path}\n  machine {machine:#x} carries no detour, skipped\n")
        return True
    r = resolve(path)
    pin = PINNED.get(r['sha256'], {})
    arch = ARCH[machine]
    print(f"{path}\n  arch {arch}  machine {r['machine']:#x}  magic {r['magic']:#x}"
          f"  imageBase {r['imageBase']:#x}\n  sha256 {r['sha256']}"
          f"{'  (the pinned build, self-testing)' if pin else '  (not a pinned build)'}")
    ok = True

    def line(label, got, key=None, fmt=lambda v: f"{v:#x}", want=pin):
        nonlocal ok
        tag = ""
        if key and key in want:
            match = want[key] == got
            ok = ok and match
            tag = "  MATCH" if match else f"  MISMATCH (pinned {fmt(want[key])})"
        print(f"  {label:13} {fmt(got)}{tag}")

    sites = r.get('sites')
    pinned_sites = pin.get('sites') or []
    for n, s in enumerate(sites or [r], 1):
        want = pin
        if sites:
            want = pinned_sites[n - 1] if n <= len(pinned_sites) else {}
            print(f"  hook {n} of {len(sites)}, build_module at {s['build_module']:#x}")
        line('hookRVA', s['hookRVA'], 'hookRVA', want=want)
        print(f"  {'insn':13} {s['insn']}")
        line('stolen', s['stolen'], 'stolen', fmt=str, want=want)
        line('resume', s['resume'], 'resume', want=want)
        line('wm', s['wm'], 'wm', fmt=str, want=want)
        if s.get('load_path') is not None:
            frame = {0x8664: 'rsp', 0x14c: 'ebp', 0xaa64: 'x29'}[machine]
            slot = ((lambda v: f"{frame}+{v:#x}") if machine == 0x8664
                    else (lambda v: f"{frame}{v:+#x}"))
            line('load_path', s['load_path'], 'load_path', fmt=slot, want=want)
    line('caveRVA', r['caveRVA'], 'caveRVA')
    line('caveSize', r['caveSize'], 'caveSize', fmt=str)
    need = PAYLOAD[r['machine']]
    print(f"  {'placement':13} {r['placement']}")
    print(f"  {'cave fill':13} {r['fill']:#02x}   room {r['caveSize']} bytes, payload {need}"
          f" -> {'fits' if r['caveSize'] >= need else 'TOO SMALL'}")
    def table(items, want):
        nonlocal ok
        for n, va in items.items():
            pinned_va = want.get(n)
            tag = ""
            if pinned_va:
                match = pinned_va == va
                ok = ok and match
                tag = "  MATCH" if match else f"  MISMATCH (pinned {pinned_va:#x})"
            print(f"    {n:24} {va:#x}{tag}")

    table(r['exports'], pin.get('exports', {}))
    if r.get('guest'):
        print("  guest loader, which is what link64.ld resolves instead")
        table(r['guest'], pin.get('guest', {}))
    if pin:
        print(f"  self-test: {'all pinned values reproduced' if ok else 'FAILED'}")
    print()
    return ok if pin else True


def ntdlls(arg):
    """Every ntdll.dll under a bundle, a CrossOver root, or a wine directory."""
    p = pathlib.Path(arg)
    if p.is_file():
        return [str(p)]
    for root in (p / 'Contents/SharedSupport/CrossOver/lib/wine', p / 'lib/wine', p):
        archs = sorted(d for d in root.glob('*-windows') if d.is_dir())
        if not archs:
            continue
        found = []
        for d in archs:
            for name in ('ntdll.dll.notproton-orig', 'ntdll.dll'):
                if (d / name).is_file():
                    found.append(str(d / name))
                    break
        if found:
            return found
    raise SystemExit(f"{arg}: no <arch>-windows/ntdll.dll under it")


def shell_vars(path):
    """Everything build.sh and apply.py need for one ntdll, as shell assignments."""
    r = resolve(path)
    payload = (r['caveRVA'] + 15) & ~15
    room = r['caveSize'] - (payload - r['caveRVA'])
    need = PAYLOAD[r['machine']]
    if room < need:
        raise SystemExit(f"{path}: cave has {room} bytes at {payload:#x}, payload needs {need}")
    scratch = 'rsi' if r['wm'] == 'rbx' else 'rbx'
    out = {
        'NP_ARCH': ARCH[r['machine']], 'NP_MACHINE': f"{r['machine']:#x}",
        'NP_MAGIC': f"{r['magic']:#x}", 'NP_IMAGEBASE': f"{r['imageBase']:#x}",
        'NP_SHA256': r['sha256'],
        'NP_HOOK_RVA': f"{r['hookRVA']:#x}", 'NP_STOLEN': r['stolen'],
        'NP_STOLEN_BYTES': ','.join(f"0x{b:02x}" for b in bytes.fromhex(r['stolen'])),
        'NP_STOLEN_LEN': str(len(r['stolen']) // 2),
        'NP_RESUME_VA': f"{r['imageBase'] + r['resume']:#x}",
        'NP_WM': r['wm'], 'NP_SCRATCH': scratch,
        'NP_LOAD_PATH': f"{r['load_path']:#x}" if r.get('load_path') is not None else '',
        'NP_CAVE_RVA': f"{r['caveRVA']:#x}", 'NP_CAVE_SIZE': str(r['caveSize']),
        'NP_PAYLOAD_RVA': f"{payload:#x}", 'NP_PAYLOAD_VA': f"{r['imageBase'] + payload:#x}",
        'NP_CAVE_ROOM': str(room), 'NP_FILL': f"{r['fill']:#04x}",
        'NP_PLACEMENT': r['placement'],
    }
    if PINNED.get(r['sha256'], {}).get('payload'):
        out['NP_PAYLOAD_SHA256'] = PINNED[r['sha256']]['payload']
    if r.get('skip') is not None:
        out['NP_SKIP_VA'] = f"{r['imageBase'] + r['skip']:#x}"
        out['NP_STOLE_BRANCH'] = '1' if r['stole_branch'] else ''
        out['NP_STOLEN_HEAD_BYTES'] = ','.join(
            f"0x{b:02x}" for b in bytes.fromhex(r['stolen_head']))
        out['NP_FLAGS_SLOT'] = ('%#x' if r['flags_slot'] >= 0 else '-%#x') % abs(r['flags_slot'])
        out['NP_FLAGS_BIT'] = f"{r['flags_bit']:#x}"

    for n, s in enumerate(r.get('sites') or [], 1):
        out[f'NP_HOOK_RVA_{n}'] = f"{s['hookRVA']:#x}"
        out[f'NP_STOLEN_{n}'] = s['stolen']
        out[f'NP_RESUME_VA_{n}'] = f"{r['imageBase'] + s['resume']:#x}"
        out[f'NP_LOAD_PATH_{n}'] = f"{s['load_path']:#x}"
    if r.get('sites'):
        out['NP_SITES'] = str(len(r['sites']))

    for n, va in r['exports'].items():
        out['NP_' + re.sub(r'(?<!^)(?=[A-Z])', '_', n).upper()] = f"{va:#x}"
    for n, rva in (r.get('guest') or {}).items():
        out['NP_' + re.sub(r'(?<!^)(?=[A-Z])', '_', n).upper()] = f"{r['imageBase'] + rva:#x}"
    return out


if __name__ == '__main__':
    if len(sys.argv) < 2:
        raise SystemExit(f"usage: {sys.argv[0]} [--sh] <CrossOver bundle | wine dir | ntdll.dll> ...")
    if sys.argv[1] == '--sh':
        if len(sys.argv) != 3:
            raise SystemExit("--sh takes one ntdll.dll")
        for k, v in shell_vars(sys.argv[2]).items():
            print(f"{k}='{v}'")
        sys.exit(0)
    paths = [p for arg in sys.argv[1:] for p in ntdlls(arg)]
    sys.exit(0 if all([report(p) for p in paths]) else 1)
