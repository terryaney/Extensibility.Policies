# RestoreUseStaticGraphEvaluation — Notes & Known Issues

`Directory.Build.props` in this folder sets:

```xml
<RestoreUseStaticGraphEvaluation>true</RestoreUseStaticGraphEvaluation>
```

## Why it's set

`dotnet restore` / `dotnet build` were spending ~12–30s "restoring" on **every** build,
even though the actual restore was a no-op (`All projects are up-to-date for restore`,
77 ms of real work).

Root cause: the legacy restore path evaluates **each project in the reference closure**
(~19 projects here) as separate MSBuild work and **distributes it across worker-node
processes**. The per-node spawn/coordination overhead dominates because the work per
project is trivial. It scales with node count:

| Restore variant            | Time   |
| -------------------------- | ------ |
| default (`-m:16`)          | 12.6s  |
| `-m:4`                     | 5.4s   |
| `-m:2`                     | 5.6s   |
| `-m:1`                     | 1.8s   |
| **static-graph (`-m:16`)** | **1.8s** |

`RestoreUseStaticGraphEvaluation=true` builds the whole dependency graph in a single
in-process pass (no cross-node fan-out) → **~1.8s while keeping full build parallelism**.

It was **not** Windows Defender. AV exclusions were tested and made no difference; the
fix is purely an MSBuild evaluation-path change.

## What it does (and doesn't) change

- **Restore only.** It changes how the restore dependency graph is computed. It does
  **not** change the compile phase or the build-phase worker-node spin-up.
- For a clean SDK-style graph it produces the **same** `project.assets.json` as the
  legacy path.
- It is **stricter**: the graph is built up front, so a *latent* graph defect (a
  dangling `ProjectReference`, a dynamically-injected reference) can surface as an
  **error** where the legacy walk silently tolerated it. That's the main behavioral
  risk to be aware of — it surfaces pre-existing defects rather than producing wrong
  output.

## Known issues (and whether they affect this repo)

None of these currently apply to this codebase, but they are the things to re-check if
the setup changes.

| Known issue                                                                                       | Applies here? | Re-check if…                                              |
| ------------------------------------------------------------------------------------------------- | ------------- | -------------------------------------------------------- |
| Custom / non-MSBuild project types → can be *slower* by an order of magnitude                     | No            | A non-SDK / custom project type is added.                |
| `-mt` (multithreaded MSBuild) drops conditional `ProjectReference`s keyed on `MSBuildRestoreSessionId` | No        | You adopt the experimental `-mt` build mode.             |
| Explicit `TargetFramework` restore parameter → `NullReferenceException`                           | No            | You pass `/p:TargetFramework=...` to restore directly.   |
| Long global-packages path (~200 chars) with long-paths enabled → restore fails                   | No            | The NuGet global packages folder moves to a deep path.   |
| UNC paths + wildcards → `NuGet.Build.Tasks.Console.exe` crash                                      | No            | Projects/packages move onto UNC / network paths.         |
| Central Package Management + globally-referenced packages in `Directory.Build.props` → NU1100     | No            | You adopt CPM (`Directory.Packages.props`).              |
| Projects with **no** `PackageReference`s → edge-case fault                                         | No (verified) | New project-ref-only projects misbehave on restore.      |

## Day-to-day actions that *could* trigger problems

The good news: static graph changes only how project files are **read and evaluated**, not
the restore algorithm itself. It re-reads every project on each restore, and the no-op
("up-to-date") hash includes package and project references — so the **vast majority of
routine edits are safe** and need nothing special.

Ranked by how much attention they deserve:

### ✅ Safe — no special handling needed

| Action                                                                  | Why it's fine                                                              |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------- |
| Bumping a **pinned** `PackageReference` version                         | Project file changes → restore re-evaluates and re-resolves.               |
| Adding a `PackageReference` to a project **or a referenced project**    | Static `<PackageReference>` items are read every restore.                  |
| Adding/removing a **static** `<ProjectReference Include="...">`         | Graph topology change is picked up on the next restore.                    |
| Adding a new normal SDK-style project to the closure                    | Standard `Microsoft.NET.Sdk` projects evaluate the same way.               |
| New versions of your packages becoming available **upstream**           | With pinned versions, restore is deterministic — nothing re-resolves.      |

### ⚠️ Watch — usually fine, but re-test and keep the recovery step handy

