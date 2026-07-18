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

1. Discover the install roots for BTR configurations, VS Code, Copilot CLI, Claude, and Windows Terminal.
2. Scan known managed roots and remove only KAT-managed files and directories before republishing.
3. Parse canonical `meta.jsonc` files, including line comments.
4. Render target-specific frontmatter and write the final published files.
5. Install supporting skill files as copied managed files beside the rendered `SKILL.md` files.
6. Generate `~/.claude/CLAUDE.md` from the enabled instruction imports.
7. Deploy `Terminal/settings.json` to local user install folder.
8. Deploy `.editorconfig` to `C:\BTR\.editorconfig`.
9. Mark rendered files as read-only and stamp managed plain files with a `CreatedBy=KAT` alternate data stream when possible.
10. Install ripgrep via winget (with auto-upgrade).
11. Bootstrap MCP servers when requested by canonical agent tool metadata.
12. Print a deployment matrix plus compatibility summary after each run.

## Rendered Destinations

| Canonical Type | VS Code | Copilot CLI | Claude |
|------|------|------|------|
| Agents | `%APPDATA%/Code/User/prompts/*.agent.md`¹ | `~/.copilot/agents/*.agent.md`¹ | `~/.claude/agents/*.md`¹ |
| Instructions | `%APPDATA%/Code/User/instructions/*.instructions.md`¹ | `~/.copilot/instructions/*.instructions.md`¹ | `~/.claude/instructions/*.md` and generated `~/.claude/CLAUDE.md` imports for global instructions, or `~/.claude/rules/*.md`¹ for path-scoped instructions |
| Skills | `~/.copilot/skills/<id>/`² | `~/.copilot/skills/<id>/`² | `~/.claude/skills/<id>/`² |

¹ When `enabled.repositories` includes repo-local targets, the equivalent repo paths are also published: `.github/agents/*.agent.md`, `.claude/agents/*.md`, `.github/instructions/*.instructions.md`, and either `.claude/instructions/*.md` plus generated `.claude/CLAUDE.md` imports for global instructions or `.claude/rules/*.md` for path-scoped instructions.

² When `enabled.repositories` includes repo-local targets, Copilot skill output is published under `.github/skills/<id>/` and Claude skill output under `.claude/skills/<id>/`. If a canonical skill has a `commands/*.md` folder, Copilot child skills are also published under `skills/<parent>.<command>/`, and Claude command markdown is nested under `skills/<parent>/commands/`.

External installable skills use provider-native locations. With the current `skills-cli` behavior, GitHub Copilot installs land under `.agents/skills/` for project scope and `~/.agents/skills/` for global scope, while Claude installs use `.claude/skills/` or `~/.claude/skills/`.

## Ownership and Cleanup Model

The renderer is intentionally conservative about what it deletes.

- Managed plain files are recognized by the `CreatedBy=KAT` alternate data stream.
- Legacy managed symlinks are still recognized when their target points back into the Policies repository.
- Managed directories are reusable only when all of their contents are managed.
- Broken legacy managed symlinks are still removed correctly during cleanup.
- Repo-targeted outputs are treated as authoritative current targets for exact paths derived from current metadata, so they can be replaced even if the KAT marker is temporarily missing.
- Repo-local cleanup collapses empty `.github` and `.claude` ancestor folders back toward configured repository roots.
- If an `enabled.repositories` entry is removed or changed, cleanup of the previously targeted repository is manual.
- Published skill target folders are reused only when remaining contents are still KAT-managed.

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

### Tool Mapping

Tool mapping is centralized in `AI/skills/kat-policies/meta.jsonc` rather than repeated in every artifact. Individual artifact metadata should stay canonical and only carry local overrides when shared mappings are insufficient.

Current notable gaps:

1. `vscode/*` tools have no native Claude equivalent.
2. GitHub-specific Copilot tools can only be approximated with Claude `Bash` and `WebFetch` unless a closer GitHub integration is added.
3. Copilot orchestration metadata has no native Claude frontmatter equivalent, so those fields are intentionally omitted.

### Current Compatibility Summary

The remaining compatibility warnings are the intentional Copilot orchestration omissions for currently-enabled agents that use `subAgents`:

1. `kat-nexgen` (enabled, has `subAgents`)
2. `Ultralight.Orchestrator` (disabled, has `subAgents`)

Disabled agents (Code Review, Ultralight suite) do not produce warnings during sync. The summary is dynamic — run `update.ps1` to see the current state.
