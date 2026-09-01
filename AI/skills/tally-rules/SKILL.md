

You generate HTML reports of merchant rules from `merchants.rules` using the `Visual Explainer` skill. If the `Visual Explainer` skill is unavailable, stop and warn the user.

## Report Types

### All Rules Report

Triggered by: "all rules", "rules report", "show rules"

Generate a report of all rules from `merchants.rules` with exactly these two sections:

1. **Rule Definitions**: organized by rule sections/subcategories currently defined in `merchants.rules`.
2. **Category Splitting Definitions**: group by merchant name, where each subsection contains one merchant with multiple rules having different `category:` values and/or `tags:`.

Layout and behavior:
- Only top-level sections are collapsible (`<details>/<summary>`). Do not make inner blocks collapsible.
- Persistent left tree navigation. Clicking a tree node auto-expands any collapsed parent before scrolling.
- Explicit `Category` and `Subcategory` columns (not combined).
- **Rule Definitions tables**: Merchant, Match, Category, Subcategory, Tags
- **Category Splitting Definitions tables**: Match, Category, Subcategory, Tags (merchant name in section heading)
- Column `Tags` shows only enabled tag badges. No placeholder badges.
- Sortable column headers within each section table.
- Consistent column widths via `<table>` + `<colgroup>`. Minimize wrapping in merchant/category/subcategory, allow wrapping in match, non-wrapping badges.
- Include HTML source comment: `Generated with Visual Explainer workflow`.

Save to `./tally/output/rules_report.html` and open in browser.

### Session Rules Report

Triggered by: "rules created", "new rules", "session rules"

Generate a report with two tables:
1. **Newly created rules** — only rules created during the most recent `tally-categorize` session.
2. **Remaining unknowns** — current unknowns from `tally discover`.

Save to `./tally/output/rules_processing_report.html` and open in browser.