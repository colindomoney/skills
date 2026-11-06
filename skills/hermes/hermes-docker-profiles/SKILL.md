---
name: hermes-docker-profiles
description: Stand up or rebuild a custom Hermes Agent (Nous Research) in Docker from the nousresearch/hermes-agent image (above 0.22.0), with the Hermes home bind-mounted from ./hermes-home to /opt/data, one multiplexing gateway serving N profiles, an idempotent bootstrap.sh that halts for the human logins (portal, bot tokens in profile .env, MCP OAuth paste-back) and a deploy.sh that syncs SOUL.md, skills and scripts from git. Use when starting a new dockerised Hermes agent project, "run Hermes in Docker", adding a profile, doing the portal or MCP login in the container, turning on the dashboard, bumping the Hermes image, or debugging restart loops, 409 Conflict, or "authentication failed" on every Telegram message.
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, docker, compose, hermes-agent, telegram, oauth"
  version: "0.2.0"
  last-verified: "YYYY-MM-DD"
  status: skeleton
---

# Hermes Agent in Docker: home bind mount, profiles, logins

One container from the stock `nousresearch/hermes-agent` image, pinned by digest. The whole Hermes home is a gitignored bind mount (`./hermes-home` to `/opt/data`), and everything versioned (souls, skills, scripts) lives in git and is copied in by `deploy.sh`. A rebuild is therefore git plus a handful of logins.

Written for Hermes above 0.22.0, starting from the `stable` image tag. Hermes moves quickly, so treat specifics as a starting point: when behaviour disagrees with this file, read the image (`docker run --rm --entrypoint sh <image> -c '...'`, starting at `/opt/hermes/docker/`) and believe it.

## When to use / when not to

- **Use when** building a single-purpose agent (chat bot, worker pipeline) that should be reproducible from git.
- **Don't use when** Hermes runs natively on a Mac: use `hermes-macos-launchd` or `hermes-tmux-stack`.
- **Out of scope:** Kanban dispatcher design, cron job design, publishing pipelines.

## The canonical form

All in `references/`. Copy them to a new repo root, then replace the placeholders.

| Placeholder | Where | Replace with |
|---|---|---|
| `PROJECT` | `project.conf`, `docker-compose.yml` | Container and image name |
| `PROFILE_ONE`, `PROFILE_TWO` | `project.conf` | Your profile names |

| File | Role |
|---|---|
| `project.conf` | The one file a project edits: profiles, bot profiles, skills, cwd, model pins, disabled toolsets, hooks, data dirs |
| `Dockerfile` | `FROM` by digest, plus only what the image lacks. Never redefine ENTRYPOINT, CMD, `HERMES_HOME` or the user |
| `docker-compose.yml` | The runtime contract, including `command: ["gateway", "run"]` |
| `bootstrap.sh` | Idempotent stand-up that halts for humans. `--verify` proves it |
| `deploy.sh` | Repo to home: souls, skills, scripts, hook allowlist |
| `backup.sh` | Tars `DATA_DIRS` only, and refuses secret-shaped paths |

The runtime shape, tested on `stable`:

```text
container -> s6 -> root `gateway run` (one process, one poller per token)
                   |- serves default
                   |- serves PROFILE_ONE (own .env, own bot token, own SOUL, skills, cron)
                   `- serves PROFILE_TWO
```

Repo layout: the files above plus `soul/`, `skills/`, `scripts/`, `data/`. `.gitignore` must list `hermes-home/` and every data mount.

## Steps

1. **Create the repo** from `references/`, and edit `project.conf` and `docker-compose.yml`. List every writable mount in `HERMES_WRITE_SAFE_ROOT`, and set `TZ`.
2. **Pin the image:**
   ```sh
   docker pull nousresearch/hermes-agent:stable
   docker image inspect --format '{{index .RepoDigests 0}}' nousresearch/hermes-agent:stable   # into FROM
   ```
3. **Run `./bootstrap.sh`.** It builds, starts the container (safe with no tokens, because nothing polls), and halts at H1:
   ```sh
   docker exec -it --user hermes -e HOME=/opt/data PROJECT hermes setup --portal
   ```
4. **Re-run.** It creates profiles, applies settings, deploys content, and halts at H2 for bot tokens. Edit `hermes-home/profiles/<p>/.env` (0600) by hand, never `echo >>`, never through an agent. Bootstrap checks shape and never prints values.
5. **Re-run with `RESTART=1`** so the gateway reads the tokens.
6. **MCP OAuth, if any.** The callback binds 127.0.0.1 inside the container, so it completes by paste-back within 300 s:
   ```sh
   docker exec -it --user hermes PROJECT hermes -p <p> mcp login <server>
   ```
   Open the printed URL on the host, authorise, copy the dead `http://127.0.0.1:<port>/callback?code=...` URL from the address bar, and paste it at the prompt. Proof: `profiles/<p>/mcp-tokens/<server>.json`.
7. **Dashboard, if wanted.** Write `HERMES_DASHBOARD_BASIC_AUTH_USERNAME` and `_PASSWORD` to `hermes-home/dashboard.env` by hand, then re-run. Bootstrap adds `HERMES_DASHBOARD=1` and a session secret. The compose port stays on loopback.
8. **After any repo change:** `./deploy.sh`, then `/new` to the bot. After `config.yaml`, tokens or hooks: `docker compose restart`.

### Add a profile

Add it to `PROFILES` and each `case` in `project.conf`, add `soul/<p>.md`, then `./bootstrap.sh`. A running gateway picks new profiles up by itself; give a new bot a restart.

### Bump the image

