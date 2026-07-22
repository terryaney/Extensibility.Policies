

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

1. If the user asks about Tally features and `tally.exe` help is not sufficient, confirm details from the reference sites above before answering.

2. If the user believes a feature should work, or says the report does not look correct, do not answer without proof from source code or documentation.

3. If the user is asking why a rule is not working, NEVER automatically change rules without first confirming.

4. Only add `field: memo = field.memo` to a merchant rule when that merchant's transactions are known to have meaningful memo content. Do **not** add it by default. An empty memo causes a spurious `+1 Memo` label in the report.

5. When the user asks to add a memo to a specific transaction identified by merchant name, date, and/or amount:
   - Locate the transaction in the correct data file by searching for matching rows. If more than one row matches, list them and ask the user to confirm which one before making changes.
   - Write the memo text into the memo column of that CSV row. If the row has no memo column, do NOT add one manually. The file format must already include a memo field in `settings.yaml`; alert the user if it does not.
   - Find the rule in `merchants.rules` that matches that transaction.
   - If the rule already covers **all** transactions for that merchant, with no date or amount filters, and other transactions for that merchant do **not** have memos, create a new **more specific** rule placed **before** the generic rule that adds `field: memo = field.memo`.
   - If the existing rule is already specific enough, or **all** transactions for that merchant have memos, simply add `field: memo = field.memo` to the existing rule if it is not already there.
   - Do **not** regenerate the report automatically after this change unless the user asks.

6. NEVER automatically generate merchant rules. If transactions do not match existing rules but you have a strong guess, list them and get confirmation before adding any rules.
   - Continue until tally reports **0** unknowns.
   - After running tally, always run `tally discover` to get the complete list of unknown transactions.
   - Do not prompt the user based on report output. Use `tally discover` as the authoritative source of unknowns.
   - If `tally discover` returns unknowns after `tally up` or any other report-generation workflow, automatically present the first batch without waiting to be asked.
   - When presenting unknown merchants for review, use a table with these exact columns: **Merchant**, **Add'l Info**, **Frequency**, **Amount**, **My Guess**.
   - **Merchant**: clean name only. NEVER include city, state, description, or parenthetical qualifiers such as `(Rochester)` or `(online)` in the Merchant column. Put that context in **Add'l Info** instead.
   - **Add'l Info**: use for clarifying context such as `Bayfield WI restaurant`, `2 txns identical`, or `online subscription`. If two rows represent the same merchant in different cities, note that here rather than in the Merchant name.
   - For payment rails and transfer-like descriptions such as `PAYPAL`, `VENMO`, `ZELLE`, `APPLE CASH`, and similar wrappers, try to extract the counterparty or merchant name from the raw description and include it in **Add'l Info**.
   - **My Guess**: before suggesting any category or subcategory, grep `merchants.rules` to enumerate the existing `category:` and `subcategory:` pairs actually used in the file. Only suggest pairs that already exist. If no existing pair fits well, suggest the closest match and flag it with a `?`.
   - Number each review-table row so the user can respond by row number.
   - Process unknowns 20 at a time unless the user specifies otherwise.
   - For each batch, present the unknowns immediately after `tally discover` in the required table format and ask for confirmation before creating any rules.
   - When creating the rules after confirmation, insert each one into its proper category section per rule **13**. Do not append to the end of the file and do not create `(continued)` or batch-named section headers.

7. Never suggest that the user should run a `tally` command to get information. If tally can provide relevant information, run the command yourself and present the results.

## Hard gate — required before any report generation

For every `tally up`, "run tally," "generate report," or equivalent request, complete Rule 8 in order. Do not run `tally up` until every filename printed by the prescribed unregistered-CSV command has been inspected and handled.

A wildcard `file:` source (such as `apple-mastercard*.csv`) does not waive this gate. For every printed file, validate its column count against the matching source format and append missing trailing fields before running Tally.

If the new CSV's header names or column order differ from the known-good file for that source, stop before `tally up`. Show the old and new header order and a proposed semantic field mapping.

Ask the user to choose:
1. Preferred: reorder the new CSV's columns and header into the known-good order, preserving every value and CSV quoting, so it continues to use the existing source format.
2. Alternative: add a separately scoped data-source block with a confirmed new format.

Do not take either action until the user confirms the mapping and choice. Do not modify the existing wildcard source block.

