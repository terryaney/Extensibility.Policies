## Plan: KAT Policies Workflow Hardening

Stabilize credential detection and execution order, reduce workflow noise, and simplify deployed artifacts so skill runs are minimal by default while detailed output remains available on demand. The implementation will move kat-policies runtime scripts to a repo-root scripts path, merge metadata into one source, remove unsupported skill frontmatter fields for VS Code compatibility, and make update.ps1 the single source for settings safeguards and summary tables.

**Steps**
1. Phase 1: Metadata and path consolidation baseline.
2. Move kat-policies runtime scripts from AI/skills/kat-policies/scripts to scripts/kat-policies and update all hardcoded references in skill text and script loaders to the new canonical path.
3. Merge shared MCP/tool mapping metadata into AI/skills/kat-policies/meta.jsonc, remove scripts/meta.jsonc usage, and update loading functions in update.ps1 to read only one metadata file.
4. Update generated/deployed skill packaging so runtime scripts are not copied into deployed skill folders unless explicitly required by a client runtime contract. This removes the confusing scripts artifact footprint. Depends on steps 2-3.
5. Phase 2: Credential and bootstrap correctness.
6. Reorder skill workflow so git pull is attempted before bootstrap credential checks, and preserve explicit warning text when pull fails due to unstaged changes/conflicts.
7. Fix CheckOnly compliance logic in install-context7-remote.ps1 and install-github-remote.ps1 so a configuration is only marked compliant when referenced environment credentials actually exist. This prevents false compliant states.
8. Adjust update.ps1 Invoke-McpBootstrap flow so a stale-config CheckOnly result cannot suppress required credential handling and blocked reporting. Depends on step 7.
9. Keep manual update.ps1 behavior unchanged for interactive terminal prompting; only tighten non-interactive/chat gating and reporting behavior.
10. Phase 3: Skill UX and response shaping.
11. Remove step-by-step narrative response requirements from SKILL.md and switch to end-only summary output, with prompts only for user action (platform approvals or credential collection).
12. Remove unsupported allowed-tools frontmatter emission from generated Copilot skill documents in update.ps1 to eliminate VS Code validation warnings.
13. Ensure body replacement tokens (including KAT_QUESTION_TOOL_GUIDANCE) are fully resolved in generated skill outputs after metadata merge; add validation check so unresolved tokens are reported as blocked/warning.
14. Implement output mode policy: default minimal summary and script tables only; detailed artifact/location reporting only when detailed verbosity is requested.
15. Phase 4: Reporting and settings safeguards in update.ps1.
16. Make Write-ArtifactLocationsTable run only for detailed verbosity.
17. Refactor Write-ConfigurationLocationsTable to default columns Type | Status and include Location only in detailed mode.
18. Move VS Code duplicate-context settings check/apply flow into update.ps1 so manual runs and skill runs share one enforcement path and one reporting model.
19. Add a canonical settings metadata file (meta.vscode.settings.jsonc) and implement script-side reconciliation/apply logic with explicit status reporting in Configuration Locations. Depends on step 18.
20. Update final skill summary contract to remove the workflow status table and include: pull warning (if any), direct sync outcome sentence, required script tables, and explicit skipped/blocked reasons.
21. Phase 5: Approval-friction guidance and verification.
22. Add a short actionable section to skill output/help describing platform approval reduction options in VS Code (scoped tool approvals/workspace trust patterns as supported), including exact settings/approval paths and caveats.
23. Verify end-to-end scenarios: clean repo, dirty repo pull failure, missing CONTEXT7_API_KEY, missing GITHUB_TOKEN, detailed vs default verbosity, and settings already compliant vs changed.
24. Validate generated artifacts and frontmatter across VS Code, Copilot CLI, and Claude targets; confirm no unsupported fields and no unresolved replacement tokens.

**Relevant files**
- c:\BTR\Extensibility\Policies\AI\skills\kat-policies\SKILL.md — workflow order, user-prompt policy, final response contract, script path references.
- c:\BTR\Extensibility\Policies\AI\skills\kat-policies\meta.jsonc — consolidated skill + shared mappings metadata, body replacements.
- c:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\update.ps1 — primary orchestration, skill rendering, table/report gating, settings safeguard integration.
- c:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\install-context7-remote.ps1 — CheckOnly compliance correctness for Context7 credential state.
- c:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\install-github-remote.ps1 — CheckOnly/runtime auth behavior for GitHub.
- c:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\Kat.Policy.Mcp.psm1 — shared pass-through/result semantics and table primitives if reporting contract needs extension.
- c:\BTR\Extensibility\Policies\scripts\kat-policies\* (new canonical location) — relocated runtime scripts after migration.
- c:\BTR\Extensibility\Policies\AI\skills\kat-policies\meta.vscode.settings.jsonc (new) — desired duplicate-context settings source for script reconciliation.

**Verification**
1. Run update.ps1 in non-interactive mode with missing CONTEXT7_API_KEY and verify pass-through reports blocked (not compliant) and skill prompts for credential only when required.
2. Run skill from VS Code with a dirty git working tree and verify summary begins with pull warning, continues sync against current checkout, and contains no intermediate narrative responses.
3. Run default verbosity and confirm Artifact Locations table is omitted; run detailed verbosity and confirm Artifact Locations plus location column in Configuration Locations appear.
4. Validate generated Copilot SKILL.md frontmatter has no unsupported allowed-tools field and no unresolved replacement tokens.
5. Confirm manual interactive update.ps1 still prompts in terminal when expected and non-interactive mode never falls back to Read-Host.
6. Validate VS Code user settings safeguard statuses are emitted in Configuration Locations as Type | Status by default, with location expansion only in detailed mode.

**Decisions**
- Scripts path: move to repo-root scripts path.
- Metadata: merge to a single meta.jsonc source.
- Settings safeguards: move into update.ps1 with status reporting in Configuration Locations.
- Output policy: minimal by default; detailed tables only on explicit detailed request.
- allowed-tools field: remove from generated Copilot skill frontmatter.

**Further Considerations**
1. Migration strategy for existing deployed skill folders should include cleanup of legacy scripts directories to prevent stale artifacts after rollout.
2. If token replacement validation detects unresolved placeholders, treat as blocked in normal mode or warning in detailed mode depending on strictness preference.
3. If VS Code approval suppression settings are limited by product policy, keep guidance explicit about what can and cannot be suppressed.
