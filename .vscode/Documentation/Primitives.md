# Installed Primitives

This document lists all AI primitives and tools that `update.ps1` publishes to each supported client. Each item is authored once under `/AI` and rendered into the format each client expects.

For how the renderer works and where files land, see [KatPolicies.md](KatPolicies.md).

## Agents

| Agent | Description | VS Code | CLI | Claude | Codex |
|-------|-------------|:-------:|:---:|:------:|:-----:|
| Anvil | Evidence-first coding agent with adversarial multi-model review and SQL-tracked verification. | ✅ | ✅ | — | n/a |
| KAT .NET Core Code Review | Runs three parallel code reviews (GPT, Gemini, Codex). | — | — | — | n/a |
| KatApp Assistant | Expert assistant for KatApp runtime and KAML view development. | ✅ | ✅ | ✅ | n/a |
| Nexgen Assistant | Expert assistant for Nexgen server-side BRD and CalcEngine integration. | ✅ | ✅ | ✅ | n/a |
| Ultralight Coder | Writes code following mandatory coding principles. | — | — | — | n/a |
| Ultralight Designer | Handles all UI/UX design tasks. | — | — | — | n/a |
| Ultralight Orchestrator | Breaks requests into phases and delegates to specialist subagents. | — | — | — | n/a |
| Ultralight Planner | Creates comprehensive implementation plans by researching the codebase. | — | — | — | n/a |

> "—" means the agent is currently disabled in metadata. Disabled agents are still authored canonically and can be enabled by setting `enabled.copilot` / `enabled.claude` to `true` in their `meta.jsonc`.

> "n/a" means agents are out of scope for that client entirely. Codex uses a different subagent definition format and there is no cheap mapping from canonical `.agent.md` frontmatter to it. Setting `enabled.codex` on an agent reports `unsupported` in the deployment matrix instead of publishing.

> Agents with Copilot orchestration fields (`subAgents`, `handoffs`) have those fields omitted from Claude output because Claude has no equivalent frontmatter. The renderer reports these as compatibility notes.

## Instructions

| Instruction | Description | Scope | Codex |
|-------------|-------------|-------|:-----:|
| KAT Shared Instruction | Shared KAT communication, code, and .NET guidance. | Global | — |
| Nexgen Instructions | Nexgen/LWC instructions. | Global | — |
| Tally Instructions | Spending instructions for Tally and bank exports. | Global | ✅ |

Instructions are published to VS Code, Copilot CLI, and Claude by default. Global instructions render as `CLAUDE.md` imports for Claude and as `.instructions.md` files for Copilot. Path-scoped instructions render as Claude rules and Copilot `applyTo`-scoped instruction files.

Codex is opt-in per instruction — the column above shows which currently set `enabled.codex: true`. Codex output is a single delimited region inside `AGENTS.md` holding every enabled instruction, ordered by id, with no frontmatter. Because Codex has no glob scoping, a non-`**` `instructions.scope` is rendered as a prose preamble and the sync warns that it is a soft gate.

## Skills

| Skill | Description | VS Code | CLI | Claude | Codex |
|-------|-------------|:-------:|:---:|:------:|:-----:|
| frontend-design | Production-grade frontend interfaces with high design quality. | ✅ | ✅ | ✅ | — |
| kat-caveman | Ultra-compressed communication mode (~75% token reduction). | ✅ | ✅ | ✅ | — |
| kat-grill-me | Stress-test a plan or design with relentless questioning. | ✅ | ✅ | ✅ | — |
| kat-handoff | Compact a conversation into a handoff document. | ✅ | ✅ | ✅ | — |
| kat-policies | Sync all AI primitives from the canonical policy repo. | ✅ | ✅ | ✅ | — |
| kat-review | Two-axis code review (Standards + Spec) since a fixed point. | ✅ | ✅ | ✅ | — |
| primitive-evaluator | Evaluate and improve prompt primitives (skills, agents, instructions). | ✅ | ✅ | — | — |
| visual-explainer | Generate self-contained HTML pages that visually explain systems and data. | ✅ | ✅ | ✅ | — |

Skills with a `commands/` folder also generate child skills for Copilot (e.g. `visual-explainer.diff-review`) and nested command files for Claude. Codex receives neither — `commands/` and `agents/` folders are excluded from Codex skill output.

This table lists the unrestricted skills. User-restricted skills (see the `applyForUsers` note in [readme.md](../../readme.md)) are omitted, and the repo-scoped Tally skills are currently the only Codex-enabled ones. Codex skill output carries `name` + `description` frontmatter only; license, compatibility, context, and allowed-tools are dropped.

### External Primitives

External primitives are declared in `AI/external.primitives.jsonc` and installed via provider-native tooling rather than the canonical renderer. Each entry targets a single client and has a root `enabled` boolean.

| Primitive | Client | Notes |
|-----------|--------|-------|
| skill-creator | Claude | Installed via `npx skills add`. User-restricted (`applyForUsers`). |

When `enabled` is `false`, the updater removes the previously installed external primitive from the client's known install path.

> Copilot-client external primitives install to `~/.agents/skills/<id>/`, which is also where Codex global skills go. Removing a disabled primitive is a recursive delete of that whole `<id>` folder, so a Codex skill sharing the id would be destroyed with it. The sync detects the id overlap up front, warns, and skips the Codex publish. There are no Copilot-client external primitives today, so the collision surface is currently zero.

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

| Server | VS Code | CLI | Claude | Codex |
|--------|:-------:|:---:|:------:|:-----:|
| Context7 | ✅ | ✅ | ✅ | n/a |
| GitHub | ✅ | ✅ | ✅ | n/a |
| KatLedger | ✅ | — | — | n/a |

> MCP is out of scope for Codex. Codex configures servers in `config.toml`, while the three `install-*.ps1` helpers write JSON (`mcp.json`, `mcp-config.json`, `.claude.json`). Setting `codex: true` on a server in the shared `mcp` block reports `unsupported` with a footnote rather than attempting a bootstrap.

## VS Code Settings Safeguards

The sync applies a set of managed VS Code user settings from `AI/skills/kat-policies/meta.vscode.settings.jsonc`. These settings reduce duplicate context noise (disabling redundant agent/skill/instruction discovery paths) and enable chat tooling features. The sync does not set `chat.permissions.default` — that is left to per-repo `.vscode/settings.json` if desired.
