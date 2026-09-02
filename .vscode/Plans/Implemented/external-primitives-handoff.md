# Handoff: Lean Into External Installs

Written 2026-08-07 at the end of a long session. Purpose: carry the argument into a fresh context without re-deriving it. The prompt to start the next session is at the bottom.

## Where the user wants to end up

**"Almost like an IT department managing deployments of tools I want everyone to have installed for 1–3 harnesses."**

Concretely: stop being the maintainer of other people's skill *content*. Let upstream own the body, let `npx skills` fetch and update it, and keep KAT's job as **deployment policy** — who gets it, on which harnesses, at which scope, with which frontmatter decorations applied afterwards.

The pivot: things `meta.jsonc` currently does by *rendering a body* should, where possible, become **post-install decoration of an external install**. `context: fork` is the motivating example — the user wants it, it's a one-line frontmatter edit, and it should not cost a permanent fork of someone else's prose.

## What already shipped this session (done, published, verified)

The cross-harness conflict work is complete and is **not** up for re-litigation. See [codex-conflicts.md](external-primitives-handoff.codex-conflicts.md) for decisions D1–D11 and their rationale. Summary of what changed:

- Tally bodies neutralized; all three published trees byte-identical. `bodyReplacements.codex` removed from four metas.
- `visual-explainer`'s `share` command-table row wrapped in `<!-- claude:start -->`.
- `update.ps1` gained `Assert-CrossHarnessPolicy` (runs before any managed root is cleared): D2 error, D8/D9/D11 warnings, `@`-import rejection, plus D5 (repo-scoped codex instructions skip `.github/instructions`), D6 (`skills.modelInvocable` / `skills.userInvocable`), D7 (`agents/openai.yaml`).
- `kat-handoff` set to `modelInvocable: false`, restoring upstream intent that was lost during its original copy-paste import. `kat-grill-me` deliberately left implicit-invocable, matching Pocock.
- Docs updated: Primitives.md (read matrix, precedence, command shapes), Metadata.md (new flags, marker-safety, warnings), KatPolicies.md (settled overlap section, vendored-vs-external, install path tracking), readme.md (stale "open question" blockquote replaced).

## Established facts, by layer

State which layer a claim belongs to. Conflating them wasted time in the last session.

