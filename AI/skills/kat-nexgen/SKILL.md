# Nexgen Site Guidance

Use the Nexgen skill for the Life at Work Connect (LWC) site: server-side BRD and CalcEngine integration, BRD structure, result-tab exports, API DataSource mappings, xDS data model flow, command processing, cache refresh semantics, and Nexgen-specific data production.

Nexgen is a single site built on top of the reusable KatApp framework using specialized CalcEngine behavior.

## Scope Boundary

Nexgen owns site-specific server-side data production and CalcEngine integration. It explains where data comes from, how BRD rows merge, how CalcEngine result tabs are produced, how API DataSource mappings work, how xDS data is shaped, how commands are processed, and how cache refresh is triggered.

If the task is purely about KAML rendering, `v-ka-*`, petite-vue behavior, `application.*`, modal display, or consuming already-available RBLe data in a view, give a short triage response instead of answering from Nexgen server-side assumptions. State that the task is KatApp-owned, name the reason, and ask the user to rerun with `/kat-katapp` unless explicit KatApp guidance is already available in the conversation.

Example triage response:

```md
This is KatApp-owned because it concerns `v-ka-modal` rendering and view-side RBLe consumption. Use `/kat-katapp` for the detailed answer.
```

## Retrieval Order

1. Read the local workspace document first: `./.vscode/Documentation/CalcEngines.md`.
2. If the workspace document is not enough, fetch only the relevant section from `https://raw.githubusercontent.com/terryaney/Documentation.Camelot/main/Nexgen/CalcEngines.md`.
3. Read only the heading or section needed for the current task. Do not load the entire document unless the task spans multiple sections.

## Code Anchors

- `Services/BrdService.cs` - BRD calculation flow, merge rules, app settings, user settings, manual result caching.
- `Services/ApiDataService.cs` - xDS data model and API data refresh flow.

## Headings To Target

- `Benefit Requirements Document`
- `BRD Settings`
- `API DataSource Mappings`
- `appSettings Table`
- `appAttributeMapping Table`
- `userEligibility Table`
- `manualResults Table`
- `userCalculatedData Table`
- `Global and Client BRD Merging Flow`
- `Managing xDS Data Model`
- `Temp Query Processing`
- `Refreshing API Data On Demand / cacheRefreshKeys`
- `Command Processing`
- `RBL Calculation Caching`

## High-Value Invariants

- `apiDataSource` is the parent row. `apiDataSourceMapping` and `apiDataSourceInputs` rows must reference an existing `apiDataSource.id`.
- Prefer `.KEY` command verbs over hardcoded endpoints.
- Never generate AuthIDs in CalcEngines. `{legalIdentifier}` is filled by server code.
- A `{QS.*}` query string creates temp query results, so mapped profile fields and history tables gain the `Query` suffix.
- `views` and `manualResults` merge field-by-field. Some tables replace wholesale. All other tables merge by key.
- Use `on_brd=0` when a client BRD needs to turn off a global BRD row after merge.
- `CLEAR.BRD` must be the final command when a command sequence re-runs BRD.
- BRD tables are the source of truth for API registration and mapping.

## Working Style

- Answer with concrete table names, merge rules, and call out whether behavior is CalcEngine-side, server-side, or KatApp-side.
- Fetch docs or read code before answering if the behavior is not obvious from these invariants.
- If docs and code disagree, prefer code and point out the mismatch.