# Installed Primitives

This document lists all AI primitives and tools that `update.ps1` publishes to each supported client. Each item is authored once under `/AI` and rendered into the format each client expects.

For how the renderer works and where files land, see [KatPolicies.md](KatPolicies.md).

## Agents

| Agent | Description | VS Code | CLI | Claude |
|-------|-------------|:-------:|:---:|:------:|
| Anvil | Evidence-first coding agent with adversarial multi-model review and SQL-tracked verification. | ✅ | ✅ | — |
| KAT .NET Core Code Review | Runs three parallel code reviews (GPT, Gemini, Codex). | — | — | — |
| KatApp Assistant | Expert assistant for KatApp runtime and KAML view development. | ✅ | ✅ | ✅ |
| Nexgen Assistant | Expert assistant for Nexgen server-side BRD and CalcEngine integration. | ✅ | ✅ | ✅ |
| Ultralight Coder | Writes code following mandatory coding principles. | — | — | — |
| Ultralight Designer | Handles all UI/UX design tasks. | — | — | — |
| Ultralight Orchestrator | Breaks requests into phases and delegates to specialist subagents. | — | — | — |
| Ultralight Planner | Creates comprehensive implementation plans by researching the codebase. | — | — | — |

> "—" means the agent is currently disabled in metadata. Disabled agents are still authored canonically and can be enabled by setting `enabled.copilot` / `enabled.claude` to `true` in their `meta.jsonc`.

> Agents with Copilot orchestration fields (`subAgents`, `handoffs`) have those fields omitted from Claude output because Claude has no equivalent frontmatter. The renderer reports these as compatibility notes.

## Instructions

| Instruction | Description | Scope |
|-------------|-------------|-------|
| KAT Shared Instruction | Shared KAT communication, code, and .NET guidance. | Global |
| Nexgen Instructions | Nexgen/LWC instructions. | Global |
| Tally Instructions | Spending instructions for Tally and bank exports. | Global |

Instructions are published to all three clients. Global instructions render as `CLAUDE.md` imports for Claude and as `.instructions.md` files for Copilot. Path-scoped instructions render as Claude rules and Copilot `applyTo`-scoped instruction files.

## Skills

| Skill | Description | VS Code | CLI | Claude |
|-------|-------------|:-------:|:---:|:------:|
| frontend-design | Production-grade frontend interfaces with high design quality. | ✅ | ✅ | ✅ |
| kat-caveman | Ultra-compressed communication mode (~75% token reduction). | ✅ | ✅ | ✅ |
| kat-grill-me | Stress-test a plan or design with relentless questioning. | ✅ | ✅ | ✅ |
| kat-handoff | Compact a conversation into a handoff document. | ✅ | ✅ | ✅ |
| kat-policies | Sync all AI primitives from the canonical policy repo. | ✅ | ✅ | ✅ |
| kat-review | Two-axis code review (Standards + Spec) since a fixed point. | ✅ | ✅ | ✅ |
| primitive-evaluator | Evaluate and improve prompt primitives (skills, agents, instructions). | ✅ | ✅ | — |
| visual-explainer | Generate self-contained HTML pages that visually explain systems and data. | ✅ | ✅ | ✅ |

Skills with a `commands/` folder also generate child skills for Copilot (e.g. `visual-explainer.diff-review`) and nested command files for Claude.

### External Primitives

External primitives are declared in `AI/external.primitives.jsonc` and installed via provider-native tooling rather than the canonical renderer. Each entry targets a single client and has a root `enabled` boolean.

| Primitive | Client | Notes |
|-----------|--------|-------|
| skill-creator | Claude | Installed via `npx skills add`. User-restricted (`applyForUsers`). |

When `enabled` is `false`, the updater removes the previously installed external primitive from the client's known install path.

## Tools

The sync script also installs supporting developer tools.

| Tool | Install Method | Description |
|------|---------------|-------------|
| ripgrep (`rg`) | winget | Very fast text search CLI. Reduces failed/slow search tool attempts in large repos. Auto-upgraded on each sync unless `-DisableToolAutoUpgrade` is passed. |

## MCP Servers

MCP servers are bootstrapped best-effort. If a prerequisite is missing, the helper reports the gap and skips rather than failing the sync.

| Server | Description |
|--------|-------------|
| **Context7** | Remote HTTP endpoint for library documentation lookups. Gives agents access to current docs for libraries and frameworks. Requires `CONTEXT7_API_KEY` environment variable. |
| **GitHub** | Remote GitHub MCP endpoint for repository operations — issue search, PR management, code search, and file access. Uses host OAuth or `GITHUB_TOKEN` PAT. |
| **KatLedger** | Local MCP server for the KAT session ledger database. Downloads the `KatLedger.exe` binary from GitHub releases and stores the DB at `%USERPROFILE%\.kat\KatLedger\KatLedger.db`. VS Code only. |

Each server is configured only for clients that canonical agent tool metadata actually requests. The current configuration (from `meta.jsonc`) is:

| Server | VS Code | CLI | Claude |
|--------|:-------:|:---:|:------:|
| Context7 | ✅ | ✅ | ✅ |
| GitHub | ✅ | ✅ | ✅ |
| KatLedger | ✅ | — | — |

## VS Code Settings Safeguards

The sync applies a set of managed VS Code user settings from `AI/skills/kat-policies/meta.vscode.settings.jsonc`. These settings reduce duplicate context noise (disabling redundant agent/skill/instruction discovery paths) and enable chat tooling features. The sync does not set `chat.permissions.default` — that is left to per-repo `.vscode/settings.json` if desired.
