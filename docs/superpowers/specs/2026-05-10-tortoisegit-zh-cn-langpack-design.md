# TortoiseGit zh_CN Language Pack — Design

**Date:** 2026-05-10
**Scope:** Extend `dev_env.bat` so that menu option `5` installs the Simplified Chinese (zh_CN) language pack alongside TortoiseGit.

## Goal

When a user installs TortoiseGit via this script (option `5` or `all`), the Simplified Chinese language pack is also installed so that "中文(简体)" appears as a selectable language under TortoiseGit Settings → General → Language.

The script will not change the default UI language. Users opt in via the Settings dialog after install.

## Non-goals

- Not adding a separate menu entry for the language pack.
- Not installing Traditional Chinese (zh_TW).
- Not writing `HKCU\Software\TortoiseGit\LanguageID` to force the UI language.
- Not changing existing tasks (Java, Node, Python, Maven, Git, Android) or the bat-half of the script.

## Changes

All changes are inside the PowerShell payload (between `###PS_START###` and `###PS_END###`).

### 1. URL table (`$urls`)

Add one entry, derived from the existing `$v.TGit`:

```powershell
TGitLang = "https://download.tortoisegit.org/tgit/$($v.TGit)/TortoiseGit-LanguagePack-$($v.TGit)-64bit-zh_CN.msi"
```

The language pack version is locked to the TortoiseGit version — bumping `$v.TGit` automatically bumps the language pack URL. No new entry in `$v` and no new entry in `$paths` (the language pack installs into the existing TortoiseGit directory, not its own versioned dir).

### 2. `$TaskGit` extension

Append a language-pack block to the existing `$TaskGit` scriptblock, after the TortoiseGit MSI install and `Add-PathVar` lines. Pseudocode:

```
if (Test-Path $paths.TGit) {
    $langMarker = "$($paths.TGit)\Languages\TortoiseProc2052.dll"
    if (!(Test-Path $langMarker)) {
        $f = Download-Official $urls.TGitLang "tgit_lang_zh_CN.msi" "https://tortoisegit.org/download/"
        Start-Process msiexec.exe -ArgumentList "/i `"$f`" /quiet /norestart" -Wait
    }
}
```

Notes on the design choices:

- **Guard on `Test-Path $paths.TGit`** — if `git` was already on PATH and TortoiseGit was therefore not freshly installed *and* no prior install exists at `$paths.TGit`, we skip the language pack. Trying to install a TortoiseGit language pack with no TortoiseGit present produces a confusing MSI dialog/error.
- **Idempotency marker `Languages\TortoiseProc2052.dll`** — `2052` is the LCID for zh_CN; the language pack drops `TortoiseProc2052.dll`, `TortoiseGitMerge2052.dll`, `TortoiseGitBlame2052.dll`, `TortoiseGitIDiff2052.dll`, and `TortoiseGitUDiff2052.dll` into `<TGitDir>\Languages\`. Existence of the first DLL is a sufficient idempotency check, mirroring the file-presence pattern used by every other task in the script.
- **No `INSTALLDIR`** — the language-pack MSI auto-locates the TortoiseGit installation via its installer registry; passing `INSTALLDIR` is not required and (per past TortoiseGit installer behavior) ignored.
- **Referer header** — reused from the existing TortoiseGit download to keep behavior consistent in case the CDN ever filters by referer.

### 3. Console output

The new block prints a single status line in the existing style, e.g.:

```
  [Lang] zh_CN already installed.       (skip case)
  [Lang] Installing TortoiseGit zh_CN language pack...
```

This keeps the section under the existing `>> Git & TortoiseGit` Cyan header — no new section header.

## Idempotency matrix

| State                                          | Behavior                                                        |
|------------------------------------------------|-----------------------------------------------------------------|
| First run, fresh machine                       | Install TortoiseGit, then install zh_CN language pack.          |
| TortoiseGit installed, language pack missing   | Skip TortoiseGit MSI, install zh_CN language pack.              |
| Both already installed                         | Skip both (file-presence guards).                               |
| `git` on PATH, no TortoiseGit ever installed   | Skip Git, skip TortoiseGit, **skip language pack** (guarded).   |
| `$v.TGit` bumped to a new version              | New TortoiseGit dir → new language pack download/install.       |

## Risks

- **CDN URL drift.** TortoiseGit's mirror has historically used the `download.tortoisegit.org/tgit/<version>/...` pattern; if that ever changes, both the existing `$urls.TGit` and the new `$urls.TGitLang` break together. Mitigation: same as today — `Download-Official` already retries via curl and surfaces a clear error.
- **Language pack version skew.** The pack is published shortly after the main installer for each release. If a brand-new `$v.TGit` value is set before the matching language pack is published, the download will 404. Mitigation: only bump `$v.TGit` once both URLs return 200.

## Out of scope (explicitly)

- Switching the default UI language automatically.
- Installing additional language packs (Traditional Chinese, etc.).
- Adding a separate menu number for "language pack only" reinstalls — users can re-run option `5` and the file-presence guard ensures only the missing piece installs.
- Uninstalling old TortoiseGit / language-pack versions when `$v.TGit` is bumped (consistent with the rest of the script's "keep old versioned dirs" behavior).
