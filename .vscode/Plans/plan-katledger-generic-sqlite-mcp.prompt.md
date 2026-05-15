## Plan: Generic KatLedger SQLite MCP

Evolve KatLedger from an Anvil-shaped verification ledger into a general-purpose local SQLite MCP server for KAT agents and skills.

### Problem

The current KatLedger server still hardcodes the `anvil_checks` table and only exposes the `insert_check`, `count_checks`, `list_checks`, and `read_checks` workflow with required `workspace` and `task_id` fields. That does not match the broader goal of reusable persistent local storage for future VS Code agents.

### Decisions

1. Use a **hybrid** contract: generic SQL capabilities are the primary surface, with convenience helpers allowed only if they add clear value.
2. Replace the current Anvil-specific tool surface **in one cut** rather than keeping temporary compatibility wrappers.
3. Keep one canonical local database at `%USERPROFILE%\.kat\KatLedger\KatLedger.db`.

### Proposed Direction

1. Redesign the MCP tool surface under `kat/ledger/*` around generic database access.
2. Remove hardcoded Anvil schema assumptions from the server runtime.
3. Move agent-specific rules such as `workspace`, `task_id`, and table naming conventions into agent prompts instead of the MCP server.
4. Update Anvil to create and manage its own tables explicitly through the generic KatLedger contract.
5. Refresh packaging, release notes, installer assumptions, and verification coverage for the new generic runtime.

### Planned Work

#### Phase 1 - Contract redesign

- Define the generic KatLedger tool set.
- Finalize which operations are included in the hybrid contract.
- Define result shapes, error behavior, and practical response-size limits.
- Define SQL safety boundaries for a single local DB file.

#### Phase 2 - Runtime refactor

- Replace `anvil_checks`-specific methods in the standalone `Mcp.KatLedger` repo.
- Remove server-enforced `workspace` / `task_id` / `phase` semantics.
- Add generic execution/query logic against `%USERPROFILE%\.kat\KatLedger\KatLedger.db`.
- Preserve stable startup/bootstrap behavior for the DB file and install root.

#### Phase 3 - Anvil migration

- Update Anvil metadata and prompts to use the generic KatLedger operations.
- Make Anvil own its schema creation and table naming explicitly.
- Remove assumptions that the server owns the `anvil_checks` lifecycle.

#### Phase 4 - Packaging and install updates

- Update docs, self-test coverage, and release packaging in `Mcp.KatLedger`.
- Confirm KatPolicies installer/release assumptions still match the new runtime contract.
- Ensure `update.ps1` remains release-driven and local-install based.

#### Phase 5 - Verification

- Validate generic table creation, inserts, queries, updates, and deletes.
- Validate Anvil’s migrated schema flow end to end.
- Confirm release packaging, install path, and deployed runtime remain correct.

### Relevant Repos / Files

- `C:\BTR\Extensibility\Mcp.KatLedger\*`
- `C:\BTR\Extensibility\Policies\AI\agents\anvil\meta.jsonc`
- `C:\BTR\Extensibility\Policies\AI\agents\anvil\body.md`
- `C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\install-katledger.ps1`
- `C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\update.ps1`

### Todo Breakdown

- `plan-katledger-contract`
- `refactor-katledger-runtime`
- `migrate-anvil-ledger-usage`
- `refresh-katledger-release`
- `verify-generic-katledger`
