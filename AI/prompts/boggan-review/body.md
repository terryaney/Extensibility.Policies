Run a multi-model code review:

1. Invoke three parallel subagents using Opus, Gemini, and Codex.
2. Cross-grade: have each reviewer evaluate the other two reviews for false positives and missed issues
3. Synthesize a deduplicated list of findings ordered by severity (Critical > Major > Minor > Nit)
4. Output one final fix list with file, line, and suggested change for each item

# Output Format

```markdown
## Summary
One-sentence summary of the overall change quality.

## Findings
### [Severity] Title
**File:** `path/to/file.ts:L42`
**Issue:** Description of the problem and why it matters.
**Suggestion:** Concrete fix or approach.

## Verdict
APPROVE | REQUEST_CHANGES | NEEDS_DISCUSSION
```