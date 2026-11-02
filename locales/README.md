# mt-copier Localization & Language Pack Guide

This directory contains external language packs for the `mt-copier` Web Dashboard.

---

## 1. Quick Start: Adding a New Language

Adding a new language takes just **3 simple steps** and **requires NO code compilation**:

1. **Copy the starter template**:
   Copy `template.json` in this directory and rename it to your target IETF language tag (e.g. `de.json` for German, `ko.json` for Korean, `fr.json` for French, `it.json` for Italian, `pt.json` for Portuguese).

2. **Translate the strings**:
   Open your newly created `<lang>.json` file in any text editor.
   Update the metadata header:
   ```json
   "meta": {
     "name": "Deutsch",
     "code": "de",
     "author": "Your Name / GitHub Handle",
     "version": "1.0.0"
   }
   ```
   Translate each string value on the right-hand side.
   *Note: Preserve all `{variable}` placeholders (such as `{ticket}`, `{lots}`, `{symbol}`, `{count}`) so numbers and symbols are formatted correctly.*

3. **Verify and Deploy**:
   - Simply keep your file inside this `locales/` directory next to `copier-hub.exe`.
   - Run the automated validator to ensure no keys or placeholders are missing:
     ```bash
     python tools/i18n_check.py locales/de.json
     ```
   - Refresh your browser: your new language will automatically appear in the top-right `🌐 Language` selector!

---

## 2. Robust Fallback Mechanics

You do not need to worry about breaking the interface if your translation is still in progress:
- **Automatic Fallback to English**: If any specific key is missing from your language pack, the UI will seamlessly display the built-in English fallback text.
- **Zero UI Breaks**: No empty buttons or missing labels will ever crash the dashboard.

---

## 3. Directory Layout

The localization matrix provides **100% complete coverage across 423 translation keys**:

| File | Language | Type | Coverage |
|---|---|---|---|
| *(Built-in)* | **English (en)** | Core baseline compiled inside binary | 423 / 423 keys (100%) |
| *(Built-in)* | **简体中文 (zh-CN)** | Core Chinese compiled inside binary | 423 / 423 keys (100%) |
| `zh-TW.json` | **繁體中文 (zh-TW)** | External Drop-in Plugin | 423 / 423 keys (100%) |
| `ja.json` | **日本語 (ja)** | External Drop-in Plugin | 423 / 423 keys (100%) |
| `ru.json` | **Русский (ru)** | External Drop-in Plugin | 423 / 423 keys (100%) |
| `es.json` | **Español (es)** | External Drop-in Plugin | 423 / 423 keys (100%) |
| `template.json` | **Starter Template** | Clean reference template for new translators | 423 / 423 keys (100%) |
| `README.md` | **Documentation** | This guide | - |

---

## 4. Contributing Back

If you created a new language pack or improved an existing translation:
1. Ensure `python tools/i18n_check.py locales/<your-lang>.json` passes cleanly.
2. Submit a Pull Request to the GitHub repository: `mt-copier-mt4-mt5`.
3. Your translation will be included in the next official release!
