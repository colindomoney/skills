# Hindsight 0.10.3 API endpoints used for operations

Base `http://localhost:8888`. Full spec: `GET /openapi.json`.

| Call | Purpose |
|---|---|
| `GET /version` | `api_version`; must equal Hermes venv `hindsight_client` |
| `GET /v1/default/banks/{bank}/stats` | `total_nodes`, `total_documents`, `total_observations`, `last_consolidated_at`, `pending_consolidation`, `failed_consolidation` (memory units, not ops), `failed_operations` |
| `GET /v1/default/banks/{bank}/operations?status=pending\|processing\|failed&limit=N` | queue; `task_type`, `error_message` |
| `GET /v1/default/banks/{bank}/operations/{id}` | one op; `status` |
| `DELETE /v1/default/banks/{bank}/operations/{id}` | cancel; works on orphaned `processing` ops (needs full UUID) |
| `POST /v1/default/banks/{bank}/consolidate` | trigger consolidation; returns `operation_id` |
| `POST /v1/default/banks/{bank}/consolidation/recover` | reset units marked failed so the next run retries them; non-destructive |
| `DELETE /v1/default/banks/{bank}/documents/{document_id}` | delete a document and all its memory units (no per-unit delete exists) |
| `DELETE /v1/default/banks/{bank}` | delete a whole bank; only for throwaway test banks |

Useful SQL (via `scripts/hindsight-pg.sh sql`), table `memory_units`: columns `bank_id`, `fact_type` (`experience|world|observation`), `document_id`, `created_at`, `consolidated_at`, `consolidation_failed_at`. Table `async_operations`: `operation_type`, `status`, `worker_id`, `error_message`.
