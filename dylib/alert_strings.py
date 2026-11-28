#!/usr/bin/env python3
# The run script's alert strings, taken from the app's catalogue: every entry whose comment
# starts with "Run script". The dylib writes the table beside the run script, which reads it
# when it shows an alert, so alerts follow the player's language even without the app.
#
#   alert_strings.py <Localizable.xcstrings> <out.h> <symbol>   C header for the dylib
#   alert_strings.py --table <Localizable.xcstrings> <out.tsv>  the table itself, for tests
#
# A line is "<language>\t<English>\t<translation>". %@ and %N$@ become {N}, a line break \n.
import json
import re
import sys
from pathlib import Path

LANGUAGES = ("it", "ru", "zh-Hans")
PLACEHOLDER = re.compile(r"%(?:(\d+)\$)?@")


def script_form(text: str, where: str) -> str:
    count = 0

    def number(match: re.Match) -> str:
        nonlocal count
        count += 1
        return "{" + (match[1] or str(count)) + "}"

    out = PLACEHOLDER.sub(number, text)
    if "%" in out.replace("%%", ""):
        raise ValueError(f"{where}: only %@ and %N$@ placeholders work in the run script")
    if "\t" in out or "\\" in out or "{0}" in out:
        raise ValueError(f"{where}: tabs, backslashes and {{0}} cannot go in the table")
    return out.replace("%%", "%").replace("\n", "\\n")


def table(catalog: Path) -> str:
    strings = json.loads(catalog.read_text(encoding="utf-8"))["strings"]
    lines = []
    for key in sorted(strings):
        entry = strings[key]
        if not entry.get("comment", "").startswith("Run script"):
            continue
        english = script_form(key, repr(key))
        if "\\n" in english:
            raise ValueError(f"{key!r}: an English key cannot hold a line break")
        for language in LANGUAGES:
            unit = entry.get("localizations", {}).get(language, {}).get("stringUnit", {})
            if unit.get("state") != "translated":
                continue
            value = script_form(unit["value"], f"{language} of {key!r}")
            if sorted(re.findall(r"\{\d\}", value)) != sorted(re.findall(r"\{\d\}", english)):
                raise ValueError(f"{language} of {key!r}: its placeholders differ from the English")
            lines.append(f"{language}\t{english}\t{value}\n")
    return "".join(lines)


def c_literal(text: str) -> str:
    # Octal escapes stop after three digits, so a following character can't extend one.
    out = []
    for line in text.splitlines(keepends=True):
        body = "".join(
            chr(b) if 0x20 <= b < 0x7F and b not in (0x22, 0x5C, 0x3F) else f"\\{b:03o}"
            for b in line.encode("utf-8")
        )
        out.append(f'    "{body}"')
    return "\n".join(out) if out else '    ""'


def main() -> int:
    args = sys.argv[1:]
    try:
        if len(args) == 3 and args[0] == "--table":
            Path(args[2]).write_text(table(Path(args[1])), encoding="utf-8")
            return 0
        if len(args) != 3:
            sys.stderr.write(__doc__ or "usage: alert_strings.py <catalog> <out.h> <symbol>\n")
            return 2
        catalog, dst, symbol = Path(args[0]), Path(args[1]), args[2]
        text = table(catalog)
    except (OSError, ValueError, KeyError) as error:
        sys.stderr.write(f"alert_strings.py: {error}\n")
        return 1
    guard = f"NOTPROTON_GENERATED_{symbol.upper()}_H"
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_text(
        f"// Generated from {catalog.as_posix()} by dylib/alert_strings.py. Edit that file.\n"
        f"#ifndef {guard}\n#define {guard}\n\n"
        f"static const char {symbol}[] =\n{c_literal(text)};\n\n#endif // {guard}\n",
        encoding="ascii",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