| Action                                                                  | Concern                                                                                                   |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Referencing a project that is **not NuGet-aware** (doesn't import NuGet.targets) | Static graph can **fail to restore** an "unrestorable" project where the legacy path succeeded. This means a **non-SDK** project: a legacy (non-`Microsoft.NET.Sdk`) `.csproj`, a native `.vcxproj`, or a custom MSBuild project. **It does *not* mean a project with zero packages** — see the note below. (NuGet/Home #12322, #10019) |
| Editing `Directory.Build.props` / `.targets` or other **imported** files | Imported-file edits are the classic source of a **stale restore** — the change may not be picked up until a forced/clean restore. |
| Switching a `PackageReference` to a **floating** version (`*`, ranges)   | Restore re-resolves every time regardless (and defeats the no-op). Static graph doesn't break it, but you lose the fast no-op. |
| Adding multi-targeting (`<TargetFrameworks>`) to a project              | Generally fine; only the *explicit `/p:TargetFramework=` on the restore command line* is a known NRE trigger — don't do that. |

### ⛔ Avoid / treat as a real interaction

| Action                                                                  | Why                                                                                                      |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| Adding `<ProjectReference>` items **dynamically inside a Target**, or conditioned on restore-time state | Static graph builds the graph **up front**, so references that only materialize at build time can be **missed**, and those projects get excluded from restore. Declare references statically. |
| Adopting **Central Package Management** (`Directory.Packages.props`)     | Known NU1100 with globally-referenced packages. Re-test the whole restore when you turn it on.            |
| Moving projects/packages onto **UNC / network paths** or a very long global-packages path | Documented crashes / long-path failures with static graph.                                               |

> **"No NuGet packages" is safe.** A normal SDK-style project
> (`Microsoft.NET.Sdk`) with **zero `<PackageReference>` items** — only project
> references, or none at all — is still fully restorable, because the SDK always imports
> NuGet.targets. This repo already contains such projects and they restore/build cleanly
> (verified). The old "no PackageReferences → *Value Cannot Be Null*" bug (NuGet/Home
> #9280) was an early-NuGet issue fixed years ago and is not present on SDK 10.x. The row
> above is specifically about **non-SDK / non-NuGet-aware** project *types*, not empty
> package lists.

### How to recognize and recover

A static-graph problem shows up as a **restore/build error that appears only after a
change that "should" have worked** — typically `NU1100` ("unable to resolve"), an NRE/ANE
("object reference…", "value cannot be null"), or a project unexpectedly missing from
restore.

First recovery step (fixes stale-graph artifacts):

```powershell
dotnet restore --force      # or delete the obj\ folders and restore again
```

To confirm whether static graph is actually the culprit, restore once with it off:

```powershell
dotnet restore /p:RestoreUseStaticGraphEvaluation=false
```

If that succeeds and the static-graph run didn't, you've isolated it — work around the
specific case (usually: make a dynamic reference static, or exclude the offending
non-SDK project) rather than disabling the property globally.

## Validation performed

- Restore via the props file: **1.9s**, exit 0.
- Full clean build: **succeeds, 0 warnings / 0 errors**.

If you change any of the "re-check if…" conditions above, re-run a clean
`dotnet build` + the test suite to confirm behavior is unchanged.

## How to disable / revert

Delete the property from `Directory.Build.props`, or override per-invocation:

```powershell
dotnet restore /p:RestoreUseStaticGraphEvaluation=false
```

## Alternatives — same speed without this property

If you ever need to turn the property off (e.g. one of the edge cases above bites), you
can recover the fast restore a different way: stop MSBuild from fanning the per-project
graph evaluation across worker nodes.

| Approach                                          | How                                                                 | Trade-off                                                                 |
| ------------------------------------------------- | ------------------------------------------------------------------- | ------------------------------------------------------------------------- |
| **Single-process build** (per command)           | `dotnet restore -m:1` / `dotnet build -m:1`                         | ~1.8s restore, but you also lose **parallel compilation** of the build.   |
| **Disable node reuse** (per command or env-wide)  | `dotnet build -nodeReuse:false`, or set env `MSBUILDDISABLENODEREUSE=1` | ~3s restore; keeps within-build parallelism, just doesn't persist nodes.  |

`-m:1` is the simplest one-off; the `MSBUILDDISABLENODEREUSE=1` environment variable is
the broadest (honored by every MSBuild invocation regardless of how it's launched —
restart the terminal / editor after setting it).

These were measured equivalent to static-graph for *restore* speed, but they are
**inferior overall**: `-m:1` serializes the actual compile, and the env var is machine-
wide rather than scoped to this repo. Prefer `RestoreUseStaticGraphEvaluation` (this
file) as the default; treat these as the fallback.

## Scope

`Directory.Build.props` applies to every project under `c:\BTR\Camelot`
(DataStore, `Core`, `Abstractions`, etc.). Notes:

- `c:\BTR\GlobalConfiguration` is **outside** `Camelot` and does **not** inherit it.
- `Extensibility\Command.Palette` has its own `Directory.Build.props`, so MSBuild stops
  there and it does **not** inherit this one (expected).

## Sources

- [NuGet/Home #10019 — non-MSBuild project types](https://github.com/NuGet/Home/issues/10019)
- [NuGet/Home #12322 — failure referencing an unrestorable project](https://github.com/NuGet/Home/issues/12322)
- [NuGet/Home #9280 — "Value Cannot Be Null" (older, fixed)](https://github.com/NuGet/Home/issues/9280)
- [dotnet/msbuild #13153 — `-mt` with static graph restore](https://github.com/dotnet/msbuild/issues/13153)
- [NuGet/Home #13046 — explicit TargetFramework NRE](https://github.com/NuGet/Home/issues/13046)
- [NuGet/Home #12121 — long-path awareness](https://github.com/NuGet/Home/issues/12121)
- [dotnet/msbuild #9405 — UNC paths + wildcards crash](https://github.com/dotnet/msbuild/issues/9405)
- [NuGet/Home #12895 — CPM NU1100](https://github.com/NuGet/Home/issues/12895)
- [G-Research — Improve NuGet restores with static graph evaluation](https://www.gresearch.com/news/improve-nuget-restores-with-static-graph-evaluation-2/)
