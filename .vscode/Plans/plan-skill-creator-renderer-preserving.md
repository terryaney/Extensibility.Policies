# Skill Creator renderer-preserving migration plan

## Problem

Keep a single canonical `AI/skills/skill-creator/` source that stays as close as possible to the upstream Anthropic skill layout, while making KAT deployment produce:

- a Claude skill that looks as close as possible to a direct Anthropic-style install
- a Copilot skill that can use equivalent helper behavior without requiring a second duplicated skill tree
- one maintainable canonical source with minimal divergence from upstream

The user wants to preserve the Claude-facing relative layout assumptions where practical, especially for `agents/`, and prefers renderer-driven client adaptation over source duplication.

## Confirmed direction

1. **Do not create a duplicate `skill-creator.copilot` skill folder.**
2. **Keep the `agents/` folder inside the canonical skill** so Claude output remains structurally close to the original skill.
3. Add a **single `AI/skills/skill-creator/agents/meta.jsonc`** that describes the helper agents in a grouped/container form keyed by helper filename.
4. When the renderer sees a skill-local `agents/` folder:
   - **Claude**: preserve the folder inside the skill so the deployed skill still looks like the original Anthropic layout.
   - **Copilot**: synthesize real helper agents from that metadata and publish them as non-user-invocable agents with names like `{parent}-{agent}`.
5. Rewrite the Copilot skill body so it refers to those synthesized helper-agent names, while the Claude body can keep the relative-file mental model.
6. **Scripts should support client-aware processing from the canonical source.** The target is to use markers/replacements for support files during deployment, not to duplicate full script trees.

## Current state

- Canonical skills already publish copied support files beside `SKILL.md`.
- Canonical agents already publish as real Copilot/Claude agents from `AI/agents/`.
- Current renderer logic handles client markers/body replacements for canonical markdown bodies, but copied support files are still largely raw copies.
- The imported `skill-creator` currently has these bundled areas:
  - `agents/`
  - `scripts/`
  - `references/`
  - `assets/`
  - `eval-viewer/`
- Claude-specific blockers still exist in the actual logic of several Python scripts because they call `claude -p`, but the source-layout goal is now clearer: **preserve source shape, adapt at render time**.

## Recommended architecture

### 1. Keep one canonical skill tree

Keep:

- `AI/skills/skill-creator/SKILL.md`
- `AI/skills/skill-creator/meta.jsonc`
- `AI/skills/skill-creator/agents/*`
- `AI/skills/skill-creator/scripts/*`
- `AI/skills/skill-creator/references/*`
- `AI/skills/skill-creator/assets/*`
- `AI/skills/skill-creator/eval-viewer/*`

No second skill folder unless the renderer approach proves impossible.

### 2. Add grouped metadata for skill-local helper agents

Add `AI/skills/skill-creator/agents/meta.jsonc` with a grouped shape roughly like:

```jsonc
{
  "grader": { /* normal canonical agent-like fields */ },
  "comparator": { /* normal canonical agent-like fields */ },
  "analyzer": { /* normal canonical agent-like fields */ }
}
```

The renderer should interpret that file only when it is under `skills/<id>/agents/`.

### 3. Renderer behavior for skill-local agents

For `skills/<parent>/agents/`:

- **Claude output**
  - copy `agents/` into the skill unchanged or nearly unchanged
  - preserve the relative-file model so the deployed Claude skill still resembles upstream

- **Copilot output**
  - do not rely on raw `agents/*.md` inside the skill as executable helpers
  - instead, synthesize published helper agents using names like:
    - `skill-creator-grader`
    - `skill-creator-comparator`
    - `skill-creator-analyzer`
  - mark them non-user-invocable in Copilot metadata
  - update the Copilot-rendered skill text so it calls those agents by name

### 4. Renderer behavior for scripts

The intended direction is to support **client-aware rendering of copied support files**, especially `scripts/`.

That means the renderer should be able to process canonical script sources before publishing them, rather than only copying them verbatim.

Preferred order of solutions:

1. **Support file client markers/replacements**
   - extend the renderer so selected copied files can be client-processed during publish

2. **Language-safe marker syntax**
   - if HTML comment markers break `.py` validity, introduce a second marker form that remains valid in Python and other code files

3. **Fallback sidecar overrides**
   - allow files like `run_eval.copilot.py` only where necessary
   - use them sparingly to minimize duplication

The goal is still minimal divergence from upstream source, so sidecar per-client files are a fallback, not the default plan.

## Why this is better than splitting the skill

- The Claude deployment remains visually and structurally close to the upstream Anthropic skill.
- The Copilot-specific behavior is introduced in the renderer, where the platform differences actually belong.
- Source duplication stays low.
- The canonical source remains easy to diff against upstream.

## Todos

1. Design and document `skills/<id>/agents/meta.jsonc` grouped metadata shape for skill-local helper agents.
2. Extend the renderer so skill-local helper agents can be synthesized into real Copilot agents named `{parent}-{agent}` while preserving the original `agents/` folder for Claude.
3. Update `AI/skills/skill-creator/SKILL.md` so Copilot-rendered output refers to synthesized helper-agent names, while Claude-rendered output can preserve the local-folder assumptions.
4. Extend the renderer so copied support files can receive client-aware processing during deployment.
5. Define a language-safe client-marker format for code files such as `.py`, or fall back selectively to sidecar files like `*.copilot.py` where markers are not practical.
6. Audit each `scripts/` file and decide whether it:
   - stays shared with markers
   - needs a small Copilot sidecar
   - remains Claude-only in behavior even if the file still ships
7. Revisit `assets/` and `eval-viewer/` after the support-file rendering work; keep them shared unless a concrete client issue forces divergence.
8. Render and validate final Claude and Copilot outputs against the desired source-preservation goal.

## Important implementation constraints

- Hidden helper behavior is still stronger in Copilot than in Claude.
  - Copilot can enforce non-user-invocable helper agents.
  - Claude does not have the same exact enforcement model, so helper intent is partly conventional there.
- The Claude skill should keep relative-path-oriented helper documentation where that preserves upstream compatibility.
- The Copilot skill should be rewritten at render time to call published helper agents by name, not by relative skill file path.
