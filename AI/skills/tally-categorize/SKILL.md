

You are categorizing unknown transactions and managing merchant rules. Run the report, discover unknowns, generate a review file, process user answers, and loop until 0 unknowns remain.

## Tagging Column Semantics

CSV data files use a `{tagging}` column (separate from `{memo}`) to hold annotation directives that drive rule matching. The tagging column is never displayed in the report.

- Format: `CATEGORY: Category / Subcategory` and/or `TAG: tagname`
- Multiple entries are comma-separated: `CATEGORY: Health & Fitness / Tennis, TAG: fixed-budget`
- Known shorthand: Normally, `CATEGORY: Health / X` resolves directly to `Health & Fitness / X` and is used in match expression for a specific merchant.

## Workflow

1. Run `tally up`.
2. Run `tally discover` (source of truth for unknowns).
3. If 0 unknowns and no ambiguous matches → done. If `merchants.rules` was modified, regenerate the all-rules report via `/tally-rules`.
4. Generate `tally/config/unknowns-schema.json` from `merchants.rules` (see Schema Generation below).
5. Generate `.tmp-tally/unknowns.yaml` with unknowns + ambiguous matches (see YAML Generation below).
6. Open the YAML file in the editor. Tell user: "Review file is open. Fill in answers and say 'done' or 'process N-M' for a partial batch."
7. Wait for user to respond.
8. Read YAML back, process each answered row (see Processing below).
9. Run `tally up` + `tally discover` (full refresh).
10. If unknowns remain → goto 4 (regenerate schema + YAML with remaining items).
11. If 0 unknowns → done. If `merchants.rules` was modified during this session, regenerate the all-rules report via `/tally-rules`.

When done, open the `spending_summary.html` report in the browser for the user.

## Schema Generation

Parse `merchants.rules` to build `tally/config/unknowns-schema.json`:

- **`useRule` enum**: All unique rules excluding tag-only rules. Uniqueness key: `Name + Category + Subcategory + Tags`. Format: `[Name] Category / Subcategory` or `[Name] Category / Subcategory | tags: x, y` (omit category/subcategory/tags tokens when absent). If multiple rule blocks share the same key, deduplicate to one enum entry and log a warning comment in the schema.
- **`edits.category` enum**: All distinct `category / subcategory` pairs from `merchants.rules` plus `""`.
- **`edits.tags` enum**: All tag names from tag-only rules that check `contains(field.tagging, "TAG: ...")` plus `""`. Description note: "Comma-separate for multiple. Unknown tags create new tag-only rules."
- **`edits.memo`**: Free string, no enum.
- **`newRule`**: Free string, no enum.

## YAML Generation

Write `.tmp-tally/unknowns.yaml` with this structure:

```yaml
# yaml-language-server: $schema=../tally/config/unknowns-schema.json
# ─── Navigation ───
# Ctrl+F "useRule:" → F3 to jump between items. Ctrl+Space for autocomplete.
#
# ─── Answer Fields ───
# useRule:  Select existing merchant rule. AI updates match to include this tx.
#           If rule requires CATEGORY/TAG tagging to match, AI auto-adds it to CSV.
# newRule:  Free-form instruction for AI (e.g. "create merchant [Tom Aney]")
# edits.category:  Adds CATEGORY: X / Y to CSV tagging column.
# edits.tags:  Adds TAG: x to CSV tagging column. Ctrl+Space for known tags.
#              Multiple: comma-separate (e.g. "fixed-budget, income"). Yellow squiggle expected.
# edits.memo:  Text added to memo column in CSV data file.
#
# ─── When done ───
# Say "done" in chat. Or "process 1-5" for partial batch.
# Auto-generated — do not hand-edit outside of a /tally-categorize session.

source: <source-file-name>
unknowns:
  - id: 1
    date: MM/DD/YYYY
    merchant: DESCRIPTION
    amount: -$X.XX
    description: "additional context from statement if available"
    additionalInfo: "AI guess and contextual notes"
    useRule: 
    newRule: 
    edits:
      category: 
      tags: 
      memo: 
```

Field rules:
- `id`: sequential integer for batch-referencing in chat.
- `date`: transaction date from CSV.
- `merchant`: description/merchant from CSV (cleaned).
- `amount`: signed amount with $ prefix.
- `description`: omit entirely if no meaningful description beyond merchant name.
- `additionalInfo`: AI's category guess + contextual notes (e.g. "Shopping / Shoes — likely running shoes", "? — VENMO counterparty: John Doe"). Start with guess, then context after em-dash.
- Transactions ordered descending by date.
- Group by source file (one `source:` + `unknowns:` block per file).

### Ambiguous Matches

After unknowns, add a second section for transactions that DO match existing rules but need confirmation:
- **Target / Walmart**: amount ≥ $75 (Target) or > $125 (Walmart/Costco). Pre-fill `useRule` with current match. `additionalInfo`: "⚠ Large amount on mixed-use merchant. Currently matches [X]. Confirm or override."
- **Best Buy in December**: Pre-fill `useRule`. `additionalInfo`: "⚠ December purchase — could be Christmas gift."

If user leaves `useRule` as-is with no other changes → confirmed, skip.

## Processing Answers

For each row with any answer filled in:

| Field | Action |
|---|---|
| `useRule` only | Find that rule in `merchants.rules`. Update its `match:` expression minimally to also match this transaction (add `or contains(...)` clause). If rule's match checks `field.tagging` for a `CATEGORY:` or `TAG:` pattern, auto-add that tagging to the CSV row. |
| `newRule` | Parse free-form instruction. Create rule in proper category section per insertion logic. |
| `edits.category` | Add `CATEGORY: X / Y` to the CSV tagging column for that transaction's row. |
| `edits.tags` | For each tag: add `TAG: x` to CSV tagging column. If tag doesn't exist as a tag-only rule AND is not within edit-distance 2 of an existing tag, create a new tag-only rule. If within edit-distance 2, warn user about possible typo before creating. |
| `edits.memo` | Add text to CSV memo column for that transaction's row. |
| All blank | Skip — will reappear in next loop iteration. |

Multiple fields can be filled simultaneously (e.g. `newRule` + `edits.category`).

## Rule Insertion Logic

**Never create `[Category Override - ...]` bracket names.** When a non-Amazon CSV row has a `CATEGORY: X / Y` in its tagging column, add a rule to the `# --- Non-Amazon category overrides ---` block inside `# === CATEGORY: tagging overrides ===`.
- Bracket name: use merchant's existing name or clean merchant name.
- Match: `contains("DESCRIPTION_PATTERN") and contains(field.tagging, "CATEGORY: X / Y")` with **no source filter**.

**Insert into the correct category section — never append.**  The `merchants.rules` file has a fixed layout:
1. Preserved infrastructure at top: Field Transforms, Variables, Tag-only rules, CC Payments / Transfers, Family Account Transfers, Check Number / Deposit Reference Rules, CATEGORY: tagging overrides. Never add generic merchant rules here.
2. Below: one section per `category:` value (`# === Auto ===`, `# === Food ===`), sorted alphabetically.
   - Insert into the matching section. **Never** create `# === X (continued) ===`, batch headers, or append to EOF.
   - If category doesn't exist, create one new `# === Category ===` header in alphabetical position.
   - **Same-merchant pairs across categories:** keep adjacent in the primary rule's section. `# Category Override` comment above rules whose category differs.
   - **Within-pair order:** specific filters before generic (first-match-wins).