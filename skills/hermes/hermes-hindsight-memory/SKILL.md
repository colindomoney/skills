---
name: hermes-hindsight-memory
description: "Run, upgrade, diagnose and recover the self-hosted Hindsight memory server (vectorize-io/hindsight in Docker, embedded pg0 Postgres, Groq gpt-oss) that Hermes Agent uses as its memory.provider in local_external mode on localhost:8888. Use when Hindsight retains or recalls fail, Hermes logs 'Hindsight retain failed' / 'recall failed: Server disconnected' / 422 / 500, memory 'isn't syncing' or 'nothing new since', last_consolidated_at looks stuck, failed_consolidation is non-zero, consolidation hits Groq json_validate_failed, ops sit in 'processing', the hindsight container crash-loops after a reboot ('JSON error: EOF while parsing', 'lock file ... remnant'), backup-alerter flags a STALE hermes_hindsight dump, or when bumping the Hindsight image or Hermes's hindsight plugin."
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, hindsight, docker, compose, postgres, groq, memory"
  version: "0.1.0"
  last-verified: "2026-11-15"
  status: live
---

# Hindsight memory server for Hermes

Hermes's long-term memory runs on a local Hindsight container (`memory.provider: hindsight`, plugin mode `local_external`, `api_url: http://localhost:8888`, bank `hermes`). It fails silently: Hermes keeps working, logs a WARNING, and nothing reaches the bank for weeks. This skill keeps the server pinned to the client, sizes Postgres shared memory properly, and fixes the failure modes that have actually happened.

## When to use / when not to

- Use when: anything about the Hindsight server, its bank, consolidation, or the plugin's retain/recall errors.
- Don't use when: changing which memory provider Hermes uses. It must stay `hindsight`; see the Hermes memory notes, not this skill.
- Don't use when: the Hermes gateway itself is down. See `hermes-tmux-stack`.
- Backups of the bank are taken nightly by `hermes-maintenance.sh` (pg_dump to `~/Backups/hermes/volumes`, shipped to the NAS). That job is outside this skill.

## The canonical form

`references/docker-compose.yml` is the running file from `~/Deployments/Hindsight/docker-compose.yml`, and `references/env.example` is the matching `.env` template. The four lines that matter:

```yaml
    image: ghcr.io/vectorize-io/hindsight:0.10.3      # == hindsight_client in the Hermes venv. Never :latest.
    shm_size: 1g                                      # Docker's 64 MB default breaks pg0
      HINDSIGHT_API_WORKER_ID: hindsight              # fixed, or every recreate orphans in-flight ops
      HINDSIGHT_API_CONSOLIDATION_LLM_MODEL: openai/gpt-oss-120b   # retain/reflect stay on gpt-oss-20b
```

Scripts in `scripts/`:

- `hindsight-health.sh`: read-only. Shows server version against the client version, bank stats, ops by status, image, shm and worker ID. Run it first, every time.
- `hindsight-pg.sh dump|sql`: pg_dump or psql inside the container, with credentials read from pg0's `instance.json`.
- `hindsight-reboot-recover.sh`: takes a cold snapshot, removes 0-byte pg0 state files, then recreates the container.

## Steps

### Diagnose

1. Run `scripts/hindsight-health.sh`. The server `api_version` must equal the venv's `hindsight_client` version. If they differ, every retain fails; go to Upgrade.
2. Check whether writes are actually landing. Run `echo "select date_trunc('day',created_at), count(*) from memory_units where bank_id='hermes' and created_at > now()-interval '30 days' group by 1 order by 1;" | scripts/hindsight-pg.sh sql`. An empty result means Hermes is not writing, however healthy the server looks.
3. Count client-side failures by day in `~/.hermes/logs/agent.log*`: `grep -h -E 'Hindsight (retain|recall|flush-on-shutdown) failed' ~/.hermes/logs/agent.log* | cut -c1-10,40-140 | sort | uniq -c`.
4. If the container is restarting, check `docker inspect hindsight-hindsight-1 --format '{{.RestartCount}}'` and `docker logs --since 10m hindsight-hindsight-1 | grep -E 'RuntimeError|FATAL'`. For the EOF or lock-file errors, see Recover after reboot.

### Upgrade, or bump the pin when Hermes updates its plugin

1. Find the client version: `find ~/.hermes/installs -maxdepth 9 -type d -name 'hindsight_client-*.dist-info'`.
2. Confirm that tag exists. Get a token from `curl -s 'https://ghcr.io/token?scope=repository:vectorize-io/hindsight:pull'`, then `GET https://ghcr.io/v2/vectorize-io/hindsight/tags/list` with `Authorization: Bearer <token>`.
3. Take a dump first, because migrations are one-way: `scripts/hindsight-pg.sh dump > ~/Backups/hermes/volumes/hindsight-pre-<ver>-$(date +%F-%H%M%S).dump`, and check the file starts with `PGDMP`.
4. Change the `image:` tag, then run `docker compose config -q && docker compose pull && docker compose up -d` in the compose directory.
5. Check that `docker logs` shows `Database migrations completed successfully` and `Application startup complete`, then run the health script again.
6. Cancel anything the recreate left in `processing` (see Gotchas).

