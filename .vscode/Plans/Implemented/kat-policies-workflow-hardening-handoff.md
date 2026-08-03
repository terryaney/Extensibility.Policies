## KAT Policies Workflow Hardening - Agent Handoff Brief

### Objective
Implement the approved KAT Policies hardening changes to fix credential detection correctness, reduce skill-run response noise, simplify deployment artifacts, and standardize reporting defaults.

### Source of Truth
- Full plan: .vscode/Plans/kat-policies-workflow-hardening-plan.md

### In-Scope Files
- AI/skills/kat-policies/SKILL.md
- AI/skills/kat-policies/meta.jsonc
- AI/skills/kat-policies/scripts/update.ps1
- AI/skills/kat-policies/scripts/install-context7-remote.ps1
- AI/skills/kat-policies/scripts/install-github-remote.ps1
- AI/skills/kat-policies/scripts/Kat.Policy.Mcp.psm1 (only if required for reporting contract support)

### New/Relocated Artifacts
- scripts/kat-policies/* (new canonical runtime script location)
- AI/skills/kat-policies/meta.vscode.settings.jsonc (new settings metadata)

### Ordered Work
1. Move kat-policies runtime scripts from AI/skills/kat-policies/scripts to scripts/kat-policies and update all hardcoded references.
2. Merge shared scripts metadata into AI/skills/kat-policies/meta.jsonc and remove dependency on scripts/meta.jsonc.
3. Update packaging/deployment logic so runtime scripts are not copied into deployed skill folders unless explicitly required.
4. Reorder SKILL workflow so git pull occurs before credential pre-checks.
5. Fix CheckOnly compliance in Context7/GitHub bootstrap helpers so compliant requires both config and runtime credential availability.
6. Update update.ps1 bootstrap orchestration so stale CheckOnly compliance cannot suppress blocked states or required credential handling.
7. Keep manual interactive update.ps1 behavior unchanged.
8. Remove step-by-step narrative requirements in SKILL.md; prompt user only for required actions.
9. Remove unsupported allowed-tools from generated Copilot skill frontmatter.
10. Ensure placeholder substitution is complete (including KAT_QUESTION_TOOL_GUIDANCE) and report unresolved placeholders explicitly.
11. Make Artifact Locations table detailed-only.
12. Change Configuration Locations default columns to Type | Status; include Location only in detailed mode.
13. Move VS Code duplicate-context settings check/apply into update.ps1 using meta.vscode.settings.jsonc.
14. Update final skill summary contract to minimal default with precise blocked/skipped reasons.
15. Add concise guidance on reducing VS Code platform approval prompts (with limits/caveats).

### Non-Goals
- No broad refactors outside kat-policies workflow hardening.
- No behavior change to manual interactive credential prompting in update.ps1.
- No redesign of deployment matrix schema unless required by accepted output changes.

### Acceptance Criteria
1. Missing CONTEXT7_API_KEY in non-interactive check path is reported as blocked, not compliant.
2. Skill run with dirty repo shows pull warning and continues against current checkout.
3. Default verbosity omits Artifact Locations table.
4. Detailed verbosity includes Artifact Locations and Configuration Locations with Location column.
5. Generated Copilot SKILL frontmatter contains no unsupported allowed-tools field.
6. No unresolved placeholder tokens appear in rendered outputs.
7. VS Code duplicate-context settings safeguard runs from update.ps1 and reports status in Configuration Locations.
8. Skill output is minimal by default and does not emit step-by-step narrative chatter.

### Required Validation Runs
1. Non-interactive run with missing CONTEXT7_API_KEY.
2. Skill run with dirty git working tree.
3. Default and detailed verbosity comparison run.
4. Manual interactive run to confirm terminal prompting remains intact.
5. Rendered artifact inspection across VS Code, Copilot CLI, and Claude outputs.

### Required Final Agent Output
Return exactly these sections:
1. Change Summary
2. Files Changed
3. Behavior Deltas
4. Validation Evidence
5. Open Risks / Follow-ups

### Constraints
- Preserve existing coding style and avoid unrelated reformatting.
- Do not introduce whitespace-only diffs.
- Keep path and naming changes explicit in the summary.
