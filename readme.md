# Development Policies

To ensure all developers use the same rules, we maintain a single source of truth under git source control management.  This folder contains shared development policies used across all local .NET and source controlled projects. These policies ensure consistent formatting, coding standards, and dependency management across all repositories.

NOTE:

Edit only the files in `C:\BTR\Extensibility\Policies\`. All projects immediately inherit the changes. No need to update or copy files into individual repos.

Because these configuration files are either hard coded locations or only discovered by walking upward from the project directory, every BTR/KAT project picks up the shared rules by default. The update script renders canonical AI content into client-specific formats, then installs only KAT-managed copied files into the detected destination folders.

## Installation

1. Clone repository to your local machine:
  `git clone https://tfs.acsgs.com/tfs/PDSI/HRS2/_git/HRS%20BTR%20-%20extensibility.policies C:\BTR\Extensibility\Policies`
1. Run the following command in Terminal:
  `C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\update.ps1`

If KAT Policies agent metadata requires Context7 MCP Server , `update.ps1` automatically runs `AI\skills\kat-policies\scripts\install-context7-remote.ps1`. The helper always requires `CONTEXT7_API_KEY` and fails fast when it is missing. Set `CONTEXT7_API_KEY` first:

`[Environment]::SetEnvironmentVariable("CONTEXT7_API_KEY", "<your-key>", "User")`

Optional preview without file writes:

`C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\install-context7-remote.ps1 -WhatIf`

Once you've installed this once, the `kat-policies` skill will be available in your Copilot and Claude chats.  Simply ask to "update KAT policies" and the agent will pull the latest files and run the script automatically.

## Quick Reference

| File | Description |
|------|-------------|
| `.editorconfig` | Defines consistent coding styles across editors and IDEs (Visual Studio, VS Code, Rider, etc.).|
| `Directory.Packages.Camelot.props` | Manages NuGet package versions for Camelot framework projects |
| `Directory.Packages.Evolution.props` | Manages NuGet package versions for Evolution framework projects |
| `/AI` | Canonical source for agents, instructions, skills, and per-client metadata rendered into Copilot and Claude destinations. |
| `/Terminal` | Provides consistent Terminal settings for Windows Terminal. |

## AI Layout

Canonical AI content lives under `/AI` and is authored once, then rendered into client-specific formats by `AI/skills/kat-policies/scripts/update.ps1`.

### Canonical Source Tree

```text
/AI/
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
      scripts/
      references/
      templates/
```

### Agents

Each canonical agent lives in a folder somewhere under `/AI/agents/`.

- `body.md` is the shared prompt body.
- `meta.jsonc` uses the shared metadata shape plus canonical `agents.*` fields such as `agents.model`, `agents.tools`, `agents.userInvocable`, `agents.subAgents`, and `agents.handoffs`.
- `agents.model` is the VS Code Copilot model display name. Copilot CLI and Claude output map from that canonical value through `AI\skills\kat-policies\scripts\meta.mappings.jsonc`.
- Canonical metadata is VS Code Copilot-centric. Claude output is rendered from the same canonical fields instead of being authored as a separate source format.
- Grouping folders are allowed. Policy sync walks `AI\agents` recursively and treats the first folder containing both `body.md` and `meta.jsonc` (or `meta.json`) as the canonical agent directory.
- Published agent naming still comes from `meta.jsonc.id` (with the existing leaf-folder fallback when `id` is omitted), so source nesting does not change the generated output filename.

### Instructions

Each canonical instruction lives in `/AI/instructions/<id>/`.

- `body.md` is the shared instruction content.
- `meta.jsonc` uses the shared metadata shape plus `instructions.scope`.
- `instructions.scope` is optional. If it is omitted, the instruction is global. If it is present as an empty array, it is also global. A non-empty array means path-scoped output. Copilot `applyTo` is derived from this scope during rendering.

### Skills

Each canonical skill lives in `/AI/skills/<id>/`.

- `SKILL.md` contains the shared body only.
- `meta.jsonc` uses the shared metadata shape plus skill-specific fields such as `license`, `compatibility`, `metadata`, and `skills.excludeCommands.copilot`.
- Supporting files remain beside the skill and are installed into published skill directories as regular folders containing KAT-managed copied files.
- `commands/*.md` are canonical command workflow files. If present, they are automatically nested in `~/.claude/skills/{id}/commands/` for Claude and rendered as standalone child skills for Copilot with a filesystem-safe folder id `<skill>-<command>` and a published skill name `<skill>.<command>`.

### Rendered Destinations

The renderer currently targets these install locations:

