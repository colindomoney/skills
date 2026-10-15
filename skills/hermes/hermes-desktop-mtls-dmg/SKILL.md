---
name: hermes-desktop-mtls-dmg
description: Rebuild the patched Hermes Desktop (Electron) macOS DMG with mTLS client-certificate support and the "-cd" version marker, from a Hermes Agent release tag, ad-hoc signed with upstream's own routine. Use when asked to "rebuild Hermes Desktop with mTLS", "build me a new Hermes DMG", "port the mTLS patches to 0.x.y", after `hermes update` or "Update now" replaced the patched app with stock, or when Hermes Desktop can't reach an mTLS-protected remote gateway (hermes.domoney.online).
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, electron, macos, mtls, codesign, dmg, git"
  version: "0.1.0"
  last-verified: "2026-10-15"
  status: live
---

# Hermes Desktop mTLS DMG

Stock Hermes Desktop can't reach a remote gateway behind mTLS, because its main-process traffic (status, OAuth, JSON, downloads, the "Test remote" WebSocket probe) uses Node HTTP, which never asks the macOS Keychain for a client certificate. A local patch series fixes this. For origins listed in `~/Library/Application Support/Hermes/client-certificates.json`, it answers Electron's `select-client-certificate` and routes all traffic for those origins through the Electron session that owns the certificate. A third patch adds a display-only `-cd` suffix so a patched build is recognisable in About. Upstream doesn't ship this feature, so every Hermes update means porting the patches and rebuilding.

## When to use / when not to

- **Use when** rebuilding the patched Desktop app for a new Hermes release, or porting the patches.
- **Don't use for** the backend/gateway or the tmux service stack. Use `hermes-tmux-stack` for those. The SSH-loopback and `--skip-desktop` patches are not part of the DMG.

## Source of truth

- **Runbook:** `~/Documents/Obsidian Vault/20 Areas/AI/Hermes Agent/Patches/Hermes PR 2 - Desktop mTLS/BUILD-WITH-CLAUDE-CODE.md`. Read it first. Its "Current patches" list names the newest folder.
- **Patches:** `port-<date>-<base>/0001..0003-*.patch` beside the runbook. Always use the top folder.
  - `0001`: `client-certificate.ts`, `client-certificate-transport.ts`, the download transport and the ws-probe, plus tests.
  - `0002`: wiring in `apps/desktop/electron/main.ts`, for configured origins only.
  - `0003`: `-cd` in `app-version.ts`.
- **Certificate selector** (mode 600). It holds no key material:
  ```json
  { "version": 1, "origins": { "https://hermes.domoney.online": { "issuerName": "DoMoney-Client-CA", "subjectName": "<this mac's cert CN>" } } }
  ```

## Steps

1. **Pin the target.** Use the release tag the user names, for example `v0.22.2`. Check that no `hermes update` is running: `~/.hermes/.hermes-update-in-progress` should be absent. Run `pgrep "hermes update"` too, but don't trust it on its own: it also matches the gateway processes, whose inline launcher contains that string. The PIDs are listed inside the marker file.
2. **Clone fresh into a new, empty directory.** Never build in the live checkout `~/.hermes/hermes-agent`.
   ```bash
   D=~/.hermes/.worktrees/hermes-desktop-mtls-<ver>; test -e "$D" && exit 1
   git -c http.version=HTTP/1.1 clone --depth 1 --branch v<ver> https://github.com/NousResearch/hermes-agent.git "$D"
   git -C "$D" switch -c local/desktop-mtls-dmg-<date>
   ```
3. **Apply the patches.**
   - Try `git apply --check` on each patch first.
   - If one fails:
     - Apply it with `git apply --reject` and fix the `.rej` by hand.
     - Or use `patch -p1 --verbose -b -z .orig`, which applies at offsets.
     - Then inspect every hunk's landing function with `git diff`.
     - Commit with the original author, date and message from `git mailinfo`.
   - `git am` any patch that applies cleanly.
   - Delete any `*.orig` files before committing.
4. **Verify the source** from `apps/desktop`, in this order:
   - `npm ci` (from the repo root).
   - Focused tests only:
     ```bash
     npx vitest run electron/client-certificate.test.ts electron/client-certificate-transport.test.ts \
       electron/client-certificate-wiring.test.ts electron/gateway-file-download-transport.test.ts \
       electron/gateway-ws-probe.test.ts electron/app-version.test.ts src/lib/version-status.test.ts
     ```
   - `npm run typecheck`.
   - `eslint` on the changed files.
   - `git diff --check`.
   - Grep the diff for domains, CA names, host names and `BEGIN` blocks.
5. **Build** for the native arch with no `--arm64`. Run it **in the background**, because it takes minutes:
   ```bash
   CSC_IDENTITY_AUTO_DISCOVERY=false npm run build
   CSC_IDENTITY_AUTO_DISCOVERY=false npm run builder -- --mac --dir --publish never
   ```
   The output is `apps/desktop/release/mac-arm64/Hermes.app`.
6. **Prove the patch is inside the build before signing:**
   ```bash
   A=apps/desktop/release/mac-arm64/Hermes.app
   grep -c "presenting client certificate" "$A/Contents/Resources/app.asar.unpacked/dist/electron-main.mjs"   # ≥1
   grep '"commit"' "$A/Contents/Resources/install-stamp.json"   # must be patched HEAD, not the tag commit
   ```
