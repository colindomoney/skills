---
name: hermes-desktop-mtls-dmg
description: Build, port, debug and install the patched Hermes Desktop (Electron) macOS DMG with mTLS client-certificate support, the "-cd" version marker and an update-proof "external" stamp, from a Hermes Agent release tag or commit, ad-hoc signed with upstream's own routine. Use when asked to "rebuild Hermes Desktop with mTLS", "build me a new Hermes DMG", "port the mTLS patches to 0.x.y", when the pinned app breaks after a backend update (409 client_upgrade_required), when Hermes Desktop can't reach an mTLS-protected remote gateway (hermes.domoney.online), or to check what `hermes update` will do to the patched app.
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, electron, macos, mtls, codesign, dmg, git"
  version: "0.2.0"
  last-verified: "2026-11-06"
  status: live
---

# Hermes Desktop mTLS DMG

Stock Hermes Desktop can't reach a remote gateway behind mTLS, because its main-process traffic (status, OAuth, JSON, downloads, the "Test remote" WebSocket probe) uses Node HTTP, which never asks the macOS Keychain for a client certificate. A local patch series fixes this: for origins listed in `~/Library/Application Support/Hermes/client-certificates.json`, it answers Electron's `select-client-certificate` and routes their traffic through the Electron session that owns the certificate. Upstream doesn't ship this, so the app is built locally, kept pinned, and rebuilt only when a backend update breaks it.

## When to use / when not to

- **Use when** building or porting the patched app, diagnosing mTLS or client/backend version failures, or planning an update around the pinned app.
- **Don't use for** the backend or service stack: `hermes-tmux-stack` (Mac host with tmux) or `hermes-macos-launchd` (launchd agents). The SSH-loopback and `--skip-desktop` patches are not part of the DMG.

## The canonical form

**Patches:** `~/Documents/Obsidian Vault/20 Areas/Hermes Agent/Patches/Hermes PR 2 - Desktop mTLS/port-<date>-<base>/`. They are private and not in this repo. Use the newest folder, named under "Current patches" in `BUILD-WITH-CLAUDE-CODE.md` beside it, which is the build record. [not covered: a machine without that vault has no patch source.]

| Patch | Purpose |
|---|---|
| `0001` | `client-certificate.ts`, `client-certificate-transport.ts`, download transport, ws-probe, tests |
| `0002` | `apps/desktop/electron/main.ts` wiring, for configured origins only |
| `0003` | Display-only `-cd` in `app-version.ts`, also applied to `clientVersion` in `hermes:version` |
| `0004` | `updateMechanism: external` stamp, below |

`0004` in `apps/desktop/scripts/write-build-stamp.mjs` is what makes the app survive updates:

```diff
   const updateMechanism = {
-    '': 'self',
-    bootstrap: 'self',
+    '': 'external',
+    bootstrap: 'external',
```

**Certificate selector** (mode 600, no key material):

```json
{ "version": 1, "origins": { "https://hermes.domoney.online": { "issuerName": "DoMoney-Client-CA", "subjectName": "<this mac's cert CN>" } } }
```

## Steps

### Diagnose

Read-only. Never use the Hermes CLI for this (see Gotchas).

```bash
A=/Applications/Hermes.app
grep -E '"(commit|updateMechanism)"' "$A/Contents/Resources/install-stamp.json"
grep -c "presenting client certificate" "$A/Contents/Resources/app.asar.unpacked/dist/electron-main.mjs"
git -C ~/.hermes/hermes-agent log -1 --format='%h %ci %s'        # local backend
ssh hermes.home 'git -C ~/.hermes/hermes-agent rev-parse --short=10 HEAD'   # every other backend
test -e ~/.hermes/.hermes-update-in-progress && echo "update running: wait"
security find-identity -v -p basic | grep <cn>
```

Check the target's toolchain with `git show <tag>:package.json | grep -A2 engines`, and `.npmrc` for `engine-strict`. Dry-run the patches without touching a worktree:

```bash
export GIT_INDEX_FILE=<scratch>/idx; git read-tree '<tag>^{commit}'
git apply --cached --check <patch>        # repeat per patch
unset GIT_INDEX_FILE
```

### Patch

1. **Pin the target** the user names. Choose it against every backend the app connects to.
2. **Clone into a new, durable directory,** never `/tmp` or the live checkout. A healthy full clone gives pre-image blobs for 3-way merges:
   ```bash
   D=~/.hermes/.worktrees/hermes-desktop-mtls-<ver>; test -e "$D" && exit 1
   git clone --no-checkout <full-clone> "$D"     # else: git -c http.version=HTTP/1.1 clone --depth 1 --branch v<ver> <github-url> "$D"
   git -C "$D" checkout -b local/desktop-mtls-dmg-<date> '<tag>^{commit}'
   ```