8. Whenever the user says `tally up`, or an equivalent such as `run tally`, `generate report`, or `do report`, do the following **before** executing `tally up`:
   - Run this PowerShell command to find CSV files not yet registered in `settings.yaml`. Do **not** do this comparison manually or from memory:

   ```powershell
   $registered = (Select-String -Path tally/config/settings.yaml -Pattern '^\s+file:\s+data/(.+)$' -AllMatches).Matches | ForEach-Object { $_.Groups[1].Value.ToLower() }
   Get-ChildItem tally/data -Filter "*.csv" -Recurse | Where-Object { $registered -notcontains $_.Name.ToLower() } | Select-Object -ExpandProperty Name
   Get-ChildItem tally/data -Filter "*.CSV" -Recurse | Where-Object { $registered -notcontains $_.Name.ToLower() } | Select-Object -ExpandProperty Name
   ```

   - Any file names printed by that command are unregistered and must be handled before proceeding.
   - For any CSV file not already present in `settings.yaml`:
      - If the file prefix matches an existing source block file prefix, such as `wellsfargo-visa-*.csv`, reuse the same format string, but first validate the column count before adding it to `settings.yaml`:
        1. Count the fields in the format string, splitting by `,` while respecting `{...}` tokens.
        2. Read the first data row of the new CSV and count its columns.
        3. If the CSV has fewer columns than the format, it is missing trailing fields. Auto-append the correct number of `,""` entries to **every row** so the column count matches. Do this silently without asking the user.
        4. Only after the CSV column count matches the format, add the source block to `settings.yaml`.
      - If the file prefix does not match any existing source block file prefix, make a guess at the account name, get confirmation from the user, then add a new source block to `settings.yaml` in alphabetical order by account name and then file name. Evaluate the file format to create the format string.
        - If there is no `memo` field in the configuration, always append both trailing `{memo}` and `{tagging}` fields to the format string. You must also modify the CSV data file by adding `,"",""` to the end of each data row. If the file has a header row, also add `,Memo,Tagging` to the end of the header row.
        - If there is more than one column that might represent the merchant, explain the format analysis and ask the user to confirm the format string.
      - **Whitespace normalization check:** after a new CSV is registered, inspect the merchant/description column in its data rows. If descriptions contain runs of multiple spaces (e.g., `T-MOBILE         PCS SVC`) while other files in the same account use single-spaced descriptions (e.g., `T-MOBILE PCS SVC`), existing `contains()` rules using literal single spaces will silently fail to match. Flag this to the user and suggest collapsing all `\s+` runs in the description column to a single space so existing rules match. Only normalize after the user confirms.
      - **CHECK description merge check:** if a new CSV has a separate check-number column (e.g., `CHECK #`) AND rows where the description is literally `CHECK` with the number in the separate column, existing rules using patterns like `contains("CHECK # 3529")` will not match because the number is not in the description. Flag this to the user and suggest rewriting the description of each such row to `CHECK # <number>` (concatenating the check-number column value) so existing rules match. Only normalize after the user confirms.
   - Always regenerate the report and open it in the browser.
   - Immediately after the report is generated, run `tally discover`. If unknowns remain, automatically present the first batch of up to 20 unknowns to the user in the required table format, using `tally discover` as the source of truth, and continue the review workflow from rule **6**.
   - For newly added files, do a second review pass for transactions that may already match existing rules but are still intentionally ambiguous and should be confirmed before trusting the current categorization:
     1. If a new `Wells Fargo Checking` row contains `ATM ` and does not already have the desired `CATEGORY:` value in the CSV tagging column, ask the user what `CATEGORY: X / Y` tag to add to that CSV row. After the CSV tag is added, if `merchants.rules` does not already have a matching non-Amazon tagging override for that exact `CATEGORY:` string, add one in the `# --- Non-Amazon category overrides ---` block.
     2. If a newly processed row matches `OFFICIAL PAYMENT WEB PMTS`, explicitly ask the user whether that specific transaction should be treated as a credit-card fee before relying on the existing rule.
     3. For mixed-use merchants that already have broad rules, specifically `Target`, `Costco`, `Walmart`, `Best Buy`, and `Lowe's`, if a transaction amount is greater than `125`, ask the user to confirm whether the existing categorization is still correct before relying on the existing rule.
     4. If a newly processed row matches `PAYPAL INST XFER`, ask the user to identify the counterparty and confirm the category/subcategory before creating a rule. These transfers often go to individuals and the purpose is not inferable from the description alone.
     5. If a newly processed row matches `AZ ADV ACH DEPOSIT`, ask the user to confirm if this is a 'Goldman Sachs 529' deposit.  The purpose is not inferable from the description alone as there may be different merchants with this transaction description. If not Goldman Sachs 529, follow steps below.
       - Review rules for any other `AZ ADV ACH DEPOSIT` transactions with tagging rules and prompt user if one applies and should be used.
       - If no existing rule, get a merchant name and category / subcategory specific to this transaction and add csv tagging of `TAG: Merchant Name` and `CATEGORY: Category / Subcategory` 
     6. If a newly processed row matches `WITHDRAWAL MADE IN A BRANCH/STORE`, always ask the user to confirm the category/subcategory before creating a rule. The purpose is never inferable from the description alone.
  - After processing is complete, if `tally/config/merchants.rules` was modified anywhere in the current `tally up` workflow, also regenerate the all-rules report from rule **10**, save it to `./tally/output/rules_report.html`, and open it in the browser.
   
