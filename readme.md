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

Canonical AI content now lives under `/AI`.

### Agents

Store each agent as:

```text
/AI/agents/<id>/
  body.md
  meta.json
```

`body.md` contains the shared prompt body. `meta.json` contains target-specific fields such as names, models, tools, destination toggles, and Copilot-only orchestration metadata.

### Instructions

Store each instruction as:

```text
/AI/instructions/<id>/
  body.md
  meta.json
```

The renderer turns that into:

1. Copilot `.instructions.md` files with `applyTo`
1. Claude `.claude/rules/*.md` files with `paths`
1. Claude `.claude/instructions/*.md` imports
1. A generated `.claude/CLAUDE.md` containing `@instructions/<file>.md` imports

### Skills

Store each skill as a canonical directory under `/AI/skills/<skill>`.

`SKILL.md` now contains only the shared body. `meta.json` contains the frontmatter fields and publication toggles. The renderer writes target-specific `SKILL.md` files into Copilot and Claude skill folders, then links the rest of the skill directory contents beside them.

## Renderer Notes

The update script now renders from canonical AI source instead of copying pre-rendered `/Copilot` or `/Claude` trees.

Agent metadata supports the current structure:

```json
{
  "id": "kat-katapp",
  "name": "KatApp Assistant",
  "description": "Expert assistant for KatApp/kaml framework development.",
  "enabled": {
    "vscode": true,
    "copilotCli": true,
    "claude": true
  },
  "models": {
    "vscode": "GPT-5.4 (copilot)",
    "copilotCli": "gpt-5.4",
    "claude": "default"
  },
  "tools": {
    "copilot": ["vscode/memory", "edit", "search", "web", "read", "todo"],
    "claude": "auto"
  },
  "copilot": {
    "userInvocable": true,
    "agents": ["Reviewer (GPT)"]
  },
  "claude": {
    "target": "agent"
  }
}
```

Instruction metadata supports:

```json
{
  "id": "kat",
  "description": "Shared KAT communication, code, and .NET guidance.",
  "enabled": {
    "vscode": true,
    "copilotCli": true,
    "claudeInstruction": true,
    "claudeRule": true,
    "claudeImport": true
  },
  "scope": {
    "copilot": "**",
    "claude": ["**"]
  }
}
```

Skill metadata supports:

```json
{
  "id": "visual-explainer",
  "name": "visual-explainer",
  "description": "Generate beautiful, self-contained HTML pages that visually explain systems.",
  "license": "MIT",
  "compatibility": "Requires a browser to view generated HTML files.",
  "metadata": {
    "author": "nicobailon",
    "version": "0.5.1"
  },
  "enabled": {
    "copilot": true,
    "claude": true
  },
  "claude": {
    "exposeCommands": true
  }
}
```

For the full supported field list, see `/AI/meta.md`.

## Compatibility Notes

### Copilot VS Code vs Copilot CLI

Both are rendered from the same canonical agent metadata, but the CLI output intentionally drops Copilot VS Code-only orchestration fields such as `agents` and `handoffs`.

### Claude Agents vs Commands vs Skills

Use Claude agents when you want a manually enabled persona with its own model/tool declaration. Use Claude commands for slash-invoked workflows. Use skills for reusable capability packs that multiple prompts can pull in.

That means your Copilot-style "agent" maps best to `~/.claude/agents` when you want manual selection and model pinning. A Claude command is better only when the thing is really a reusable workflow macro.

### Tool Mapping

`tools.claude: "auto"` maps known Copilot tools to the closest native Claude tools. The script warns when there is no native equivalent.

Current notable gaps:

1. `vscode/*` tools have no native Claude equivalent.
1. `io.github.upstash/context7/*` needs a matching MCP server in Claude if you want parity.
1. GitHub-specific Copilot tools can only be approximated with Claude `Bash` and `WebFetch` unless you install a GitHub CLI or MCP integration.

## Copilot Notes

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