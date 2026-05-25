# Primitive Evaluator

Use this skill to evaluate and improve **existing prompt primitives** rather than creating new ones.

Phase-one primitive types:

- skills
- agents
- instructions

This skill is for cases where the primitive already exists and the user wants to:

- compare a candidate against a baseline
- grade outputs against explicit expectations
- review evidence across multiple evals
- identify where the primitive helps, hurts, or adds cost
- improve the primitive based on measured results

If the user wants to **author a new skill from scratch** or run **Claude trigger-description tuning**, use a separate authoring workflow. Do not fold those workflows back into this evaluator.

## Core stance

Treat evaluation as a first-class workflow:

1. define what "better" means
2. run the same realistic prompts against a baseline and a candidate
3. capture outputs, timing, and evidence
4. grade the results with discriminating expectations
5. review qualitative outputs and quantitative summaries together
6. revise the primitive only after the evidence is clear

Do not claim rigor you did not actually execute. If a benchmark is partial, say so. If the assertions are weak, say so. If the result is qualitative rather than statistically strong, say so.

## What to capture before running evals

Start by grounding the evaluation:

1. **Primitive type** — skill, agent, or instruction
2. **Primitive path** — the current candidate to review
3. **Baseline** — what the candidate should be compared against
4. **Outcome** — what the user wants improved: correctness, structure, triggering, latency, tool use, reproducibility, or another concrete behavior
5. **Evidence shape** — which files, transcripts, screenshots, logs, or summaries matter

Prefer a real baseline over vague before/after impressions. Good defaults:

- **new draft primitive** -> baseline is `baseline` with no primitive or the prior behavior the user is replacing
- **edited primitive** -> baseline is the prior checked-in version or a snapshot taken before changes
- **two competing implementations** -> baseline is the weaker or incumbent version, candidate is the proposed replacement

## Storage and evidence guidance

Use workspace files for portable artifacts and client-native storage for the evidence ledger:

- **Copilot VS Code**: use KatLedger MCP for evidence, verdicts, and follow-up actions when ledger tracking adds value
- **Copilot CLI**: use `session` / `session_store` SQL for run tracking, findings, and cross-session recall
- **Claude**: keep the same workspace/result files, but do not import Claude trigger-optimization automation into this evaluator

Do **not** introduce project-local SQLite databases as the default tracking path for Copilot CLI.

## Recommended workspace layout

Create a sibling workspace such as `<primitive-name>-workspace/` and organize runs by iteration:

```text
<primitive-name>-workspace/
  iteration-1/
    eval-<name>/
      eval_metadata.json
      candidate/
        run-1/
          outputs/
          transcript.md
          grading.json
          timing.json
      baseline/
        run-1/
          outputs/
          transcript.md
          grading.json
          timing.json
    benchmark.json
    benchmark.md
    feedback.json
```

`candidate` and `baseline` are the preferred configuration names for this evaluator. The bundled viewer and benchmark scripts understand them directly.

## Writing evals

Save eval prompts to `evals/evals.json` near the primitive or in the workspace when the primitive should stay untouched. Use `references/schemas.md` for the exact shapes.

Each eval should include:

- an id
- a descriptive name
- the user-like prompt
- expected output description
- any required input files
- expectations once you know what should be measured

Make the prompts realistic. Favor prompts a real user would actually type over toy prompts that only prove the happy path.

## Running the evaluation loop

### 1. Run candidate and baseline on the same prompts

For each eval, run the same task against both configurations:

- **candidate** -> the primitive under review
- **baseline** -> the comparison target

Launch both runs as close together as the current client allows. If task or agent primitives are available, use them. If not, run the workflows inline and keep the structure consistent. Do not assume `claude -p`, `.claude/commands`, or any other Claude-only automation exists.

Save:

- transcript
- outputs
- timing when available
- notes about uncertainty, workarounds, or missing evidence

### 2. Draft or refine expectations while runs are active

Good expectations are:

- objectively checkable
- hard to satisfy accidentally
- phrased so the benchmark is readable at a glance

