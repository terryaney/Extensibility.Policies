# Central Package Management (CPM) for .NET

This document describes the planned design for centralized NuGet package versioning across BTR/KAT .NET projects. It covers the framework-level `Directory.Packages.props` layout, how `.csproj` files change, and override mechanisms.

> **Not implemented yet.** Nothing below is wired up; it describes the intended design only. The `Directory.Packages.props` files described here have never existed in this repo.

## Design

CPM works by NuGet auto-discovering the nearest file named exactly `Directory.Packages.props` while walking **up** the directory tree from each project. To give each KAT framework its own version set, the file lives at the **framework root** rather than being carried per-repo or given a framework-specific name:

- `C:\BTR\Camelot\Directory.Packages.props` — versions for Camelot framework repos.
- `C:\BTR\Evolution\Directory.Packages.props` — versions for Evolution framework repos.

Because every Camelot repo lives under `C:\BTR\Camelot` and every Evolution repo under `C:\BTR\Evolution`, each project auto-discovers the correct framework file with no per-project import, and the two frameworks can pin different versions. These files would be deployed and KAT-owned (stamped with the `CreatedBy=KAT` alternate data stream), so they are managed centrally and should not be hand-edited in place.

### Framework File Shape

```xml
<Project>
  <PropertyGroup>
    <ManagePackageVersionsCentrally>true</ManagePackageVersionsCentrally>
  </PropertyGroup>
  <ItemGroup>
    <PackageVersion Include="Serilog" Version="2.12.0" />
    <PackageVersion Include="Microsoft.Extensions.Logging" Version="7.0.0" />
  </ItemGroup>
</Project>
```

## How `.csproj` Files Change

With CPM on, projects reference packages with **no version** — the version comes from the framework's `Directory.Packages.props`:

```xml
<ItemGroup>
  <PackageReference Include="Serilog" />
  <PackageReference Include="Microsoft.Extensions.Logging" />
</ItemGroup>
```

Specifying `Version` on a `PackageReference` while CPM is on raises **NU1008**; use the override mechanisms below instead.

## Overriding Versions

### Repo-Level Override

Add a `Directory.Packages.props` at the repo root. NuGet uses the **nearest** file and stops walking, so this shadows the framework file. Import the framework file explicitly, then adjust individual versions with `Update`:

```xml
<Project>
  <Import Project="C:\BTR\Camelot\Directory.Packages.props" />
  <ItemGroup>
    <PackageVersion Update="Serilog" Version="2.0.11" />
  </ItemGroup>
</Project>
```

This changes only Serilog for that repo and inherits all other framework versions unchanged.

### Single-Project Override

Use `VersionOverride` on the `PackageReference` (a plain `Version` is NU1008 under CPM):

```xml
<ItemGroup>
  <PackageReference Include="Serilog" VersionOverride="2.0.13" />
</ItemGroup>
```

This is the highest-precedence override and should be used sparingly.