| Canonical Type | VS Code | Copilot CLI | Claude |
|------|------|------|------|
| Agents | `%APPDATA%/Code/User/prompts/*.agent.md`<sup>1</sup> | `~/.copilot/agents/*.agent.md`<sup>1</sup> | `~/.claude/agents/*.md`<sup>1</sup> |
| Instructions | `%APPDATA%/Code/User/instructions/*.instructions.md`<sup>1</sup> | `~/.copilot/instructions/*.instructions.md`<sup>1</sup> | `~/.claude/instructions/*.md` and generated `~/.claude/CLAUDE.md` imports for global instructions, or `~/.claude/rules/*.md`<sup>1</sup> for path-scoped instructions |
| Skills | n/a | `~/.copilot/skills/<id>/`<sup>2</sup> | `~/.claude/skills/<id>/`<sup>2</sup> |

<sup>1</sup> When `enabled.repositories` includes repo-local targets, the equivalent repo paths are also published for supported clients: `.github/agents/*.agent.md`, `.claude/agents/*.md`, `.github/instructions/*.instructions.md`, and either `.claude/instructions/*.md` plus generated `.claude/CLAUDE.md` imports for global instructions or `.claude/rules/*.md` for path-scoped instructions.
<sup>2</sup> When `enabled.repositories` includes repo-local targets for a skill, Copilot skill output is published under `.github/skills/<id>/` and Claude skill output under `.claude/skills/<id>/`. If a canonical skill has a `commands/*.md` folder, Copilot child skills are also published under `skills/<parent>.<command>/`, matching the published skill name `<parent>.<command>`, and Claude command markdown is nested under `skills/<parent>/commands/`.

## Renderer Notes

The update script now renders from canonical source instead of maintaining separate pre-rendered `/Copilot` and `/Claude` trees. This section is the primary reviewer handoff for the renderer direction and contains the target metadata reference.

### Purpose

The renderer is trying to accomplish four things:

1. Keep one canonical source of truth for agents, instructions, skills, and terminal policy content.
1. Render each artifact into the format expected by each client instead of authoring duplicate files by hand.
1. Take ownership only of KAT-managed outputs and avoid deleting unrelated user files.
1. Surface client compatibility gaps explicitly so missing parity is visible during each sync.

### Supported Process

`AI/skills/kat-policies/scripts/update.ps1` currently supports this workflow:

1. Discover the install roots for VS Code, Copilot CLI, Claude, and Windows Terminal.
1. Scan known managed roots and remove only KAT-managed files and directories before republishing.
1. Parse canonical `meta.jsonc` files, including line comments.
1. Render target-specific frontmatter and write the final published files.
1. Install supporting skill files as copied managed files beside the rendered `SKILL.md` files.
1. Generate `~/.claude/CLAUDE.md` from the enabled instruction imports.
1. Copy Terminal settings instead of linking them, because Windows Terminal does not reliably live-reload changes through linked paths.
1. Mark rendered files as read-only and stamp managed plain files with a `CreatedBy=KAT` alternate data stream when possible.
1. Print a deployment matrix plus compatibility summary after each run.
1. When Context7 is requested by canonical agent tool metadata, invoke the remote Context7 bootstrap helper to ensure VS Code, Copilot CLI, and Claude Context7 MCP entries are set to remote HTTP (converting existing local `stdio` entries where present).

### Ownership And Cleanup Model

The cleanup rules matter because the renderer is intentionally conservative.

- Managed plain files are normally recognized by the `CreatedBy=KAT` alternate data stream.
- Legacy managed symlinks are still recognized when their target points back into the Policies repository so older installs can be cleaned up.
- Managed directories are reusable only when all of their contents are managed.
- Broken legacy managed symlinks are still removed correctly during cleanup.
- Repo-targeted outputs are treated as authoritative current targets for the exact paths derived from current metadata, so they can be replaced even if the KAT marker is temporarily missing.
- Repo-local cleanup now collapses empty `.github` and `.claude` ancestor folders back toward configured repository roots.
- If an `enabled.repositories` entry is removed or changed to a different repository, cleanup of the previously targeted repository is manual because that older target path is no longer discoverable from current metadata.
- Published skill target folders are reused only when any remaining contents are still KAT-managed; if unmanaged content remains, that specific skill publish is blocked until the folder is cleaned up manually.

### Metadata Reference

Use one shared shape across all `meta.jsonc` files. Put the common properties first, then add artifact-specific prefixed sections so applicability is obvious.

The target schema also includes a shared mappings file at `AI/skills/kat-policies/scripts/meta.mappings.jsonc`. Keep that file high-level and reusable: it is where shared client translations and renderer mappings live so individual artifact metadata can stay focused on canonical intent.

