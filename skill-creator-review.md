# skill-creator — Integration Review

**Source:** [anthropics/skills · skill-creator](https://github.com/anthropics/skills/tree/main/skills/skill-creator)  
**Output:** raw `SKILL.md` dropped into target directory (no meta.jsonc, no KAT canonical structure)  
**Date:** 2026-05-22

---

## What It Does

skill-creator guides an AI through interviewing a user about a desired capability, authoring a well-structured `SKILL.md`, writing test cases, running parallel evaluations, reviewing results, and iterating until the skill performs well. Output is a single `SKILL.md` file.

The skill has three existing platform branches: **Claude Code** (full eval pipeline), **Claude.ai** (write-only, no evals), and **Cowork** (subagents available, no browser). **There is no Copilot branch.**

---

## Claude / Anthropic-Specific Elements

**1. `claude -p` CLI command — Blocker for Copilot**  
The entire evaluation engine runs on this command. Every test case spawns two subagent processes (`with_skill` / `without_skill`) via `claude -p` in parallel. The benchmark, grader, comparator, and description-optimization loop all depend on it. No Copilot CLI equivalent exists.

**2. Python scripts use the Anthropic SDK — Blocker for Copilot**  
`improve_description.py`, `run_eval.py`, and `run_loop.py` call the Anthropic API to iterate on skill descriptions. The `--model` flag expects a Claude model ID. Would require a full SDK swap to be usable outside Claude Code.

**3. Native subagent spawning — Blocker for Copilot**  
The skill spawns parallel named subagents (grader.md, comparator.md, analyzer.md) in the same turn — a Claude Code capability. Copilot has no equivalent native subagent mechanism. The entire blind-comparison and grading workflow is unavailable.

**4. Platform-specific sections — Gap**  
Explicit branches exist for Claude.ai and Cowork but not Copilot. Without one, Copilot falls through to undefined behavior and would attempt Claude Code workflows that fail silently.

**5. Model ID self-reference — Minor**  
Description optimization uses "the model ID from your system prompt (powering the current session)" for API calls — assumes a Claude model ID. Doesn't map cleanly to Copilot.

**6. Eval query framing — Minor**  
Trigger-eval guidance says queries should be "realistic for a Claude Code or Claude.ai user." A Copilot section would reframe this as "VS Code Copilot user."

---

## What Works Fine for Copilot As-Is

- **Core interview + authoring workflow** — capturing intent, writing test cases, drafting and iterating on a `SKILL.md` is pure natural-language guidance that works identically in Copilot.
- **SKILL.md format and conventions** — frontmatter fields, progressive disclosure, 500-line limit, trigger guidance — all platform-neutral.
- **Manual review workflow** — user examines outputs, provides feedback, skill is revised. Less efficient than the automated pipeline but fully functional.

---

## Copilot Compatibility Decision Table

| Feature | Claude Code | Copilot | Action |
|---|---|---|---|
| Interview + SKILL.md authoring | Full | Full | None |
| Test case design guidance | Full | Full | None |
| Parallel eval runs (`claude -p`) | Full | Unavailable | Gate behind Claude Code check |
| Subagent grader / comparator | Full | Unavailable | Gate behind Claude Code check |
| Python scripts (Anthropic SDK) | Full | Unavailable | Document as Claude Code prerequisite |
| Eval viewer (HTML report) | Full | Unavailable | Gate behind Claude Code check |
| Description optimization loop | Full | Unavailable | Gate behind Claude Code check |
| Manual output review + iterate | Full | Full | None — this is the Copilot path |
| Platform-specific section | Exists | Missing | Add Copilot section to SKILL.md |

---

## Recommended Changes

Minimal changes to make the skill Copilot-safe:

1. **Add a "Copilot-Specific Instructions" section** — mirrors the existing Claude.ai section. States: eval pipeline not available, use manual review path, skip all `claude -p` and Python script steps.
2. **Gate eval/benchmark sections with a platform check** — same pattern already used for Claude.ai. Copilot users skip directly to manual review + iterate.
3. **Remove or soften model ID self-reference** — the description optimization step that pulls the current model ID is Claude-only; make it conditional or omit for Copilot.
4. **Rephrase trigger-eval query guidance** in any Copilot section to reference VS Code Copilot users rather than Claude Code / Claude.ai users.

---

## Open Questions

**Q1:** Should the Copilot path guide the user to run the eval pipeline manually using Claude Code after the fact (generate SKILL.md in Copilot, then test it in Claude Code), or is pure manual review acceptable?

**Q2:** Will coworkers installing this skill have Claude Code available, or could they only have Copilot? If Claude Code is guaranteed on the machine, the Python scripts work regardless of which AI authored the SKILL.md.

**Q3:** The skill outputs a raw `SKILL.md` only. Does the deployment workflow have the coworker manually create `meta.jsonc` afterward, or should skill-creator be extended to emit the full KAT canonical structure?

**Q4:** Should the `agents/` directory (grader, comparator, analyzer) ship with the KAT deployment, or be stripped since Copilot users can't invoke them?
