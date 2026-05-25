# External installable primitive manifest

## Problem

`AI\skills\skill-creator` has been removed from this repo. The repo currently only manages primitives that physically exist under `AI\agents`, `AI\instructions`, or `AI\skills`. We need a top-level manifest for externally managed primitives so selected external primitives can be installed automatically for eligible users and supported clients without keeping a checked-in local copy.

## Current state

- `scripts\update.ps1` currently discovers local skills only by enumerating subdirectories under `AI\skills` that contain `SKILL.md`.
- There is no top-level external primitive manifest today, and no concept of an external/installable primitive catalog.
- Existing per-primitive metadata already supports:
  - `enabled`
  - `applyForUsers` (existing code spelling)
  - repository scoping via `enabled.repositories`
  - skill-specific options such as `skills.excludeCommands` and `skills.excludeItems`
- `Publish-Skills` renders local skill directories into Copilot and Claude target skill roots. It does not execute external install commands.
- `npx skills add https://github.com/anthropics/skills --skill skill-creator` uses the `skills` npm CLI (`vercel-labs/skills`), not this repo. It installs the selected skill from that GitHub source into one or more detected agent skill directories, defaulting to project scope unless `-g` is used. In interactive mode it can prompt for target agents and install method; with flags it can run non-interactively.

## Proposed approach

1. Add `AI\external.primitives.jsonc` as the top-level manifest for externally managed/installable primitives.
2. Define a container object keyed by logical primitive id, for example `installablePrimitives.skill-creator`.
3. Reuse existing gating fields where possible:
   - `enabled`
   - `applyForUsers`
4. Add a structured install definition instead of a free-form embedded script as the first implementation:
   - source repo/url
   - primitive type (`skill`)
   - selector (`skill-creator`)
   - target agents or client mapping
   - install flags/options needed for non-interactive execution
5. Extend `scripts\update.ps1` to:
   - load `AI\external.primitives.jsonc`
   - evaluate user/client gating with the same conventions already used for local primitives
   - detect whether the client/tooling needed for installation is available
   - install missing eligible external primitives
   - record install status in the existing deployment/reporting flow
6. Keep the first version idempotent and conservative:
   - install when missing
   - do not auto-update already installed external primitives unless explicitly designed later
   - fail visibly in the deployment table when install prerequisites or commands fail

## Suggested schema direction

```jsonc
{
  "installablePrimitives": {
    "skill-creator": {
      "type": "skill",
      "source": "https://github.com/anthropics/skills",
      "selector": {
        "skill": "skill-creator"
      },
      "enabled": {
        "copilot": true,
        "claude": true
      },
      "applyForUsers": [ "terry.aney" ],
      "install": {
        "provider": "skills-cli",
        "project": true,
        "nonInteractive": true
      }
    }
  }
}
```

Why this shape:

- keyed container gives stable ids and simple lookups
- `applyForUsers` matches current code and avoids introducing a second user-filter property
- structured install data is safer than arbitrary embedded PowerShell because it is easier to validate, report, and keep idempotent
- a raw script fallback can be added later only if a real install case cannot fit the structured model

Confirmed decisions:

- the manifest is only for externally installed primitives, not repo-managed local primitives
- keep the existing `applyForUsers` property name
- use a structured install object rather than embedded script text
- only install when missing
- the initial `skill-creator` entry should target both Copilot and Claude when enabled and installed

## Risks / design notes

- `skills add` targets agent names such as `github-copilot` and `claude-code`; the manifest-to-client mapping needs to be explicit so `enabled.copilot` / `enabled.claude` resolve to the correct CLI agent flags.
- installs should be project-scoped unless a later requirement justifies global scope
- external primitives should be install-missing-only in the first version
- If `skill-creator` remains referenced from local content (for example `primitive-evaluator` guidance), that reference may still be fine, but docs may need to clarify that it is externally installed rather than repo-managed.
- use `AI\external.primitives.jsonc` for clarity instead of overloading `AI\meta.jsonc`

## Todos

1. Define the `AI\external.primitives.jsonc` schema for external/installable primitives and settle field names.
2. Add manifest loading plus user/client gating to `scripts\update.ps1`.
3. Implement a structured installer path for `skills-cli` sources with deployment reporting and non-interactive support.
4. Decide whether to update any local docs or references that currently imply `skill-creator` is repo-managed.
