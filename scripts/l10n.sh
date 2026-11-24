#!/bin/bash
# Проверка перевода интерфейса: какие строки из кода приложения (Sources/Mnemosyne) ещё не переведены
# в Resources/en.lproj/Localizable.strings и какие русские литералы не проходят через локализацию.
# Ключи извлекает сам компилятор (-emit-localized-strings), так что интерполяции совпадают с рантаймом.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${L10N_OUT:-.build/l10n}
rm -rf "$OUT" && mkdir -p "$OUT"
swift build -Xswiftc -emit-localized-strings -Xswiftc -emit-localized-strings-path -Xswiftc "$OUT" >/dev/null
python3 scripts/l10n_check.py "$OUT" Resources/en.lproj/Localizable.strings "$@"
