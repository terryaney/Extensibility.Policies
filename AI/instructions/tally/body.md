

## What This Repo Is

This is a **Tally** financial analysis configuration project. It contains no source code, only configuration files that drive the `tally` CLI tool to parse bank and credit-card CSV exports, categorize transactions, and generate spending reports.

Primary files:

- `tally/config/settings.yaml`
- `tally/config/merchants.rules`
- `tally/config/views.rules`

Reference sites:

- Tally product site: https://tallyai.money/
- Tally GitHub repository: https://github.com/davidfowl/tally

## Rules

1. If the user asks for help
- Tally features are described with `tally.exe -h` (and -h command).  If not sufficient, confirm details from the reference sites above before answering.
- Workflows are performed by skills listed below.  Provide user with the correct skill to invoke, and do not perform the workflow inline.
2. If the user is asking why a rule is not working, NEVER automatically change rules without first confirming.
3. NEVER automatically generate merchant rules without confirmation.

## Communication preference
1. Keep progress updates and final answers brief by default.
2. Do not narrate routine actions or provide audit/detail summaries unless asked.
3. Report only: result, files changed, and any decision or blocker needing user input.

## Tally Skills

All tally report generation, file registration, transaction categorization, and rule management MUST go through the appropriate skill. Do not perform these operations inline.

| Skill | Purpose |
|---|---|
| `tally-files` | Register new CSV data files in `settings.yaml`. Validates columns, normalizes data, handles headers. |
| `tally-categorize` | Run `tally up`, discover unknowns, generate YAML review file, process answers, create/update rules. Loop until 0 unknowns. |
| `tally-rules` | Generate rules reports (all rules, session rules, new rules). |

If the user says "tally up", "run tally", "generate report", "process unknowns", "categorize", or equivalent without a skill invoked, respond: "Use the `tally-files` skill if you have new CSVs to register, or the `tally-categorize` skill to run the report and process unknowns."

If the user asks for a rules report without a skill invoked, respond: "Use the `tally-rules` skill to generate a rules report."