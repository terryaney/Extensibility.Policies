# Installed Primitives

This document lists all AI primitives and tools that `update.ps1` publishes to each supported client. Each item is authored once under `/AI` and rendered into the format each client expects.

For how the renderer works and where files land, see [KatPolicies.md](KatPolicies.md).

## Agents

**No agents are currently defined.** `AI/agents/` is empty, so the sync publishes none and the deployment matrix omits the Agents section entirely rather than printing an empty table.

The renderer still supports them in full. To add one, create `AI/agents/<id>/` with a `meta.jsonc` and `body.md`; nested directories group related agents (`AI/agents/kat/<id>/`). Skills can also carry helper agents in an `agents/` subfolder with its own `meta.jsonc`, which publish as `<skill>-<agent>`.

What still applies whenever agents come back:

> Setting `enabled.copilot` / `enabled.claude` to `true` publishes the agent; either left `false` reports `disabled`.

> **Codex is out of scope for agents entirely.** It uses a different subagent definition format and there is no cheap mapping from canonical `.agent.md` frontmatter to it. Setting `enabled.codex` on an agent reports `unsupported` in the deployment matrix instead of publishing.

> Agents with Copilot orchestration fields (`subAgents`, `handoffs`) have those fields omitted from Claude output because Claude has no equivalent frontmatter. The renderer reports these as compatibility notes.

## Instructions

| Instruction | Description | Scope | Codex |
|-------------|-------------|-------|:-----:|
| KAT Shared Instruction | Shared KAT communication, code, and .NET guidance, plus the generated Skill Amendments section. | Global | ✅ |
| Nexgen Instructions | Nexgen/LWC instructions. | Global | — |
| Tally Instructions | Spending instructions for Tally and bank exports. | Global | ✅ |

