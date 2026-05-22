# AGENTS.md

This file provides guidance to Codex (Codex.ai/code) when working with code in this repository.

## What this repo is

A single-file Windows 11 dev-environment installer. Running `dev_env.bat` self-elevates to admin, presents a menu (`1` Java, `2` Node, `3` Python, `4` Maven, `5` Git+TortoiseGit, `6` Android SDK, `7` apktool, `8` zipalign, `9` clautel, `all` for 1–8 only, or comma-separated like `1,3,9`), then installs the chosen toolchains under `D:\dev_env\<tool>\<version>` and registers Machine-scope environment variables.

There is no build, no test suite, no package manager. The deliverable *is* `dev_env.bat`.

## Architecture: bat-wraps-PowerShell pattern

`dev_env.bat` is a polyglot file. The PowerShell payload lives between the literal markers `###PS_START###` and `###PS_END###` near the bottom of the file. The batch half (lines 1–41):

1. Self-elevates by writing a `getadmin.vbs` shim and re-launching via `runas`.
2. Locates the markers by line number using `findstr /n /b`, then uses PowerShell's `Select-Object -Skip / -First` to extract the payload to `%temp%\dev_env_install.ps1`.
3. Executes the extracted script with `-ExecutionPolicy Bypass`, then deletes it.

When editing, **the marker lines must remain exactly `###PS_START###` and `###PS_END###` at column 0** — the line-number extraction breaks otherwise. Do not move them or add prefixes.

## Architecture: per-tool task scriptblocks

Inside the PS payload, each tool is a `$TaskXxx = { ... }` scriptblock dispatched by the menu `switch`. They all follow the same shape, and new tools should too:

1. **Skip if already on PATH** via `Test-CommandAvailable` (calls `Get-Command`). This means a tool installed system-wide outside `D:\dev_env` is left alone — only `JAVA_HOME`/`NODE_HOME`/etc. and PATH entries get added (or not, if the tool is already detected).
2. **Skip if already installed under `$paths.Xxx`** — versioned target dirs (`D:\dev_env\java\21.0.5`, etc.) act as the idempotency check. Bumping a version in the `$v` hashtable forces a fresh install into a new directory; it does not delete the old one.
3. **Download to `$tempCache`** (`D:\dev_env\__temp_cache__`) via `Download-Official`, which tries `Invoke-WebRequest` with a Chrome User-Agent and falls back to `curl.exe`. The cache is wiped in the `finally` block at the end of the run.
4. **Install** — `.zip` is `Expand-Archive`'d and `.tar.gz` is extracted with the built-in `tar.exe` (Python uses python-build-standalone, a relocatable `.tar.gz`), then the inner directory is moved into place; `.msi`/`.exe` installers (Git, TortoiseGit) are invoked silently (`/VERYSILENT`, `/quiet`) with an explicit `/DIR=`/`INSTALLDIR=` so they land inside `$paths.Xxx`.
5. **Register env vars** — `Set-EnvVar` writes Machine scope and also `Set-Item Env:` so the *current* PowerShell session sees it (needed for tools like `sdkmanager` that run later in the same session). `Add-PathVar` appends to Machine `Path` using a `%VAR%`-style entry (e.g. `%JAVA_HOME%\bin`) but checks both the symbolic and resolved form to avoid duplicates.

The Android task is the only one with cross-task ordering: `sdkmanager.bat` requires Java on PATH, so it falls back to prepending `$paths.Java8\bin` or `$paths.Java17\bin` to `$env:Path` for the current session, and throws if Java isn't installed yet. Preserve that check if you refactor.

### clautel (menu `9`)

- **Hard deps:** `node`, `npm` (menu `2`), and `claude` (Claude Code CLI — not installed by this repo).
- **Install:** `npm install -g clautel@latest` on every run of menu `9` (no `$v` pin).
- **Does not run** `clautel setup`; user configures `~\.clautel\config.json` manually afterward.
- **Keepalive:** registers `DevEnvWin11-Clautel-Keepalive` — `AtStartup` (S4U) + 5-minute repetition; action is `wscript.exe` → `clautel-watch-launch.vbs` (`vbHide`) → hidden `clautel-watch.ps1`. Mutex `Global\DevEnvWin11-Clautel-Watch` + `clautel status` avoid duplicate daemons. Artifacts under `%LOCALAPPDATA%\DevEnvWin11\`.
- **Migration:** removes obsolete `DevEnvUbuntu-WSL-VMHolder` / `DevEnvUbuntu-WSL-Keepalive` scheduled tasks if present. WSL/systemd clautel cleanup is documented in DevEnvUbuntu README, not automated here.

## Environment broadcast

After all tasks run, the script `Add-Type`s a tiny C# `Win32Helper` and calls `SendMessageTimeout(HWND_BROADCAST, WM_SETTINGCHANGE, ..., "Environment", ...)` so Explorer and already-open shells pick up the new env vars without a logoff. If you change how env vars are written, keep this broadcast — it's why users don't have to restart their terminal.

## Versions and URLs

All version numbers live in the `$v` hashtable; URLs are templated from `$v` in `$urls`. To bump a tool, change `$v` only — `$paths` and `$urls` interpolate from it. Sources are deliberately official (`download.oracle.com`, `nodejs.org`, `archive.apache.org`, `git-for-windows` and `astral-sh/python-build-standalone` GitHub releases, `download.tortoisegit.org`, `dl.google.com`); don't swap in mirrors without a reason.

Python is the exception to "change `$v` only": it needs both `$v.Python` (e.g. `3.12.13`) and `$v.PythonRelease` (the python-build-standalone release tag, e.g. `20260510`) — the two are paired, since each PBS release ships specific patch versions.

Note the JDK version drift: `$v.Java = "21.0.5"` in the script, but `pkg/` contains `jdk-8.zip` and `jdk-17.zip`. Those zips are **not** wired into any task and aren't tracked in git — treat them as a manual offline cache, not part of the install flow, unless you add a task that consumes them.

## Editing tips

- Test changes by running `dev_env.bat` from an unprivileged shell — it should re-launch elevated. If the UAC re-launch loop misbehaves, check that `%~s0` (short path) and the `getadmin.vbs` step are intact.
- The PS payload runs through `Out-File -Encoding UTF8` extraction, so don't rely on BOM-sensitive parsing. Keep the payload ASCII-safe where possible.
- `Read-Host` blocks on user input — anything you add to the menu flow will hang non-interactive runs.
