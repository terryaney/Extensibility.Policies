# Update Script Review Implementation Plan

## Purpose
This document captures the approved implementation scope for improving `AI/skills/kat-policies/scripts/update.ps1`. It is documentation only. It does not implement the changes.

The goal is to keep the policy sync script correct, easier to reason about, and truthful in deployment reporting without expanding ownership behavior beyond the approved scope.

## Approved Decisions
1. Fix the Developer Mode startup bug so a missing registry value does not crash under strict mode.
2. Do not implement historical repo-root tracking. If `publish.repositoryRoot` is removed or changed, cleanup of the previously targeted repo is manual.
3. For current repo-local targets, cleanup should still cover both `.github/agents` and `.claude/agents` plus `.claude/commands` for the currently configured `repositoryRoot` so enabled or target toggles do not leave stale artifacts behind.
4. If publishing any skill primitive into a skill `{id}` folder would place managed content beside remaining unmanaged content, skip publishing that skill target and emit a warning. Cleanup behavior stays unchanged: remove KAT-managed content, remove empty folders, leave unmanaged content alone.
5. Fix Claude command deployment reporting so failures are visible and status is accurate.
6. Remove dead manifest cleanup logic if no manifest lifecycle exists.
7. Reduce duplicate metadata reads and restructure the script into clearer phases or helpers.

## Not In Scope
- No historical manifest or state tracking for prior repo roots.
- No automatic cleanup of a repo after `repositoryRoot` is removed or changed.
- No change to cleanup semantics for unmanaged files beyond blocking side-by-side skill publish.
- No broad architecture rewrite across multiple files unless a coder chooses to do so and keeps behavior equivalent.

## Implementation Plan

### 1. Fix the Developer Mode guard
Status: Complete.

Rationale:
The current startup check can throw before it reaches the intended warning path when the registry value is missing.

Acceptance criteria:
- Missing `AllowDevelopmentWithoutDevLicense` value does not throw.
- The script warns and exits through the existing disabled-Developer-Mode path.
- Existing success behavior is unchanged when the value is present and enabled.

### 2. Preload canonical definitions once
Status: Complete.

Rationale:
The script currently reads canonical metadata more than once. Preloading definitions will reduce duplicate reads and make later phases easier to follow.

Acceptance criteria:
- Agents, instructions, and skills are loaded into in-memory definition objects once per run.
- Each definition includes the metadata and any body content needed later.
- Cleanup and publish phases reuse the same loaded definitions instead of re-reading the same metadata files.

### 3. Refactor the sync flow into named phases or helpers
Status: Complete.

Rationale:
The current flow is difficult to reason about because many concerns are handled inside one large procedure. Separating the phases makes behavior easier to audit and safer to change.

Acceptance criteria:
- The main sync entry point reads as a sequence of named phases.
- Environment discovery, cleanup context generation, publishing, and reporting are separated into helpers.
- Behavior remains equivalent except for the explicitly approved changes in this document.

### 4. Update repo-local cleanup for current `repositoryRoot` cases
Status: Complete.

Rationale:
If `repositoryRoot` is still configured, toggling enabled flags or switching `claude.target` should not leave stale repo-local artifacts behind. The repo path is still known, so cleanup can be broader there.

Acceptance criteria:
- For each currently configured `repositoryRoot`, cleanup scans `.github/agents`, `.claude/agents`, and `.claude/commands` regardless of current enabled flags or current Claude target type.
- Toggling `enabled.vscode`, `enabled.claude`, or `claude.target` does not leave stale artifacts in the currently configured repo.
- The implementation does not add historical tracking for removed or changed repo roots.

Documentation note for coder:
- Add or preserve a clear note that if `publish.repositoryRoot` is removed or changed to a different repo, cleanup of the previously targeted repo is manual.

### 5. Block side-by-side skill publish when unmanaged content remains
Status: Complete.

Rationale:
Cleanup semantics should stay conservative, but publishing managed content beside unmanaged leftovers in a skill `{id}` folder should be treated as unsafe.

Acceptance criteria:
- Normal cleanup behavior remains unchanged.
- Before publishing a skill target folder, the script verifies that any remaining content in that `{id}` folder is fully KAT-managed.
- If unmanaged content remains, publishing for that specific skill target is skipped.
- A warning or blocked status makes the reason visible to the operator.

### 6. Fix Claude exposed-command reporting
Status: Complete.

Rationale:
The deployment summary should reflect reality. If a Claude command cannot be published, the output should not claim full success.

Acceptance criteria:
- Each exposed Claude command publish result is checked.
- Command publish failures are surfaced in deployment reporting.
- The parent Claude skill status no longer reports success when required command publishing failed.

### 7. Remove dead manifest cleanup logic
Status: Complete.

Rationale:
Dead ownership code makes the script harder to understand and creates false expectations about how cleanup state is tracked.

Acceptance criteria:
- If `.kat-managed.json` is not part of a real manifest lifecycle after refactor, the cleanup branch for it is removed.
- Ownership behavior is easier to explain from the code.

### 8. Keep all other behavior stable
Status: Complete.

Rationale:
This pass is intended to improve correctness and maintainability without expanding scope.

Acceptance criteria:
- Publishing targets and supported features remain aligned with the current readme intent.
- No new ownership model is introduced beyond the approved changes above.
- Unrelated behavior is not refactored just because it could be.

## Maintainability Guidance
Use small helpers so the main sync flow is easy to audit. Names may vary, but helpers in this shape are preferred:
- `Get-EnvironmentRoots`
- `Get-AgentDefinitions`
- `Get-InstructionDefinitions`
- `Get-SkillDefinitions`
- `Get-ManagedContexts`
- `Publish-EditorConfig`
- `Publish-TerminalFiles`
- `Publish-Agents`
- `Publish-Instructions`
- `Publish-Skills`
- `Publish-ClaudeDocument`
- `Write-SyncReport`

The point is not the exact names. The point is to separate discovery, cleanup, publishing, and reporting into distinct steps.

## Pester Note
Pester is PowerShell’s common automated test framework. For a .NET developer, the easiest mental model is that it plays the same role that xUnit or NUnit plays for C# tests. It is the standard way to write repeatable PowerShell tests for file-system behavior, function output, and error handling.

## Suggested Follow-up Tests
These tests are optional for the first coding pass.

1. Missing Developer Mode registry value.
2. Repo-local cleanup when enabled flags change but `repositoryRoot` remains configured.
3. Repo-local cleanup when `claude.target` flips between agent and command.
4. Skill publish blocked by an unmanaged file in the target `{id}` folder.
5. Claude command publish conflict is reported correctly.

## Handoff Notes
- Preserve existing cleanup semantics except where this document explicitly changes them.
- Do not expand repo ownership tracking beyond the approved scope.
- Prefer small, named helpers over one larger procedural block.
- Keep the implementation pragmatic and behaviorally tight.