3. **Apply in order** with `git am -3`. On conflict, resolve it and run `git am --continue`, which keeps author and date.
4. **Audit the port.**
   - Check every `main.ts` hunk's landing function by name in `git diff`, and remove any `*.orig` or `*.rej`.
   - List remote-reaching transports and confirm each configured origin goes through the certificate session:
     ```bash
     grep -nE "https?\.(request|get)|client\.request\(|new WebSocket|electronNet\.|[^.]fetch\(" -r apps/desktop/electron --include='*.ts' --exclude='*.test.*'
     ```
   - New local-only branches, such as `gatewayEndpoint` in `saveGatewayFile`, stay untouched.
   - `git grep` the stamp script for new `updateMechanism` values, and confirm `_update_owned_macos_bundles` still keys on `self`.

### Verify and build

Run with Node from the target's `engines` first on `PATH` (`npm ci` refuses otherwise under `engine-strict`), e.g. `~/.hermes/tools/node-<ver>-darwin-arm64/bin`. Run long steps in the background.

1. `npm ci` from the repo root.
2. From `apps/desktop`, focused tests only:
   ```bash
   npx vitest run electron/client-certificate.test.ts electron/client-certificate-transport.test.ts \
     electron/client-certificate-wiring.test.ts electron/gateway-file-download-transport.test.ts \
     electron/gateway-ws-probe.test.ts electron/app-version.test.ts src/lib/version-status.test.ts \
     scripts/write-build-stamp.test.mjs
   ```
