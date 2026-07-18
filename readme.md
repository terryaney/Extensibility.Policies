# Development Policies

Shared development policies for all BTR/KAT projects. One repository, one sync command — every developer gets the same coding standards, AI agents, skills, instructions, and tool configurations across VS Code, Copilot CLI, and Claude.

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

The sync script detects which clients are installed (VS Code, Copilot CLI, Claude) and publishes only to those targets. Undetected clients are skipped, not failed.

### Agents

| Name | Description |
|------|-------------|
| Anvil | Evidence-first coding agent. Verifies before presenting. Attacks its own output. Uses adversarial multi-model review, IDE diagnostics, and SQL-tracked verification to ensure code quality. |
| KatApp Assistant | Expert assistant for KatApp runtime and KAML view development. Answers questions about directives, state, KatApp client APIs, RBLe result consumption in views, and petite-vue integration. |
| Nexgen Assistant | Expert assistant for Nexgen server-side BRD and CalcEngine integration: BRD structure, result-tab exports, API DataSource mappings, xDS data model flow, command processing, and cacheRefreshKeys. |

### Instructions

| Name | Description |
|------|-------------|
| KAT Shared Instruction | Shared KAT communication, code, and .NET guidance rendered for Copilot and Claude. |
| Nexgen Instructions | Nexgen/LWC instructions rendered for Copilot and Claude. |
| Tally Instructions | Spending instructions when working with Tally and new bank exports. |

### Skills

| Name | Description |
|------|-------------|
| frontend-design | Create distinctive, production-grade frontend interfaces with high design quality. |
| kat-caveman | Ultra-compressed communication mode. Cuts token usage ~75% by dropping filler, articles, and pleasantries. |
| kat-grill-me | Grill the user relentlessly about a plan or design before building. |
| kat-handoff | Compact the current conversation into a handoff document for another agent to pick up. |
| kat-policies | Update all AI features (commands, skills, agents, etc.) for Claude and Copilot. |
| kat-review | Two-axis code review (Standards + Spec) since a fixed point. Runs both reviews in parallel. |
| primitive-evaluator | Evaluate and improve existing prompt primitives such as skills, agents, and instructions. |
| visual-explainer | Generate self-contained HTML pages that visually explain systems, code changes, plans, and data. *Plus child command skills.* |

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

### Compatibility Notes

The sync finishes with a deployment matrix and compatibility summary. Some Copilot orchestration features (subagents, handoffs) have no Claude equivalent and are intentionally omitted — the summary calls these out so you know what is and isn't portable across clients.

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
