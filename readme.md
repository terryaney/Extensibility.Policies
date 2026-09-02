# Development Policies

Shared development policies for all BTR/KAT projects. One repository, one sync command — every developer gets the same coding standards, AI agents, skills, instructions, and tool configurations across VS Code, Copilot CLI, Claude, and Codex CLI.

## Conduent LLM Models

The following models are currently enabled for our organization. Recommendations by priority:

> You can also just ask Copilot Chat "what model should I use for X?" — it sees the available models and knows their strengths from its own training data.

**Planning and Multi-Project Research**
- **GPT-5.5** — Strongest advanced reasoning and broad contextual understanding for mapping architectures across interdependent projects.
- Claude Opus 4.6 — Excellent for highly structural, nuanced planning and documentation-heavy research.

**Frontend Design and Coding**
- **Claude Sonnet 4.6** — Industry gold standard for frontend. Exceptional grasp of visual layout, component architecture, CSS/Tailwind, and modern UX patterns.
- GPT-5.5 — Highly competent, but Sonnet generally outputs cleaner, more modern frontend components.

**Implementation of Complex Plans**
- **GPT-5.3-Codex** — Purpose-built for code generation. Fast, precise output when translating a well-defined plan into code.
- Claude Opus 4.6 — Better when implementation requires ongoing judgment calls or the plan is loosely defined.

**Everyday Coding** (multi-file context, < 60 lines output)
- **GPT-5.3-Codex** — Optimized for code. Fast, precise output for typical tasks where you read 6-7 files to write a short function.
- GPT-5.4 — Strong general-purpose coder. Good balance of reasoning and speed.
- Claude Haiku 4.5 — Fastest response times for simple, well-scoped tasks.

> **Gemini 2.5 Pro** is also available. Its massive context window shines when feeding in genuinely large codebases, but for typical multi-file tasks every pinned model handles the context fine.

## Installation

```powershell
git clone https://tfs.acsgs.com/tfs/PDSI/HRS2/_git/HRS%20BTR%20-%20extensibility.policies C:\BTR\Extensibility\Policies
C:\BTR\Extensibility\Policies\scripts\update.ps1
```

### Refresh Policies

When policy files are updated, re-sync to pick up the changes. Two options:

- **From chat** — ask to "update KAT policies" in Copilot or Claude. The **kat-policies** skill pulls the latest files and re-runs the sync automatically.
- **From terminal** — saves AI tokens. Pull and re-run the script directly:

  ```powershell
  cd C:\BTR\Extensibility\Policies; git pull; .\scripts\update.ps1
  ```

## What Gets Installed

The sync script detects which clients are installed (VS Code, Copilot CLI, Claude, Codex CLI) and publishes only to those targets. Undetected clients are skipped, not failed.

