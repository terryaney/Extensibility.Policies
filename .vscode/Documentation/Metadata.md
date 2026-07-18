# Metadata Reference

This document describes the shared `meta.jsonc` schema used across all canonical agents, instructions, and skills.

For how the renderer uses this metadata, see [KatPolicies.md](KatPolicies.md).

## Shared Schema

One shape is used across all `meta.jsonc` files. Common properties come first, then artifact-specific prefixed sections.

| Field | Type | Applies To | Notes |
|-------|------|------------|-------|
| `id` | string | agents, instructions, skills | Canonical id and base filename or folder name. |
| `name` | string | agents, instructions, skills | Rendered display name. |
| `description` | string | agents, instructions, skills | Rendered summary or description. |
| `enabled.copilot` | bool | agents, instructions, skills | Publishes all Copilot outputs (both VS Code and Copilot CLI). If `true`, overrides sub-client properties. Defaults to `true`. |
| `enabled.copilot.vscode` | bool | agents, instructions, skills | Optional. Publishes only VS Code output when `enabled.copilot` is `false` or absent. Ignored when `enabled.copilot` is `true`. Defaults to `false` when `enabled.copilot` is explicitly `false`; otherwise inherits the `enabled.copilot` default. |
| `enabled.copilot.cli` | bool | agents, instructions, skills | Optional. Publishes only Copilot CLI output when `enabled.copilot` is `false` or absent. Same default logic as `.vscode`. |
| `enabled.claude` | bool | agents, instructions, skills | Publishes Claude outputs. Defaults to `true`. |
| `enabled.repositories` | string[] | agents, instructions, skills | Optional repo-local publish roots. When omitted, publishing is user-level only. |
| `agents.model` | string | agents | Canonical VS Code Copilot model display name. Copilot CLI and Claude map from this value through shared mappings in `AI/skills/kat-policies/meta.jsonc`. |
| `agents.tools` | string[] | agents | Canonical tool array. Shared client translations belong in the [shared mappings](#shared-mappings). |
| `agents.userInvocable` | bool | agents | Canonical user-invocable flag for Copilot agent rendering. Claude has no direct equivalent. |
| `agents.subAgents` | array | agents | Canonical subagent/orchestration list for Copilot-aware agent composition. Unsupported clients omit it. |
| `agents.handoffs` | object[] | agents | Canonical handoff metadata for orchestrator-style agents. Unsupported clients omit it. |
| `instructions.scope` | string[] | instructions | Optional. Omitted or `[]` means global instruction output. Non-empty array means path-scoped output. Copilot `applyTo` is derived from this field. |
| `license` | string | skills | Optional. Preserve it when present. |
| `compatibility` | string | skills | Optional compatibility note rendered with the skill. |
| `metadata` | object | skills | Optional nested metadata. Preserve it when present. |
| `skills.excludeCommands.copilot` | string[] | skills | Optional list of canonical command basenames to skip when generating Copilot child skills. |
| `skills.excludeItems.<client>` | string[] | skills | Optional list of top-level bundled files or folders to exclude from rendered output for a specific client. Keys: `copilot`, `claude`. |
| `bodyReplacements` | object | agents, instructions, skills | Optional per-client string substitutions applied after client markers are resolved. See [Body Replacements](#body-replacements). |

### Agent Handoffs

`agents.handoffs[]` supports these nested fields:

| Field | Type | Notes |
|-------|------|-------|
| `label` | string | Handoff label shown in Copilot. |
| `agent` | string | Target agent name. |
| `prompt` | string | Prompt text sent to the target. |
| `send` | bool | Optional, defaults to `false`. |

## Client Markers

Canonical body content supports optional client markers for small wording differences inside shared content. Markers are stripped during publishing so each client receives only its relevant block.

**Top-level client markers** — apply across the entire Copilot family or Claude:

```md
<!-- copilot:start -->
Copilot-only text (VS Code and CLI).
<!-- copilot:end -->

<!-- claude:start -->
Claude-only text.
<!-- claude:end -->
```

**Sub-client markers** — narrow content to a specific Copilot target:

```md
<!-- copilot-vscode:start -->
VS Code Copilot-only text.
<!-- copilot-vscode:end -->

<!-- copilot-cli:start -->
Copilot CLI-only text.
<!-- copilot-cli:end -->
```

### Marker Resolution Matrix

| Marker tag | VS Code | Copilot CLI | Claude |
|---|---|---|---|
| `copilot` | kept | kept | removed |
| `copilot-vscode` | kept | removed | removed |
| `copilot-cli` | removed | kept | removed |
| `claude` | removed | removed | kept |

`copilot` and `copilot-vscode`/`copilot-cli` may coexist freely. Content inside a plain `<!-- copilot:start -->` block appears in both VS Code and CLI output, while sub-client blocks vary wording further.

Skills deploy a single shared file read by both VS Code and Copilot CLI. Sub-client markers in skill bodies are still resolved, but only plain `<!-- copilot:start -->` markers are meaningful in practice.

### Code-Safe Line Markers

Copied support files can use a code-safe line marker form when HTML comments would break the file syntax:

```py
# [kat:copilot:start]
copilot_only = True
# [kat:copilot:end]

# [kat:claude:start]
claude_only = True
# [kat:claude:end]
```

## Body Replacements

`meta.jsonc` supports an optional `bodyReplacements` object for client-specific string substitutions. After client markers are resolved, the renderer applies all replacements for the matching client key top-to-bottom.

```jsonc
"bodyReplacements": {
    "copilot.vscode": {
        "`ask_user`": "`vscode/askQuestions`",
        "`session_store`": "`session_store_sql`"
    },
    "copilot.cli": {
        "`ask_user`": "`some_cli_tool`"
    },
    "claude": {
        "`ask_user`": "`AskUserQuestion`"
    }
}
```

Valid client keys are `copilot.vscode`, `copilot.cli`, `copilot` (shared skills), and `claude`. Each key's value is a flat object mapping old strings to new strings. Replacements are applied as plain string substitutions in declared order.

### Sidecar Overrides

Copied support files support sidecar overrides when markers are not practical. A file like `run_eval.copilot.py` publishes as `run_eval.py` only for Copilot, and `run_eval.claude.py` publishes as `run_eval.py` only for Claude. When both a shared base file and a client sidecar exist, the sidecar wins for that client and the sidecar filename itself is not published.

## Shared Mappings

`AI/skills/kat-policies/meta.jsonc` is the central location for reusable client translations, MCP settings, and mappings:

- **Model mappings** — how canonical `agents.model` values (VS Code display names) are rendered for Copilot CLI and Claude.
- **Tool mappings** — how canonical tool names translate to each client's tool identifiers (e.g., `edit` → Claude `Edit`/`Write`).
- **MCP settings** — which MCP servers are enabled for each client.

Individual artifact metadata should stay focused on canonical intent. Only carry local overrides when the shared mappings are insufficient.

## Target Schema Notes

- `meta.jsonc` is the canonical metadata format across agents, instructions, and skills.
- Canonical metadata is VS Code Copilot-centric. Client-specific differences are derived by the renderer.
- Repo-local publishing is controlled by `enabled.repositories`.
- `claude.target` is legacy-only for agents and should not be used.
- Legacy root-level field shapes may still exist in older artifacts, but this document describes the target schema only.
