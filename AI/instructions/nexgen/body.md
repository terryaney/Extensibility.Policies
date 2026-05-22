
## Route To Specialized Agents

- **KatApp Assistant** — Use for KatApp or KAML framework work: `v-ka-*` directives, KatApp state, `rbl.*`, KatApp JS or TS APIs, petite-vue behavior, `.kaml` authoring, and RBLe result rendering.
- **Nexgen Assistant** — Use for Nexgen domain behavior: BRD structure, API DataSource mappings, xDS model flow, command processing, and `cacheRefreshKeys`.
- Use the specialist when the task depends on framework or domain rules rather than generic TypeScript or JavaScript knowledge.

## Frontend Guidance

- In `.kaml`, prefer petite-vue directives and KatApp patterns over manual DOM manipulation.
- Do not suggest jQuery.
- Prefer `camelot.html` helpers first, then vanilla JavaScript if needed.
- If a missing helper keeps recurring, suggest adding it to `camelot.js` and the matching typings.