---
name: hermes-lmstudio-provider
description: Add a local LM Studio server (OpenAI-compatible, 127.0.0.1:1234) as a selectable provider in Hermes Agent so its models show in the dashboard/web UI model picker, including reloading the LM Studio model at 64k context and restarting the Hermes dashboard. Use when adding LM Studio to Hermes, using a local model in Hermes, LM Studio missing from the Hermes dashboard picker, Hermes rejecting a model as "below the minimum 64,000" context, or speed-testing a model served by LM Studio.
license: MIT
metadata:
  author: colindomoney
  tags: "hermes, lmstudio, llm, local-models, gguf, mlx"
  version: "0.1.0"
  last-verified: "2026-10-09"
  status: live
---

# Hermes: LM Studio as a provider

Hermes Agent ships a built-in `lmstudio` provider (default `http://127.0.0.1:1234/v1`, no key needed when LM Studio auth is off), so no `custom_providers` entry is needed. Two things stop it working out of the box: Hermes refuses any model loaded with under 64k context, and the dashboard model picker hides LM Studio unless it is the active provider or has a `providers.lmstudio` block that declares its models. The steps below add it as an on-demand option without changing the default provider. If you want it as the default, run `hermes model` and pick LM Studio instead.

## When to use / when not to

- Use when: LM Studio runs on the same machine as Hermes and you want its models selectable per session (CLI `/model`, `--provider lmstudio`, or the dashboard picker).
- Don't use when: the model is served by vLLM/llama-server/another host. Use a `custom_providers:` entry with `base_url`, `api_key`, `model`, `models.<id>.context_length` instead (the existing `Spark` entry in `~/.hermes/config.yaml` is the example).

## The canonical form

Appended to `~/.hermes/config.yaml` (there was no existing top-level `providers:` key; merge into it if there is one):

```yaml
providers:
  lmstudio:
    models:
    - ornith-1.5-35b-a3b
```

Do not add `base_url` to this block. With a `base_url`, Hermes treats the entry as a custom endpoint and handles it differently.

LM Studio model load at Hermes' minimum context:

```bash
lms load <model-id> --context-length 65536 --estimate-only   # check it fits
lms unload <model-id>
lms load <model-id> --context-length 65536 -y
lms ps                                                       # CONTEXT column = 65536
```

`lms` is on PATH or at `~/.lmstudio/bin/lms`.

## Steps

1. Confirm the server and get exact model IDs:
   `curl -s http://127.0.0.1:1234/api/v0/models` (shows `state`, `loaded_context_length`, `max_context_length`, `capabilities`).
2. Reload the model at 65536 context (above). Check with `lms ps`.
3. Smoke-test through Hermes without touching config:
   `hermes -z "Reply with exactly: LMSTUDIO_OK" --provider lmstudio -m <model-id>`
4. Back up and edit config: `cp ~/.hermes/config.yaml ~/.hermes/config.yaml.pre-lmstudio.bak`, then add the `providers.lmstudio.models` block.
5. Validate config loads and the default provider is unchanged (run from `~/.hermes/hermes-agent`):
   ```bash
   venv/bin/python -c "
   from hermes_cli.config import load_config
   from hermes_cli.model_switch_providers import list_authenticated_providers as f
   c=load_config()
   rows=f(current_provider=c['model']['provider'], user_providers=c.get('providers'), custom_providers=c.get('custom_providers'), for_picker=True, non_blocking_catalogs=True)
   print([(r['slug'], r['models']) for r in rows if r['slug']=='lmstudio'], c['model']['provider'])"
   ```
   Expect `[('lmstudio', ['<model-id>'])]` and the original default provider.
6. Restart the dashboard (see Gotchas for why `--stop` may not work):
   ```bash
   kill $(lsof -nP -tiTCP:9119 -sTCP:LISTEN)
   cd ~ && nohup hermes dashboard --no-open > ~/.hermes/logs/dashboard-manual.log 2>&1 &
   grep DASHBOARD_READY ~/.hermes/logs/dashboard-manual.log
   ```
7. Reload the web UI at http://127.0.0.1:9119; LM Studio appears in the model picker.

## Gotchas

- **64k minimum.** LM Studio's default load was 8,192 tokens. Hermes then fails with `Model ... has a context window of 8,192 tokens, which is below the minimum 64,000 required by Hermes Agent`. If you reload at 64k with `lms`, that setting is lost the next time the model unloads (TTL, eviction, restart). To make it stick, set the per-model default in LM Studio: My Models → gear icon on the model → Context Length 65536. Hermes' `model.context_length` is not a fix: it only applies to the *default* provider's runtime.
- **Picker visibility.** A bare `providers: {lmstudio: {}}` makes the row appear with an **empty model list**. Hermes only live-probes LM Studio's catalogue when it is the active provider. Declare the models explicitly.
- **Restarting the dashboard.** If the dashboard was started by hand from a shell, `hermes dashboard --status` reports "No hermes dashboard or serve processes running" while it is still listening on 9119, and `--stop` won't find it. Kill the listener on 9119 directly. Relaunching with `nohup` detaches it, but it won't survive a reboot.
- **Restarting only isn't enough.** Restarting the dashboard does nothing until the `providers.lmstudio` block exists.
- **Gateway.** The messaging gateway (`ai.hermes.gateway`, launchd) was not restarted in the original setup. Only the dashboard needed it for the picker. [not covered: whether gateway sessions see the new provider without a restart]
- **Reasoning models eat tokens.** Thinking models (e.g. Qwen3.5-MoE derivatives) can spend the whole `max_tokens` budget in `reasoning_content` before they answer. Allow for it when timing or capping output.
- **Speculative decoding.** It was on by default with only ~41% draft acceptance on a small-active-parameter MoE. It may cost more than it saves; benchmark with it off.

## Verify

- `lms ps` shows the model `IDLE` with `CONTEXT 65536`.
- The step 3 smoke test prints `LMSTUDIO_OK`.
- The step 5 script lists the model under `lmstudio` and the default provider is unchanged.
- The dashboard picker at http://127.0.0.1:9119 shows "LM Studio" with the model.

## Speed test (optional)

Use LM Studio's native endpoint, which returns `stats.tokens_per_second` and `stats.time_to_first_token`:

```bash
curl -s http://127.0.0.1:1234/api/v0/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"<model-id>","messages":[{"role":"user","content":"Write 600 words on TLS 1.3 handshakes."}],"max_tokens":1500}' \
  | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["stats"], d["usage"])'
```

For prefill speed, send a long random-word prompt and divide `prompt_tokens` by `time_to_first_token`. Reference figures on an M4 Pro (64 GB) with `ornith-1.5-35b-a3b` Q4_K_M: ~55 tok/s generation, ~700 tok/s prefill, so a 6k-token prompt waits ~8.5 s for its first token.

## References

- Hermes docs: `~/.hermes/hermes-agent/website/docs/integrations/providers.md` ("LM Studio — Desktop App with Local Models"); `lmstudio_load_mode` (`explicit` default, `jit` for LM Studio JIT/auto-evict).
- Picker logic: `~/.hermes/hermes-agent/hermes_cli/model_switch_providers.py` (`_lap_lmstudio_row`).
- Load logic: `~/.hermes/hermes-agent/hermes_cli/models_local.py` (`ensure_lmstudio_model_loaded`).
