## Plan: Local SQL MCP Auto-Bootstrap

Build a local MCP server with SQLite-backed ledger operations, then integrate it into the existing KAT bootstrap flow so update.ps1 installs/configures it automatically for VS Code, Copilot CLI, and Claude. Use structured tool operations instead of raw SQL so statement whitelisting is largely unnecessary while still preventing destructive misuse.

**Steps**
1. Phase 1 - Define tool contract and runtime decisions.
2. Finalize MCP tool name (`anvil/sql_local`) and operation surface (`read_checks`, `insert_check`, `count_checks`, `list_checks`) with structured parameters instead of free-form SQL.
3. Decide canonical DB path (`%USERPROFILE%/.copilot/agents/anvil.db`) and schema initialization behavior (`CREATE TABLE IF NOT EXISTS anvil_checks`, optional `schema_version`).
4. Define workspace scoping contract: always require `workspace` and `task_id` in write/read operations to avoid cross-repo collisions.
5. Phase 2 - Implement local MCP server.
6. Create a new local MCP server under the repo (recommended location: `AI/skills/kat-policies/mcp/sql-local/`) with one exposed tool namespace (`anvil/sql_local/*`).
7. Implement startup bootstrap in server process: ensure DB directory exists, open SQLite DB, run schema migration SQL idempotently.
8. Implement structured handlers for each operation and parameter validation (required fields, max output snippet length, enum validation for `phase`, integer validation for `passed`).
9. Add minimal guardrails instead of statement whitelist: only server-owned SQL templates, no pass-through SQL endpoint, and operation-level validation.
10. Phase 3 - Add KAT bootstrap installer parity flow.
11. Add new helper script `AI/skills/kat-policies/scripts/install-sql-local.ps1` following existing `-CheckOnly/-PassThru` pattern from context7/github helpers.
12. In helper, configure MCP client files for all selected clients: `%APPDATA%/Code/User/mcp.json`, `%USERPROFILE%/.copilot/mcp-config.json`, `%USERPROFILE%/.claude.json` with local stdio server entry for `anvil/sql_local`.
13. Extend `AI/skills/kat-policies/scripts/update.ps1` with parity detection function for `anvil/sql_local`, and invoke bootstrap using `Invoke-McpRemoteBootstrap` pattern (same install prompt and blocked handling style).
14. Update `AI/agents/anvil/meta.jsonc` to include required tool ID (`anvil/sql_local/*` or exact IDs based on final server tooling).
15. Phase 4 - Update Anvil instructions and verification behavior.
16. Update `AI/agents/anvil/body.md` copilot-vscode section to instruct ledger reads/writes through `anvil/sql_local` tool operations, not `session_store_sql` and not terminal duckdb CLI.
17. Keep copilot-cli sections unchanged where they intentionally use `session_store`, unless you explicitly want CLI to also use local MCP.
18. Replace SQL examples in vscode-only sections with operation examples that map to structured calls (`insert_check`, `count_checks`, `list_checks`) and ensure workspace/task filters are explicit.
19. Phase 5 - Verification and rollout.
20. Validate bootstrap check mode: run `install-sql-local.ps1 -CheckOnly -PassThru` and ensure status transitions (`needs-install` to `ok`) mirror existing helpers.
21. Validate full sync path: run `AI/skills/kat-policies/scripts/update.ps1` and confirm MCP entries are written for all selected clients.
22. Perform end-to-end smoke test with Anvil prompt: baseline insert, after insert, review insert, count gate query, evidence list query.
23. Add failure-mode checks: missing runtime binary, blocked config write, unavailable client, and ensure clear `blocked/no-client` result reporting.

**Relevant files**
- `c:/BTR/Extensibility/Policies/AI/skills/kat-policies/scripts/update.ps1` - add sql-local parity detection + bootstrap invocation.
- `c:/BTR/Extensibility/Policies/AI/skills/kat-policies/scripts/Kat.Policy.Mcp.psm1` - reuse shared config mutation helpers; only extend if a missing helper is needed.
- `c:/BTR/Extensibility/Policies/AI/skills/kat-policies/scripts/install-context7-remote.ps1` - implementation template for check/apply pattern.
- `c:/BTR/Extensibility/Policies/AI/skills/kat-policies/scripts/install-github-remote.ps1` - implementation template for client config writes and pass-thru status.
- `c:/BTR/Extensibility/Policies/AI/agents/anvil/meta.jsonc` - declare `anvil/sql_local` tool requirement.
- `c:/BTR/Extensibility/Policies/AI/agents/anvil/body.md` - switch VS Code ledger instructions to local MCP operations.
- `c:/BTR/Extensibility/Policies/AI/skills/kat-policies/mcp/sql-local/*` - new local MCP server implementation.
- `c:/BTR/Extensibility/Policies/AI/skills/kat-policies/scripts/meta.mappings.jsonc` - optional only if client alias mapping is required.

**Verification**
1. Run helper in check mode and inspect `IsCompliant/RequiresInstall/HasBlocked` pass-thru values.
2. Run update sync and confirm deployment report includes sql-local bootstrap outcome.
3. Verify each client config contains expected stdio MCP server entry and survives reruns idempotently.
4. Trigger Anvil ledger workflow and confirm rows appear in `anvil_checks` with correct `workspace/task_id/phase` values.
5. Confirm cross-workspace isolation by writing from two different workspace paths and querying by workspace.

**Decisions**
- Include: local-only MCP server, SQLite backend, structured operation surface, auto-install in update.ps1, all three clients auto-configured.
- Exclude: MSLocalDB backend, remote HTTP service, terminal duckdb dependency, raw SQL pass-through endpoint.
- On whitelist question: with structured operations, statement whitelisting is not needed because the server never accepts arbitrary SQL. If you later add raw SQL mode, whitelist/guardrails become mandatory.

**Further Considerations**
1. Runtime packaging choice for MCP server: Option A Node single-script, Option B .NET single-file exe. Recommendation: choose .NET single-file on this Windows-first stack for easiest deployment via PowerShell.
2. CLI parity strategy: keep CLI on session_store for now vs unify CLI with local sql MCP. Recommendation: keep current CLI behavior now and unify later only if needed.
3. Schema evolution policy: migration table (`schema_version`) now vs ad hoc later. Recommendation: add minimal schema versioning now to avoid fragile future upgrades.