Codex is the one exception to "everything goes everywhere": it is **opt-in per artifact**. VS Code, Copilot CLI, and Claude receive an artifact unless its metadata turns them off; Codex receives nothing unless the metadata explicitly sets `enabled.codex: true`. See [Codex CLI](#codex-cli) for why.

### Agents

None are currently published. The sync still supports agents in full — see [Primitives.md](.vscode/Documentation/Primitives.md#agents) for how to add one.

### Instructions

| Name | Description |
|------|-------------|
| KAT Shared Instruction | Shared KAT communication, code, and .NET guidance, rendered for Copilot, Claude, and Codex. Also carries the generated **Skill Amendments** section — local rules that override an installed skill's own instructions without editing it. |
| Nexgen Instructions | Nexgen/LWC instructions rendered for Copilot and Claude. |
| Tally Instructions | Spending instructions when working with Tally and new bank exports. |

### Skills

| Name | Description |
|------|-------------|
| kat-code-review | Two-axis code review (Standards + Spec) since a fixed point. Runs both reviews in parallel. *External: upstream `mattpocock/skills`.* |
| kat-frontend-design | Create distinctive, production-grade frontend interfaces with high design quality. *External: upstream `anthropics/skills`.* |
| kat-grill-me | Grill the user relentlessly about a plan or design before building. *External: upstream `mattpocock/skills`.* |
| kat-handoff | Compact the current conversation into a handoff document for another agent to pick up. *External: upstream `mattpocock/skills`.* |
| kat-policies | Update all AI features (commands, skills, agents, etc.) for Claude and Copilot. |
| kat-skill-creator | Create new skills, and evaluate or improve existing ones with A/B grading against a baseline. *External: upstream `anthropics/skills`.* |
| kat-visual-explainer | Generate self-contained HTML pages that visually explain systems, code changes, plans, and data. *External: upstream `nicobailon/visual-explainer`.* |

Most third-party skills install straight from upstream rather than being copied into this repo, so their content stays current automatically. Where a skill needs local behaviour changes, those are declared as **amendments** alongside the install rather than by editing upstream's text — see [Primitives.md](.vscode/Documentation/Primitives.md#amendments).

### Tools

| Name | Description |
|------|-------------|
| ripgrep (`rg`) | Very fast text search CLI. Installed and auto-upgraded via winget. AI agents rely on it for codebase navigation. |

### MCP Servers

| Name | Description |
|------|-------------|
| Context7 | Library and framework documentation lookups. Requires `CONTEXT7_API_KEY`. |
| GitHub | Repository operations — issues, PRs, code search. Uses host OAuth or `GITHUB_TOKEN`. |
| KatLedger | Session ledger database for tracking AI usage (VS Code only). |

Note: MCP servers are bootstrapped best-effort — if a prerequisite is missing, the sync reports the gap and continues.

### Configuration

| Name | Description |
|------|-------------|
| .editorconfig | Consistent coding styles across Visual Studio, VS Code, and Rider. Deployed to `C:\BTR\`. |
| Windows Terminal settings | Shared Terminal appearance and profile configuration. |
| VS Code chat settings | Reduces duplicate context noise and enables chat tooling features. Does **not** force `chat.permissions.default`. |

### Codex CLI

Codex support covers **instructions and skills only**. Agents and MCP servers are out of scope for now: Codex uses a different subagent definition format, and it configures MCP through `config.toml` rather than the JSON files the bootstrap helpers write.

| What | Where it lands |
|------|----------------|
| Instructions | `AGENTS.md` — `%USERPROFILE%\.codex\AGENTS.md` for global, `<repo>\AGENTS.md` for repo-scoped |
| Skills | `%USERPROFILE%\.agents\skills\<id>\` for global, `<repo>\.agents\skills\<id>\` for repo-scoped |

Two things make Codex different from the other clients, and both are why it is opt-in:

- **`AGENTS.md` is shared with humans and other tools.** It is a cross-vendor convention file, not a KAT-private tree like `.github/` or `.claude/`. The sync therefore owns only the region between `<!-- kat:start -->` and `<!-- kat:end -->` and leaves everything else in the file alone. Turning Codex off strips that region — including the delimiters — and deletes the file only if the region was all it contained.
- **`%USERPROFILE%\.agents\skills\` is not exclusively ours.** `npx skills` writes every *universal* agent's global install there — both Copilot and Codex — so external primitives share the folder, and uninstalling one deletes the whole `<id>` directory. A vendored skill id that collides with an external primitive id is rejected as an error before anything is published.

> **Codex output does not stay Codex-only.** Copilot reads `AGENTS.md` at both surfaces, and reads `.agents/skills` in VS Code while resolving `.github/skills` in the CLI. Since that cannot be configured away, the rule is to make the renders identical rather than to control who reads them: bodies in co-scanned output must name primitives without an invocation sigil, and `bodyReplacements.codex` is rejected for skills and instructions. The sync enforces both. See [Cross-Harness Reads](.vscode/Documentation/Primitives.md#cross-harness-reads) for the full matrix and [codex-conflicts.md](.vscode/Plans/Implemented/external-primitives-handoff.codex-conflicts.md) for the reasoning.

### Compatibility Notes

The sync finishes with a deployment matrix and compatibility summary. Some Copilot orchestration features (subagents, handoffs) have no Claude equivalent and are intentionally omitted — the summary calls these out so you know what is and isn't portable across clients.

Two matrix statuses are easy to confuse:

- **`excluded`** — nothing was asked for. The artifact's metadata does not enable that client.
- **`unsupported`** — something *was* asked for and could not be delivered. You get this when metadata sets `codex: true` on an agent or an MCP server, both of which are out of scope. The footnote under the table says why.

## User-Restricted Items

Some items are restricted to specific users via `applyForUsers` in their metadata. If an item you need is excluded, ask the policy maintainer to add your username (or machine user ID) to the `applyForUsers` array in the relevant `meta.jsonc` or `external.primitives.jsonc` entry, then re-sync.

## Developer Documentation

Detailed documentation for working on the policies themselves lives in [.vscode/Documentation/](.vscode/Documentation/):

| Document | Contents |
|----------|----------|
| [Primitives.md](.vscode/Documentation/Primitives.md) | Full inventory of installed agents, instructions, skills, tools, and MCP servers. |
| [RepoStructure.md](.vscode/Documentation/RepoStructure.md) | Repository layout, canonical source tree, and quick reference. |
| [KatPolicies.md](.vscode/Documentation/KatPolicies.md) | Renderer workflow, rendered destinations, ownership model, and compatibility notes. |
| [Metadata.md](.vscode/Documentation/Metadata.md) | `meta.jsonc` schema, client markers, body replacements, and shared mappings. |
| [CentralPackageManagement.md](.vscode/Documentation/CentralPackageManagement.md) | Planned .NET CPM design (not yet implemented). |
