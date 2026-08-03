# KAT Policies Renderer

This document describes how `scripts/update.ps1` renders canonical content into client-specific formats and the compatibility model across clients.

For the metadata schema, see [Metadata.md](Metadata.md). For the list of installed primitives, see [Primitives.md](Primitives.md).

## Purpose

The renderer accomplishes four things:

1. Keep one canonical source of truth for agents, instructions, skills, and terminal policy content.
2. Render each artifact into the format expected by each client instead of authoring duplicate files by hand.
3. Take ownership only of KAT-managed outputs and avoid deleting unrelated user files.
4. Surface client compatibility gaps explicitly so missing parity is visible during each sync.

## Sync Workflow

`scripts/update.ps1` runs this workflow:

1. Discover the install roots for BTR configurations, VS Code, Copilot CLI, Claude, Codex CLI, and Windows Terminal.
2. Scan known managed roots and remove only KAT-managed files and directories before republishing.
3. Parse canonical `meta.jsonc` files, including line comments.
4. Render target-specific frontmatter and write the final published files.
5. Install supporting skill files as copied managed files beside the rendered `SKILL.md` files.
6. Generate `~/.claude/CLAUDE.md` from the enabled instruction imports.
7. Splice the enabled Codex instructions into each target `AGENTS.md` as a single delimited region, and strip that region from every `AGENTS.md` that no longer has enabled content. See [Codex AGENTS.md Region](#codex-agentsmd-region).
8. Deploy `Terminal/settings.json` to local user install folder.
9. Deploy `.editorconfig` to `C:\BTR\.editorconfig`.
10. Mark rendered files as read-only and stamp managed plain files with a `CreatedBy=KAT` alternate data stream when possible.
11. Install ripgrep via winget (with auto-upgrade).
12. Bootstrap MCP servers when requested by canonical agent tool metadata.
13. Print a deployment matrix plus compatibility summary after each run.

Codex is opt-in per artifact: `enabled.copilot` and `enabled.claude` default to `true`, but `enabled.codex` defaults to `false`. The asymmetry is deliberate — see [Codex CLI](#codex-cli) under Compatibility Notes.

## Rendered Destinations

| Canonical Type | VS Code | Copilot CLI | Claude | Codex CLI |
|------|------|------|------|------|
| Agents | `%APPDATA%/Code/User/prompts/*.agent.md`¹ | `~/.copilot/agents/*.agent.md`¹ | `~/.claude/agents/*.md`¹ | not published — out of scope³ |
| Instructions | `%APPDATA%/Code/User/instructions/*.instructions.md`¹ | `~/.copilot/instructions/*.instructions.md`¹ | `~/.claude/instructions/*.md` and generated `~/.claude/CLAUDE.md` imports for global instructions, or `~/.claude/rules/*.md`¹ for path-scoped instructions | a delimited region inside `~/.codex/AGENTS.md`, or inside `<repo>/AGENTS.md`⁴ |
| Skills | `~/.copilot/skills/<id>/`² | `~/.copilot/skills/<id>/`² | `~/.claude/skills/<id>/`² | `~/.agents/skills/<id>/`⁵ |
| MCP servers | `%APPDATA%/Code/User/mcp.json` | `~/.copilot/mcp-config.json` | `~/.claude.json` | not configured — out of scope³ |

¹ When `enabled.repositories` includes repo-local targets, the equivalent repo paths are also published: `.github/agents/*.agent.md`, `.claude/agents/*.md`, `.github/instructions/*.instructions.md`, and either `.claude/instructions/*.md` plus generated `.claude/CLAUDE.md` imports for global instructions or `.claude/rules/*.md` for path-scoped instructions.

² When `enabled.repositories` includes repo-local targets, Copilot skill output is published under `.github/skills/<id>/` and Claude skill output under `.claude/skills/<id>/`. If a canonical skill has a `commands/*.md` folder, Copilot child skills are also published under `skills/<parent>.<command>/`, and Claude command markdown is nested under `skills/<parent>/commands/`.

³ Setting `codex: true` on an agent or MCP server does not fail the sync. The matrix reports `unsupported` with a footnote so the request stays visible rather than silently vanishing into `excluded`.

⁴ Repo-scoped Codex instructions go to `<repo>/AGENTS.md`. All enabled instructions for one file share a single region, ordered by id, each under a literal `###### <id> instructions ######` heading. Codex has no `applyTo` equivalent, so `instructions.scope` is rendered as a prose preamble and the sync warns that it is a soft gate.

⁵ Repo-scoped Codex skills go to `<repo>/.agents/skills/<id>/`. Codex reads only `name` and `description` from `SKILL.md` frontmatter, so license, compatibility, context, and allowed-tools are dropped. `commands/` and `agents/` folders are not copied — Codex has no analogue for either.

External installable skills use provider-native locations. With the current `skills-cli` behavior, GitHub Copilot installs land under `.agents/skills/` for project scope and `~/.agents/skills/` for global scope, while Claude installs use `.claude/skills/` or `~/.claude/skills/`. Note that this is the same directory Codex uses for its global skills — see [Shared Skill Directory](#shared-skill-directory).

## Ownership and Cleanup Model

The renderer is intentionally conservative about what it deletes.

- Managed plain files are recognized by the `CreatedBy=KAT` alternate data stream.
- Legacy managed symlinks are still recognized when their target points back into the Policies repository.
- Managed directories are reusable only when all of their contents are managed.
- Broken legacy managed symlinks are still removed correctly during cleanup.
- Repo-targeted outputs are treated as authoritative current targets for exact paths derived from current metadata, so they can be replaced even if the KAT marker is temporarily missing.
- Repo-local cleanup collapses empty `.github`, `.claude`, and `.agents` ancestor folders back toward configured repository roots.
- If an `enabled.repositories` entry is removed or changed, cleanup of the previously targeted repository is manual.
- Published skill target folders are reused only when remaining contents are still KAT-managed.

Two Codex destinations do not fit the "own a directory and clean everything in it" model, so they are handled by targeted cleanup instead.

- **`AGENTS.md`** sits at a repository root, which contains the entire repository and can therefore never be an ownable managed root. Cleanup walks an explicit list of `AGENTS.md` paths built from the enabled instruction repositories plus `~/.codex`, and splices each one.
- **`~/.agents/skills/`** is shared with Copilot-client external primitives. Registering it as a managed root would let a Codex cleanup pass delete another client's installs. Cleanup instead removes exactly the ids Codex stopped publishing, and only when every file in the folder is still KAT-managed.

### Codex AGENTS.md Region

`AGENTS.md` is the cross-vendor convention file that several tools read and that people edit by hand, so the renderer does not own the whole file. It owns only the text between `<!-- kat:start -->` and `<!-- kat:end -->`.

| Situation | Behavior |
|---|---|
| Delimiters present | Replace everything between them, in place. Content above and below is untouched. |
| Delimiters absent, file exists | Append the region at the end of the file. |
| File absent | Create it containing only the region. |
| No enabled instructions remain | Strip the region **and** the delimiters. Delete the file only if nothing but whitespace remained. |

After a strip that leaves human content behind, the renderer clears the `CreatedBy=KAT` marker and the read-only bit — KAT no longer contributes to that file, so it should not keep claiming it. An orphaned `<!-- kat:start --><!-- kat:end -->` pair is never left behind; the only thing full stripping costs is placement memory across a disable/re-enable cycle.

A pre-existing hand-written `AGENTS.md` is not KAT-owned, so the first sync reports it as `skipped` and leaves it alone until `update.ps1` is run with `-Overwrite`. Because ownership is region-scoped, that overwrite still preserves the hand-written prose — it appends the KAT region beneath it rather than replacing the file.

### Shared Skill Directory

`~/.agents/skills/<id>/` is both the Codex global skill location and the install target for Copilot-client entries in `AI/external.primitives.jsonc`. Copilot's own *rendered* skills are not involved — those go to `~/.copilot/skills/<id>/` — so a skill with both `copilot: true` and `codex: true` writes two files in two roots and is not a conflict.

A real collision requires an `external.primitives.jsonc` entry with `"client": "copilot"` whose id matches a Codex-enabled global skill id. The sync computes this as one id-set intersection at publish time; on a hit it warns and lets Codex skip that skill. The reason it warns rather than ignoring: disabling an external primitive runs a recursive delete on `~/.agents/skills/<id>`, which would take the Codex skill folder with it. Silent overlap there is destructive, not merely confusing.

## Tool Confirmation Notes

KAT Policies can write settings that reduce duplicate context noise and lower approval friction, but it does not force a global default permission mode. The supported approval levers are:

- Workspace trust
- The chat session permission level
- `chat.permissions.default` (set per-repo in `.vscode/settings.json`, not globally)
- Per-tool approvals in the chat UI

The managed VS Code safeguard payload keeps duplicate-context settings plus tool-enablement settings, but it does not set `chat.permissions.default` in user settings.

## Compatibility Notes

### Copilot VS Code vs Copilot CLI

Both are rendered from the same canonical agent metadata, but they do not load the same artifact types.

- VS Code agent output is published as `.agent.md` prompt files.
- Copilot CLI agent output is published under `~/.copilot/agents`.
- VS Code-only orchestration fields (`agents.subAgents`, `agents.handoffs`) are intentionally omitted from CLI output.
- VS Code supports slash commands through prompt files and skills, not through Claude-style nested skill commands.

### Claude Agents vs Commands vs Skills

Claude has a different artifact model from Copilot.

- Claude agents are subagents with their own model, tools, and memory.
- Claude commands are slash-invoked Markdown files nested in skill folders (`~/.claude/skills/<id>/commands/`).
- Claude skills are reusable capability packs under `~/.claude/skills`.
- Claude agent frontmatter has no equivalent to Copilot `userInvocable: false`.
- Claude skills have invocation controls (`user-invocable`, `disable-model-invocation`), but those are skill-level concerns, not subagent frontmatter.

### Codex CLI

Codex receives instructions and skills only. Agents and MCP servers are deferred, not rejected on principle:

- **Agents** — there is no cheap mapping from canonical `.agent.md` frontmatter to the Codex subagent format.
- **MCP** — Codex configures servers in `config.toml`, while the three `install-*.ps1` helpers write JSON.

Requesting either anyway (`codex: true` on an agent, or on an MCP server in the shared `mcp` block) produces an `unsupported` cell plus a compatibility warning rather than a silent `excluded`.

Within the supported types, these differences are worth knowing:

- `enabled.codex` defaults to `false` while `copilot` and `claude` default to `true`. This is deliberate. Codex writes into shared locations — `AGENTS.md` is a merge target and `~/.agents/skills` is shared with Copilot external primitives — so a silent opt-in would have consequences the other clients do not.
- Instruction output carries no YAML frontmatter. Copilot's `applyTo:` has no Codex equivalent.
- `instructions.scope` becomes a prose preamble ("The following applies when working on files matching …") because an `AGENTS.md` body is unconditionally active for its whole subtree. The sync warns that this is a soft gate, not enforcement. A scope of `**` or an absent scope produces no preamble.
- Skill frontmatter is `name` + `description` only, per Codex's own skill-creator sample. Allowed-tools, license, compatibility, and context are dropped.

Codex also reads locations KAT deliberately does not write: `$CODEX_HOME/skills` (marked deprecated in Codex source), `.codex/skills/`, and `AGENTS.override.md`. The override file shadows `AGENTS.md` at both scopes, so a hand-written one will silently win over KAT output.

#### Open Question: Overlap With Copilot

Codex output may not stay Codex-only. Copilot appears to also read `AGENTS.md`, and to prefer `.agents/skills` over `.github/skills`. If that holds, enabling Codex for an artifact means the content can reach Copilot as well, which is not what the per-client `enabled` flags imply.

This is observed behavior, not a settled design. No approach has been chosen yet, and the renderer's current split is unchanged pending that decision — see [.vscode/Plans/codex-conflicts.md](../Plans/codex-conflicts.md). Until it is resolved, treat the client-marker and `bodyReplacements` boundaries between `copilot` and `codex` as intent rather than as an enforced guarantee about which client sees what.

### Tool Mapping

Tool mapping is centralized in `AI/skills/kat-policies/meta.jsonc` rather than repeated in every artifact. Individual artifact metadata should stay canonical and only carry local overrides when shared mappings are insufficient.

Current notable gaps:

1. `vscode/*` tools have no native Claude equivalent.
2. GitHub-specific Copilot tools can only be approximated with Claude `Bash` and `WebFetch` unless a closer GitHub integration is added.
3. Copilot orchestration metadata has no native Claude frontmatter equivalent, so those fields are intentionally omitted.
4. Tool metadata is not mapped for Codex at all. Codex skill frontmatter carries no allowed-tools field, so tool declarations simply do not travel to Codex output.

### Matrix Statuses

| Status | Meaning |
|---|---|
| `global` / `repository` | Published successfully, at user or repo scope. |
| `excluded` | Nothing was asked for — the artifact's metadata does not enable that client. |
| `unsupported` | Something *was* asked for and could not be delivered, e.g. `codex: true` on an agent or MCP server. Footnoted with the reason. |
| `skipped` | An existing file is no longer read-only or was never KAT-owned. Re-run with `-Overwrite` to replace it. |
| `removed` | A previously published artifact was cleaned up because it is no longer enabled. |
| `blocked` | The write failed. The footnote and the Manual Cleanup Required list say why. |

`excluded` and `unsupported` are easy to conflate. The distinction matters because `excluded` needs no action while `unsupported` means a metadata request is going unfulfilled.

### Current Compatibility Summary

The remaining compatibility warnings are the intentional Copilot orchestration omissions for currently-enabled agents that use `subAgents`:

1. `kat-nexgen` (enabled, has `subAgents`)
2. `Ultralight.Orchestrator` (disabled, has `subAgents`)

Disabled agents (Code Review, Ultralight suite) do not produce warnings during sync.

Codex adds three more warning kinds, none of which appear unless an artifact opts in: an out-of-scope request (`codex: true` on an agent or MCP server), a scope reduced to a prose preamble, and a global skill id colliding with a Copilot-client external primitive. The summary is dynamic — run `update.ps1` to see the current state.