7. **Sign** with upstream's routine. It keeps `com.nousresearch.hermes` and an identifier-pinned designated requirement (DR), so TCC grants and Keychain ACLs carry over. Run it from the clone root:
   ```bash
   A="$PWD/apps/desktop/release/mac-arm64/Hermes.app"; xattr -cr "$A"
   ~/.hermes/hermes-agent/venv/bin/python -c "
   import sys; sys.path.insert(0,'.')
   from pathlib import Path
   from hermes_cli import main_desktop as m
   print(m._desktop_macos_local_codesign(Path('$A'), desktop_dir=Path('apps/desktop'), identity='-'))"
   codesign --verify --deep --strict --verbose=2 "$A"   # valid on disk + satisfies its Designated Requirement
   ```
8. **Build the DMG on `~/Desktop`,** where `hermes update` can't clobber it. The name is `Hermes-mac-arm64-mtls-cd-<ver>-<sha10>.dmg`.
   - Stage `Hermes.app` (via `ditto`) and an `/Applications` symlink.
   - `hdiutil create -format UDZO -fs APFS`.
   - `hdiutil verify`.
   - Mount read-only and check the app inside:
     - `codesign --verify --deep --strict`.
     - `lipo -archs` returns `arm64`.
     - `cmp app.asar` against the build.
   - Record `shasum -a 256`.
9. **Save the patches** to the vault.
   - `git format-patch <tag-commit>..HEAD` → a new `port-<date>-v<ver>-<sha7>/` folder, with a `SHA256SUMS.txt` covering the DMG and the patches.
   - Prove the saved copy reproduces the build:
     - `git am` it in a throwaway worktree at the tag.
     - `git diff --quiet` against the build branch.
   - Update "Current patches", "Last build" and the gotchas in the runbook.
10. **Don't install** unless asked. Install steps are in the runbook:
    - Back up to `/Applications/Hermes.app.backup-<date>-<label>`.
    - `ditto` the new app into place.
    - Unregister stray copies with `lsregister -u`.

## Gotchas

- **Never run the full Electron vitest suite (`--project electron`) on the user's desktop session.** It throws a flood of macOS popups and blocks the chat for about 30 minutes. A rejected or interrupted compound command may already have done part of its work: one switched the clone to the base tag, never switched back, and the next build came out stock. After any interruption, check `git status -sb` and `git reflog` before going on.
- **Run long builds in the background** and keep answering the user. A foreground build leaves the user's messages unanswered until it finishes.
- **`git fetch` crashes on the live checkout.** It is a `tree:0` partial clone (`BUG: builtin/pack-objects.c … should_include_obj`). Don't repair it. Clone fresh instead.
- **GitHub clones cut out** with `unexpected disconnect while reading sideband packet` / `early EOF` over HTTP/2, and for blobless clones too. The fix is `-c http.version=HTTP/1.1` with `--depth 1`.
- **`--arm64` breaks the build.** `run-electron-builder.mjs` stages native deps to `build/native-deps-darwin-arm64`, and `frontend-common.mjs` rejects that path. Pass no arch flag.
- **The main process ships unpacked,** in `app.asar.unpacked/dist/electron-main.mjs`. Grepping `app.asar` for mTLS strings finds nothing, and that's expected.
- **Patch offsets look alarming but can be fine.** With `main.ts` churning by thousands of lines, `patch` reports offsets of +325, −418 and +614. Check each hunk lands in the right function, by name, rather than trusting the numbers.
- **Electron passes `host:port`** (e.g. `hermes.domoney.online:443`), not a URL, to `select-client-certificate`. The patch handles this.
- **`security find-identity -p ssl-client` can show nothing** even when the identity works. Use `security find-identity -v -p basic | grep <cn>`.
- **The version label is borrowed from the connected backend.** `package.json` and `CFBundle*` are `0.0.0`. To identify the real build, use `Contents/Resources/install-stamp.json` → `commit`.
- **Updates overwrite the patched app.** `hermes update` and the Desktop **Update now** button both install stock. Rebuild after every update.
- **Known gap:** remote media (`registerMediaProtocol`) is not routed through the certificate session.
- **Keep secrets out:** never copy `.p12`/PEM/tokens/`connection*.json` into the clone or DMG.
- **Hostnames:** `hermes.home` is the LAN name for the same box; the app connects via the FQDN `https://hermes.domoney.online`, which is what the selector must list. Check `connections.json` → `url` if unsure.

## Verify

After the user installs and launches the app, `~/.hermes/logs/desktop.log` should show:

```
[mtls] presenting client certificate <cn> to hermes.domoney.online:443
[mtls] client certificate session ready for https://hermes.domoney.online
[boot] Remote Hermes backend is ready
```

The About screen should show `v<ver>-cd`, the patched commit, and Build Origin `Local (local/desktop-mtls-dmg-<date>)`. If macOS asks about **Hermes Safe Storage**, enter the password and choose **Always Allow**.

## References

- The runbook and the patch folders at the vault path above.
- Upstream: `https://github.com/NousResearch/hermes-agent` (`apps/desktop/electron/main.ts`, `hermes_cli/main_desktop.py::_desktop_macos_local_codesign`)
