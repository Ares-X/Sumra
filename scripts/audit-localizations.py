#!/usr/bin/env python3
"""Check catalog integrity and list untranslated source labels without dependencies.

Usage: python3 scripts/audit-localizations.py [--json path] [--write-coverage]
The inventory covers literal L calls and the named dynamic owners below. It is a
source audit, not proof of linguistic quality or complete runtime UI coverage.
English intentionally uses source text, so its override count is not coverage.
Explicit product/format names need no translation and are excluded from coverage.
"""
import argparse
from collections import Counter
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parent.parent
STRING = r'"(?:\\.|[^"\\])*"'
ENTRY = re.compile(rf'^\s*({STRING})\s*=\s*({STRING});\s*$', re.MULTILINE)
# Product/format names are intentionally identical across interface languages.
INVARIANT = {'Sumra', 'PDF', 'Dracula', 'Gruvbox'}
PRINTF = re.compile(r'%(?:\d+\$)?[-+ #0]*(?:\d+|\*)?(?:\.(?:\d+|\*))?(?:hh|ll|[hljztL])?[@diuoxXfFeEgGaAcCsSp]')
TEMPLATE = re.compile(r'\{[A-Za-z][A-Za-z0-9]*\}')


def strings(source):
    # Swift interpolation is runtime content, not a catalog key.
    return {json.loads(value) for value in re.findall(STRING, source) if r'\(' not in value}


def source_inventory():
    literal = set()
    for path in (ROOT / 'Sources/Sumra').glob('*.swift'):
        source = path.read_text()
        for match in re.finditer(rf'\bL\(\s*({STRING})\s*\)', source):
            literal.update(strings(match[1]))
    dynamic = set()
    menus = (ROOT / 'Sources/Sumra/ReaderMenus.swift').read_text()
    # englishTitle ends before the next property; include command display names,
    # not IDs, shortcuts or execution argument strings elsewhere in this file.
    title = menus.split('private var englishTitle: String {', 1)[1]
    depth, end = 1, 0
    for end, char in enumerate(title):
        depth += (char == '{') - (char == '}')
        if depth == 0:
            break
    dynamic.update(strings(' '.join(re.findall(rf'\breturn\s+({STRING})', title[:end]))))
    zoom = (ROOT / 'Sources/SumraCore/ReadingZoom.swift').read_text()
    fit = re.search(r'fitTitles\s*=\s*\[([^\]]+)\]', zoom)[1]
    for match in re.finditer(rf'{STRING}\s*:\s*({STRING})', fit):
        dynamic.update(strings(match[1]))
    themes = (ROOT / 'Sources/Sumra/ReaderTheme.swift').read_text().split('private static let legacy:', 1)[0]
    for match in re.finditer(rf'\bname:\s*({STRING})', themes):
        dynamic.update(strings(match[1]))
    dynamic.update({'Light', 'Dark'})  # AppIconStyle.label
    # Inline localized choice lists, including map(L) and arrays used by grid rows.
    for filename, variable in [('ReaderAids.swift', 'names')]:
        source = (ROOT / 'Sources/Sumra' / filename).read_text()
        for match in re.finditer(rf'let {variable}\s*=\s*\[([^\]]+)\]', source):
            dynamic.update(strings(match[1]))
    for path in (ROOT / 'Sources/Sumra').glob('*.swift'):
        for match in re.finditer(r'\[([^\[\]]+)\]\.map\(L\)', path.read_text()):
            dynamic.update(strings(match[1]))
    return literal, dynamic


def placeholders(value):
    # %% is a literal percent; "% Contents" is a palette section prefix.
    if value.startswith('% '):
        value = value[2:]
    return Counter(PRINTF.findall(value.replace('%%', '')))


def audit():
    literal, dynamic = source_inventory()
    source_keys = literal | dynamic
    inventory = source_keys - INVARIANT
    errors, catalogs = [], {}
    for path in sorted((ROOT / 'Sources/Sumra/Resources/Localizations').glob('*.lproj/Localizable.strings')):
        locale = path.parent.stem
        source = path.read_text()
        entries = {}
        for match in ENTRY.finditer(source):
            key, value = json.loads(match[1]), json.loads(match[2])
            if key in entries:
                errors.append(f'{locale}: duplicate key {key!r}')
            if not value.strip():
                errors.append(f'{locale}: empty translation {key!r}')
            if placeholders(key) != placeholders(value):
                errors.append(f'{locale}: format placeholders differ for {key!r}')
            if key.count('%%') != value.count('%%'):
                errors.append(f'{locale}: literal percent escapes differ for {key!r}')
            if Counter(TEMPLATE.findall(key)) != Counter(TEMPLATE.findall(value)):
                errors.append(f'{locale}: command template placeholders differ for {key!r}')
            entries[key] = value
        # Anything beyond comments and parsed entries is a catalog syntax error.
        remainder = ENTRY.sub('', re.sub(r'/\*.*?\*/', '', source, flags=re.DOTALL))
        if remainder.strip():
            errors.append(f'{locale}: unparsed catalog content')
        catalogs[locale] = {'entries': len(entries), 'sourceLanguage': locale == 'en'}
        if locale != 'en':
            catalogs[locale].update({
                'literalPresent': len(literal & entries.keys()),
                'inventoryPresent': len(inventory & entries.keys()),
                'missing': sorted(inventory - entries.keys()),
            })
    return {'scope': 'literal L calls plus explicit dynamic command, fit, theme, icon and choice-list owners; runtime text not inventoried',
            'literalKeys': sorted(literal), 'dynamicKeys': sorted(dynamic),
            'sourceKeys': sorted(source_keys), 'invariantKeys': sorted(source_keys & INVARIANT),
            'inventoryKeys': sorted(inventory), 'catalogs': catalogs, 'errors': errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--json', type=Path, help='write exact key and locale gap sets')
    parser.add_argument('--write-coverage', action='store_true', help='refresh bundled coverage from current source and catalogs')
    parser.add_argument('--check', action='store_true', help='check coverage freshness (also the default)')
    args = parser.parse_args()
    result = audit()
    total = len(result['inventoryKeys'])
    coverage = {locale: {'translated': total if catalog['sourceLanguage'] else catalog['inventoryPresent'], 'total': total}
                for locale, catalog in result['catalogs'].items()}
    coverage_path = ROOT / 'Sources/Sumra/Resources/Localizations/coverage.json'
    if args.write_coverage and not result['errors']:
        coverage_path.write_text(json.dumps(coverage, ensure_ascii=False, sort_keys=True, indent=2) + '\n')
    elif not coverage_path.exists() or json.loads(coverage_path.read_text()) != coverage:
        result['errors'].append('Bundled localization coverage is stale; run scripts/audit-localizations.py --write-coverage')
    if args.json:
        args.json.parent.mkdir(parents=True, exist_ok=True)
        args.json.write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(f"{len(result['catalogs'])} catalogs; {len(result['literalKeys'])} literal keys; {len(result['inventoryKeys'])} inventoried source keys")
    for locale, catalog in result['catalogs'].items():
        if catalog['sourceLanguage']:
            print(f"{locale}: {catalog['entries']} intentional source-language overrides")
        else:
            print(f"{locale}: {catalog['inventoryPresent']} inventoried keys present; {len(catalog['missing'])} missing")
    for error in result['errors']:
        print(error)
    raise SystemExit(bool(result['errors']))


if __name__ == '__main__':
    main()
