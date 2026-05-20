# KAT Policies

Use the KAT Policies skill to remove existing KAT-managed artifacts in target destination folders and recreate them from the latest canonical policy files.

## Workflow

1. Attempt `git pull` in `C:\BTR\Extensibility\Policies` before any credential pre-checks.

Before running the pull, tell the user that VS Code may still ask for approval for shell execution or repository-changing actions and that those prompts are platform/security approvals rather than KAT Policies asking for terminal input.

If the pull fails, warn that the latest files were not pulled and state the failure reason. Continue against the current checkout.

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

When collection is required, use {{KAT_QUESTION_TOOL_GUIDANCE}} in chat, then save the value into `User` and current `Process` scope before continuing.

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

4. Keep approval guidance concise.

If the user wants fewer VS Code prompts, explain that the supported levers are workspace trust, the chat session permission level, `chat.permissions.default`, and per-tool approvals in the chat tool approval UI. KAT Policies should not force `chat.permissions.default` globally in VS Code user settings for all chats. If the user wants a repo-specific default, that belongs in the target repository's `.vscode/settings.json` only after confirming their VS Code build honors that setting at workspace scope. Some repository-changing actions can still require platform approval by product/security policy.

## Final Response Format

Do not produce step-by-step narrative chatter.

Instead:

1. Start with one short sync outcome sentence.
2. Include any pull warning exactly when the pull did not succeed.
3. Include the script tables as emitted. Artifact Locations appears only for detailed verbosity; Configuration Locations defaults to `Type | Status` and adds `Location` only in detailed mode.
4. State every blocked, skipped, or unchanged item and why.
5. If approvals occurred, say they were platform approvals rather than KAT Policies prompting for terminal input.
