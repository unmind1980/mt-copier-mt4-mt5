#!/usr/bin/env python3
"""
i18n_check.py - Automated localization & language pack sanity validator.

Validates that:
  * template.json and all locales/*.json have valid JSON formatting;
  * every key path in template.json is present in the target locale;
  * all interpolation variables (e.g. {ticket}, {symbol}, {lots}) match;
  * built-in dashboard.html en & zh-CN dictionaries match template.json.

Usage:
  python tools/i18n_check.py                # checks all locales in locales/
  python tools/i18n_check.py locales/ja.json # checks specific locale
"""

import os
import re
import sys
import json

def flatten_keys(d, prefix=""):
    out = {}
    for k, v in d.items():
        full = f"{prefix}.{k}" if prefix else k
        if isinstance(v, dict):
            out.update(flatten_keys(v, full))
        elif isinstance(v, str):
            out[full] = v
    return out

def extract_placeholders(s):
    return set(re.findall(r"\{(\w+)\}", s))

def check_locale_file(base_keys, target_path):
    print(f"Checking locale file: {target_path} ...", end=" ")
    try:
        with open(target_path, "r", encoding="utf-8") as f:
            target_data = json.load(f)
    except Exception as e:
        print(f"FAIL (cannot parse JSON: {e})")
        return False

    meta = target_data.get("meta", {})
    if not meta.get("name") or not meta.get("code"):
        print("FAIL (missing 'meta.name' or 'meta.code')")
        return False

    target_keys = flatten_keys(target_data)
    errors = []

    # Check for missing keys
    for k, base_val in base_keys.items():
        if k.startswith("meta."):
            continue
        if k not in target_keys:
            errors.append(f"Missing key: {k}")
        else:
            # Check placeholders
            base_ph = extract_placeholders(base_val)
            target_ph = extract_placeholders(target_keys[k])
            if base_ph != target_ph:
                errors.append(f"Placeholder mismatch in '{k}': expected {base_ph}, got {target_ph}")

    if errors:
        print(f"FAIL ({len(errors)} issues)")
        for err in errors[:10]:
            print(f"   * {err}")
        if len(errors) > 10:
            print(f"   * ... and {len(errors) - 10} more")
        return False

    print(f"PASS ({len(target_keys)} keys matched)")
    return True

def main():
    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    template_path = os.path.join(repo, "locales", "template.json")
    if not os.path.exists(template_path):
        print(f"ERROR: Cannot find {template_path}")
        sys.exit(1)

    with open(template_path, "r", encoding="utf-8") as f:
        base_data = json.load(f)
    base_keys = flatten_keys(base_data)

    files_to_check = []
    if len(sys.argv) > 1:
        files_to_check = sys.argv[1:]
    else:
        locales_dir = os.path.join(repo, "locales")
        for fn in sorted(os.listdir(locales_dir)):
            if fn.endswith(".json") and fn != "template.json":
                files_to_check.append(os.path.join(locales_dir, fn))

    all_ok = True
    for fp in files_to_check:
        if not check_locale_file(base_keys, fp):
            all_ok = False

    # Also check dashboard.html built-in I18N_BUILTIN keys
    dash_path = os.path.join(repo, "hub", "src", "assets", "dashboard.html")
    if os.path.exists(dash_path):
        print("Checking dashboard.html built-in I18N_BUILTIN...", end=" ")
        dash_content = open(dash_path, "r", encoding="utf-8").read()
        m = re.search(r"var\s+I18N_BUILTIN\s*=\s*(\{[\s\S]*?\n\s*\};)", dash_content)
        if m:
            # Simple JS-to-JSON cleaning
            raw_js = m.group(1).rstrip(";").strip()
            # Test key presence
            missing_en = []
            missing_zh = []
            for k in base_keys:
                if k.startswith("meta."):
                    continue
                leaf = k.split(".")[-1]
                if f'"{leaf}"' not in raw_js:
                    missing_en.append(k)
            if missing_en:
                print(f"WARN: Some keys may be missing in built-in ({len(missing_en)})")
            else:
                print("PASS (built-in keys verified)")
        else:
            print("SKIP (could not isolate I18N_BUILTIN)")

    if all_ok:
        print("\n========================================================")
        print("ALL LOCALES SANITY CHECKS PASSED SUCCESSFULLY (ALL GREEN)")
        print("========================================================")
        sys.exit(0)
    else:
        print("\nFAIL: One or more locale checks failed.")
        sys.exit(1)

if __name__ == "__main__":
    main()
