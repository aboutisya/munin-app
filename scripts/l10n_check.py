"""Сверка ключей локализации. Аргументы: папка .stringsdata, файл перевода, [--keys путь для списка непереведённых]."""
import glob, json, os, re, sys

out_dir, strings_file = sys.argv[1], sys.argv[2]
dump = sys.argv[sys.argv.index("--keys") + 1] if "--keys" in sys.argv else None

keys = {}
for f in glob.glob(os.path.join(out_dir, "**", "*.stringsdata"), recursive=True):
    data = json.load(open(f))
    src = data.get("source", "")
    if "/Sources/Mnemosyne/" not in src:
        continue  # ядро не локализуется
    for entry in data.get("tables", {}).get("Localizable", []):
        keys.setdefault(entry["key"], f"{os.path.relpath(src)}:{entry['location']['startingLine']}")

pair = re.compile(r'^\s*"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)"\s*;\s*$')
def unescape(s): return s.encode().decode("unicode_escape").encode("latin-1").decode("utf-8")
translated = {}
for line in open(strings_file, encoding="utf-8"):
    m = pair.match(line)
    if m: translated[unescape(m.group(1))] = unescape(m.group(2))

cyr = re.compile(r"[А-Яа-яЁё]")
missing = sorted(k for k in keys if cyr.search(k) and k not in translated)
stale = sorted(k for k in translated if k not in keys)

# Русские литералы в коде приложения, которые компилятор не увидел как локализуемые.
literal = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
known = {re.sub(r"%(?:lld|@|lf|d|ld|f)", "", k) for k in keys}
loose = []
for path in glob.glob("Sources/Mnemosyne/**/*.swift", recursive=True):
    for n, line in enumerate(open(path, encoding="utf-8"), 1):
        code = line.split("//")[0] if "//" in line and '"' not in line.split("//")[0][-1:] else line
        if line.strip().startswith("///") or line.strip().startswith("//"):
            continue
        for m in literal.finditer(line):
            s = m.group(1)
            if not cyr.search(s) or "localized:" in line[:m.start()][-30:]:
                continue
            plain = re.sub(r"\\\([^)]*\)", "", s)
            if plain not in known:
                loose.append(f"{path}:{n}: {s}")

print(f"Ключей в коде: {len(keys)}, переведено: {len(translated)}")
print(f"Без перевода: {len(missing)}")
for k in missing: print(f"  {keys[k]}  {json.dumps(k, ensure_ascii=False)}")
print(f"Лишние переводы (ключа нет в коде): {len(stale)}")
for k in stale: print(f"  {json.dumps(k, ensure_ascii=False)}")
print(f"Русские литералы мимо локализации (проверьте вручную): {len(loose)}")
for l in loose: print("  " + l)
if dump:
    json.dump({k: "" for k in missing}, open(dump, "w"), ensure_ascii=False, indent=1)
