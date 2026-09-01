# Handoff: Lean Into External Installs

Written 2026-08-07 at the end of a long session. Purpose: carry the argument into a fresh context without re-deriving it. The prompt to start the next session is at the bottom.

## Where the user wants to end up

**"Almost like an IT department managing deployments of tools I want everyone to have installed for 1–3 harnesses."**

Concretely: stop being the maintainer of other people's skill *content*. Let upstream own the body, let `npx skills` fetch and update it, and keep KAT's job as **deployment policy** — who gets it, on which harnesses, at which scope, with which frontmatter decorations applied afterwards.

The pivot: things `meta.jsonc` currently does by *rendering a body* should, where possible, become **post-install decoration of an external install**. `context: fork` is the motivating example — the user wants it, it's a one-line frontmatter edit, and it should not cost a permanent fork of someone else's prose.

## What already shipped this session (done, published, verified)

The cross-harness conflict work is complete and is **not** up for re-litigation. See [codex-conflicts.md](codex-conflicts.md) for decisions D1–D11 and their rationale. Summary of what changed:

- Tally bodies neutralized; all three published trees byte-identical. `bodyReplacements.codex` removed from four metas.
- `visual-explainer`'s `share` command-table row wrapped in `<!-- claude:start -->`.
- `update.ps1` gained `Assert-CrossHarnessPolicy` (runs before any managed root is cleared): D2 error, D8/D9/D11 warnings, `@`-import rejection, plus D5 (repo-scoped codex instructions skip `.github/instructions`), D6 (`skills.modelInvocable` / `skills.userInvocable`), D7 (`agents/openai.yaml`).
- `kat-handoff` set to `modelInvocable: false`, restoring upstream intent that was lost during its original copy-paste import. `kat-grill-me` deliberately left implicit-invocable, matching Pocock.
- Docs updated: Primitives.md (read matrix, precedence, command shapes), Metadata.md (new flags, marker-safety, warnings), KatPolicies.md (settled overlap section, vendored-vs-external, install path tracking), readme.md (stale "open question" blockquote replaced).

## Established facts, by layer

State which layer a claim belongs to. Conflating them wasted time in the last session.

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

**[harness] — settled in [codex-conflicts.md](codex-conflicts.md)**

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

## Prompt for the next session

> I want to pivot `C:\BTR\Extensibility\Policies` toward external skill installs. Goal: I act like an IT department deploying tools to teammates across 1–3 harnesses (Copilot, Claude Code, Codex), but I never maintain other people's skill *content* — upstream owns the body, `npx skills` fetches and updates it, and KAT owns deployment policy plus small post-install decorations like `context: fork`.
>
> Read `.vscode\Plans\external-primitives-handoff.md` first — it has the established facts by layer, the corrections not to re-derive, and the open questions. Then read `.vscode\Plans\codex-conflicts.md` for the cross-harness decisions that are already settled and closed.
>
> Use the `kat-grill-me` skill to work the open questions in that handoff. Be explicit about which layer each claim belongs to — `[CLI]` for `npx skills` behavior, `[KAT]` for what `update.ps1` does today, `[schema]` for `external.primitives.jsonc` which we can change, `[harness]` for client behavior. Verify facts yourself rather than asking me, and use `Invoke-WebRequest` rather than `WebFetch` when comparing file contents, because `WebFetch` paraphrases.
>
> Separately, I also want to build a skill that helps import a new skill into this repo when I give it a GitHub repo or skills.sh URL. That's described at the end of the handoff.
