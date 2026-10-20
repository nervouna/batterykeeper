#!/usr/bin/env python3
"""Writes App/Localizable.xcstrings from the keys the compiler extracted and the translations.

Usage: scripts/build.sh debug && scripts/make-strings.py

The keys come from the .stringsdata files of the last Debug build (SWIFT_EMIT_LOC_STRINGS), so the
catalog always holds exactly the strings the code uses. Translations live in
scripts/translations-<language>.json, keyed by the English source string. The script fails when a
key that needs a translation has none, or when a translation is no longer used.
"""

import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DATA = os.path.join(
    ROOT, "build/DerivedData/Build/Intermediates.noindex/BatteryKeeper.build/Debug/BatteryKeeper.build/Objects-normal/arm64"
)
LANGUAGES = ["zh-Hans"]
# Keys that read the same in every language.
NEUTRAL = {"", "%", "W", "°C"}


def main() -> int:
    keys = set()
    for path in glob.glob(os.path.join(DATA, "*.stringsdata")):
        with open(path, encoding="utf-8") as f:
            data = json.load(f)
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                continue
            keys.update(entry["key"] for entry in entries)
    if not keys:
        print("error: no extracted strings; run scripts/build.sh debug first", file=sys.stderr)
        return 1

    problems = []
    strings = {}
    translations = {}
    for language in LANGUAGES:
        with open(os.path.join(ROOT, f"scripts/translations-{language}.json"), encoding="utf-8") as f:
            translations[language] = json.load(f)
        for unused in sorted(set(translations[language]) - keys):
            problems.append(f"{language}: unused translation {unused!r}")

    for key in sorted(keys):
        entry = {"extractionState": "manual"}
        localizations = {}
        for language in LANGUAGES:
            value = translations[language].get(key)
            if value is None:
                if key not in NEUTRAL:
                    problems.append(f"{language}: missing translation for {key!r}")
                continue
            localizations[language] = {"stringUnit": {"state": "translated", "value": value}}
        if localizations:
            entry["localizations"] = localizations
        strings[key] = entry

    if problems:
        for problem in problems:
            print("error: " + problem, file=sys.stderr)
        return 1

    catalog = {"sourceLanguage": "en", "strings": strings, "version": "1.0"}
    with open(os.path.join(ROOT, "App/Localizable.xcstrings"), "w", encoding="utf-8") as f:
        json.dump(catalog, f, ensure_ascii=False, indent=2, sort_keys=True)
        f.write("\n")
    print(f"wrote App/Localizable.xcstrings: {len(strings)} strings")
    return 0


if __name__ == "__main__":
    sys.exit(main())
