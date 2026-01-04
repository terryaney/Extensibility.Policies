# 📘 Development Policies

This folder contains shared development policies used across all local .NET and source controlled projects. These policies ensure consistent formatting, coding standards, and dependency management across all repositories.

## 1. Global .editorconfig Setup

**Purpose**

`.editorconfig` defines consistent coding styles across editors and IDEs (Visual Studio, VS Code, Rider, etc.).  To ensure all development uses the same rules, we maintain a single authoritative `.editorconfig` file in `C:\BTR\Policies`.

Because `.editorconfig` files are only discovered by walking upward from the project directory, we expose this file globally by creating a symlink at the root of all development:

> C:\BTR\.editorconfig → C:\BTR\Policies\.editorconfig

This ensures every project under C:\BTR automatically picks up the shared rules.

### Creating the Symlink (One Time Setup per Developer)

Run PowerShell as Administrator:

```
New-Item -ItemType SymbolicLink `
  -Path "C:\BTR\.editorconfig" `
  -Target "C:\BTR\Policies\.editorconfig"
```

**Verification**

After creating the link, `C:\BTR\.editorconfig` should appear as a file.  Opening it should show the contents of `C:\BTR\Policies\.editorconfig`. Any project under `C:\BTR\...` will automatically use these settings.

### Updating the Global `.editorconfig`

Edit only the file in `C:\BTR\Policies\.editorconfig`.  All projects immediately inherit the changes.  No need to update or copy files into individual repos.

## 2. Global Package Management for .NET

**Purpose**

We maintain consistent NuGet package versions across all repositories by using shared `Directory.Packages.props` files stored in `C:\BTR\Policies`.

Each framework's repository imports appropriate file (i.e. `Directory.Packages.Camelot.props`) so that all projects use the same dependency versions by default.

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

## Summary

**Global `.editorconfig`**
- Authoritative file lives in `C:\BTR\Policies`
- Developers create a symlink at `C:\BTR\.editorconfig`
- Automatically applies to all projects under `C:\BTR`

**Global Package Management**
- Shared `Directory.Packages[framework].props` lives in `C:\BTR\Policies`
- Each repository imports it via `<Import/>` statement in .csproj
- Overrides allowed:
	- Repo level `Directory.Packages.props`
	- Project level version in .csproj