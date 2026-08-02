# Plan: Codex CLI support in update.ps1

## Problem

`scripts/update.ps1` publishes AI artifacts to three clients — `vscode`, `copilotCli`, and `claude`. Four tally meta files already declare `enabled.codex` and `bodyReplacements.codex`, but the script reads neither key: `Resolve-BodyReplacements` has `[ValidateSet('copilot','vscode','copilotCli','claude')]`, and every publish path is hardcoded to the existing three targets. Codex CLI is installed (`%LOCALAPPDATA%\Programs\OpenAI\Codex\bin\codex.exe`) and repo artifacts for it are currently maintained by hand.

## Scope

| Category | Codex |
|---|---|
| `instruction` | supported |
| `skill` | supported |
| `agent` | **out** — no cheap mapping from `.agent.md` frontmatter to the Codex subagent format |
| `mcp` | **out** — Codex uses `config.toml`; the three `install-*.ps1` helpers are JSON-based |

Out-of-scope categories render `excluded`, or `unsupported` with a footnote when a meta explicitly sets `codex: true`.

## Target paths

Verified against Codex source docs (`codex-rs/codex-home/src/instructions/mod.rs`, `codex-rs/core/src/agents_md.rs`, `codex-rs/core-skills/src/loader.rs`), not from model recall.

| Artifact | Path |
|---|---|
| Global instructions | `%USERPROFILE%\.codex\AGENTS.md` |
| Repo instructions | `{repo}\AGENTS.md` |
| Global skills | `%USERPROFILE%\.agents\skills\{id}\SKILL.md` |
| Repo skills | `{repo}\.agents\skills\{id}\SKILL.md` |

Secondary paths that Codex also reads but KAT does **not** write: `$CODEX_HOME/skills` (user scope, marked deprecated in source), `.codex/skills/` (repo scope), `AGENTS.override.md` (shadows `AGENTS.md` at both scopes — a hand-written one silently wins over KAT output).

Behavioral notes that constrain the design: repo `AGENTS.md` files are **concatenated from the `.git` project root down to cwd**, and `.agents/skills` discovery is **recursive**. Neither changes what KAT writes, but both mean stray files anywhere under a repo are live input.

## Decisions

1. **`enabled.codex` defaults to `false`.** `copilot` and `claude` both default to `true`; codex is deliberately asymmetric and strictly opt-in. Rationale: codex semantics differ from the other clients — `AGENTS.md` is a shared merge target and `~/.agents/skills` is shared with Copilot external primitives — so a silent opt-in would light up 3 instructions and 13 skills on the first run, including 10 non-tally skills into the shared skills directory. The deployment matrix renders `excluded` per artifact, so the opt-in requirement stays visible rather than silent.

2. **`AGENTS.md` is a delimited region, not a whole file.** KAT owns only the content between `<!-- kat:start -->` and `<!-- kat:end -->`. Rationale: unlike `.claude/` and `.github/`, `AGENTS.md` is the cross-vendor convention file that Codex, Cursor, Amp and others read and that humans edit directly. `C:\BTR\TallySpending\AGENTS.md` already holds hand-written orientation prose that whole-file ownership would destroy.

   Writer algorithm:
   - delimiters found → replace everything between them, in place
   - delimiters absent, file exists → append the block at the end
   - file absent → create it containing only the block

3. **Strip semantics on disable.** Remove the block content **and** the delimiters. If the block was the file's entire content (only whitespace outside), delete the file. Rationale: an orphan `<!-- kat:start --><!-- kat:end -->` pair is permanent noise in every `git diff`; the only thing full stripping loses is placement memory across a disable/re-enable cycle, which is cosmetic and rare.

4. **One KAT block per `AGENTS.md`, containing all enabled instructions**, ordered by id, each under a literal `###### {id} instructions ######` H6 heading. No per-instruction delimiter pairs. Rationale: matches how the rest of `update.ps1` works — render the complete desired state and write it, rather than reconciling N independent fragments. Codex reads the file as one concatenated blob, so position between two KAT bodies carries no semantic weight.

