# KatApp Framework Guidance

Use the KatApp skill for KatApp runtime and KAML view development: `v-ka-*` directives, KatApp state, RBLe result access, modal workflows, petite-vue integration, `application.*` APIs, and view-side consumption of already-produced data.

## Scope Boundary

KatApp owns reusable framework and runtime behavior. It explains how KAML views consume data, bind state, render lists, handle events, compose local KAML packages, and interact with KatApp client APIs.

If the task asks how data is produced, merged, mapped, cached, or refreshed in Nexgen, give a short triage response instead of guessing from KatApp runtime patterns. State that the task is Nexgen-owned, name the reason, and ask the user to rerun with `/kat-nexgen` unless explicit Nexgen guidance is already available in the conversation.

Example triage response:

```md
This is Nexgen-owned because it concerns API DataSource mappings and cache refresh. Use `/kat-nexgen` for the detailed answer.
```

## Retrieval Order

1. Read the workspace index first: `c:\BTR\Camelot\RCL\KatApp\.vscode\Documentation\KatApp.md`.
   - If the workspace index is not available, fetch the same patterns from `https://raw.githubusercontent.com/terryaney/Documentation.Camelot/main/KatApp/KatApp.md`.
2. Read only the smallest section needed for the current task. Do not load the full document unless the task truly spans multiple sections.
3. Fast routing options listed below. If the question is outside these areas, use the `KatApp.md` index file to determine the proper section to fetch.
   - Start with `KatApp.03.State.md` for `rbl.value`, `rbl.source`, state shape, and result processing questions.
   - Start with `KatApp.06.CustomDirectives.md` for `v-ka-*` questions.
   - Start with `KatApp.07.Api.md` for `application.*`, event, lifecycle, and modal API questions.
   - Start with `KatApp.02.KamlViewSpecifications.md` for `.kaml`, scoping, and `local-kaml-package` questions.
   - Start with `KatApp.01.GettingStarted.md` for app startup or calc-engine configuration questions.

## Working Notes

- Prefer the section files for focused reads and targeted retrieval.
- The section files are the authoritative KatApp documentation.
- Cross-section links have been rewritten to target the owning section file directly.

## High-Value Invariants

- KatApp uses petite-vue syntax and constraints, not full Vue. Do not assume `ref`, `computed`, transitions, or render-function patterns are available.
- Prefer KatApp patterns such as `v-ka-*`, `v-ka-input`, `rbl.value()`, and `rbl.source()` over generic DOM manipulation.
- Scope DOM work with `application.selectElement()` and `application.selectElements()` instead of document-global selectors when possible.
- For multi-CalcEngine questions, clarify or specify the CalcEngine key and tab.
- For modal workflows, prefer `application.showModalAsync(...)` or `v-ka-modal`.
- Prefer `file.kaml`, `file.kaml.js`, and `file.kaml.css` with `local-kaml-package` instead of embedding large script or style blocks.
- jQuery is not available. Prefer KatApp helpers or `camelot.js` helpers if available, then vanilla JavaScript.

## Quick Reference

- Use `application.state.rbl.value(...)` for scalar result lookup.
- Use `application.state.rbl.source(...)` for row collections used by `v-for` and other list rendering.
- Use `application.showModalAsync(...)` or `v-ka-modal` for modal behavior instead of ad hoc Bootstrap wiring.

## Working Style

- Answer from the framework's perspective first, not from generic Vue or DOM patterns.
- Fetch docs or read code before answering when the behavior is not obvious from these invariants.
- If docs and code disagree, prefer code and point out the mismatch.