The KAT Shared Instruction also carries the generated `## Skill Amendments` section — see [Amendments](#amendments). That is why it is Codex-enabled: amendments are the only safe channel for Codex-only guidance, so the instruction hosting them has to reach Codex.

Instructions are published to VS Code, Copilot CLI, and Claude by default. Global instructions render as `CLAUDE.md` imports for Claude and as `.instructions.md` files for Copilot. Path-scoped instructions render as Claude rules and Copilot `applyTo`-scoped instruction files.

Codex is opt-in per instruction — the column above shows which currently set `enabled.codex: true`. Codex output is a single delimited region inside `AGENTS.md` holding every enabled instruction, ordered by id, with no frontmatter. Because Codex has no glob scoping, a non-`**` `instructions.scope` is rendered as a prose preamble and the sync warns that it is a soft gate.

## Skills

| Skill | Description | VS Code | CLI | Claude | Codex |
|-------|-------------|:-------:|:---:|:------:|:-----:|
| kat-policies | Sync all AI primitives from the canonical policy repo. | ✅ | ✅ | ✅ | — |

Skills with a `commands/` folder also generate child skills for Copilot (e.g. `<skill>.<command>`) and nested command files for Claude. Codex receives neither — see [Command Shapes](#command-shapes).

This table lists the unrestricted **vendored** skills, and it is deliberately short: every skill that has an upstream now installs from it instead — see [External Primitives](#external-primitives). What remains is KAT's own domain work. User-restricted skills (see the `applyForUsers` note in [readme.md](../../readme.md)) are omitted, as are the repo-scoped Tally skills, which are the only Codex-enabled vendored ones. For what Codex skill output actually carries, see [Codex Skill Output](#codex-skill-output).

### External Primitives

External primitives are declared in `AI/external.primitives.jsonc`. Upstream owns the body, `npx skills` fetches it, and KAT owns deployment policy plus small post-install decorations. Each entry names a `source` repository, the upstream `skill` name, and a `clients` array; the sync compiles the `npx skills add` invocation itself rather than storing a hand-written command.

| Primitive | Clients | Notes |
|-----------|---------|-------|
| kat-caveman | — | **Disabled**, kept as documentation. Pocock deleted `caveman` upstream, so the old vendored copy was a fork of a dead skill. `JuliusBrussee/caveman` is a live alternative (plus 13 `caveman-*` siblings), unevaluated. |
| kat-code-review | Claude, Copilot, Codex | Upstream `mattpocock/skills` `code-review`. Upstream's setup-skill dependency is neutralized by [amendments](#amendments) rather than by forking the body. |
| kat-frontend-design | Claude, Copilot, Codex | Upstream `anthropics/skills` `frontend-design`. Body *and* description track upstream; KAT contributes only the prefix and `context: fork`. |
| kat-grill-me | Claude, Copilot, Codex | Upstream `mattpocock/skills` `grilling` — the real skill, not the `grill-me` shim. Decorated with `context: fork`. |
| kat-handoff | Claude, Copilot, Codex | Upstream `mattpocock/skills` `handoff`. Decorated with `context: fork` and `skills.modelInvocable: false`. |
| kat-skill-creator | Claude, Copilot, Codex | Upstream `anthropics/skills` `skill-creator`. Also evaluates *existing* skills — it snapshots the current version as an A/B baseline and grades against it, which is what the retired `primitive-evaluator` forked. |
| kat-visual-explainer | Claude, Copilot, Codex | Upstream `nicobailon/visual-explainer`. Upstream ships no native Copilot or Codex skill, so its own `configs/` guidance is carried as [amendments](#amendments). Claude needs none — it reads `commands/` natively. |

When `enabled` is `false`, the updater removes the primitive from every root the entry's clients resolve to. An entry that is renamed, deleted outright, or whose `applyForUsers` no longer includes the current user is swept separately: `Remove-OrphanedExternalPrimitives` scans each install root for directories carrying a `.kat-external.json` whose `id` is no longer in the manifest and removes them. Without it a rename would strand the previous Copilot mirror, since that copy is KAT's own and the rename step only consumes the directory `npx` wrote.

> **Upstream has to still exist.** A byte-identical body is necessary but not sufficient — `skill` is resolved against upstream HEAD at install time. `kat-caveman` passed every content check and still failed, because Pocock had deleted it. There is no pre-flight check for this yet; verify with `npx skills add <source> --list` before deleting a vendored copy.

### Install Paths and the Universal Root

`npx skills` classifies any agent whose project directory is `.agents/skills` as a **universal** agent and, for those, writes the shared `~/.agents/skills` at global scope — ignoring the per-agent global path in its own agent table. `github-copilot` and `codex` are both universal; `claude-code` is not. So one install command produces at most two directories, and KAT finishes the job:

| Client | Written by | Final path |
|--------|-----------|------------|
| `claude` | `npx` directly | `~/.claude/skills/<id>/` |
| `codex` | `npx` (universal root) | `~/.agents/skills/<id>/` |
| `copilot` | KAT mirrors the universal copy | `~/.copilot/skills/<id>/` |

The Copilot mirror is required because Copilot CLI resolves `~/.copilot/skills` and never reads `~/.agents/skills` — see the [read matrix](#cross-harness-reads). The mirror is a byte copy of the decorated universal tree, satisfying the co-scanning rule that trees Copilot may pick a winner from must be identical. When an entry lists `copilot` but not `codex`, the universal copy is deleted after mirroring so a Copilot-only entry does not silently surface in Codex.

### Amendments

An external skill's body belongs to upstream, so the only way to correct its behaviour is from outside it. Instructions are that lever — they *concatenate* rather than replace, so a rule published alongside a skill overrides what the skill says without KAT ever owning its prose. This is what replaces the body edits that used to force vendoring.

**Vendored skills can amend too**, and the reason is Codex. [`bodyReplacements.codex` is banned](KatPolicies.md#shared-skill-directory) because Codex skill output is co-read by Copilot, so a skill body has no way to address Codex alone. A *global* Codex instruction lands in `~/.codex/AGENTS.md`, which Copilot does not read — making an amendment the only safe channel for Codex-only guidance ("ignore location X, use location Y"). Declare them in the skill's `meta.jsonc` using the same shape.

Amendments are declared on the entry they amend, so the override is findable from the thing it overrides:

```jsonc
"kat-code-review": {
  "source": "https://github.com/mattpocock/skills",
  "skill": "code-review",
  "clients": [ "claude", "copilot", "codex" ],
  "amendments": {
    "all": [ "kat-code-review: never suggest running a setup skill…" ],
    "copilot": [ "…applies only to the Copilot render…" ]
  }
}
```

`all` reaches every client the entry deploys to. A client key (`claude`, `copilot`, `codex`) is emitted wrapped in that client's markers so the existing [client-marker](Metadata.md#client-markers) filter does the per-client work. Naming a client the entry does not deploy to is a warning and the lines are dropped — dead text, not a silent no-op.

Every amendment is appended to the **`kat` instruction** as a `## Skill Amendments` section, rather than published as an artifact of its own. That keeps one shared-rules file per harness and one `@import` in `CLAUDE.md`. It also makes the `kat` instruction's client enablement the delivery gate — which is why `kat` sets `enabled.codex: true`. An amendment targeting a client `kat` does not reach warns rather than failing silently. When nothing declares amendments, no section is added.

Codex safety comes from scope: a *global* Codex instruction lands in `~/.codex/AGENTS.md`, which Copilot does **not** read (unlike a repo-scoped `AGENTS.md`, which it does). So a `codex` amendment cannot leak into Copilot's context the way `bodyReplacements.codex` would. Note the corollary — enabling Codex on `kat` also sends the rest of the KAT shared rules to `~/.codex/AGENTS.md`.

**Amendments do not replace client markers.** Marker text lives in a skill body and loads only when that skill fires; an amendment is a global instruction present in every conversation. Moving per-client skill prose into amendments would put skill-specific guidance into every session's context, and amendments cannot substitute a word mid-sentence the way `bodyReplacements` and `{{KAT_*}}` placeholders do. Markers are the mechanism amendments are *built on*, not something they supersede.

### Post-Install Decoration

`npx` installs upstream's bytes under upstream's own name. KAT then, in place and after *every* install:

1. **Renames** `<root>/<skill>` to `<root>/<id>`, so the `kat-` prefix survives. Skill directories are a flat namespace with no scoping — two upstreams both shipping `handoff` would collide and the last install would silently win — so the prefix is load-bearing, not cosmetic.
2. **Patches frontmatter** with the same vocabulary a vendored skill's `meta.jsonc` uses: `name`, `description`, `argument-hint`, `license`, `compatibility`, `context`, and `skills.modelInvocable` / `skills.userInvocable`. The patch is line-surgical, so upstream's nested blocks (`metadata:`, lists) survive untouched. Codex-only directories get the reduced `name` + `description` form.
3. **Patches `agents/openai.yaml`** for `allow_implicit_invocation` when the entry sets `skills.modelInvocable` and upstream ships that file — Codex has no frontmatter equivalent.
4. **Writes `.kat-external.json`** recording source, upstream name, clients, and install time. `npx` leaves no provenance in the installed tree (`skills list` reads its source labels from the lockfile), so this is how a KAT-deployed install is identifiable. It deliberately is *not* the `CreatedBy=KAT` alternate data stream: that stream marks a file KAT may delete, and `Clear-ManagedRoot` would reap the install before it was ever used.

Decoration is a render step, not stored state — every sync re-runs the install command, which re-pulls upstream HEAD and overwrites `SKILL.md`, so the patch re-applies each time and cannot drift.

`--copy` is mandatory and KAT always passes it. Without it the CLI symlinks each agent directory back to one shared cache: patching a symlinked file would write into every other consumer's copy, and a symlinked directory reads as a reparse point, which `Test-LegacyManagedItem` treats as KAT-managed and reaps.

> External primitives land in roots KAT also publishes to — `~/.claude/skills`, `~/.copilot/skills`, and `~/.agents/skills` (KAT's Codex global root). A shared id would mean two writers own one directory: the vendored publish overwrites the install, and disabling the entry recursive-deletes the whole folder. `Assert-CrossHarnessPolicy` errors on any external id that matches a vendored skill id, so a skill migrating to external must leave `AI/skills` in the same commit.

## Cross-Harness Reads

Copilot is the only client that reads another client's trees. Every cell below is confirmed from vendor documentation, not inferred.

| Location | Copilot | Claude Code | Codex |
|---|:---:|:---:|:---:|
| `<repo>/.github/skills/<id>/` | reads (CLI resolves here) | — | — |
| `<repo>/.claude/skills/<id>/` | **reads** | reads | — |
| `<repo>/.agents/skills/<id>/` | **reads** (VS Code resolves here) | — | reads |
| `~/.copilot/skills/<id>/` | reads | — | — |
| `~/.claude/skills/<id>/` | — | reads | — |
| `~/.agents/skills/<id>/` | **reads** (VS Code) | — | reads |
| `<repo>/AGENTS.md` | **reads** (both surfaces) | — | reads |
| `<repo>/CLAUDE.md` | **reads** | reads | — |
| `<repo>/.github/instructions/*.instructions.md` | reads | — | — |
| `<repo>/.claude/rules/*.md` | — | reads | — |
| `~/.codex/AGENTS.md` | — | — | reads |
| `<repo>/.github/agents/<id>.agent.md` | reads | — | — |
| `<repo>/.claude/agents/<id>.md` | — | reads | — |
| `<repo>/.codex/agents/<id>.toml` | — | — | reads |

Consequences:

- Claude Code is fully isolated — `.claude/skills`, `~/.claude/skills`, and `CLAUDE.md` only. It reads neither `AGENTS.md` nor `.agents/skills`.
- Agent trees are disjoint at both scopes. No client reads another client's agents, so per-client divergence in an agent body is always safe.
- Skills de-duplicate by id; instructions concatenate. A second skill copy costs nothing once the copies match, but a second instruction copy is loaded *in addition*, and Copilot CLI only de-dupes files that are byte-identical.

### Copilot CLI vs VS Code Precedence

The two Copilot surfaces resolve repo skills from different trees: **Copilot CLI resolves `.github/skills`, VS Code Copilot resolves `.agents/skills`.** Both are load-bearing — dropping either removes skills from one surface. Where the same id exists in more than one readable tree, Copilot picks a single winner and the winner varies by surface, so the renders in co-scanned trees must be identical rather than per-client.

### Scope-Dependent Co-Scanning

Whether Copilot sees Claude or Codex skill output depends on the artifact's scope.

| Scope | Published skill trees | Copilot-readable |
|---|---|---|
| Repo, `enabled.codex: false` | `.github/skills`, `.claude/skills` | both |
| Repo, `enabled.codex: true` | `.github/skills`, `.claude/skills`, `.agents/skills` | all three |
| Global, `enabled.codex: false` | `~/.copilot/skills`, `~/.claude/skills` | `~/.copilot/skills` only — **disjoint** |
| Global, `enabled.codex: true` | `~/.copilot/skills`, `~/.claude/skills`, `~/.agents/skills` | `~/.copilot/skills` and `~/.agents/skills` |

Copilot never reads `~/.claude/skills`, so a global non-Codex skill publishes to disjoint trees and client-specific wording there is correct. Enabling Codex on a global skill adds `~/.agents/skills`, which Copilot does read, and the skill becomes co-scanned. This scope boundary is what the sigil-neutrality and marker rules key off — see [Metadata.md](Metadata.md#client-markers).

### Command Shapes

Commands have a different shape in each client. A body that documents its own invocation is therefore client-specific by construction, which is why it is unsafe in a co-scanned tree.

| Client | Shape | Invoked as |
|---|---|---|
| Claude | Nested in the skill's `commands/` folder | `/skill:command` |
| Copilot | Flattened into a sibling skill (`~/.copilot/skills/visual-explainer.diff-review/`) | `visual-explainer.diff-review` |
| Codex | No analogue | — |

### Codex Skill Output

Codex skill frontmatter is `name` + `description` only.

| Dropped field | Consequence | Warned |
|---|---|---|
| `license` | Informational | no |
| `compatibility` | Informational | no |
| `context` | Behavioral — loses the Claude context mode | yes |
| `allowed-tools` | Behavioral in principle; never emitted for any client today | yes |

`license` and `compatibility` are deliberately silent — a warning that fires on harmless metadata is one that gets ignored.

Support files **do** travel to Codex. Only the `commands/` and `agents/` subfolders are excluded; `references/`, `templates/`, `scripts/`, and loose files are copied like any other client.

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
