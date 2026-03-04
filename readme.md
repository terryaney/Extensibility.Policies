# 📘 Development Policies

To ensure all developers use the same rules, we maintain a single source of truth under git source control management.  This folder contains shared development policies used across all local .NET and source controlled projects. These policies ensure consistent formatting, coding standards, and dependency management across all repositories.

**NOTE:** 

Edit only the files in `C:\BTR\Policies\`.  All projects immediately inherit the changes.  No need to update or copy files into individual repos.

Because these configuration files are either hard coded locations or only discovered by walking upward from the project directory.  This ensures every BTR/KAT project by default picks up the shared rules. We expose files globally by creating a symlink (or copies with CreatedBy:KAT Alternative Data Stream (ADM) setting) at appropriate locations that can be cleaned up during the update process.

## Installation

1. Clone repository to your local machine:
	`git clone https://tfs.acsgs.com/tfs/PDSI/HRS2/_git/HRS%20BTR%20-%20extensibility.policies C:\BTR\Policies`
1. Run following command in Terminal:
	`C:\BTR\Policies\Copilot\skills\kat-policies\scripts\update.ps1`

Once you've installed this once, the `kat-policies` skill will be available in your Copilot and Claude chats.  Simply ask to "update KAT policies" and the agent will pull the latest files and run the script automatically.

## Quick Reference

| File | Description |
|------|-------------|
| `.editorconfig` | Defines consistent coding styles across editors and IDEs (Visual Studio, VS Code, Rider, etc.).|
| `Directory.Packages.Camelot.props` | Manages NuGet package versions for Camelot framework projects |
| `Directory.Packages.Evolution.props` | Manages NuGet package versions for Evolution framework projects |
| `/Copilot` | Provides consistent Copilot instructions and prompts for AI-assisted development in GitHub Copilot chats. |
| `/Claude` | Provides consistent Claude instructions and prompts for AI-assisted development in Claude Code chats. |
| `/Terminal` | Provides consistent Terminal settings for Windows Terminal. |

## Copilot Notes

Ultralight Orchestration (Orchestrator) - Started from [Holland Gist](https://gist.github.com/burkeholland/0e68481f96e94bbb98134fa6efd00436)
	- Updated Coder from Claude Opus 4.6 (copilot) to GPT-5.3-Codex (copilot) from [Montemagno](https://x.com/jamesmontemagno/status/2023941950815302139?s=52) - want to see his agent files still.  Also one comment was 'single-pass full implementation', should I try to put that in planner/orchestrator?
	- Updated Orchestrator from Claude Sonnet 4.5 (copilot) to Claude Sonnet 4.6 (copilot) after release of 4.6 and all the hype.
	- Updated Planner from GPT-5.2 (copilot) to Claude Sonnet 4.6 (copilot) after release of 4.6 and all the hype.

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
  <Import Project="C:\BTR\Policies\Directory.Packages.Camelot.props" />
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