9. If the user asks for a report of `rules created`, or an equivalent such as `new rules` or `session rules`, while processing a new file, use the `Visual Explainer` skill to create a report with two tables: newly created rules and remaining unknowns. Save it to `./tally/output/rules_processing_report.html` and open it in a browser. Include only rules created during the most recent `tally up` session, not all rules from `merchant.rules`. Never create a custom HTML report outside the skill workflow. If the `Visual Explainer` skill is unavailable, stop execution and warn the user.

10. If the user asks for a report of `all rules`, use the `Visual Explainer` skill and create a report of all rules from `merchant.rules` with exactly these two sections:
   1. **Rule Definitions**: the current all-rules report content, organized by rule sections/subcategories currently defined in `merchants.rules`.
   2. **Category Splitting Definitions**: group by merchant name, where each subsection contains exactly one merchant that has multiple rules with different `category:` values and/or different `tags:` definitions.
   - Only these two top-level sections are collapsible (`<details>/<summary>`). Do not make inner section/subsection blocks collapsible.
   - Keep a persistent left tree navigation visible. Clicking a tree node must auto-expand any collapsed parent section(s) before scrolling to the target anchor.
   - In section tables, use explicit columns for `Category` and `Subcategory` (not a combined `Classification` badge). For tag-only rows, leave category/subcategory cells blank.
   - **Column layout:**
     - **Rule Definitions tables**: Merchant, Match, Category, Subcategory, Tags
     - **Category Splitting Definitions tables**: Match, Category, Subcategory, Tags (no Merchant column—merchant name is in section heading)
    - Include a visible provenance marker in the HTML source comment: `Generated with Visual Explainer workflow` and follow Visual Explainer reference patterns from `templates/data-table.html` and `references/responsive-nav.md` rather than ad-hoc styling.
   - Name the tag column `Tags` and show only enabled tag badges. Do not show `No tags`, `Hidden`, or other negative/placeholder markers.
   - Make section table headers clickable to sort rows by that column within the current section table.
   - Keep column widths consistent within each section using HTML table layout (`<table>` + `<colgroup>`), not CSS grid for tabular data. Minimize wrapping in merchant/category/subcategory, allow most wrapping in match, and keep badges non-wrapping.
   - For visual badges (memo/tags/etc.), show badges only when a feature is enabled/present. Do not render placeholder badges for disabled/empty values.
   - Use the Visual Explainer skill workflow and output conventions. If direct skill command invocation is unavailable in the current agent runtime, generate an equivalent self-contained HTML report that preserves this same two-section structure and visual behavior.
   Save it to `./tally/output/rules_report.html` and open it in a browser. Never create a custom HTML report outside the skill workflow. If the `Visual Explainer` skill is unavailable, stop execution and warn the user.

