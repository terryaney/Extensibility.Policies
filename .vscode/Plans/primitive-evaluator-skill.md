# Copilot primitive evaluator plan

## Problem

Build a Copilot-native evaluator for existing prompt primitives without continuing to overload `AI/skills/skill-creator/` with client-specific reductions. The new evaluator should cover skills, agents, and instructions while reusing the strongest evaluation ideas from `skill-creator` without inheriting Claude-only trigger automation as part of the core design.

## Current state

- `AI/skills/skill-creator/` now renders cleanly for both Claude and Copilot, including synthesized Copilot helper agents from `agents/meta.jsonc`.
- `skill-creator` still mixes two concerns:
  - **authoring** new skills
  - **evaluating/improving** existing skills
- The automated evaluation loop in `scripts/run_eval.py`, `scripts/run_loop.py`, and `scripts/improve_description.py` is still Claude-specific because it shells out through `claude -p`, writes into `.claude/commands`, and measures Claude skill invocation behavior.
- The useful reusable parts are broader than skills:
  - grader / comparator / analyzer roles
  - benchmark aggregation and viewer ideas
  - workspace/eval metadata conventions from `references/schemas.md`
- Ledger/storage support already has a client split:
  - **VS Code Copilot** can use KatLedger MCP via `kat/ledger/*`
  - **Copilot CLI** should use SQL-backed session storage rather than project-local DB files

## Decision so far

- **Architecture:** new evaluator skill
- **Phase one scope:** skills, agents, and instructions
- **Reuse style:** clone-first from `skill-creator`, then remove unsupported pieces and refactor/extract shared pieces later
- **Current transition decision:** revert `skill-creator` to Claude-only now while the new evaluator is built

## Recommendation

Create a **new canonical evaluator skill** for Copilot-native review of existing prompt primitives, and revert `skill-creator` to a Claude-only role now rather than continuing to hollow it out with more client markers.

Why:

- `skill-creator` is still fundamentally an authoring skill with Claude-specific trigger-optimization branches.
- The user’s Copilot use case is narrower: **evaluate, compare, grade, and improve existing primitives**.
- A separate evaluator can target **skills, agents, and instructions** cleanly, while `skill-creator` stays focused on authoring and Claude-first optimization.
- Reuse should happen at the **concept / helper / schema / viewer** level, not by cloning all of `skill-creator` and deleting half of it with markers.

## Proposed approach

1. Revert `AI/skills/skill-creator/` to a Claude-only role so it stops carrying transitional Copilot behavior.
2. Create a new canonical skill, tentatively `primitive-evaluator`, focused on reviewing existing primitives instead of creating new ones.
3. Seed it from `skill-creator` content and structure where that speeds delivery, then strip or replace the Claude-only branches:
   - creation/interview guidance that does not belong in an evaluator
   - `claude -p` trigger-measurement flow
   - `.claude/commands` assumptions
   - packaging/install guidance that is specific to Claude skill distribution
4. Reuse the strongest portable pieces from `skill-creator`:
   - evaluation workflow language
   - helper-agent roles (`grader`, `comparator`, `analyzer`)
   - benchmark/workspace schema ideas
   - viewer and aggregation utilities where they are not Claude-trigger-specific
5. Keep Claude-only trigger evaluation inside `skill-creator` (or behind a later Claude adapter), not in the Copilot-native evaluator core.
6. Add explicit storage guidance:
   - VS Code: KatLedger-backed verification/evidence tracking
   - CLI: SQL session/session_store tracking instead of local SQLite files
7. Decide whether the reverted `skill-creator` should later add a light handoff back to the evaluator when a Copilot user asks to review an existing primitive.

## Todos

1. Revert `skill-creator` to Claude-only rendering/behavior.
2. Inventory reusable `skill-creator` assets and separate:
   - portable evaluation pieces
   - Claude-only trigger-automation pieces
3. Design the evaluator’s canonical shape:
   - `SKILL.md`
   - `meta.jsonc`
   - helper agents
   - references/schemas
   - optional scripts/viewer utilities
4. Define workspace/result schema for primitive evaluation:
   - run directories
   - grading/comparison outputs
   - benchmark summary
   - evidence ledger records
5. Define client-specific storage strategy:
   - KatLedger for VS Code
   - SQL session storage for CLI
6. Decide whether `skill-creator` should:
   - stay independent
   - reference the evaluator in Copilot-only sections
   - or share extracted docs/utilities later

## Notes

- The user chose a **fast clone-first path** for the evaluator, so initial duplication is acceptable if it reduces implementation risk. Refactoring can come after the evaluator proves out.
- The cleanest long-term split is:
  - `skill-creator` = authoring / creation / Claude trigger optimization
  - `primitive-evaluator` = evaluation / grading / comparison / improvement of existing primitives
- Phase one should already support **skills, agents, and instructions**, so naming, schemas, and examples should be primitive-oriented from the start rather than skill-only.
- The remaining design choice after implementation starts is whether `skill-creator` eventually references the evaluator for Copilot users, or stays purely Claude-focused with no cross-link.
