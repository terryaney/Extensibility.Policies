# Development Policies

To ensure all developers use the same rules, we maintain a single source of truth under git source control management.  This folder contains shared development policies used across all local .NET and source controlled projects. These policies ensure consistent formatting, coding standards, and dependency management across all repositories.

NOTE:

Edit only the files in `C:\BTR\Extensibility\Policies\`. All projects immediately inherit the changes. No need to update or copy files into individual repos.

Because these configuration files are either hard coded locations or only discovered by walking upward from the project directory, every BTR/KAT project picks up the shared rules by default. The update script renders canonical AI content into client-specific formats, then installs only KAT-managed symlinks or rendered files into the detected destination folders.

## Installation

1. Clone repository to your local machine:
  `git clone https://tfs.acsgs.com/tfs/PDSI/HRS2/_git/HRS%20BTR%20-%20extensibility.policies C:\BTR\Extensibility\Policies`
1. Run the following command in Terminal:
  `C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\update.ps1`

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
    <id>/
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
      commands/        # optional, Claude-only command publishing today
      scripts/         # optional helper scripts
      references/      # optional supporting material
      templates/       # optional supporting material
```

### Agents

Each canonical agent lives in `/AI/agents/<id>/`.

- `body.md` is the shared prompt body.
- `meta.jsonc` holds the renderer-facing metadata: names, descriptions, models, tools, target toggles, Copilot orchestration, and optional repo-local publish roots. Comments are allowed and stripped by the renderer.

### Instructions

Each canonical instruction lives in `/AI/instructions/<id>/`.

- `body.md` is the shared instruction content.
- `meta.jsonc` decides where that content is published: VS Code Copilot instructions, Copilot CLI instructions, and one Claude mode at a time (`claudeGlobalInstruction` or `claudePathInstruction`).

### Skills

Each canonical skill lives in `/AI/skills/<id>/`.

- `SKILL.md` contains the shared body only.
- `meta.jsonc` contains publication toggles and frontmatter fields.
- Supporting files remain beside the skill and are installed into published skill directories as regular folders containing KAT-managed symlinked files.
- `commands/*.md` are canonical command workflow files. If present, they are automatically published to `~/.claude/commands/*.md` for Claude and rendered as standalone child skills named `<parent>-<command>` for Copilot. The `commands` directory is not installed inside published skill folders.

### Rendered Destinations

The renderer currently targets these install locations:

| Canonical Type | VS Code | Copilot CLI | Claude |
|------|------|------|------|
| Agents | `%APPDATA%/Code/User/prompts/*.agent.md`<sup>1</sup> | `~/.copilot/agents/*.agent.md`<sup>1</sup> | `~/.claude/agents/*.md`<sup>1</sup> |
| Instructions | `%APPDATA%/Code/User/instructions/*.instructions.md`<sup>1</sup> | `~/.copilot/instructions/*.instructions.md`<sup>1</sup> | `~/.claude/instructions/*.md` and generated `~/.claude/CLAUDE.md` imports for global instructions<br>`~/.claude/rules/*.md`<sup>1</sup> for 'path' restricted instructions |
| Skills | n/a | `~/.copilot/skills/<id>/` | `~/.claude/skills/<id>/` and optional `~/.claude/commands/*.md` |

<sup>1</sup> When `publish.repositoryRoot` is set, the equivalent repo-local path is also published for enabled targets: `.github/agents/*.agent.md`, `.claude/agents/*.md`, `.github/instructions/*.instructions.md`, `.claude/rules/*.md`.

## Renderer Notes

The update script now renders from canonical source instead of maintaining separate pre-rendered `/Copilot` and `/Claude` trees. This section is the primary reviewer handoff for the current renderer design and contains the canonical metadata reference.

### Purpose

The renderer is trying to accomplish four things:

1. Keep one canonical source of truth for agents, instructions, skills, and terminal policy content.
1. Render each artifact into the format expected by each client instead of authoring duplicate files by hand.
1. Take ownership only of KAT-managed outputs and avoid deleting unrelated user files.
1. Surface client compatibility gaps explicitly so missing parity is visible during each sync.

### Supported Process

`AI/skills/kat-policies/scripts/update.ps1` currently supports this workflow:

1. Discover the install roots for VS Code, Copilot CLI, Claude, and Windows Terminal.
1. Scan known managed roots and remove only KAT-managed files, symlinks, and directories before republishing.
1. Parse canonical `meta.jsonc` files, including line comments.
1. Render target-specific frontmatter and write the final published files.
1. Install supporting skill files as symlinks beside the rendered `SKILL.md` files.
1. Generate `~/.claude/CLAUDE.md` from the enabled instruction imports.
1. Copy Terminal settings instead of linking them, because Windows Terminal does not reliably live-reload changes through linked paths.
1. Mark rendered files as read-only and stamp managed plain files with a `CreatedBy=KAT` alternate data stream when possible.
1. Print a deployment matrix plus compatibility summary after each run.

### Ownership And Cleanup Model

The cleanup rules matter because the renderer is intentionally conservative.

- Managed plain files are normally recognized by the `CreatedBy=KAT` alternate data stream.
- Managed symlinks are recognized when their target points back into the Policies repository.
- Managed directories are reusable only when all of their contents are managed.
- Broken managed symlinks are now removed correctly during cleanup.
- Repo-targeted agent outputs are treated as authoritative current targets for the exact paths derived from current metadata, so they can be replaced even if the KAT marker is temporarily missing.
- Repo-local cleanup now collapses empty `.github` and `.claude` ancestor folders back toward the configured repository root.
- If `publish.repositoryRoot` is removed or changed to a different repository, cleanup of the previously targeted repository is manual because that older target path is no longer discoverable from current metadata.
- Published skill target folders are reused only when any remaining contents are still KAT-managed; if unmanaged content remains, that specific skill publish is blocked until the folder is cleaned up manually.

### Metadata Reference

#### Agent Metadata

Path: `/AI/agents/<id>/meta.jsonc`

| Field | Type | Notes |
|------|------|------|
| `id` | string | Canonical id and base filename. |
| `name` | string | Rendered into Copilot and Claude frontmatter. |
| `description` | string | Rendered into Copilot and Claude frontmatter. |
| `enabled.vscode` | bool | Publishes a VS Code agent prompt. Defaults to `true`. |
| `enabled.copilotCli` | bool | Publishes a Copilot CLI agent. Defaults to `true`. |
| `enabled.claude` | bool | Publishes a Claude agent. Defaults to `true`. |
| `models.vscode` | string | VS Code Copilot model. |
| `models.copilotCli` | string | Copilot CLI model. |
| `models.claude` | string | Claude model. |
| `publish.repositoryRoot` | string | If set, publishes VS Code output into `<repo>/.github/agents` and Claude output into `<repo>/.claude/agents` instead of user-level folders. |
| `tools.copilot` | string[] | Legacy tool declaration for VS Code and Copilot CLI. |
| `tools.claude` | string[] or `"auto"` | Legacy Claude declaration. `"auto"` still works but explicit per-client mappings are preferred. |
| `tools.<toolId>.vscode` | string or string[] | Explicit VS Code mapping for one canonical tool id. Defaults to the tool id when omitted. |
| `tools.<toolId>.copilotCli` | string or string[] | Explicit Copilot CLI mapping for one canonical tool id. Defaults to the tool id when omitted. |
| `tools.<toolId>.claude` | string or string[] | Explicit Claude mapping for one canonical tool id. Omit it when there is no Claude mapping. |
| `copilot.userInvocable` | bool | Copilot-only. Rendered as `user-invocable` for Copilot agents. No Claude subagent equivalent exists. |
| `copilot.agents` | string[] | VS Code Copilot-only orchestration metadata. Omitted from CLI and Claude rendering. |
| `copilot.handoffs` | object[] | VS Code Copilot-only handoff metadata. Omitted from CLI and Claude rendering. |
| `claude.memory` | string | Claude memory scope: `user`, `project`, or `local`. |

Supported `copilot.handoffs[]` fields:

| Field | Type | Notes |
|------|------|------|
| `label` | string | Handoff label shown in Copilot. |
| `agent` | string | Target agent name. |
| `prompt` | string | Prompt text to send. |
| `send` | bool | Defaults to `false`. |

#### Instruction Metadata

Path: `/AI/instructions/<id>/meta.jsonc`

| Field | Type | Notes |
|------|------|------|
| `id` | string | Canonical id and base filename. |
| `name` | string | Informational today. |
| `description` | string | Used for Claude rule frontmatter. |
| `enabled.vscode` | bool | Publishes a VS Code `.instructions.md` file. Defaults to `true`. |
| `enabled.copilotCli` | bool | Publishes a Copilot CLI `.instructions.md` file. Defaults to `true`. |
| `enabled.claudeGlobalInstruction` | bool | Publishes `~/.claude/instructions/<id>.md` and adds `@instructions/<id>.md` to generated `CLAUDE.md` (or repo-local `.claude/...` when `publish.repositoryRoot` is set). |
| `enabled.claudePathInstruction` | bool | Publishes `~/.claude/rules/<id>.md` (or repo-local `.claude/rules/<id>.md` when `publish.repositoryRoot` is set). |
| `publish.repositoryRoot` | string | If set, publishes VS Code output into `<repo>/.github/instructions` and Claude output into `<repo>/.claude/...` instead of user-level folders. |
| `scope.copilot` | string | Rendered as Copilot `applyTo`. Defaults to `**`. |
| `scope.claude` | string[] | Rendered as Claude rule `paths` for `claudePathInstruction`. It does not affect `claudeGlobalInstruction`. |

Claude instruction modes are mutually exclusive:

- `claudeGlobalInstruction` writes `.claude/instructions/<id>.md` and includes it in generated `CLAUDE.md` imports.
- `claudePathInstruction` writes `.claude/rules/<id>.md` with explicit `paths`.
- If both are enabled, the renderer publishes only `claudePathInstruction` and emits a compatibility warning.
- Claude instruction and rule outputs do not currently use a `model` frontmatter field in this renderer. Claude `model` metadata is only emitted for agents.

Claude agent rendering note:

- When canonical agent metadata still uses `models.claude = "default"`, the renderer emits `model: sonnet` because current Claude frontmatter only accepts `sonnet`, `opus`, `haiku`, or `inherit`.

Recommended usage:

- Use `claudeGlobalInstruction: true` for global always-on instructions.
- Use `claudePathInstruction: true` for path-scoped or conditional Claude behavior.
- Enable only one Claude mode per instruction.
- Set `publish.repositoryRoot` when you want repo-local `.claude/...` output instead of user-level output.

#### Skill Metadata

Path: `/AI/skills/<id>/meta.jsonc`

| Field | Type | Notes |
|------|------|------|
| `id` | string | Target folder name under published skill roots. |
| `name` | string | Rendered into skill frontmatter. |
| `description` | string | Rendered into skill frontmatter. |
| `license` | string | Optional. |
| `compatibility` | string | Optional. |
| `metadata` | object | Optional flat object rendered as nested frontmatter. |
| `enabled.copilot` | bool | Publishes to Copilot CLI. Defaults to `true`. |
| `enabled.claude` | bool | Publishes to Claude. Defaults to `true`. |
| `copilot.excludeCommands` | string[] | Optional list of canonical command file basenames to skip when generating Copilot child skills. |

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

If a canonical skill has a `commands/*.md` folder, Copilot publishing also generates standalone child skills named `<parent>-<command>` such as `visual-explainer-diff-review`. Copilot skill installs do not include a `commands` folder.

### Current Implementation Notes

- `meta.jsonc` is the canonical metadata format across agents, instructions, and skills.
- Explicit per-client tool mappings are supported and are now preferred over opaque Claude `"auto"` mapping.
- Claude Context7 support is emitted explicitly when a `context7` MCP server is present in `.claude.json`.
- The renderer still accepts legacy metadata shapes where practical, but new work should use the explicit schema.
- The `kat` instruction now uses `claudeGlobalInstruction` without a duplicate global Claude rule.

## Compatibility Notes

### Copilot VS Code vs Copilot CLI

Both are rendered from the same canonical agent metadata, but they do not load the same artifact types.

- VS Code agent output is published as `.agent.md` prompt files.
- Copilot CLI agent output is published under `~/.copilot/agents`.
- VS Code-only orchestration fields such as `copilot.agents` and `copilot.handoffs` are intentionally omitted from CLI output.
- VS Code supports slash commands through prompt files and skills, not through Claude-style `.claude/commands/*.md` files.

### Claude Agents vs Commands vs Skills

Claude has a different artifact model from Copilot.

- Claude agents are subagents with their own model, tools, and memory.
- Claude commands are slash-invoked Markdown files. If a skill has a `commands/*.md` folder, commands are automatically published to `~/.claude/commands`.
- Claude skills are reusable capability packs under `~/.claude/skills`.
- Claude agent frontmatter has no equivalent to Copilot `userInvocable: false`.
- Claude skills do have invocation controls such as `user-invocable` and `disable-model-invocation`, but those are skill-level concerns, not subagent frontmatter.

### Tool Mapping

The renderer supports both legacy and explicit tool mapping.

- Legacy `tools.claude: "auto"` still maps known Copilot tools to the closest native Claude tools.
- Explicit `tools.<toolId>.<client>` mappings are preferred because they remove guesswork and make intended omissions visible in metadata.
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