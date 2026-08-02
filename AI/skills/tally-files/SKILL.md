

You are onboarding new CSV data files into the Tally spending configuration. Your ONLY job is to validate formats and normalize data issues before tally sees the file. Tally — not this skill — records files in `tally/config/inventory.yaml`, and it only ever appends; do not write to that file yourself. Do NOT run `tally up`, generate reports, or process unknowns — that belongs to `/tally-categorize`.

**Ordering constraint (accepted by the user):** tally registers a file in `tally/config/inventory.yaml` the moment it parses it during `tally up`. If `tally up` runs before this skill sees a file, that file will look already-registered on the next pass and never get validated here. Correct order is always: download → this skill → `/tally-categorize` (which runs `tally up`). If a file was validated out of order, recovery is to hand-delete its entry from `tally/config/inventory.yaml` so it surfaces again.

## Step 1: Find new files

Compare CSV files in `tally/data/` against `tally/config/inventory.yaml`. Any CSV whose path is not listed in the inventory is new. Run this PowerShell command — do **not** do this comparison manually or from memory:

```powershell
$inv = if (Test-Path tally/config/inventory.yaml) { (Select-String -Path tally/config/inventory.yaml -Pattern '^\s*-\s*path:\s*"?(.*?)"?\s*$').Matches | ForEach-Object { Split-Path $_.Groups[1].Value -Leaf } } else { @() }
Get-ChildItem tally/data -Filter "*.csv" | Where-Object { $inv -notcontains $_.Name } | Select-Object -ExpandProperty Name
Get-ChildItem tally/data -Filter "*.CSV" | Where-Object { $inv -notcontains $_.Name } | Select-Object -ExpandProperty Name
```

If no files are printed, tell the user: "All files are validated. To force re-validation of a file, delete its entry in `tally/config/inventory.yaml` and re-invoke this skill."

## Step 2: Determine source for each new file

Check if the filename matches any existing `file:` glob pattern in `settings.yaml` data sources.

### Matches existing glob → validate against format string

1. **Column count**: Parse the source's format string to count expected fields (split by `,` respecting `{...}` tokens). Read the first data row of the CSV and count its columns. If the CSV has fewer columns, silently append `,""`  to **every row** to match.

2. **Header check**: Read the first row. If it looks like data (not headers), generate a header row from the format string and prepend it:
   - `{date:...}` → `Date`
   - `{amount}` / `{-amount}` / `{+amount}` → `Amount`
   - `{description}` → `Description`
   - `{txn_type}` → `Type`
   - `{memo}` → `Memo`
   - `{tagging}` → `Tagging`
   - `{_}` (sequential) → `_col1`, `_col2`, ...

   If headers exist, do a semantic check: verify each header name is compatible with the format token at that position (e.g., `Transaction Date` aligns with `{date}`, `Amount (USD)` aligns with `{amount}`). If a mismatch is found, stop and show the user the expected vs. actual header mapping. Ask how to proceed before touching the file.

3. **Post-checks** (apply to Wells Fargo Checking files especially):
   - **Whitespace normalization:** If descriptions have multi-space runs while other files for the same source use single spaces, flag and suggest collapsing. Only after user confirmation.
   - **CHECK description merge:** If CSV has a check-number column AND `CHECK` description rows, flag and suggest rewriting to `CHECK # <number>`. Only after user confirmation.

4. Do not add an entry to `inventory.yaml` yourself — tally registers the file automatically the first time `tally up` parses it (see `/tally-categorize`).

5. **Notify** about any padding performed (e.g., "Padded amazon-chase-visa-2026-Q2.CSV: 7 → 8 columns, added empty Tagging").

### No glob match → new source workflow

1. Run `tally inspect <file>` to get auto-detected format (date, description, amount positions).

2. Show the user **all** CSV columns. Ask them to confirm or adjust:
   - Which columns map to which format tokens
   - Whether any existing column is `Memo` or `Tagging` (could be named `Notes`, `Comments`, etc.)
   - Do not assume — ask.

3. If `Memo` is not present in the CSV, append `{memo}` to the format string and add a `Memo` header + `,""`  to every row.

4. If `Tagging` is not present in the CSV, append `{tagging}` to the format string and add a `Tagging` header + `,""`  to every row.

5. If no header row exists, generate one from the finalized format string (same mapping as above).

6. Build the complete format string covering all columns (use `{_col1}`, `{_col2}`, etc. for unmapped columns).

7. Propose an account name and a **glob** file pattern (e.g., `data/capitalone-savings*.csv`). Ask user to confirm. User may choose exact filename instead.

8. Add the new source block to `settings.yaml` in alphabetical order by account name.

9. Apply post-checks (whitespace, CHECK merge) with confirmation.

10. Do not add an entry to `inventory.yaml` yourself — tally registers the file automatically the first time `tally up` parses it.

## Done

Tell user: "Files validated. Invoke `/tally-categorize` to run the report and process unknowns — tally will register these files in `tally/config/inventory.yaml` as it parses them."