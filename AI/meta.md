# AI Meta Support

This file documents the canonical metadata supported by the KAT policies renderer.

## General Notes

- `body.md` or `SKILL.md` body content is the shared text rendered into target-specific files.
- Any field not listed here is currently ignored by the renderer.
- Empty agent `body.md` files are valid. The non-orchestrator `Code.Review.*` reviewer agents are metadata-only today, so their `body.md` files are intentionally empty.

## Agent Meta

Path: `/AI/agents/<id>/meta.jsonc`

Canonical format: `meta.jsonc`. The renderer still accepts legacy `meta.json` for compatibility, but new or edited metadata should use `meta.jsonc`.

Supported top-level fields:

| Field | Type | Required | Notes |
|------|------|----------|------|
| `id` | string | yes | Base filename and canonical id. |
| `name` | string | yes | Rendered into Copilot and Claude frontmatter. |
| `description` | string | yes | Rendered into Copilot and Claude frontmatter. |
| `enabled.vscode` | bool | no | Defaults to `true`. Publishes to VS Code Copilot prompts. |
| `enabled.copilotCli` | bool | no | Defaults to `true`. Publishes to Copilot CLI agents. |
| `enabled.claude` | bool | no | Defaults to `true`. Publishes to Claude agents or commands. |
| `models.vscode` | string | no | Copilot VS Code model name. |
| `models.copilotCli` | string | no | Copilot CLI model name. |
| `models.claude` | string | no | Claude model name. |
| `tools.copilot` | string[] | no | Legacy format. Rendered as Copilot `tools`. |
| `tools.claude` | string[] or `"auto"` | no | Legacy format. `"auto"` maps known Copilot tools to closest Claude tools and emits warnings for gaps. |
| `tools.<toolId>.vscode` | string or string[] | no | Explicit format. Overrides the VS Code tool id(s) emitted for one canonical tool entry. Defaults to `<toolId>` when omitted. |
| `tools.<toolId>.copilotCli` | string or string[] | no | Explicit format. Overrides the Copilot CLI tool id(s) emitted for one canonical tool entry. Defaults to `<toolId>` when omitted. |
| `tools.<toolId>.claude` | string or string[] | no | Explicit format. Claude tool id(s) emitted for one canonical tool entry. Omitted means no Claude mapping. |
| `copilot.userInvocable` | bool | no | Rendered as `user-invocable` for Copilot agent files. |
| `copilot.agents` | string[] | no | VS Code Copilot only. Omitted from CLI and Claude rendering. |
| `copilot.handoffs` | object[] | no | VS Code Copilot only. Omitted from CLI and Claude rendering. |
| `claude.target` | string | no | `agent` or `command`. Defaults to `agent`. |
| `claude.memory` | string | no | Claude memory scope for rendered agents. Current supported values are `user`, `project`, or `local`. |

When using `meta.jsonc`, line comments are allowed and are stripped before parsing.

Supported `copilot.handoffs[]` fields:

| Field | Type | Required | Notes |
|------|------|----------|------|
| `label` | string | yes | Handoff label shown in Copilot. |
| `agent` | string | yes | Target agent name. |
| `prompt` | string | yes | Prompt text to send. |
| `send` | bool | no | Defaults to `false`. |

## Instruction Meta

Path: `/AI/instructions/<id>/meta.jsonc`

Canonical format: `meta.jsonc`. The renderer still accepts legacy `meta.json` for compatibility, but new or edited metadata should use `meta.jsonc`.

Supported fields:

| Field | Type | Required | Notes |
|------|------|----------|------|
| `id` | string | yes | Base filename and canonical id. |
| `name` | string | no | Currently informational only. |
| `description` | string | no | Used for Claude rule frontmatter. |
| `enabled.vscode` | bool | no | Defaults to `true`. Publishes a VS Code Copilot `.instructions.md`. |
| `enabled.copilotCli` | bool | no | Defaults to `true`. Publishes a Copilot CLI `.instructions.md`. |
| `enabled.claudeInstruction` | bool | no | Defaults to `false`. Publishes `~/.claude/instructions/<id>.md`. |
| `enabled.claudeRule` | bool | no | Defaults to `false`. Publishes `~/.claude/rules/<id>.md`. |
| `enabled.claudeImport` | bool | no | Defaults to `false`. Adds `@instructions/<id>.md` to generated `CLAUDE.md`. |
| `scope.copilot` | string | no | Rendered as Copilot `applyTo`. Defaults to `**`. |
| `scope.claude` | string[] | no | Rendered as Claude rule `paths`. |

## Skill Meta

Path: `/AI/skills/<id>/meta.jsonc`

Canonical format: `meta.jsonc`. The renderer still accepts legacy `meta.json` for compatibility, but new or edited metadata should use `meta.jsonc`.

Canonical skill bodies live in `/AI/skills/<id>/SKILL.md` without frontmatter. The renderer emits target-facing `SKILL.md` files using the fields below.

Supported fields:

| Field | Type | Required | Notes |
|------|------|----------|------|
| `id` | string | yes | Target folder name under `~/.copilot/skills` and `~/.claude/skills`. |
| `name` | string | yes | Rendered into skill frontmatter. |
| `description` | string | yes | Rendered into skill frontmatter. |
| `license` | string | no | Rendered into skill frontmatter when present. |
| `compatibility` | string | no | Rendered into skill frontmatter when present. |
| `metadata` | object | no | Rendered as nested frontmatter. Current renderer supports a flat object of scalar values. |
| `enabled.copilot` | bool | no | Defaults to `true`. Publishes the rendered skill into Copilot CLI. |
| `enabled.claude` | bool | no | Defaults to `true`. Publishes the rendered skill into Claude. |
| `claude.exposeCommands` | bool | no | If `true`, any `commands/*.md` files are also linked into `~/.claude/commands`. Defaults to whether the canonical skill has a `commands/` directory. |

The renderer excludes canonical `meta.json` and `meta.jsonc` from published skill directories. Everything else in the skill directory is linked beside the rendered `SKILL.md`.