### Recover after reboot (crash loop, `RestartCount` climbing)

1. Run `scripts/hindsight-reboot-recover.sh`. It stops the container, tars the volume to `~/Backups/hermes/volumes/hindsight-pg0-cold-*.tar.gz`, removes only zero-byte `instance.json`, `postmaster.pid` and `postmaster.opts`, then recreates the container.
2. pg0 regenerates `instance.json` from the credentials it is given on every start (pg0 defaults), so nothing needs to be rebuilt by hand.
3. Check that `docker logs` shows `PostgreSQL started` and that `total_nodes` matches the previous figure.
4. Re-run the nightly backup (`~/.hermes/scripts/hermes-maintenance.sh`) so backup-alerter's `hermes_hindsight` check clears.

### Failed consolidations

1. `failed_consolidation` counts memory units that ran out of LLM retries, not operations. Find them with `select document_id, count(*) from memory_units where consolidation_failed_at is not null group by 1;`.
2. Re-queue them, which is non-destructive: `POST /v1/default/banks/hermes/consolidation/recover`, then `POST /v1/default/banks/hermes/consolidate`.
3. If the same batch fails again with `json_validate_failed`, it will never succeed. There is no endpoint to delete a single unit, so delete the whole source document with `DELETE /v1/default/banks/hermes/documents/<id>`, but only with the user's OK and after a dump. Check first how many units the document holds, because it is usually more than the failed ones.

## Gotchas

- **Unpinned `:latest` is the main failure.** It sat at 0.7.1 from May to November 2026 while the plugin's client moved to 0.10.3. Retains got 422 and no unit was written for 17 weeks. Pin the tag to the client version and re-check it after every `hermes update` or `hermes plugins update hindsight`.
- **64 MB `/dev/shm`.** Retains returned 500: `could not resize shared memory segment ... No space left on device`. Fix it with `shm_size: 1g`.
- **Worker ID defaults to the container hostname.** A worker only reclaims ops under its own ID, so every recreate leaves ops in `processing` forever, and they block later consolidations for the bank. With the ID fixed this stops. To clear orphans, `DELETE /v1/default/banks/hermes/operations/<full-id>`; that cancels `processing` ops too.
- **Stale `last_consolidated_at` is not a stuck queue.** If nothing was written, there is nothing to consolidate. Check `pending_consolidation` and new `memory_units` before blaming consolidation. Hermes's own agent made this mistake.
- **Groq dashboard traffic is not proof memory works.** Calls of 75 tokens in and 38 out are the `Verifying connection` ping at each boot; a crash loop produces one a minute. A real retain is about 3k input tokens.
- **Reboot truncation.** After a clean macOS reboot (Postgres logged a clean shutdown), pg0's `instance.json`, `postmaster.pid` and `postmaster.opts`, and the container's `/tmp/.s.PGSQL.5432.lock`, came back as 0 bytes. The lock file is in the container's writable layer, so a restart keeps it and only a recreate clears it.
- **No retry in `local_external` mode.** The plugin's `_run_hindsight_operation` only reconnects and retries on a dropped connection in `local_embedded` mode. In `local_external`, a stale pooled connection fails the call outright (`Server disconnected`). After a recreate, expect one failure per gateway process, or respawn the gateway. The upstream fix is not yet raised.
- **gpt-oss-20b is unreliable at consolidation JSON.** Groq returns 400 `json_validate_failed` with an empty `failed_generation`, many retries per batch, and some batches never succeed. That is why consolidation alone runs on gpt-oss-120b. Provider and key fall back to the main LLM settings. Don't change models without the user's OK.
- **Pulling images over SSH can fail on the keychain** (`keychain cannot be accessed`). For helper containers, reuse the local Hindsight image (`--entrypoint sh -u 0`) rather than pulling alpine.
- **Before deleting bank data,** take a pg_dump and a cold volume tarball. Neither is pruned automatically, so delete them once the user is satisfied.
- **Don't use `docker exec` against a crash-looping container.** It races the restarts.

## Verify

```bash
scripts/hindsight-health.sh                      # versions equal; shm=1073741824; worker id = hindsight; nothing in processing
curl -s -X POST localhost:8888/v1/default/banks/hermes/consolidate   # then poll the op: status=completed
docker logs --since 10m hindsight-hindsight-1 | grep -c 'scope=consolidation'   # retry errors; expect ~0 on 120b
```

To test a round trip without touching the real bank, use the Hermes venv's own client against a throwaway bank. Call `aretain_batch(bank_id="diag-test", ...)`, wait 15 s (past uvicorn's keep-alive), call `arecall(...)`, then `DELETE /v1/default/banks/diag-test`. Run Python with `-I`, from a scratch directory.

## References

- `references/docker-compose.yml`: the running compose file (`~/Deployments/Hindsight`)
- `references/env.example`: `.env` template (provider, key, base model, retain token cap)
- `references/api.md`: the endpoints used above
- Plugin source: `~/.hermes/plugins/hindsight/__init__.py`; client config: `~/.hermes/hindsight/config.json`
- Related: `hermes-tmux-stack` (gateway respawn), `hermes-macos-nas-backup`
