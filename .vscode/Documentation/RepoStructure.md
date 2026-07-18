# Repository Structure

This document describes the layout of the Policies repository and where to find each type of content. Use it as a map when navigating the canonical source tree or locating scripts.

For how the renderer transforms this structure into published artifacts, see [KatPolicies.md](KatPolicies.md). For the metadata schema each file uses, see [Metadata.md](Metadata.md).

## Quick Reference

| Path | Description |
|------|-------------|
| `.editorconfig` | Consistent coding styles across editors and IDEs (Visual Studio, VS Code, Rider, etc.). Deployed to `C:\BTR\.editorconfig`. |
| `/AI` | Canonical source for agents, instructions, skills, and per-client metadata. |
| `/AI/external.primitives.jsonc` | Install catalog for external primitives — keyed by id, with a target `client`, `enabled` boolean, and install `command`. |
| `/Terminal` | Windows Terminal settings. Deployed to the Windows Terminal LocalState folder. |
| `/scripts/update.ps1` | Main sync script. Renders all canonical content and deploys to target clients. |
| `/scripts/Kat.Policy.Mcp.psm1` | Shared PowerShell module used by update.ps1 and MCP bootstrap helpers. |
| `/scripts/install-context7-remote.ps1` | Context7 MCP bootstrap helper. |
| `/scripts/install-github-remote.ps1` | GitHub MCP bootstrap helper. |
| `/scripts/install-katledger.ps1` | KatLedger MCP bootstrap helper. |
| `/.vscode/Documentation/` | Developer documentation (this folder). |

## AI Layout

Canonical AI content lives under `/AI` and is authored once, then rendered into client-specific formats by `scripts/update.ps1`.

### Canonical Source Tree

```text
/AI/
  external.primitives.jsonc
  agents/
    [group/]*
      <agent-folder>/
        body.md
        meta.jsonc
  instructions/
    <id>/
      body.md
      meta.jsonc
  skills/
    <id>/
      SKILL.md
      meta.jsonc
      commands/
      references/
      templates/
/scripts/
  update.ps1
  install-context7-remote.ps1
  install-github-remote.ps1
  install-katledger.ps1
  Kat.Policy.Mcp.psm1
```

### Agents

Each canonical agent lives in a folder somewhere under `/AI/agents/`.

- `body.md` is the shared prompt body.
- `meta.jsonc` uses the [shared metadata shape](Metadata.md) plus canonical `agents.*` fields such as `agents.model`, `agents.tools`, `agents.userInvocable`, `agents.subAgents`, and `agents.handoffs`.
- Grouping folders are allowed. The sync walks `AI/agents` recursively and treats the first folder containing both `body.md` and `meta.jsonc` as the canonical agent directory.
- Published agent naming comes from `meta.jsonc.id` (with a leaf-folder fallback when `id` is omitted), so source nesting does not change the generated output filename.

### Instructions

Each canonical instruction lives in `/AI/instructions/<id>/`.

- `body.md` is the shared instruction content.
- `meta.jsonc` uses the [shared metadata shape](Metadata.md) plus `instructions.scope`.
- `instructions.scope` is optional. Omitted or empty means global. Non-empty array means path-scoped output. See [Metadata.md](Metadata.md) for details.

### Skills

Each canonical skill lives in `/AI/skills/<id>/`.

- `SKILL.md` contains the shared body only.
- `meta.jsonc` uses the [shared metadata shape](Metadata.md) plus skill-specific fields.
- Supporting files (references, templates, scripts) remain beside the skill and are installed into published directories as copied managed files.
- Skills may include `agents/meta.jsonc` under the skill folder for non-user-invocable helper agents.
- `commands/*.md` are canonical command workflow files — nested in Claude skills and rendered as standalone child skills for Copilot.

### External Primitives

`AI/external.primitives.jsonc` declares externally managed primitives. Each entry targets one client with a `client` property, an `enabled` boolean, and an install `command`. These use provider-native locations (e.g. `~/.agents/skills/` for Copilot, `~/.claude/skills/` for Claude) rather than the canonical renderer paths.

### Terminal

`/Terminal` contains Windows Terminal configuration files. `Terminal/meta.jsonc` can restrict deployment to specific users via `applyForUsers`. The settings file is copied (not symlinked) to the Windows Terminal LocalState folder.

## Tools

The sync installs **ripgrep** (`rg`) via `winget` and auto-upgrades it on each run. Ripgrep provides fast text search that AI agents use for codebase navigation. Pass `-DisableToolAutoUpgrade` to skip the upgrade check.