3. `npm run typecheck`, `eslint` on the changed files, `git diff --check <tag>^{commit} HEAD`. Grep that diff for domains, CA names, host names and `BEGIN` blocks.
4. Build, with no arch flag (`--arm64` stages native deps to a path upstream's build rejects):
   ```bash
   CSC_IDENTITY_AUTO_DISCOVERY=false npm run build
   CSC_IDENTITY_AUTO_DISCOVERY=false npm run builder -- --mac --dir --publish never
   ```
5. **Prove the patch is inside the build before signing:**
   ```bash
   A=release/mac-arm64/Hermes.app
   grep -c "presenting client certificate" "$A/Contents/Resources/app.asar.unpacked/dist/electron-main.mjs"   # >=1
   grep -E '"(commit|dirty|updateMechanism)"' "$A/Contents/Resources/install-stamp.json"   # patched HEAD, false, external
   ```

### Sign and package

1. **Sign** with upstream's routine from the clone root. It keeps `com.nousresearch.hermes` and an identifier-pinned DR, so TCC grants and Keychain ACLs carry over:
   ```bash
   A="$PWD/apps/desktop/release/mac-arm64/Hermes.app"; xattr -cr "$A"
   ~/.hermes/hermes-agent/venv/bin/python -c "
   import sys; sys.path.insert(0,'.')
   from pathlib import Path
   from hermes_cli import main_desktop as m
   print(m._desktop_macos_local_codesign(Path('$A'), desktop_dir=Path('apps/desktop'), identity='-'))"
   codesign --verify --deep --strict --verbose=2 "$A"   # valid on disk + satisfies its Designated Requirement
   ```
2. **Build the DMG:** stage `Hermes.app` (`ditto`) with an `/Applications` symlink, then `hdiutil create -format UDZO -fs APFS` to `~/Desktop/Hermes-mac-arm64-mtls-cd-<ver>-<sha10>.dmg`.
3. **Verify:** `hdiutil verify`, then mount read-only with `-nobrowse` and check deep codesign, `lipo -archs` returns `arm64`, `cmp` of `app.asar` and `electron-main.mjs` against the build, the stamp, and no `client-certificates*.json`, `connection*.json`, `.p12`, `.pem` or `.env` inside. Record `shasum -a 256` and archive to `~/Documents/home/Hermes Install Images/Hermes-<ver>-cd/` with `SHA256SUMS-<ver>-cd.txt`.
4. **Save the patches:** `git format-patch <tag>^{commit}..HEAD` into a new `port-<date>-v<ver>-<sha7>/`, with `SHA256SUMS.txt`. Prove them: `git am` in a throwaway durable worktree at the tag, `git diff --quiet` against the build branch, remove it. Update the runbook.

### Install

Only when the user says so, and with Hermes quit (`pgrep -x Hermes`) and no update running:

```bash
N=/Applications/.Hermes-<ver>-new.app
ditto <mounted-dmg>/Hermes.app "$N" && codesign --verify --deep --strict "$N"
mv /Applications/Hermes.app ~/.Trash/Hermes-<old-ver>-cd-<sha>.app && mv "$N" /Applications/Hermes.app
L=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
$L -u ~/.hermes/hermes-agent/apps/desktop/release/mac-arm64/Hermes.app; $L -f /Applications/Hermes.app
```

Stage first so the path is missing only for a moment: the updater treats a *missing* recorded app as one to restore. `lsregister -u` printing `-10814` only means that copy wasn't registered. Ask the user whether they want the old app trashed or kept as a backup.

### Update afterwards

- **Local:** `hermes update --channel main --backup` for one run, or `hermes update --set-channel <stable|main>` and then `hermes update --backup`. `--set-channel` alone only saves the setting. Plain `hermes update` follows the saved channel, and moves a newer checkout back to `stable`'s release.
- **tmux host:** `ssh -t hermes ~/hermes-upgrade.sh`, never plain `hermes update`. See `hermes-tmux-stack`.
- **Expected:** the app waits for the update marker, reconnects by itself and isn't rewritten. Rebuild only when it breaks.

## Debug

| Symptom | Likely cause | Check or fix |
|---|---|---|
| 409 `client_upgrade_required` on session edits | Client older than the backend's mutation protocol | Compare the app's stamp with the backend; rebuild from the backend's commit |
| `options is not defined` or a similar runtime error after a clean patch apply | Upstream changed code that a patch moves | Focused tests catch it; fix by passing the value in explicitly |
| Remote unreachable, no `[mtls] presenting` line | Selector missing or wrong, or the app is stock | Check the file's origin (FQDN, from `connections.json` `url`), mode 600, and the app's stamp |
| `[mtls] no client certificate matched` | Issuer or subject differs from the Keychain identity | `security find-identity -v -p basic`; correct the selector |
| App reverted to stock | App was stamped `self`, or a copy was launched from the checkout | `grep updateMechanism` in `/Applications/Hermes.app`; reinstall from the DMG |
| About shows an unexpected version | Label borrows from the connected backend | `install-stamp.json` `commit` is the build's identity |
| `Update follow-up 'build' did not finish`, `--force-build` nag | The stock build in the checkout failed | Harmless with an `external` app; ignore it |
| Stock build came out despite the patches | A stray `git switch` | `git status -sb`, `git reflog`; check the stamp before signing |

## Gotchas

- **The live install can move during a build.** An Update click or a cron job can switch the checkout mid-session. Recheck its commit before relying on it, and check `desktop.log` for `launched posix hand-off`.
- **Check every backend, not just local.** A pinned client has to work with all of them. The `hermes.domoney.online` connection is the one that exercises the patches.
- **`hermes update --check` is not read-only here.** The launcher runs any owed post-update completion first and bumps its retry count. Read git and files directly when diagnosing.
- **`--skip-desktop` is the wrong tool.** It lives in the checkout that updates replace, and the Update button's hand-off doesn't pass it. The stamp lives in the app.
- **Don't run `hermes desktop` or `--force-build` on a patched install.** They can build or launch the stock bundle in the checkout, which has no mTLS. `hermes update` also rebuilds that bundle if `apps/desktop/release` or the desktop `dist` exists there. It's harmless, but wasteful.
- **`npx vitest` provisions a Python environment.** `vitest.hermes-python.ts` creates about 780M in `~/.hermes/installs/<hash>/` and writes `pm_*` receipts to `logs/update_receipts/`. Setting `HERMES_PYTHON` skips this, though contracts driving real `hermes_cli` code need a real interpreter. Tell the user what it left behind.
- **Never run the full Electron suite (`--project electron`) on the user's desktop session.** It floods macOS with popups and blocks the chat for about 30 minutes. `desktop-uninstall.test.ts` also has 3 POSIX cleanup failures on macOS from `/var` versus `/private/var`, unrelated to these patches.
- **`git am -3` may report a "constructed fake ancestor".** Expect real conflicts in `main.ts`, especially for patches whose pre-image is a local commit.
- **`git fetch` can crash on the live checkout,** a `tree:0` partial clone (`BUG: builtin/pack-objects.c`). Don't repair it; clone instead. GitHub clones that cut out over HTTP/2 need `-c http.version=HTTP/1.1` with `--depth 1`.
- **The main process ships unpacked,** in `app.asar.unpacked/dist/electron-main.mjs`. Grepping `app.asar` for mTLS strings finds nothing.
- **Possible gap:** `registerMediaProtocol` has no explicit certificate routing. It now uses Chromium's network stack, so it may be covered. Unverified.

## Verify

After the user installs and launches the app, `~/.hermes/logs/desktop.log` should show:

```text
[mtls] presenting client certificate <cn> to hermes.domoney.online:443
[mtls] client certificate session ready for https://hermes.domoney.online
```

- **About:** shows `v<ver>-cd`, the patched commit, Build Origin `Local (local/desktop-mtls-dmg-<date>)`, and "Updates are managed by the package owner outside this app."
- **Ownership,** from the live checkout, returns `[]`:
  ```bash
  ~/.hermes/hermes-agent/venv/bin/python -c "import sys; sys.path.insert(0,'$HOME/.hermes/hermes-agent'); from pathlib import Path; from hermes_cli import main_desktop as m; print(m._update_owned_macos_bundles([Path('/Applications/Hermes.app')]))"
  ```
- **Session edits and cold start:** rename a session on each backend with no 409, then quit fully and reopen once. If macOS asks about **Hermes Safe Storage**, enter the password and choose **Always Allow**.

## References

- Build record and history: `BUILD-WITH-CLAUDE-CODE.md` beside the patches. User-facing summary: `Hermes Update Cheatsheet.md` in the same vault area.
- Upstream: `https://github.com/NousResearch/hermes-agent` (`apps/desktop/electron/main.ts`, `apps/desktop/scripts/write-build-stamp.mjs`, `hermes_cli/main_desktop.py`)