5. **No YAML frontmatter on instruction output.** Copilot's `applyTo:` has no codex equivalent.

6. **`instructions.scope` becomes a prose preamble.** Codex has no glob-scoping mechanism; an `AGENTS.md` body is unconditionally active for its whole subtree, and directory nesting does not help scopes expressed as file extensions (e.g. `nexgen`'s `**/*.cs`, `**/*.ts`, `**/*.js`, `**/*.kaml`). Render a generated line — *"The following applies when working on files matching `**/*.cs`, …"* — and emit an `Add-Warning` that this is a soft gate, not enforcement. Omit entirely when scope is absent or `["**"]`.

7. **Codex `SKILL.md` frontmatter is `name` + `description` only.** Per `codex-rs/skills/src/assets/samples/skill-creator/SKILL.md`: *"These are the only fields that Codex reads… Do not include any other fields in YAML frontmatter."* Drop `license`, `compatibility`, `context`, and allowed-tools. No `agents/openai.yaml` (deferred — needs new meta keys and a second file per skill).

8. **Skill bundles copy, with `ExcludedItemNames = @('commands','agents')`.** Codex supports `scripts/`, `references/`, `assets/` under a skill. `agents/` is excluded per scope; `commands/` has no codex analogue.

9. **Cleanup is targeted for both instructions and codex global skills — never scan-root.**
   - Instructions: `Clear-ManagedRoot` works by owning a directory and deleting anything in it outside the desired set. `AGENTS.md` sits at repo root, which contains the entire repository, so it can never be an ownable managed root. Cleanup must walk an explicit list of `AGENTS.md` paths derived from the enabled repositories plus `%USERPROFILE%\.codex` and splice each one.
   - Global skills: `Get-ExternalPrimitiveInstallPath -Client 'copilot'` writes to `%USERPROFILE%\.agents\skills\{id}` (line 993) — the exact directory Codex uses for global skills. Registering it as a codex managed root would make `Clear-ManagedRoot` delete any copilot-client external primitive on each run. Instead, delete exactly the ids codex stopped publishing. One client's cleanup pass must never reason about another client's ownership.
   - Repo skills (`{repo}\.agents\skills\`) are a genuine ownable root and may use the normal scan mechanism.

10. **Global skill id collisions warn; codex skips.** The only writer that shares codex's global skills directory is a **copilot-client external primitive** — `Get-ExternalPrimitiveInstallPath -Client 'copilot'` returns `%USERPROFILE%\.agents\skills\{Id}` (line 993). Copilot's own global *skills* are not involved: they go to `$Roots.CopilotRoot\skills\{id}` = `%USERPROFILE%\.copilot\skills\{id}` (lines 442, 816/830), so a meta declaring both `copilot: true` and `codex: true` writes two files in two roots and is not a conflict.

    A collision therefore requires an id in `external.primitives.jsonc` with `"client": "copilot"` that matches a codex-enabled global skill id — computed as one id-set intersection at publish time. On intersection: emit a warning and let codex skip that skill.

    No priority-ordering rule is applied. External primitive metas have the shape `{ client, command, enabled: <bool>, applyForUsers }` — there are no `enabled.copilot` / `enabled.codex` keys to order, so a "first key in `enabled` wins" tie-break is not expressible against them.

    The reason to warn rather than ignore: `Remove-ExternalPrimitiveInstall` runs `Remove-Item -Recurse -Force` on `%USERPROFILE%\.agents\skills\{id}` (line 1013). If a colliding copilot-client primitive is later disabled, it deletes the codex skill folder outright — silent failure here is destructive, not merely confusing.

11. **Reporting.** Codex gets a column in the Agents, Instructions, Skills, MCP, and Compatibility tables, gated on `$script:clientInstalled.codex` exactly like the other three. A permanently-`excluded` column in the Agents/MCP tables is preferable to a missing one — the matrix's job is to answer "did this reach that client," and a missing column cannot.

12. **New `unsupported` status.** `excluded` means "nothing was asked for." When a meta explicitly sets `codex: true` on an out-of-scope category, the cell must show that something was asked for and could not be delivered. Neither existing token fits: `blocked` renders red and feeds **Manual Cleanup Required**; `skipped` renders the right color but already means "file is no longer read-only, run with `-Overwrite`" throughout the report. Add a distinct `unsupported` branch to `Get-CellDisplayValue`, DarkYellow with a footnote, and bump `$statusColWidth` from 12 to 13 so `unsupported¹` is not flush against the column edge.

## Steps

**Phase 1 — plumbing (low risk, no behavior change).**
1. Add `Test-KatCodexInstalled` probing the `codex` command; populate `$script:clientInstalled.codex`.
2. Add `codex` to `Resolve-ClientMarkdown`: `$allTags` becomes `@('copilot','copilot-vscode','copilot-cli','claude','codex')`; the `codex` client keeps only `@('codex')`. Zero-risk today (no body uses `<!-- codex:start -->`) and it correctly makes the existing clients strip codex-only blocks once such blocks are authored.
3. Add `'codex'` to the `Resolve-BodyReplacements` `ValidateSet`, mapping to meta key `codex`. The four tally meta files already declare this key.

**Phase 2 — the AGENTS.md writer.**
4. Implement a merge-aware writer alongside `Write-ManagedFile`: read existing content, splice/append/create per decision 2, handle the read-only + `CreatedBy` stream dance, and implement the decision-3 strip including whole-file deletion.

**Phase 3 — publishing.**
5. Add the codex branch to `Publish-Instructions`: resolve `enabled.codex` (default `false`), render the scope preamble per decision 6, assemble the single ordered block per decision 4, and write to the global and repo `AGENTS.md` targets.
6. Add the codex branch to `Publish-Skills`: a codex `ConvertTo-SkillDocument` variant emitting `name` + `description` only, bundle copying per decision 8, published to global and repo `.agents\skills\{id}\`.

**Phase 4 — cleanup.**
7. Implement targeted instruction cleanup over the explicit `AGENTS.md` path list.
8. Implement targeted global-skill cleanup; register `{repo}\.agents\skills` as a normal managed root but leave `%USERPROFILE%\.agents\skills` unregistered.
9. Extend `Get-RemovedPathInfo` to recognise codex paths so removals report correctly.

**Phase 5 — reporting.**
10. Add the codex column to `Write-DeploymentMatrix`, `Write-McpDeploymentMatrix`, and `Write-CompatibilitySummary`, gated on install.
11. Add the `unsupported` branch to `Get-CellDisplayValue` plus DarkYellow entries in both matrix writers' cell-color logic; bump `$statusColWidth` to 13.
12. Emit warnings when `codex: true` appears on an out-of-scope category, and when an instruction's `scope` was reduced to a prose preamble.
13. Add codex paths to `Write-ArtifactLocationsTable` / `Write-ConfigurationLocationsTable` as applicable.

## Expected first-run behavior

`C:\BTR\TallySpending\AGENTS.md` and `C:\BTR\TallySpending\.agents\skills\tally-*\SKILL.md` already exist as hand-written, non-KAT-owned files (no `CreatedBy` stream, not read-only). They will report `skipped` until `update.ps1` is run with `-Overwrite`. This is accepted. Under decision 2 the hand-written orientation prose in `AGENTS.md` survives the overwrite; the KAT block appends beneath it.

The decision-9/10 collision surface is currently **zero** — not because `%USERPROFILE%\.agents\skills\` happens to be empty, but because `external.primitives.jsonc` contains a single entry (`skill-creator`) with `"client": "claude"`, which installs to `%USERPROFILE%\.claude\skills\`. There are no copilot-client external primitives, so nothing can intersect with a codex global skill id today.

## Deferred

- Codex subagents (different definition format from `.agent.md`).
- Codex MCP via `config.toml`.
- `agents/openai.yaml` generation for skill UI metadata (display name, icons, `allow_implicit_invocation`).
