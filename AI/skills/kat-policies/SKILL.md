# KAT Policies

Use the KAT Policies skill to remove existing KAT-managed artifacts in target destination folders and recreate them from the latest canonical policy files.

## Workflow

1. Check whether `C:\BTR\Extensibility\Policies` has a dirty working tree before any credential pre-checks.

Only attempt `git pull` when the repository is clean. Never run `git stash`, `git stash push`, or `git stash pop` as part of this workflow.

If the repository is dirty, do not pull. Warn that the latest files were not pulled because local changes are present, then continue against the current checkout.

When the repository is dirty, do not attempt remediation. Specifically: do not suggest stashing, do not call any stash tool, do not call any commit tool, do not ask whether to stash, and do not retry pull after any git state change. The workflow must continue directly against the current checkout.

If the pull is attempted and fails, warn that the latest files were not pulled and state the failure reason. Continue against the current checkout.

2. Determine whether MCP credential collection is actually required for this run.

Use the shared MCP configuration in `C:\BTR\Extensibility\Policies\AI\skills\kat-policies\meta.jsonc` plus the bootstrap helpers' `-CheckOnly -NonInteractive -PassThru` results to decide this:

- `C:\BTR\Extensibility\Policies\scripts\install-context7-remote.ps1`
- `C:\BTR\Extensibility\Policies\scripts\install-github-remote.ps1`

Only collect `CONTEXT7_API_KEY` in chat when **all** of the following are true:

- shared MCP metadata requests Context7 parity for at least one client
- at least one targeted client actually needs Context7 setup for this run
- the helper check reports Context7 as blocked by a missing environment value rather than already compliant or `no-client`

Only collect a GitHub PAT in chat when **all** of the following are true:

- shared MCP metadata requests GitHub parity for at least one client
- at least one targeted client actually needs GitHub MCP setup for this run
- the helper check reports GitHub as blocked by missing auth rather than already compliant or `no-client`

When collection is required, immediately invoke {{KAT_QUESTION_TOOL_GUIDANCE}} in chat and collect the credential there. Do not reply with narrative such as "I can't collect secrets through chat tooling safely here" and do not skip the question-tool step when the helper reported a missing credential. The prompt text must explicitly say that leaving the value blank, skipping, or cancelling means "continue without this credential". Use a single credential field and treat an empty response, skipped form, or cancelled form as "continue without credential" rather than an invalid blank that should be re-prompted. In that case, do not cancel the workflow; continue with the required non-interactive sync and let the final output report the blocked Context7 or GitHub status. After collection, save any provided value into `User` and current `Process` scope before continuing.

If a server is not configured to install, or no applicable client needs it, do not ask for its credential.

Never rely on `Read-Host` or ask the user to focus the terminal for credentials during chat-driven runs.

3. Execute the sync script using this exact path.

When the workflow is run from chat, always pass `-NonInteractive` so the script never falls back to terminal prompting.

If the user requested detailed output, pass `-Verbosity Detailed`. Otherwise omit it.

```powershell
# Normal run from chat
& "C:\BTR\Extensibility\Policies\scripts\update.ps1" -NonInteractive

# Detailed run from chat
& "C:\BTR\Extensibility\Policies\scripts\update.ps1" -NonInteractive -Verbosity Detailed
```

`update.ps1` now owns the VS Code duplicate-context safeguard using `C:\BTR\Extensibility\Policies\AI\skills\kat-policies\meta.vscode.settings.jsonc` and should apply those settings automatically during the sync. Only report a blocked reason if the settings file cannot be parsed or written.

Optional dry-run preview for MCP bootstrap checks only:

```powershell
& "C:\BTR\Extensibility\Policies\scripts\install-context7-remote.ps1" -WhatIf -NonInteractive
& "C:\BTR\Extensibility\Policies\scripts\install-github-remote.ps1" -WhatIf -NonInteractive
```

4. Keep workflow chat output minimal.

Do not send interim progress updates, preambles, or narration about what is about to run. Stay silent until the workflow finishes unless you need to report an actual failure that prevents completion.

5. Keep approval guidance concise.

If the user wants fewer VS Code prompts, explain that the supported levers are workspace trust, the chat session permission level, `chat.permissions.default`, and per-tool approvals in the chat tool approval UI. KAT Policies should not force `chat.permissions.default` globally in VS Code user settings for all chats. If the user wants a repo-specific default, that belongs in the target repository's `.vscode/settings.json` only after confirming their VS Code build honors that setting at workspace scope. Some repository-changing actions can still require platform approval by product/security policy.

## Final Response Format

Do not produce step-by-step narrative chatter.

Instead:

1. Do not add an opening summary sentence when the tables will be shown.
2. Include a git-pull warning only once. A dirty-repo no-pull case still counts as a git-pull failure/warning for the final response.
3. Re-render the script table content as real markdown tables for chat instead of pasting the raw ASCII output. Preserve the same rows/columns the script emitted. Artifact Locations appears only for detailed verbosity; Configuration Locations defaults to `Type | Status` and adds `Location` only in detailed mode.
4. Use simple status presentation in markdown tables:
   - blocked = `⛔ blocked`
   - removed = `🔴 removed`
   - excluded = `⚪ excluded`
   - other statuses, prefix with 🟢
5. For failure lines outside the tables, prefix them with `⚠️`:
   - `⚠️ Git pull failed: ...`
   - `⛔ Script failed: ...`
6. If a table cell in the script output included a superscript footnote marker such as `blocked¹`, preserve that marker in the markdown cell and include the matching footnote text below the table as markdown lines, for example `¹ CONTEXT7_API_KEY is missing...`.
7. After the tables, report only failed `.ps1` execution when that failure is not already obvious from the tables.
8. Do not restate blocked, skipped, excluded, compliant, unchanged items, or the git-pull failure after the tables when those were already reported.
9. If approvals occurred, note only that they were platform approvals rather than KAT Policies prompting for terminal input.

Formatting rules:

- Use bold section headers such as `**MCP Server Deployment Status**` and `**Configuration Locations**`.
- Do **not** paste raw console borders such as `+-----+`, `| col |`, or `--- Title ---`.
- Emit markdown table syntax directly, for example:

```md
**MCP Server Deployment Status**

| MCP Server | VS Code | CLI | Claude |
| --- | --- | --- | --- |
| Context7 | ❌ blocked¹ | ❌ blocked¹ | ❌ blocked¹ |
| GitHub | installed | installed | installed |

¹ CONTEXT7_API_KEY is missing in Process/User/Machine scope.
```
