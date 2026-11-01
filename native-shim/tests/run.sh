#!/bin/sh
# Builds and runs the hid_profile unit tests with ASan and UBSan. Exits non-zero on failure.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${TMPDIR:-/tmp}/np_hid_profile_tests
clang -arch arm64 -std=c11 -D_DARWIN_C_SOURCE -g -O1 -Wall -Wextra -Werror \
    -fsanitize=address,undefined -fno-sanitize-recover=all -ftrivial-auto-var-init=pattern \
    -framework IOKit -framework CoreFoundation \
    -o "$out" "$here/../hid_profile.c" "$here/test_hid_profile.c"
"$out" "$here/fixtures"

# LeakSanitizer is not available on macOS; check leaks with the system tool instead.
if command -v leaks >/dev/null 2>&1; then
    clang -arch arm64 -std=c11 -D_DARWIN_C_SOURCE -g -O1 -Wall -Wextra -Werror \
        -framework IOKit -framework CoreFoundation \
        -o "$out.leaks" "$here/../hid_profile.c" "$here/test_hid_profile.c"
    MallocStackLogging=1 leaks --atExit -quiet -- "$out.leaks" "$here/fixtures" >"$out.leaks.log" 2>&1 \
        || { cat "$out.leaks.log"; echo "leaks found"; exit 1; }
    grep -E "leaks for|Process [0-9]+:" "$out.leaks.log" | tail -1
fi
