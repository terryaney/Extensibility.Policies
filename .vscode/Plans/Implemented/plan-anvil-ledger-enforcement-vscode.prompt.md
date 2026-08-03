## Plan: Anvil Ledger Enforcement (VS Code)

Harden `AI\agents\anvil\body.md` so Medium/Large tasks cannot complete unless KatLedger evidence is complete, scoped to the current workspace, and collision-safe across reruns.

### Problem statement

Anvil already defines baseline/after/review ledger phases, but enforcement can still be bypassed by weak gate placement and deterministic `task_id` reuse. Result: partial evidence can look complete, and reruns can pollute prior task rows.

### Outcome target

1. A Medium/Large run must fail closed if required ledger rows are missing.
2. `workspace + task_id` must be unique per execution, even for repeated prompts.
3. Completion messaging must be blocked until ledger count gates pass.

### Design decisions

1. **Edit in place, not add-on policy block**  
   Strengthen the existing sections (`Task Sizing`, `Verification Ledger`, `3b`, `5b`, `5c`, `5e`, `Rules`) instead of introducing a second enforcement layer.

2. **Two-stage identifier (no schema change)**  
   Generate internal `base_task_id` from prompt text, then derive execution `task_id` with collision handling:
   - Query existing rows for current `workspace + base_task_id`.
   - If collision exists, append deterministic suffix (`-r2`, `-r3`, ...).
   - Use only final `task_id` for all inserts/selects.

3. **No silent downgrade**  
   Once classified Medium/Large, verification cannot degrade to Small-path behavior without explicit user waiver.

4. **Miss handling is mandatory**  
   On first missing required ledger step, force decision via `ask_user`:
   - Backfill now
   - Continue with waiver
   - Abort
   No completion response while unresolved.

### Planned edits by section

#### 1. `## Task Sizing`
- Require an explicit single-line size declaration before Step 4.
- Add escalation triggers for multi-file edits or public behavior changes.
- Add a hard prohibition on post-hoc downgrading to avoid ledger obligations.

#### 2. `## Verification Ledger`
- Introduce internal `base_task_id` and collision-safe final `task_id` lifecycle.
- Require `workspace` and final `task_id` on every ledger operation.
- Add explicit precondition: no Step 4 edits until baseline rows exist for this execution.

#### 3. `### 3b. Baseline Capture`
- Add hard gate query with minimum required baseline counts by task size.
- State that zero baseline rows is a blocking error, not a warning.

#### 4. `### 5b`, `### 5c`, `### 5e`
- Add minimum count gates per size:
  - Medium: baseline >= 1, after >= 2, review >= 1
  - Large: baseline >= 1, after >= 3, review >= 3
- Explicitly disallow review rows from satisfying after-phase gates.
- Require failed checks to be inserted before retry logic.

#### 5. `### 7. Present` and `## Rules`
- Add final pre-present gate query that checks all required counts.
- Block any completion-style language when counts fail.
- Add global rules:
  - No silent downgrade
  - No completion before gate query
  - No skipped insert for any verification signal

### Files in scope

- `C:\BTR\Extensibility\Policies\AI\agents\anvil\body.md`

### Validation plan

1. Run a Medium workflow and verify baseline/after/review counts satisfy gates.
2. Re-run same prompt in same workspace and verify new `task_id` is created.
3. Simulate missing after rows and verify completion path is blocked.
4. Verify review-only rows do not satisfy after-phase minimums.

### Out of scope

- Reworking non-ledger Anvil behavior
- Changing CLI-only policies unrelated to VS Code ledger enforcement
