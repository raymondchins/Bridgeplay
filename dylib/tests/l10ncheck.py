import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

catalog, intermediates = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
languages = sys.argv[3:]
source_root = catalog.resolve().parents[2]

datas = []
for path in sorted(intermediates.rglob("*.stringsdata")):
    source = pathlib.Path(json.loads(path.read_text())["source"])
    if source.exists() and source.resolve().is_relative_to(source_root):
        datas.append(str(path))
if not datas:
    sys.exit(f"l10ncheck: no .stringsdata under {intermediates}, build the app first")

original = catalog.read_text()
before = json.loads(original)["strings"]
with tempfile.TemporaryDirectory() as tmp:
    synced = pathlib.Path(tmp) / catalog.name
    shutil.copyfile(catalog, synced)
    subprocess.run(["xcrun", "xcstringstool", "sync", str(synced), "--stringsdata", *datas], check=True)
    after = json.loads(synced.read_text())["strings"]

problems = []
# "new" is a deliberate placeholder: the language shows English until someone translates it
pending = []
for key in sorted(set(after) - set(before)):
    problems.append(f"not in the catalog: {key!r}")
for key, entry in sorted(after.items()):
    if key not in before:
        continue
    if entry.get("extractionState") == "stale":
        problems.append(f"no longer used: {key!r}")
    elif entry.get("shouldTranslate", True):
        localizations = entry.get("localizations", {})
        for language in languages:
            unit = localizations.get(language, {}).get("stringUnit", {})
            if unit.get("state") == "new" and unit.get("value") == key:
                pending.append(f"{language}: {key!r}")
            elif unit.get("state") != "translated" and "variations" not in localizations.get(language, {}):
                problems.append(f"no {language} translation: {key!r}")
formatted = json.dumps(json.loads(original), ensure_ascii=False, indent=2, separators=(",", " : "), sort_keys=True)
formatted = re.sub(r"^( *)(.*) : \{\}", lambda m: f"{m[1]}{m[2]} : {{\n\n{m[1]}}}", formatted, flags=re.M)
if formatted != original:
    problems.append("not in the format xcstringstool writes, so its next sync would rewrite every line")

if problems:
    print(f"l10ncheck: {len(problems)} problem(s) in {catalog}", file=sys.stderr)
    for problem in problems:
        print(f"    {problem}", file=sys.stderr)
    sys.exit(1)
print(f"l10ncheck: {len(after)} strings, all translated for {', '.join(languages)}"
      + (f" except {len(pending)} left in English for now" if pending else ""))
for item in pending:
    print(f"    still English in {item}")
