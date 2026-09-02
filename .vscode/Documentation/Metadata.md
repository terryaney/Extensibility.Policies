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
| `enabled.codex` | bool | instructions, skills | Publishes Codex CLI outputs. **Defaults to `false`** — Codex is opt-in, unlike every other client. Setting it on an agent, or on an MCP server in the shared `mcp` block, reports `unsupported` in the matrix rather than publishing. See [Codex Notes](#codex-notes). |
| `enabled.repositories` | string[] | agents, instructions, skills | Optional repo-local publish roots. When omitted, publishing is user-level only. |
| `agents.model` | string | agents | Canonical VS Code Copilot model display name. Copilot CLI and Claude map from this value through shared mappings in `AI/skills/kat-policies/meta.jsonc`. |
| `agents.tools` | string[] | agents | Canonical tool array. Shared client translations belong in the [shared mappings](#shared-mappings). |
| `agents.userInvocable` | bool | agents | Canonical user-invocable flag for Copilot agent rendering. Claude has no direct equivalent. |
| `agents.subAgents` | array | agents | Canonical subagent/orchestration list for Copilot-aware agent composition. Unsupported clients omit it. |
| `agents.handoffs` | object[] | agents | Canonical handoff metadata for orchestrator-style agents. Unsupported clients omit it. |
| `instructions.scope` | string[] | instructions | Optional. Omitted or `[]` means global instruction output. Non-empty array means path-scoped output. Copilot `applyTo` is derived from this field. Codex has no glob-scoping mechanism, so the same value is rendered as a prose preamble instead — see [Codex Notes](#codex-notes). |
| `license` | string | skills | Optional. Preserve it when present. |
| `compatibility` | string | skills | Optional compatibility note rendered with the skill. |
| `context` | string | skills | Optional Claude Code extension. `fork` runs the skill in a forked subagent context instead of the main thread. Emitted into the shared skill frontmatter; Codex drops it, so setting it on a Codex-enabled skill warns — see [Codex Skill Warnings](#codex-skill-warnings). |
| `metadata` | object | skills | Optional nested metadata. Preserve it when present. |
| `skills.excludeCommands.copilot` | string[] | skills | Optional list of canonical command basenames to skip when generating Copilot child skills. |
| `skills.excludeItems.<client>` | string[] | skills | Optional list of top-level bundled files or folders to exclude from rendered output for a specific client. Keys: `copilot`, `claude`, `codex`. |
| `skills.modelInvocable` | bool | skills | Canonical model-invocation flag, mirroring `agents.userInvocable`. Defaults to `true`. `false` emits `disable-model-invocation: true` into the shared skill frontmatter **and** writes a Codex `agents/openai.yaml` beside `SKILL.md` carrying `policy.allow_implicit_invocation: false`. See [Invocation Flags](#invocation-flags). |
| `skills.userInvocable` | bool | skills | Canonical user-invocation flag. Defaults to `true`. `false` emits `user-invocable: false` into the shared skill frontmatter. Codex has no equivalent and drops it silently, so `false` on a Codex-enabled skill warns — see [Codex Skill Warnings](#codex-skill-warnings). |
| `bodyReplacements` | object | agents, instructions, skills | Optional per-client string substitutions applied after client markers are resolved. **Not permitted under the `codex` key for skills and instructions.** See [Body Replacements](#body-replacements). |

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

**Top-level client markers** — apply across the entire Copilot family, Claude, or Codex:

```md
<!-- copilot:start -->
Copilot-only text (VS Code and CLI).
<!-- copilot:end -->

<!-- claude:start -->
Claude-only text.
<!-- claude:end -->

<!-- codex:start -->
Codex-only text.
<!-- codex:end -->
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

| Marker tag | VS Code | Copilot CLI | Claude | Codex |
|---|---|---|---|---|
| `copilot` | kept | kept | removed | removed |
| `copilot-vscode` | kept | removed | removed | removed |
| `copilot-cli` | removed | kept | removed | removed |
| `claude` | removed | removed | kept | removed |
| `codex` | removed | removed | removed | kept |

`copilot` and `copilot-vscode`/`copilot-cli` may coexist freely. Content inside a plain `<!-- copilot:start -->` block appears in both VS Code and CLI output, while sub-client blocks vary wording further.

Skills deploy a single shared file read by both VS Code and Copilot CLI. Sub-client markers in skill bodies are still resolved, but only plain `<!-- copilot:start -->` markers are meaningful in practice.

Unmarked content goes to every client, and everything wrapped in `copilot`, `copilot-vscode`, `copilot-cli`, or `claude` markers is absent from Codex output — worth checking when enabling Codex on a body that leans heavily on markers.

### Markers Are Not Client-Exclusive

The matrix above describes which block survives into which *rendered file*, not which client ends up reading it. Copilot reads `AGENTS.md`, `.agents/skills`, and `.claude/skills`, so in a co-scanned artifact a `codex` block effectively means **"Codex and Copilot"** and a `claude` block in a repo-scoped skill means **"Claude and Copilot"**. Copilot de-duplicates same-id skills and the winner varies by surface, so a marker-driven difference in a co-scanned tree is served non-deterministically. See [Primitives.md](Primitives.md#cross-harness-reads) for the read matrix.

Markers remain exclusive, and safe, where the trees are disjoint:

| Artifact | Marker safety |
|---|---|
| Agents, any scope | Safe. No client reads another client's agent tree. |
| Global skill, `enabled.codex` off | Safe. `~/.claude/skills` is never read by Copilot. |
| Global skill, `enabled.codex` on | **Unsafe.** Adds Copilot-readable `~/.agents/skills`. |
| Repo-scoped skill or instruction | **Unsafe.** All three repo trees are Copilot-readable. |

Where markers are unsafe, bodies must be written so that all clients can read the same text — name primitives without a sigil (the `tally-categorize` skill, not `/tally-categorize` or `$tally-categorize`) and leave per-harness keystroke syntax to user documentation. The renderer warns when it finds a sigil in an unsafe body; see [Sigil Warning](#sigil-warning).

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

Valid client keys are `copilot.vscode`, `copilot.cli`, `copilot` (shared skills), `claude`, and `codex`. Each key's value is a flat object mapping old strings to new strings. Replacements are applied as plain string substitutions in declared order.

### `codex` Replacements Are an Error for Skills and Instructions

A `bodyReplacements.codex` block on a skill or instruction meta is a renderer **error**, not a warning. Codex skill and instruction output is co-read by Copilot at those paths — `.agents/skills`, `~/.agents/skills`, and `<repo>/AGENTS.md` — so a substitution intended for Codex alone lands in Copilot's context too, and where Copilot also resolves a non-Codex copy of the same id, which text wins varies by surface. The ban is unconditional rather than scoped to co-read paths, so that adding `enabled.repositories` to an artifact cannot quietly turn a working substitution into a leak.

`bodyReplacements.codex` remains legal for **agents**, whose trees are disjoint at both scopes.

The error text states the reason ("codex output is co-read by Copilot at this path") so the rule can be re-evaluated if the vendor ever makes Copilot's scan configurable ([copilot-cli#2689](https://github.com/github/copilot-cli/issues/2689)).

### Sidecar Overrides

Copied support files support sidecar overrides when markers are not practical. A file like `run_eval.copilot.py` publishes as `run_eval.py` only for Copilot, and `run_eval.claude.py` publishes as `run_eval.py` only for Claude. When both a shared base file and a client sidecar exist, the sidecar wins for that client and the sidecar filename itself is not published.

## Codex Notes

Codex is the one client that behaves differently at the metadata level, so its rules are collected here. For destinations and the ownership model, see [KatPolicies.md](KatPolicies.md#codex-cli).

- **Opt-in.** `enabled.codex` defaults to `false`. Omitting it means "do not publish to Codex", which is the opposite of what omitting `enabled.copilot` or `enabled.claude` means. Do not "fix" the asymmetry — it exists because Codex writes into `AGENTS.md` and `~/.agents/skills`, both of which are shared with humans or other tools.
- **Instructions and skills only.** `enabled.codex` on an agent, or `codex: true` on an MCP server in the shared `mcp` block, is accepted by the parser but reports `unsupported` in the deployment matrix with a footnote explaining why. Nothing is written.
- **No instruction frontmatter.** Codex instruction output carries no YAML header; there is no `applyTo` equivalent.
- **`instructions.scope` degrades to prose.** A scope of `["**/*.cs", "**/*.ts"]` renders as a generated sentence above the body and raises a compatibility warning that it is a soft gate. `["**"]` or an absent scope renders nothing extra.
- **Skill frontmatter is `name` + `description` only.** `license`, `compatibility`, and `context` are dropped, per Codex's documented frontmatter contract. (`allowed-tools` is never emitted for any client — see [KatPolicies.md](KatPolicies.md#tool-mapping).)
- **Bundled `commands/` and `agents/` folders are not copied.** Codex has no analogue for either. Every other support file — `references/`, `templates/`, `scripts/`, loose files — travels to Codex like any other client.
- **Global skill ids can collide.** A vendored skill id that also appears in `AI/external.primitives.jsonc` is a hard error, not a warning: both writers would own the same global skill directory, and disabling the external entry recursive-deletes it. Migrate, don't duplicate.
- **Codex output is mostly not Codex-only.** `.agents/skills`, `~/.agents/skills`, and `<repo>/AGENTS.md` are all read by Copilot; only `~/.codex/AGENTS.md` is Codex's alone. Enabling Codex on an artifact widens its audience, so treat `codex` markers as "Codex and Copilot" — see [Markers Are Not Client-Exclusive](#markers-are-not-client-exclusive).

### Invocation Flags

`disable-model-invocation` and `user-invocable` are Claude Code frontmatter extensions, but the renderer emits them into the **shared** skill document — the same bytes go to the Claude and Copilot copies — so that co-scanned trees stay byte-identical and the de-duplication winner stops mattering. Copilot ignores the keys.

Codex takes neither. It gets `agents/openai.yaml` beside its `SKILL.md` instead, written only when `skills.modelInvocable` is `false`:

```yaml
policy:
  allow_implicit_invocation: false
```

There is no Codex expression of `userInvocable`, which is why setting it to `false` on a Codex-enabled skill warns.

### Sigil Warning

The renderer warns when a **skill or instruction** body contains an invocation sigil — `/id`, `$id`, `/id:sub`, or `/id.sub` — matching a known primitive id, and the artifact is **repo-scoped** or **Codex-enabled at any scope**. Those are exactly the artifacts whose trees are co-scanned, where a client-specific sigil is served to the wrong client. Agents are not audited; their trees are disjoint at both scopes.

It is a warning rather than an error because sigils appear legitimately in prose often enough that a hard stop would eventually block something valid. The warning is what makes the scope rule self-policing: a global skill that later gains `enabled.repositories` or `enabled.codex: true` trips it the moment its trees become co-scanned.

### Codex Skill Warnings

These fire only when `enabled.codex` is `true` on a skill.

| Condition | Reason |
|---|---|
| `context` declared | Codex drops it, so the Codex/Copilot copy loses the context mode. |
| `skills.userInvocable: false` | No Codex equivalent; the restriction silently does not apply there. |
| `allowed-tools` declared | Dormant — never emitted for any client today (see [KatPolicies.md](KatPolicies.md#tool-mapping)). Retained so whoever wires it up does not have to rediscover the drop. |
| `commands/` or `agents/` subfolder present | Both are excluded from Codex output, and because VS Code Copilot resolves `.agents/skills`, Copilot loses them too. |

Each is a behavioral capability that goes missing from the copy Copilot resolves. `license` and `compatibility` are also dropped by Codex and deliberately do **not** warn — the loss is informational only.

### `@`-Imports Are Rejected in `AGENTS.md` Bodies

An `@relative/path` import in a **Codex-enabled instruction** body is a renderer **error**. That body is spliced into `AGENTS.md`, where Copilot expands the import and Codex — which has no import mechanism — ingests the line as literal text, so the one file means two different things to its two readers. Inline the content instead.

`CLAUDE.md`-bound bodies are unaffected; both of their readers expand imports.

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