> **STATUS 2026-09-01: implemented.** Questions 1–6 are answered and shipped; see [Resolution](#resolution-2026-09-01) at the bottom. Question 7 (the import skill) is still open. Several [CLI] facts below were **corrected** during implementation — the corrections are in the Resolution section and win over the text above them.

**[CLI] — `npx skills` (Vercel), verified by running it**

- Does **not** transform content per agent. `-a <agent>` changes the destination directory only. Same bytes everywhere. There is no per-agent variant mechanism in that ecosystem.
- Supports 75+ agents including `copilot`, `claude-code`, `codex`. `--copy` vs symlink; `-g` global vs project.
- `skills list` reports installed skills, their paths, and which agents they serve. It sees KAT-written skills and labels them `Source: local`.
- `skills remove -g -a -s` is a real uninstall across any agent it supports.
- `skills update` exists but is manual; `skills-lock.json` + `experimental_install` provide a lockfile/restore path.
- Global Copilot install path is `%USERPROFILE%\.copilot\skills\<id>`. Project path is documented as `.agents/skills/` (README prose — **not verified by running it**).
- Claude Code: `~/.claude/skills/` global, `.claude/skills/` project.

**[KAT] — `scripts/update.ps1` as it stands**

- External primitives: the manifest's `command` is re-run **every sync, unconditionally** — no "already installed" check. Because the command is an `npx skills add … --yes` re-add, each sync pulls upstream HEAD. That *is* the update mechanism; `skills update` is redundant.
- Uninstall works: `enabled: false` → `Remove-ExternalPrimitiveInstall` recursive-deletes the path.
- The path is **derived, never recorded** — a hardcoded switch on `client`.
- **Latent bug:** that switch maps `copilot` → `~/.agents/skills/<id>`, but [CLI] installs global Copilot skills to `~/.copilot/skills/<id>`. A `client: copilot` entry would install one place and "uninstall" another. Nothing hits it today (only entry is `skill-creator`, `client: claude`).
- `Get-CopilotCommandSkillDefinitions` already generates `<skill>.<command>` sibling skills for vendored skills. Reusing it against an *installed* directory is the plausible path to flattening external installs.
- Codex is not a valid `client` value; the ValidateSet is `copilot|claude`.

**[schema] — `AI/external.primitives.jsonc`, ours to change**

- Today: `{ client, command, enabled, applyForUsers }`, one client per entry, `client` a single string.
- Everything the user wants (multi-target, post-install frontmatter decoration, flattening opt-in) is a schema + renderer change, not a vendor limitation.

**[harness] — settled in [codex-conflicts.md](external-primitives-handoff.codex-conflicts.md)**

- Copilot is the universal reader: it reads `.github/skills`, `.claude/skills`, `.agents/skills`, `AGENTS.md`, and `CLAUDE.md`. Claude Code is fully isolated. Agent trees are disjoint at both scopes.
- Skills de-duplicate by name (Copilot picks one winner, and the winner differs by surface); instructions concatenate.

## Corrections made during the session — do not re-derive

- `WebFetch` runs a summarizing model and **paraphrases raw files**. It produced a rewritten version of Pocock's `SKILL.md` that led to a false claim that the user had modified `kat-grill-me`. Verified with `Invoke-WebRequest`: the body is identical to upstream, and `kat-handoff` differs from upstream by one word. **Use `Invoke-WebRequest` for byte-level comparisons.**
- Upstream `handoff/SKILL.md` carries `disable-model-invocation: true` in its frontmatter *and* `allow_implicit_invocation: false` in `agents/openai.yaml`. The original import dropped both. Upstream `grilling` has neither — only an `interface` block — so Codex may implicitly invoke it by design.
- `agents/openai.yaml` does **not** enable Codex support. Codex reads `SKILL.md` natively from `.agents/skills`. The yaml carries UI metadata and the one setting with no frontmatter equivalent (`allow_implicit_invocation`).
- Third-party skills are not "supporting three harnesses correctly" — they ship one harness-neutral text. That is the same conclusion D1 reached independently.
- An earlier draft rule ("if a skill needs command flattening, vendor it") is **retracted**. Flattening is a post-install file move, not a content change, so it does not force ownership of the body.

## Open questions for the next session

Roughly in dependency order. The first two gate most of the rest.

1. ~~**What is the decoration mechanism?**~~ **DECIDED 2026-08-08: post-install frontmatter patching.** KAT patches the frontmatter of the file `npx` installed, in place, immediately after the install command runs. The rejected alternative was a KAT-owned overlay directory — a shadow copy merged over the untouched install, which is more machinery and two copies to keep straight for the same result.

   Three constraints fall out of that choice and need to be honoured by whatever implements it:

   - **`--copy` is mandatory for any decorated entry.** [CLI] defaults to *symlinking* agent directories back to a single canonical cached copy. Patching a symlinked file edits that shared original, so the change would leak to every other agent and consumer of the cache. The existing `skill-creator` command already passes `--copy`, incidentally rather than by rule — make it a rule, and fail the entry if a decorated install omits it.
   - **The patch is a render step, not persistent state.** [KAT] re-runs the install command every sync, which overwrites the file from upstream HEAD. So the patch must re-apply after *every* install, every time. This is a benefit: there is no stored patch state that can drift from the install.
   - **Frontmatter `name` is not the directory id.** Patching `name` does not rename the installed directory, and the `kat-` prefix lives in the directory name. The prefix question therefore survives the pivot and needs its own answer — see question 5.

   Still open within this decision: which frontmatter keys are patchable (a fixed allowlist such as `context` / the invocation flags, or arbitrary), and where they are declared in [schema].
2. **Does KAT stop deriving install paths and delegate to [CLI] `skills list` / `skills remove`?** That eliminates the latent bug class rather than fixing one path, but adds a runtime dependency on CLI output parsing.
3. **Multi-target schema** — `client` as an array, or explicit per-target entries? Where does `codex` fit, given it isn't in the current ValidateSet?
4. **Flattening for external installs** — opt-in per entry? Which agents? How are stale siblings reaped when upstream renames or drops a command? Ownership is mixed: siblings would be KAT-owned inside an npx-owned root.
5. **Which existing skills migrate to external?** `kat-grill-me` and `kat-handoff` are the strongest candidates (bodies identical to upstream; only `context: fork`, the `kat-` prefix, and handoff's invocation flag are KAT additions). `visual-explainer` becomes a candidate only if #4 lands *and* `excludeCommands` for `share` can be expressed. `frontend-design` and `primitive-evaluator` need assessment. The `kat-` prefix itself is a question: external installs get upstream's id.
6. **Does the drift problem disappear?** For external entries, yes — they track HEAD. But tracking HEAD with no pin is its own risk for a team deployment. Does the user want `skills-lock.json` participation, or is HEAD-always acceptable?
7. **The import skill** (still wanted, see below).

## The import skill — still wanted

Give it a repo URL or skills.sh path; it prepares the skill for this repo. Confirmed **not** overlapping `primitive-evaluator`, which scopes itself to improving primitives that already exist and explicitly defers authoring elsewhere.

It should:

1. Fetch and pin the source (`metadata.author/repository/path/commit` — an existing convention).
2. **Decide vendored vs external** using the rule in KatPolicies.md — and after the pivot, bias toward external.
3. Determine enablement and scope, since repo-scoped or codex-enabled means co-scanned means D1 applies.
4. **Translate upstream invocation intent into the canonical flags.** Upstream may express "don't auto-fire me" as Claude frontmatter, as `agents/openai.yaml`, as both, or as neither while clearly meaning it. All must collapse into `skills.modelInvocable`. This is the step whose absence lost handoff's flag.
5. Triage frontmatter and subfolders against D9/D11.
6. Check for harness-specific tool names needing `bodyReplacements` / `{{KAT_*}}`.
7. Escalate whatever it can't settle to `kat-grill-me`.
8. **Second verb: drift check** — compare the pinned commit against upstream HEAD, show what changed, re-run the triage. Only needed for vendored entries; external ones track HEAD by construction.

---

## Resolution (2026-09-01)

Implemented in `scripts/update.ps1`, `AI/external.primitives.jsonc`, and the three documentation files. Verified by running the sync, including an uninstall/reinstall cycle.

### Corrections to the [CLI] facts above

- **The agent name is `github-copilot`, not `copilot`.** Plain `copilot` is rejected.
- **`-a` cannot take a comma-joined list.** `-a codex,claude-code` errors as "Invalid agents" even when every name is individually valid. Repeated `-a` flags are the only multi-target form.
- **Global install paths do not come from the CLI's agent table.** `getAgentBaseDir()` short-circuits: any agent whose `skillsDir` is `.agents/skills` is *universal*, and universal agents resolve to the shared `~/.agents/skills` globally, ignoring their own `globalSkillsDir` entry. `github-copilot` and `codex` are both universal, so their `globalSkillsDir` values (`~/.copilot/skills`, `~/.codex/skills`) are dead code.
- **Therefore the "latent bug" recorded above was not a bug.** KAT's original `copilot → ~/.agents/skills` mapping was correct. Reading the agent table alone is what produced the wrong claim; the resolution function is the authority.
- **`skills-lock.json` pins a content hash of `SKILL.md` plus the source repo — no commit.** It is written automatically at project root on project-scope installs.
- **`skills list -g` reports one merged row per skill name**, with a combined agent list and a single canonical path. It cannot drive a per-agent uninstall.
- **Skill directories are a flat namespace with no scoping.** Two upstreams both shipping `handoff` collide, last install silently wins. The `kat-` prefix is load-bearing.

### Answers

1. **Decoration mechanism** — post-install frontmatter patching, as decided. Patchable keys are a fixed allowlist reusing the vendored `meta.jsonc` vocabulary (`name`, `description`, `argument-hint`, `license`, `compatibility`, `context`, `skills.modelInvocable`, `skills.userInvocable`), declared inline on the manifest entry. The patch is line-surgical so upstream's nested blocks survive. `--copy` is now enforced by construction — KAT builds the command.
2. **Delegate paths to [CLI]?** No. `skills list` output is a merged view unfit for per-agent removal and is not machine-readable. KAT derives paths from the CLI's *resolution rule* instead of its table, and records provenance in a `.kat-external.json` sidecar.
3. **Multi-target schema** — `clients` array (`client` string still accepted as shorthand). `codex` is now valid. The hand-written `command` field is removed; an entry still carrying one is blocked with a migration message.
4. **Flattening** — still not implemented. Unchanged from the analysis above.
5. **Which migrate** — `kat-grill-me` and `kat-handoff`, both done and deleted from `AI/skills`. `skill-creator` was renamed to `kat-skill-creator` for prefix consistency. The `kat-` prefix survives via post-install directory rename plus a frontmatter `name` patch.

   The remaining vendored third-party skills were each checked against **their pinned commit** (comparing against HEAD conflates "KAT edited it" with "upstream moved on"). None qualify:

   | Skill | Body vs pin | Blocker |
   |---|---|---|
   | ~~`kat-caveman`~~ | byte-identical | **Retired.** Upstream deleted the skill — `skills/productivity/caveman` 404s on `main` and `caveman` is absent from `skills add --list`. External entries track HEAD, so there was nothing to track, and the vendored copy was a fork of a dead upstream. Now a **disabled** manifest entry pointing at `JuliusBrussee/caveman` (a live alternative, `caveman` plus 13 `caveman-*` siblings, unevaluated) so the option stays documented. |
   | ~~`kat-review`~~ | modified | **Migrated as `kat-code-review`** once amendments existed. Upstream needs **only** `code-review` to run; `setup-matt-pocock-skills` is optional and merely enables auto-fetching issues named in commit messages — but it writes `docs/agents/*.md` into the repo and appends an `## Agent skills` block to `CLAUDE.md`/`AGENTS.md`. The body edit that forced vendoring is now three amendment lines instead. |
   | ~~`frontend-design`~~ | one line | **Migrated as `kat-frontend-design`.** The pinned body differed only by "Claude is capable of extraordinary creative work" → "You are capable…", a harness-neutrality edit. Upstream has since rewritten the skill (3.9k → 8.2k chars) and that sentence is gone entirely, so the edit was moot. Body and description both track upstream now. |
   | ~~`visual-explainer`~~ | ~2k chars + structure | **Migrated as `kat-visual-explainer`.** The `commands/` folder installs with the external package, so the Copilot gap is discoverability, not capability — upstream's own `configs/copilot/AGENTS.md` and `configs/codex/AGENTS.md` say those harnesses load the skill as instruction text, and that guidance is now carried as amendments. Trade accepted: the 8 flattened `visual-explainer.*` Copilot sibling skills are gone; upstream's newer `mcp/`, `pptx/`, `quick/` arrive. |
   | ~~`primitive-evaluator`~~ | n/a | **Retired.** Never existed upstream — absent from `anthropics/skills` at its pinned commit *and* at HEAD, and its `metadata` recorded no `path`. Its `primitive-analyzer` / `-comparator` / `-grader` agents were `skill-creator`'s `analyzer` / `comparator` / `grader` renamed, and `skill-creator` evaluates existing skills natively ("go straight to the eval/iterate part of the loop"; it snapshots the old version as an A/B baseline). `kat-skill-creator` was widened to Copilot and Codex to cover where this was actually used. |

   One piece of the `visual-explainer` fork was KAT-authored and had nowhere upstream to go: `commands/share.md` + `scripts/share.sh`, which published a generated HTML page to an anonymous claimable Vercel preview URL. It was **dropped**, not carried forward — reading the script in full showed it resolves its `vercel-deploy` dependency only from `~/.pi/agent/skills/…` or `/mnt/skills/user/…`, neither of which exists on Windows and neither of which was installed, so it had never been able to run here. Preserving it first and verifying second was the wrong order.

   **Note on the Google-sourced claim that Anthropic shipped an `/evaluate` command and a four-subagent pipeline (Executor/Grader/Comparator/Analyzer) under "Claude Skills 2.0":** not verifiable against the installed skill. There is no `/evaluate` command and `skill-creator` ships three subagents, not four — no Executor; the runs are performed by generic subagents. The underlying point — that the evaluator primitive now lives inside `skill-creator` — does hold.

   **Lesson worth keeping: a byte-identical body is necessary but not sufficient — upstream also has to still exist.** `kat-caveman` passed every content check and still failed, because the manifest's `skill` name is resolved against HEAD at install time. A pre-flight check that `skill` appears in `skills add --list` for `source` would have caught it before the vendored copy was deleted; not implemented.
6. **Drift** — gone for external entries; they track HEAD. No lockfile participation. Accepted as-is.

### Not answered, and worth its own look

**KAT publishes its own Codex *global* skills to `~/.agents/skills`, but Codex's bundled `skill-installer` documents `$CODEX_HOME/skills` (`~/.codex/skills`) as its install root**, and that directory exists on this machine holding Codex's own `.system` bundle. KatPolicies.md notes `$CODEX_HOME/skills` is marked deprecated in Codex source, which may fully explain it. Untested either way: no vendored skill is Codex-enabled at global scope today, so nothing exercises the path. Left alone deliberately — it is a separate question from this pivot.

### Amendments (added 2026-09-02)

The driver: maintaining forked bodies is the expensive part, so the goal became "external wherever possible". Amendments are what made that reachable. An external body cannot be edited, but instructions **concatenate** rather than replace, so a rule shipped alongside the skill overrides it from outside. Declared under `amendments` (`all` plus optional `claude`/`copilot`/`codex` keys) on the thing they amend — an `external.primitives.jsonc` entry *or* a vendored skill's `meta.jsonc` — and appended to the `kat` instruction as a `## Skill Amendments` section.

Vendored skills can amend because of Codex: `bodyReplacements.codex` is banned (D2) since Codex skill output is co-read by Copilot, so a body has no way to address Codex alone. Amendments are the only safe channel for Codex-only guidance. That is also why `AI/instructions/kat/meta.jsonc` now sets `enabled.codex: true` — the instruction hosting amendments has to reach Codex. Accepted side effect: the rest of the KAT shared rules now land in `~/.codex/AGENTS.md` too.

**Amendments do not subsume client markers.** Marker text loads only when its skill fires; an amendment is a global instruction present in every conversation, and it cannot substitute a word mid-sentence the way `bodyReplacements` / `{{KAT_*}}` do. Markers are also the mechanism amendments are built on — per-client amendment lines are emitted wrapped in `<!-- claude:start -->` blocks. After the migrations there is exactly one `bodyReplacements` and one `{{KAT_*}}` placeholder left in the repo (both `kat-policies`) and zero hand-written client markers, so the cleanup that motivated the question had already happened by other means.

This reclassifies the vendoring rule. Previously "body is modified" forced vendoring; now only "body must be *rewritten*" does. A body whose *behaviour* needs correcting can go external with an amendment — which is exactly how `kat-code-review` migrated.

Codex safety is structural rather than enforced: external primitives are global-only, and a global Codex instruction lands in `~/.codex/AGENTS.md`, which Copilot does not read. A repo-scoped `AGENTS.md` would leak, which is why the D2 ban on `bodyReplacements.codex` still stands for repo-scoped artifacts.

### Bug found and fixed along the way

`@(ConvertTo-StringArray $x)` is wrong at every call site — and it is easy to reintroduce; the amendments code hit it again within an hour of the constraint being documented, collapsing three bullets into one. The function returns a comma-wrapped array so an empty result survives the return pipeline; `@()` captures that wrapper instead of flattening it, yielding a one-element array holding the array — for empty, single, and multi-value input alike. Five pre-existing call sites had it (allowed-tools rendering, excluded item names, tool mapping values). All were on code paths no current `meta.jsonc` exercises, so the effect was latent. Fixed, with the constraint documented on the function.

---

## Prompt for the next session

The pivot itself is done. What remains is the import skill:

> I want to build a skill in `C:\BTR\Extensibility\Policies` that imports a new skill into this repo when I give it a GitHub repo or skills.sh URL. It is described under "The import skill" in `.vscode\Plans\external-primitives-handoff.md` — read that file's **Resolution** section first, since the external-install mechanism it must target is now built and several facts earlier in the document are corrected there.
>
> Bias toward external: post-install decoration now covers frontmatter, the `kat-` prefix, and `applyForUsers`, so only a modified body, per-repo gating, harness-specific tool names, or a `commands/` folder still force vendoring. Read `.vscode\Documentation\KatPolicies.md` ("Vendored vs External Primitives") for the current rule.
>
> Verify facts yourself rather than asking me, and use `Invoke-WebRequest` rather than `WebFetch` when comparing file contents, because `WebFetch` paraphrases.