| Field | Type | Applies To | Notes |
|------|------|------|------|
| `id` | string | agents, instructions, skills | Canonical id and base filename or folder name. |
| `name` | string | agents, instructions, skills | Rendered display name. |
| `description` | string | agents, instructions, skills | Rendered summary or description. |
| `enabled.copilot` | bool | agents, instructions, skills | Publishes Copilot outputs for that artifact. For agents and instructions this covers both VS Code and Copilot CLI renderers where applicable. Defaults to `true`. |
| `enabled.claude` | bool | agents, instructions, skills | Publishes Claude outputs for that artifact. Defaults to `true`. |
| `enabled.repositories` | string[] | agents, instructions, skills | Optional repo-local publish roots. When omitted, publishing is user-level only. |
| `agents.model` | string | agents | Canonical VS Code Copilot model display name. Copilot CLI and Claude output map from this value through `AI\skills\kat-policies\scripts\meta.mappings.jsonc`. |
| `agents.tools` | string[] | agents | Canonical tool array. Shared client translations belong in `meta.mappings.jsonc`; keep artifact metadata focused on canonical tool intent. |
| `agents.userInvocable` | bool | agents | Canonical user-invocable flag for Copilot agent rendering. Claude agent output has no direct equivalent. |
| `agents.subAgents` | array | agents | Canonical subagent/orchestration list for Copilot-aware agent composition. Unsupported clients omit it. |
| `agents.handoffs` | object[] | agents | Canonical handoff metadata for orchestrator-style agents. Unsupported clients omit it. |
| `instructions.scope` | string[] | instructions | Optional. Omitted or `[]` means global instruction output. A non-empty array means path-scoped output. Copilot `applyTo` is derived from this field during rendering. |
| `license` | string | skills | Optional. Preserve it when present. |
| `compatibility` | string | skills | Optional compatibility note rendered with the skill. |
| `metadata` | object | skills | Optional nested metadata. Preserve it when present. |
| `skills.excludeCommands.copilot` | string[] | skills | Optional list of canonical command basenames to skip when generating Copilot child skills. |

`agents.handoffs[]` supports these nested fields:

- `label`: handoff label shown in Copilot.
- `agent`: target agent name.
- `prompt`: prompt text sent to the target.
- `send`: optional bool, defaults to `false`.

Canonical skill markdown supports optional client markers for small wording differences inside shared content:

```md
<!-- copilot:start -->
Copilot-only text.
<!-- copilot:end -->

<!-- claude:start -->
Claude-only text.
<!-- claude:end -->
```

The renderer strips these markers during publishing so each client receives only its relevant block.

If a canonical skill has a `commands/*.md` folder, Copilot publishing also generates standalone child skill folders named `<parent>.<command>`. The folder name matches the published skill name, so a command can be invoked as `/visual-explainer.diff-review`. Copilot skill installs do not include a `commands` folder.

### Target Schema Notes

- `meta.jsonc` remains the canonical metadata format across agents, instructions, and skills.
- Canonical metadata is VS Code Copilot-centric. Client-specific differences should be derived by the renderer instead of duplicated across artifact docs.
- `AI/skills/kat-policies/scripts/meta.mappings.jsonc` is the shared place for reusable client translations and mappings, including how canonical `agents.model` values are rendered for Copilot CLI and Claude.
- Repo-local publishing is controlled by `enabled.repositories`.
- Instructions use `instructions.scope` instead of split Claude-specific enable flags. Omitted scope and empty scope both mean global. Non-empty scope means path-scoped output.
- Agents should use canonical schema fields `agents.model`, `agents.tools`, `agents.userInvocable`, `agents.subAgents`, and `agents.handoffs`.
- Skills should use `skills.excludeCommands.copilot`.
- `claude.target` is legacy-only for agents and should not be documented as a normal supported field.
- Legacy root-level field shapes may still exist in older artifacts, but this readme documents the target schema only.

## Compatibility Notes

### Copilot VS Code vs Copilot CLI

Both are rendered from the same canonical agent metadata, but they do not load the same artifact types.

- VS Code agent output is published as `.agent.md` prompt files.
- Copilot CLI agent output is published under `~/.copilot/agents`.
- VS Code-only orchestration fields such as `agents.subAgents` and `agents.handoffs` are intentionally omitted from CLI output.
- VS Code supports slash commands through prompt files and skills, not through Claude-style nested skill commands under `.claude/skills/<id>/commands/`.

### Claude Agents vs Commands vs Skills

Claude has a different artifact model from Copilot.

