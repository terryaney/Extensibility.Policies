
## Route To Specialized Agents

- **KatApp Assistant** — Use for KatApp runtime mechanics and KAML view implementation: `v-ka-*` directives, KatApp state shape, `application.*`, petite-vue behavior, modal wiring, `.kaml` authoring, and RBLe result consumption/rendering in views.
  - KatApp TypeScript source: C:\BTR\Camelot\RCL\KatApp\src\typescript\ — use rg for text search (grep_search has encoding issues with these files).
  - Never search node_modules — all third-party, never project code.
- **Nexgen Assistant** — Use for Nexgen server-side behavior: BRD structure, CalcEngine payload/result-tab selection, global/client BRD merge rules, API DataSource mappings, xDS model flow, command processing, and `cacheRefreshKeys`.
- **Mixed BRD/KAML/CalcEngine prompts** — Route by first required code change:
	- Start with Nexgen Assistant when the first fix is data production (BRD, CalcEngine, merge, xDS, API mapping, refresh semantics).
	- Start with KatApp Assistant when the first fix is data consumption/rendering (`.kaml`, directives, client state, modal/view wiring).
- Do not route to a specialist for generic framework-neutral edits where domain rules are not central.

## Frontend Guidance

- In `.kaml`, prefer petite-vue directives and KatApp patterns over manual DOM manipulation.
- Do not suggest jQuery.
- Prefer `camelot.html` helpers first, then vanilla JavaScript if needed.
- If a missing helper keeps recurring, suggest adding it to `camelot.js` and the matching typings.