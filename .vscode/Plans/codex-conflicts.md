# Plan: Cross-Harness Conflicts (Codex / Claude / Copilot)

Settled 2026-08-07 via `/kat-grill-me`. Supersedes the original draft, whose premise — suppress Copilot's reads with frontmatter keys like `ignored: true` / `disable-model-invocation` — is disproven below and must not be revived.

## The actual defect

Not duplication. **Divergent content in co-scanned directories.**

Copilot reads every tree KAT publishes to. When the same skill id exists in more than one, Copilot de-duplicates by name and picks a winner — and the winner varies by surface. So a body rendered for one harness gets served to another, and the reader silently receives the wrong invocation syntax.

Observed: VS Code resolved `.agents/skills` (codex render, `$tally`); Copilot CLI resolved `.github/skills` (copilot render, `/tally`). Same repo, same id, different answers.

The fix is not to control who reads what — that is not configurable and the vendor request for it ([copilot-cli#2689](https://github.com/github/copilot-cli/issues/2689)) is open. The fix is to make the renders identical **wherever trees are co-scanned**, so the winner stops mattering.

## Verified read matrix

Every cell confirmed from vendor docs, not inference.

| Location | Copilot | Claude Code | Codex |
|---|:---:|:---:|:---:|
| `<repo>/.github/skills/<id>/` | reads (CLI resolves here) | — | — |
| `<repo>/.claude/skills/<id>/` | **reads** | reads | — |
| `<repo>/.agents/skills/<id>/` | **reads** (VS Code resolves here) | — | reads |
| `~/.copilot/skills/<id>/` | reads | — | — |
| `~/.claude/skills/<id>/` | — | reads | — |
| `~/.agents/skills/<id>/` | **reads** (VS Code) | — | reads |
| `<repo>/AGENTS.md` | **reads** (both surfaces) | — | reads |
| `<repo>/CLAUDE.md` | **reads** | reads | — |
| `<repo>/.github/instructions/*.instructions.md` | reads | — | — |
| `<repo>/.claude/rules/*.md` | — | reads | — |
| `~/.codex/AGENTS.md` | — | — | reads |
| `<repo>/.github/agents/<id>.agent.md` | reads | — | — |
| `<repo>/.claude/agents/<id>.md` | — | reads | — |
| `<repo>/.codex/agents/<id>.toml` | — | — | reads |

Consequences that drive every decision below:

- **Copilot is the universal reader.** It is the only client that reads another client's trees.
- **Claude is fully isolated.** `.claude/skills` + `~/.claude/skills` + `CLAUDE.md` only. Claude Code does not read `AGENTS.md` and does not read `.agents/skills`.
- **Co-scanning is scope-dependent, not universal.** Repo skills land in three Copilot-readable trees. Global skills land in `~/.claude/skills` (Copilot never reads) and `~/.copilot/skills` — **disjoint**, unless codex is enabled, which adds the Copilot-readable `~/.agents/skills`. This distinction is load-bearing for D1.
- **Agent trees are disjoint at both scopes.** No client reads another's agents. Per-client divergence there is always safe.
- **Skills de-duplicate; instructions concatenate.** A second skill copy is free once the copies match. A second instruction copy is loaded *in addition*, and the CLI only mechanically de-dupes files that are byte-identical.

## Asymmetries to respect

- `@relative/path` imports expand in Copilot's `AGENTS.md` / `CLAUDE.md`. **Codex has no import mechanism** — it would ingest the line as literal text. Never emit `@`-imports into an `AGENTS.md`-bound body.
- Codex does not merge same-name skills; both appear in its selector. Only Copilot picks a winner.
- The Agent Skills spec defines six frontmatter fields: `name`, `description`, `license`, `compatibility`, `metadata`, `allowed-tools`. `context`, `disable-model-invocation`, `user-invocable`, `model`, `effort`, `paths`, `hooks`, `shell` are **Claude Code extensions**. Do not assume other harnesses ignore unknown keys — Anthropic's own claude.ai/API path errors on them.
- **Commands have different shapes per client.** Claude keeps them nested in the skill's `commands/` folder (`/skill:command`); KAT flattens them into sibling skills for Copilot (`~/.copilot/skills/visual-explainer.diff-review/`, invoked `visual-explainer.diff-review`). Codex has no command analogue.
- Support files **do** travel to codex. `New-CodexSkillDefinition` sets `ExcludedItemNames = @('commands', 'agents')` ([update.ps1:3700](../../scripts/update.ps1#L3700)); `references/`, `templates/`, `scripts/`, and loose files are copied.
- `allowed-tools` is never emitted for skills on any client. `ConvertTo-SkillDocument` accepts an `$AllowedTools` parameter and never reads it ([update.ps1:3956](../../scripts/update.ps1#L3956)). This reconciles the apparent conflict between KatPolicies.md:161 and the renderer — :161 describes the mapping layer, which has no skill-frontmatter consumer.
- A model's self-report about its own context assembly is not evidence of loader behavior. Copilot CLI claiming it "de-duplicated" near-identical instruction text is a rationalization, not a mechanism.

## Decisions

| # | Decision |
|---|---|
| D1 | **Sigil-neutral bodies, where outputs are co-scanned.** A body must name primitives without a sigil — "the `tally-categorize` skill", never `/tally-categorize` or `$tally-categorize` — when the artifact is **repo-scoped**, or **codex-enabled at any scope**. Global non-codex skills publish to disjoint trees and may keep client markers. Per-harness keystroke syntax is user documentation, not model-facing content. |
| D2 | `bodyReplacements.codex` is a **renderer error** for skills and instructions. Permitted for agents (disjoint trees). Error text must state the reason — "codex output is co-read by Copilot at this path" — so the rule can be re-evaluated if that ever changes. |
| D3 | **Skill topology is unchanged.** Publish all three repo locations and both global locations. Both `.github/skills` and `.agents/skills` are load-bearing depending on Copilot surface; dropping either breaks a surface. D1 is what makes the de-dupe lottery harmless. |
| D4 | Do **not** add `skillDirectories` to Copilot settings. It would give the CLI two copies of every global skill and reintroduce the lottery. |
| D5 | **Instructions diverge from skills**: when codex is enabled, skip the `.github/instructions` write and let `AGENTS.md` serve Copilot. Justified by mechanism — concatenation makes the second copy harmful, and Copilot CLI reads `AGENTS.md` as a first-class source, so coverage is intact. Cost: no `applyTo` glob scoping for Copilot in codex-enabled repos. Acceptable while the only codex-enabled instruction is `scope: ["**"]`. |
| D6 | Two new canonical meta flags, mirroring `agents.userInvocable`: `skills.modelInvocable` (default `true`; `false` → `disable-model-invocation: true` **and** Codex `allow_implicit_invocation: false`) and `skills.userInvocable` (default `true`; `false` → `user-invocable: false`, no Codex equivalent). **As implemented**, both keys go into the *shared* non-codex document — the Copilot copy as well as the Claude copy — so co-scanned renders stay byte-identical. They are Claude Code extensions that Copilot ignores; emitting them to Claude alone would have reintroduced the divergence D1 exists to remove. |
| D7 | Emit `agents/openai.yaml` beside the codex `SKILL.md`, **`policy.allow_implicit_invocation` only**, only when `skills.modelInvocable: false`. `interface.*` and `dependencies.tools` are a later cosmetic pass. |
| D8 | Warn (not error) when a **skill or instruction** body **in D1 scope** contains an invocation sigil matching a known primitive id. Agents are not audited — their trees are disjoint at both scopes, so a sigil there can never reach the wrong client. Sigils are common enough in prose that a hard error will eventually block something legitimate. This warning is what makes D1's conditional scope self-policing: a global skill that later gains `repositories` or `codex: true` trips it the moment it becomes unsafe. |
| D9 | Warn when a codex-enabled skill declares frontmatter with **behavioral** consequence that codex drops: `context`, `skills.userInvocable: false`, and `allowed-tools` (dormant — never emitted today, retained so whoever wires up `$AllowedTools` doesn't have to rediscover this). Stay silent on `license` / `compatibility` — informational drops, and a warning that fires on harmless metadata is one you learn to ignore. |
| D10 | Codex agents stay **`unsupported`**. `.codex/agents/*.toml` is a config layer (model, reasoning, sandbox, mcp, skills), not a body with frontmatter — a separate emitter, for a primitive currently disabled everywhere, against a young schema. Documented as a known gap, not a task. |
| D11 | Warn when a **codex-enabled** skill carries a `commands/` or `agents/` subfolder. Those folders are dropped from codex output, and because VS Code Copilot resolves `.agents/skills`, Copilot loses them too. Same failure class as D9 — a behavioral capability silently absent from the copy Copilot resolves. |

### Rejected

- **Frontmatter suppression** (`ignored: true`, `disable-model-invocation`, `user-invocable` to hide content from Copilot). No documented key suppresses Copilot's `AGENTS.md` read or a skill directory scan; unknown keys are ignored, not obeyed. Building on unverified vendor behavior in a file three tools share was the most fragile option on the table.
- **Dropping `.github/skills` when codex is enabled.** Would have removed Copilot CLI's resolved copy.
- **Dropping `.github/skills` unconditionally** (relying on Copilot reading `.claude/skills`). Bets Copilot keeps reading a foreign tree; `.github/skills` is its documented home.
- **Collapsing to one directory for non-codex skills.** A Copilot regression would silently take out all Copilot skills. Two writes to KAT-owned trees cost nothing.
- **Emitting full Claude frontmatter to codex** and assuming unknown keys are ignored. Unconfirmed, and there is contrary evidence.
- **Banning global codex skills.** D1 makes them safe; one consistent rule beats a scope-dependent exception.
- **Blanket sigil-neutrality regardless of scope.** Would delete a correct, useful distinction in global skills — Claude users really do type `/visual-explainer:diff-review` and Copilot users `visual-explainer.diff-review`, and both are currently served correctly from disjoint trees.

## Work items

### 1. Neutralize the Tally set (D1)

**Done 2026-08-07.** Repo-scoped **and** codex-enabled, so squarely in D1 scope. Rewrite to bare names, then delete the replacement blocks:

- `AI/instructions/tally/body.md` — lines 37-43 (`/tally-files`, `/tally-categorize`, `/tally-rules`, and both fallback response strings).
- `AI/skills/tally-files/SKILL.md` — lines 3, 5, 42, 73.
- `AI/skills/tally-categorize/SKILL.md` — line 59.
- `AI/skills/tally-rules/SKILL.md` — line 34.
- Delete `bodyReplacements.codex` from all four metas: `AI/instructions/tally/meta.jsonc`, `AI/skills/tally-files/meta.jsonc`, `AI/skills/tally-categorize/meta.jsonc`, `AI/skills/tally-rules/meta.jsonc`.

### 2. Fix visual-explainer's `share` documentation

**Done 2026-08-07.** Not a neutralization item — visual-explainer is global and non-codex, so its trees are disjoint and its client markers are correct as-is. The defect was that `share` is excluded from Copilot via `skills.excludeCommands`, yet the SKILL.md body published to Copilot still documented it. Narrower than first assessed: the "Sharing Pages" section (usage, script invocation, `./commands/share.md` pointer) was **already** inside a `<!-- claude:start -->` block; only the command-table row leaked. Wrapped that row. Verified against published output — the Claude render carries the row and the usage section, the Copilot render carries neither.

### 3. Leave alone

- `AI/skills/kat-policies/meta.jsonc` — `{{KAT_QUESTION_TOOL_GUIDANCE}}` is a genuine tool-name difference (`vscode/askQuestions`/`ask_user` vs `AskUserQuestion`), model-facing and load-bearing. Global scope, no `codex: true`, and Copilot's personal scan never includes `~/.claude/skills`. The mechanism working as designed.
- Agent bodies with client markers (`AI/agents/kat/Code.Review/body.md`, `AI/agents/anvil/body.md`, `AI/agents/Ultralight/Planner/body.md`) — disjoint trees, and agents are disabled.

### 4. Renderer — `scripts/update.ps1`

**Done 2026-08-07.** Validation lives in `Assert-CrossHarnessPolicy`, called from `Invoke-PolicySync` *before* any managed root is cleared so a violation cannot leave the trees half-published. Errors throw; warnings flow into the existing compatibility summary. `Test-CoScannedArtifact` encodes D1's conditional scope in one place.

- D2: error on `bodyReplacements.codex` for skill/instruction metas; keep it legal for agents.
- D5: when an instruction has `enabled.codex`, skip the `.github/instructions` write.
- D6: parse `skills.modelInvocable` / `skills.userInvocable`; emit `disable-model-invocation` / `user-invocable` into Claude skill frontmatter.
- D7: emit `agents/openai.yaml` into the codex skill directory when `modelInvocable: false`.
- D8: warn on invocation sigils (`/id`, `$id`, `/id:sub`, `/id.sub`) matching a known primitive id, for artifacts in D1 scope.
- D9: warn on `context` / `skills.userInvocable: false` / `allowed-tools` for codex-enabled skills.
- D11: warn when a codex-enabled skill has a `commands/` or `agents/` subfolder.
- New: reject `@relative/path` imports in bodies bound for `AGENTS.md` — implemented as an error on codex-enabled instruction bodies, which is that set exactly.

### 5. Documentation

**Done 2026-08-07.** Also corrected `readme.md:121`, which carried the same "open question, no decision made yet" blockquote and now states the settled rule, and added the missing `context` row to Metadata.md's shared schema table — D9 warns on a field the schema never documented.

- `Primitives.md` — the read matrix, the CLI-vs-VS-Code precedence split, the scope-dependent co-scanning rule, the command-shape difference, and the informational frontmatter drops (`license`, `compatibility`) that D9 deliberately does not warn about.
- `Metadata.md` — the new flags, the D2 ban and its stated reason, the D8/D9/D11 warnings, the `@`-import rejection.
- `KatPolicies.md` — D10 recorded as a known gap; update the "observed behavior, not a settled design" paragraph at line 150, which defers to this plan and is now resolved; correct line 161's implication that allowed-tools declarations reach skill output.

### 6. Incidental fixes found while implementing

- **`kat-nexgen` tripped D8 on its first run** — it is repo-scoped, so `.claude/skills` and `.github/skills` are both Copilot-readable, and its body told the user to rerun with `/kat-katapp`. Neutralized. This is the warning earning its keep on an artifact nobody had flagged.
- **`Get-RemovedPathInfo` misclassified the codex sidecar.** Its `agents` folder check ran before its `skills` check, so removing `.agents/skills/<id>/agents/openai.yaml` reported as an *agent* named `openai.yaml` in the matrix. Guarded the agents branch with `$Path -notmatch '\\skills\\'`; a skill may legitimately own an `agents/` subfolder (helper agents, or this sidecar).

## Known gaps and residual risks

- **Codex agents unsupported** (D10).
- **Dead `$AllowedTools` parameter** in `ConvertTo-SkillDocument` — either delete it or wire it up. Out of scope here; noted so it isn't mistaken for working tool plumbing.
- **The `external.primitives.jsonc` collision guard is currently inert.** Its only entry, `skill-creator`, installs via `--agent claude-code --global` into `~/.claude/skills`, not `~/.agents/skills`. Retain the guard — a future `--agent codex` entry would make the recursive-delete collision real — but it is not evidence for any decision above.
- **`~/.agents/skills` is empty today.** All four codex-enabled artifacts are repo-scoped to `C:\BTR\TallySpending`. Global codex is permitted (D1 covers it) but currently hypothetical.
- **Importing skills with subfolders.** Pocock's `domain-modeling` carries an `agents/` folder plus loose `ADR-FORMAT.md` / `CONTEXT-FORMAT.md`. The loose files travel to every client including codex; the `agents/` folder does not, and would trip D11 if that skill is ever codex-enabled.