Weak expectations create false confidence. If an expectation only checks file existence or wording without validating the actual outcome, tighten it before trusting the result.

### 3. Grade each run

Use the helper agents when they are available:

- `{{KAT_SKILL_AGENT.primitive-grader}}`
- `{{KAT_SKILL_AGENT.primitive-comparator}}`
- `{{KAT_SKILL_AGENT.primitive-analyzer}}`

Otherwise grade inline using the same standards:

- read the transcript
- inspect the outputs directly
- require evidence for every pass
- flag weak eval design separately from primitive quality

For assertions that are easy to verify programmatically, write a small deterministic script instead of eyeballing them.

### 4. Aggregate the benchmark

From `AI/skills/primitive-evaluator/`, run:

```powershell
python -m scripts.aggregate_benchmark <workspace>\iteration-<N> --primitive-name <primitive-name> --primitive-type <skill|agent|instruction>
```

This produces:

- `benchmark.json`
- `benchmark.md`

The aggregation script is portable. It does **not** depend on Claude trigger-eval automation.

### 5. Review qualitative outputs

Use the bundled review viewer when a browser or static HTML artifact is appropriate:

```powershell
python .\eval-viewer\generate_review.py <workspace>\iteration-<N> --primitive-name <primitive-name> --benchmark <workspace>\iteration-<N>\benchmark.json
```

If a live browser is not practical, write a standalone file instead:

```powershell
python .\eval-viewer\generate_review.py <workspace>\iteration-<N> --primitive-name <primitive-name> --benchmark <workspace>\iteration-<N>\benchmark.json --static <workspace>\iteration-<N>\review.html
```

The viewer is for human review of:

- per-eval outputs
- formal grades
- previous-iteration comparison
- benchmark summaries
- feedback capture

### 6. Use blind comparison when the result is disputed

When the user asks whether a new primitive is actually better, compare candidate and baseline outputs without revealing which side produced which result. Then analyze why the winner won before you edit the primitive again.

### 7. Improve the primitive from evidence, not vibes

When revising the primitive:

- generalize from repeated failures
- remove instructions that add cost without improving outcomes
- add bundled helpers only when repeated runs prove they save work
- keep the primitive reusable across prompts instead of overfitting to the current eval set

If the evidence says the baseline is still better, say so and keep the baseline.

## Primitive-specific guidance

### Skills

Review:

- trigger wording only through manual prompt review here
- output quality
- workflow clarity
- bundled helper usefulness

If the user wants Claude trigger-description optimization, hand that work to a separate Claude-specific authoring workflow.

### Agents

Review:

- handoff quality
- tool boundaries
- refusal/guardrail behavior
- evidence-backed task completion

Treat agent metadata and prompt body as part of the same primitive. A better body with broken metadata is not a pass.

### Instructions

Review:

- whether the instruction actually changes behavior
- whether it overreaches and harms unrelated tasks
- whether scope is correct
- whether the guidance is specific enough to follow but not so rigid that it distorts normal work

For instructions, near-miss prompts matter as much as obvious matches.

## Explicit exclusions

This evaluator does **not** own:

- creating a new skill from scratch
- Claude description trigger optimization via `claude -p`
- `.claude/commands` packaging assumptions
- Claude `.skill` packaging/distribution guidance

Keep those in a separate Claude-specific authoring workflow.

## Reference files

- `references/schemas.md` — workspace, grading, comparison, benchmark, and evidence schemas
- `agents/primitive-grader.md` — formal expectation grading
- `agents/primitive-comparator.md` — blind A/B comparison
- `agents/primitive-analyzer.md` — post-hoc analysis of why one version won
- `scripts/aggregate_benchmark.py` — benchmark aggregation
- `eval-viewer/generate_review.py` — review viewer generator

## Final reminder

Keep the evaluation honest:

- same prompts
- same inputs
- same success bar
- explicit evidence
- clear distinction between qualitative judgment and measurable results

If the primitive helps, prove it. If it does not, say it plainly.