1. Back up first: `docker compose stop`, then `tar czf` the whole `hermes-home/`. It holds secrets, so keep it out of synced folders.
2. Move the digest in `FROM`, then `REBUILD=1 ./bootstrap.sh`, then `./bootstrap.sh --verify`.
3. **To roll back,** restore that tarball with the old digest. Newer images add runtime history to `state.db` under the same `schema_version`, and swapping a tag isn't caught by any downgrade guard. An older image on that home may be unable to delete those sessions.

## Gotchas

**Topology**
- **One multiplexing root gateway is the supported shape.** Use `command: ["gateway", "run"]`. `["-p", "<p>", "gateway", "run"]` gave three gateway processes and repeated restarts when tested, with exit 78 possible by the source. `gateway.standalone: true` on a profile is the opt-out if you really need a separate process.
- **One bot token, one poller.** New bot per profile. Stop the old container before starting on a second machine, and `down` it: `restart: unless-stopped` resurrects a stopped one.
- **The root profile carries no token,** so a login or CLI call can never become a second poller.
- **Never `docker compose run` once the home exists.** It goes through s6 `/init` and its boot reconciler, which can start another gateway: 409 Conflict, messages silently eaten. Use `docker exec --user hermes -e HOME=/opt/data`.

**Identity and auth**
- **Always `--user hermes`.** A root-owned file under `hermes-home/` presents as "authentication failed" on every Telegram message while CLI tests pass.
- **Under `-p`, `HERMES_HOME` is the profile dir.** Scripts resolve paths from it.
- **`HERMES_PROFILE` is not `-p`.** It silently runs the default profile and SOUL. Confirm who answered before debugging anything.
- **Never copy `auth.json`.** Profiles fall back to the root one. Nous refresh tokens are single-use, so a copy's first refresh can revoke the original days later. Bootstrap removes stale copies.
- **A login can crash after succeeding** with `FileExistsError: /opt/data`. The token is already saved.
- **A new profile has its own seeded `model` block,** so it doesn't follow the root login. Bootstrap copies it across on each run, and `model_for` pins override it.

**Settings**
- **`display.busy_input_mode: queue`** gives each message its own turn.
- **`terminal.home_mode: real`,** or tool subprocesses get `HOME=$HERMES_HOME/home` and a different `auth.json`.
- **`HERMES_WRITE_SAFE_ROOT`** ships as `/opt/data` only. `write_file` and `patch` hard-fail on any other mount.
- **`agent.disabled_toolsets`** is the hard suppression list. Never put composites (`debugging`, `safe`, `coding`) in it, because they expand to terminal and file tools.
- **`session_reset` is ignored.** Send `/new` after a deploy.
- **The container's Python has `ruamel.yaml`, not PyYAML.** Its interpreter is `/opt/hermes/.venv/bin/python`.

**Hooks**
- **Hermes runs the command without a shell.** It expands `~`, never `$VAR`, so use absolute interpreter and script paths.
- **The allowlist pins `script_mtime_at_approval`.** Any edit or fresh checkout makes a hook silently inert until re-seeded, so `deploy.sh` re-seeds it last and uses `rsync -a`, not Finder. The gateway reads the allowlist at start, so restart after a hook change. `hooks_auto_accept: true` is required, because the gateway has no TTY.
- **Under multiplexing, secondary-profile hooks run with secrets scrubbed.** Read `.env` by path if a hook needs one.

**Cron and agents**
- **`cron/jobs.json` is ground truth.** Never parse `cron list`. `cron edit` takes the id, and `--model` works there; the agent-facing `cronjob` tool has no model field.
- **The cron environment is sanitised,** so scripts read `.env` by path. Its runner pipes stdout, so spawned workers must detach their file descriptors.
- **`HERMES_CRON_SCRIPT_TIMEOUT`** defaults to 3600. Set your own ceiling.
- **Gateway sessions never see `AGENTS.md` or `CLAUDE.md`,** so instructions belong in a skill.
- **A silent reply to a human turn is rejected.**
- **If the host sleeps, the scheduler stops,** and overdue jobs catch up outside their window.

**Docker and storage**
- **Named volumes are created root-owned.** For a `node_modules` volume over a bind mount, run `docker exec --user root <c> chown 10000:10000 <path>` once.
- **Mounts look foreign-owned to git.** Add each to `safe.directory` in `hermes-home/.gitconfig`.
- **Never live-sync `hermes-home/`** (cloud-sync folders): the gateway holds SQLite files open, and sync has corrupted them. Keep the repo outside synced folders, and don't rely on `hermes backup`, which bundles secrets.
- **A dashboard on a non-loopback bind needs an auth provider,** or it exits and s6 loops, showing `ERR_EMPTY_RESPONSE`.
- **Lazy-installed backends land in `/opt/data/installs`,** so the home grows. `security.allow_lazy_installs: false` turns that off.

**Moving to another machine**
- Stop the old container first and check for in-flight work, then `rsync -aHX` so mtimes survive, then `down` the old one. Enable Docker's launch at login on the new host, and pin `TZ`.

## Verify

```sh
./bootstrap.sh --verify
docker logs --tail 300 PROJECT 2>&1 | grep -i '409 conflict'                  # first, always
docker exec --user hermes -e HOME=/opt/data PROJECT hermes -p <p> doctor
docker exec --user hermes -e HOME=/opt/data PROJECT hermes profile list
grep -E 'MULTIPLEX|Cron scheduler' hermes-home/logs/gateway.log | tail -5      # every profile served and ticked
sqlite3 hermes-home/profiles/<p>/state.db 'select model from sessions order by started_at desc limit 1'
```

The model in `state.db` is the evidence, not `config.yaml`. Done means a real message round-trips on the platform, not a green `doctor`. Debug order: container, 409, doctor, one CLI turn, gateway, platform.

## References

- `references/`: `project.conf`, `Dockerfile`, `docker-compose.yml`, `bootstrap.sh`, `deploy.sh`, `backup.sh`