- Claude agents are subagents with their own model, tools, and memory.
- Claude commands are slash-invoked Markdown files nested in skill folders (`~/.claude/skills/<id>/commands/`). If a skill has a `commands/*.md` folder, those files are automatically nested within the published skill.
- Claude skills are reusable capability packs under `~/.claude/skills`.
- Claude agent frontmatter has no equivalent to Copilot `userInvocable: false`.
- Claude skills do have invocation controls such as `user-invocable` and `disable-model-invocation`, but those are skill-level concerns, not subagent frontmatter.

### Tool Mapping

The renderer keeps tool mapping centralized instead of repeating client-specific details in every artifact.

- Shared client translations belong in `AI/skills/kat-policies/scripts/meta.mappings.jsonc`.
- Individual artifact metadata should stay canonical and only carry local overrides when the shared mappings are not enough.
- When Claude parity is impossible, the script leaves a compatibility note rather than silently pretending the clients are equivalent.

Current notable gaps:

1. `vscode/*` tools have no native Claude equivalent.
1. GitHub-specific Copilot tools can only be approximated with Claude `Bash` and `WebFetch` unless you add a closer GitHub integration.
1. Copilot orchestration metadata has no native Claude frontmatter equivalent, so those fields are intentionally omitted from Claude output.

### Current Compatibility Summary

At the time of this update, the remaining compatibility warnings are the intentional Copilot orchestration omissions for:

1. `Code.Review.GPT`
1. `Code.Review.Orchestrator`
1. `kat-nexgen`
1. `Ultralight.Orchestrator`

Everything else in the current summary is either explicitly mapped or intentionally published into only one client's model.

## Copilot Notes

**Ultralight Orchestrator **

- Started from Burke Holland's [ultralight](https://burkeholland.github.io/ultralight/)
- Updated Coder from Claude Opus 4.6 (copilot) to GPT-5.3-Codex (copilot) from [Montemagno](https://x.com/jamesmontemagno/status/2023941950815302139?s=52) - want to see his agent files still.  Also one comment was 'single-pass full implementation', should I try to put that in planner/orchestrator?
- Updated Orchestrator from Claude Sonnet 4.5 (copilot)
	- to Claude Sonnet 4.6 (copilot) after release of 4.6 and all the hype
	- to GPT-5.4 (copilot) after release of 5.4 and all the hype
- Updated Planner from GPT-5.2 (copilot) 
	- to Claude Sonnet 4.6 (copilot) after release of 4.6 and all the hype
	- back to GPT-5.4 (copilot) after release of 5.4 and all the hype

## Claude Notes

[Visual Explainer](https://github.com/nicobailon/visual-explainer) - An agent skill that turns complex terminal output into styled HTML pages you actually want to read.

## Global Package Management for .NET

Each framework (Evolution, Camelot, etc.) has its own package file (i.e. `Directory.Packages.Camelot.props`) so that the same nuget package versions are used by default (which is KAT standard policy).

The format of global package management is something like:

```xml
<Project>
  <ItemGroup>
    <PackageVersion Include="Serilog" Version="2.12.0" />
    <PackageVersion Include="Microsoft.Extensions.Logging" Version="7.0.0" />
  </ItemGroup>
</Project>
```

### Importing the Global Package File in Each Repo

All .csproj files for a given framework (Evolution, Camelot, etc.) should import the appropriate global package file to automatically use versions specified in policies.

```xml
<Project>
  <Import Project="C:\BTR\Extensibility\Policies\Directory.Packages.Camelot.props" />
</Project>
```

Example project reference to use globally managed version.  No version number is needed — it comes from the global file.

```xml
<ItemGroup>
    <PackageVersion Include="Serilog" />
    <PackageVersion Include="Microsoft.Extensions.Logging" />
</ItemGroup>
```

### Overriding Global Package Versions

There are two supported override mechanisms.

**A. Repo Level Override (`Directory.Packages.props` in a specific repository).**

If a repo needs different versions temporarily, add a local `Directory.Packages.props` file to the root of the repository.

Example `Directory.Packages.props` file to change the Serilog version to be previously supported version

```xml
<Project>
  <ItemGroup>
    <PackageVersion Include="Serilog" Version="2.0.11" />
  </ItemGroup>
</Project>
```

This file takes precedence over the global one for that repo only.

**B. Project Level Override (Inside a .csproj)**

A project can override both global and repository level versions by specifying a version explicitly:

```xml
<ItemGroup>
  <PackageReference Include="Serilog" Version="2.0.13" />
</ItemGroup>
```

This is the highest precedence override and should be used sparingly.