11. **Amazon tagging workflow**: Amazon CSV files use a `{tagging}` column, separate from `{memo}`, to hold annotation directives. Rules check `field.tagging` for these patterns. The tagging column is never displayed in the report. Only real human notes in `{memo}` trigger the `+1 Memo` display.
   - Annotation format in the tagging column: `CATEGORY: Category / Subcategory` and/or `TAG: tagname`. Multiple `TAG:` entries are allowed, comma-separated or as separate entries.
   - Known shorthand: `CATEGORY: Health` or `CATEGORY: Health / X` resolves to `Health & Fitness`, and `Health & Fitness / X`.
   - When the user says `sync amazon rules`, or an equivalent such as `update amazon rules` or `reconcile amazon rules`:
     1. Scan all Amazon CSV files, `amazon-*.CSV` in `tally/data/`, and collect all unique `CATEGORY: X` and `TAG: xxx` values from the tagging column.
     2. Forward categories: for each `CATEGORY:` pattern not already covered by a rule in the `# --- Amazon memo-driven category overrides ---` section, apply shorthands and **confirm with the user** before creating the rule. Group new ones into a single confirmation. If a category name is unrecognized because it does not exist in `merchants.rules`, flag it explicitly for confirmation.
     3. Reverse categories: for each existing rule with `contains(field.tagging, "CATEGORY: ...")`, if that exact `CATEGORY:` string does not appear in any Amazon CSV tagging column, flag it as orphaned and ask whether to remove it.
     4. Forward tags: for each `TAG: xxx` value found, if no tag-only rule `[Amazon - * Tag]` exists for it, **confirm with the user** before creating it. The new tag-only rule format is `match: is_amazon and contains(field.tagging, "TAG: xxx")` with `tags: xxx`.
     5. Reverse tags: for each existing `[Amazon - * Tag]` rule checking `contains(field.tagging, "TAG: xxx")`, if that `TAG:` string does not appear in any Amazon CSV tagging column, flag it as orphaned and ask whether to remove it.
     6. After all confirmations and rule changes, automatically run `tally up` and open the report in the browser.

12. **Never create `[Category Override - ...]` rules.** When a non-Amazon CSV row has a `CATEGORY: X / Y` annotation in its tagging column that should override the transaction's default merchant category, add a specific rule to the `# --- Non-Amazon category overrides ---` block inside the `# === CATEGORY: tagging overrides ===` section of `merchants.rules`.
    - Bracket name: use the merchant's existing name if a rule already exists in the file; otherwise use a clean merchant name with no `Category Override` prefix.
    - Match: `contains("DESCRIPTION_PATTERN") and contains(field.tagging, "CATEGORY: X / Y")` with **no source filter**, so the override works regardless of which account the transaction appears in.
    - Include `field: memo = field.memo` only if the transaction is known to have meaningful memo content.

13. **Insert new merchant rules into the existing category section — never append new section headers.** The `merchants.rules` file has a fixed layout:
    1. Preserved infrastructure at the top, in this exact order: `Field Transforms`, `Variables`, `Tag-only rules`, `CC Payments / Transfers`, `Family Account Transfers`, `Check Number / Deposit Reference Rules`, `CATEGORY: tagging overrides`. Do not add generic merchant rules to these sections — they belong to the sections below.
    2. Below the preserved top, one section per `category:` value (e.g., `# === Auto ===`, `# === Food ===`, `# === Shopping ===`), sorted alphabetically. Each section holds every rule whose `category:` equals the section name.
      - Before adding a new rule, determine its `category:` value and insert it into that section's existing block. **Never** create a `# === X (continued) ===`, `# === Batch N ===`, `# === Q# YYYY ... ===`, or any other duplicate or batch-named section header. If the category does not yet exist as a section, create exactly one new `# === Category ===` header in the correct alphabetical position and put the rule there.
      - **Never append new rules to the end of the file.** The end-of-file position is not a valid insertion point; it only looks like one because rules were historically appended there. Always locate the correct category section first.
      - **Same-merchant pairs across categories:** when a new rule shares match text with an existing rule but has a different `category:` (e.g., `[Shell Oil]` amount > 40 → `Auto / Gas` vs `[Shell Oil]` amount < 40 → `Food / Convenience`), keep both rules adjacent inside the section of the primary/default rule (the unfiltered or most-generic one). Place a single `# Category Override` comment on the line immediately above each rule whose `category:` differs from the section's category.
      - **Within-pair order:** rules with more specific filters (`amount`, `month`, `day`, `memo`, `txn_type`) must appear before the generic rule for the same merchant. First-match-wins — a generic rule placed first will shadow the specific one.
