# 📘 Development Policies

To ensure all developers use the same rules, we maintain a single source of truth under git source control management.  This folder contains shared development policies used across all local .NET and source controlled projects. These policies ensure consistent formatting, coding standards, and dependency management across all repositories.

## Installation

1. Clone repository to your local machine:
	`git clone https://tfs.acsgs.com/tfs/PDSI/HRS2/_git/HRS%20BTR%20-%20extensibility.policies C:\BTR\Policies`
1. Follow [instructions](#creating-the-symbolic-links-symlink-to-policy-configuration-files) below to create symbolic links to configuration files.

To update policy files, simply run `git pull` inside the `C:\BTR\Policies` folder.

## Quick Reference

| File | Description |
|------|-------------|
| `.editorconfig` | Defines consistent coding styles across editors and IDEs (Visual Studio, VS Code, Rider, etc.).|
| `Directory.Packages.Camelot.props` | Manages NuGet package versions for Camelot framework projects |
| `Directory.Packages.Evolution.props` | Manages NuGet package versions for Evolution framework projects |
| `/Copilot` | Provides consistent Copilot instructions and prompts for AI-assisted development in GitHub Copilot chats. |
| `/Claude` | Provides consistent Claude instructions and prompts for AI-assisted development in Claude Code chats. |
| `/Terminal` | Provides consistent Terminal settings for Windows Terminal. |

## Creating the Symbolic Links (Symlink) to Policy Configuration Files

Because these configuration files are either hard coded locations or only discovered by walking upward from the project directory, we expose this file globally by creating a symlink at appropriate locations.  This ensures every BTR/KAT project by default picks up the shared rules.

Copy the following snippet and paste into Terminal/PowerShell running as Administrator:

```powershell
New-Item -ItemType Directory -Path "C:\BTR" -Force | Out-Null
New-Item -ItemType SymbolicLink -Path "C:\BTR\.editorconfig" -Target "C:\BTR\Policies\.editorconfig" -Force

# Create Terminal symlinks for all files
$wtPackage = Get-AppxPackage -Name "Microsoft.WindowsTerminal"
if ($wtPackage) {
    $wtLocalState = Join-Path $env:LOCALAPPDATA "Packages\$($wtPackage.PackageFamilyName)\LocalState"
    # Use $wtLocalState in your symlink path
	Get-ChildItem -Path "C:\BTR\Policies\Terminal" -Recurse -File | ForEach-Object {
		$relativePath = $_.FullName.Substring("C:\BTR\Policies\Terminal".Length).TrimStart("\")
		$symlinkPath = Join-Path $wtLocalState $relativePath
		$symlinkDir = Split-Path $symlinkPath
		New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
		New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force
	}
} else {
    Write-Warning "Windows Terminal not found. Skipping Terminal symlinks."
}

# Create Claude symlinks for all files
Get-ChildItem -Path "C:\BTR\Policies\Claude" -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring("C:\BTR\Policies\Claude".Length).TrimStart("\")
    $symlinkPath = Join-Path "~\.claude" $relativePath
    $symlinkDir = Split-Path $symlinkPath
    New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force
}

# Create Copilot symlinks for all files
Get-ChildItem -Path "C:\BTR\Policies\Copilot" -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring("C:\BTR\Policies\Copilot".Length).TrimStart("\")
    $symlinkPath = Join-Path "~\AppData\Roaming\Code\User\prompts" $relativePath
    $symlinkDir = Split-Path $symlinkPath
    New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force
}
```

Edit only the files in `C:\BTR\Policies\`.  All projects immediately inherit the changes.  No need to update or copy files into individual repos.

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