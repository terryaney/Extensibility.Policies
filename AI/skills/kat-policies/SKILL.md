# KAT Policies

Use the KAT Policies skill to remove all existing 'KAT Managed' files in target destination folders and create new ones based on the latest KAT Policy files.

## Workflow

1. Check to confirm the Developer Mode status on Windows is enabled.  

```powershell
Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty AllowDevelopmentWithoutDevLicense
```

If value is not 1, prompt user to enable by running the following command in an elevated Terminal/PowerShell, then re-run the workflow after enabling Developer Mode.

```powershell
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name "AllowDevelopmentWithoutDevLicense" -Value 1 -Type DWord -Force
```

Stop processing if Developer Mode is not enabled.

2. Before any step that could otherwise fall back to terminal-sensitive input, determine whether MCP credential collection is actually required for this run.

Use the shared MCP configuration in `C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\meta.jsonc` plus the MCP bootstrap helpers' `-CheckOnly -NonInteractive -PassThru` results to decide this.

Only collect `CONTEXT7_API_KEY` in chat when **all** of the following are true:
- shared MCP metadata requests Context7 parity for at least one client
- at least one targeted client actually needs Context7 setup for this run
- the helper check indicates Context7 is blocked by a missing environment value rather than already compliant or `no-client`

Only collect a GitHub PAT in chat when **all** of the following are true:
- shared MCP metadata requests GitHub parity for at least one client
- at least one targeted client actually needs GitHub MCP setup for this run
- the helper check indicates GitHub setup is blocked by missing auth rather than already compliant or `no-client`

When collection is required, use {{KAT_QUESTION_TOOL_GUIDANCE}} to collect the value in chat, then save it into `User` and current `Process` scope before continuing.

If a server is not configured to install, or no applicable client needs it, do not ask for its credential.

Never rely on `Read-Host` or ask the user to focus the terminal for these values during chat-driven runs.

3. Attempt to do a `git pull` in the `C:\BTR\Extensibility\Policies` folder to get the latest policy files.

Before running the pull, tell the user that VS Code may still ask for approval for shell execution or repository-changing actions and that this is a platform/security approval rather than a KAT Policies prompt.

If the pull fails (for example due to merge conflicts or uncommitted changes), output a warning that the latest files were not pulled from the repository and the reason why the pull failed.

4. Execute the following script to synchronize all target locations with the latest KAT Policy files. Use this exact path directly — do not search for the script or substitute a different path.

When the workflow is being run from chat, always pass `-NonInteractive` so the script never falls back to terminal prompting for credentials.

If the user requested detailed or verbose output (e.g. "detailed", "with details", "verbose", "/kat-policies detailed"), pass `-Verbosity Detailed`. Otherwise omit the parameter (defaults to `Normal`).

```powershell
# Normal run from chat
& "C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\update.ps1" -NonInteractive

# Detailed run from chat — shows additional diagnostic entries such as repo-scoped artifacts whose target repository does not exist
& "C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\update.ps1" -NonInteractive -Verbosity Detailed
```

`update.ps1` automatically runs the remote-only Context7 bootstrap helper when canonical metadata requires Context7 parity. This bootstrap always requires `CONTEXT7_API_KEY` in environment scope (`Process`, `User`, or `Machine`) and fails fast when missing.

`update.ps1` also runs the GitHub MCP bootstrap helper when canonical metadata requires `github/*` tool parity. The helper enforces remote GitHub MCP where possible: VS Code is set to remote HTTP (`https://api.githubcopilot.com/mcp/`), Copilot CLI is configured to a non-readonly remote override (`github-mcp-server`) with PAT auth when available or host OAuth best effort when PAT is missing, and Claude is configured remote-first while preserving an existing local fallback when PAT auth is unavailable.

When GitHub PAT variables are missing, the helper now prints explicit setup guidance, warns that auth is still required, and tells the user to set `GITHUB_TOKEN` in User scope.

Copilot CLI and Claude artifacts are created only when those clients are detected as installed. If a client is absent, the helper reports status `no-client` and does not create that client's artifacts.

Optional dry run preview for MCP bootstrap checks only (no file writes):

```powershell
& "C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\install-context7-remote.ps1" -WhatIf -NonInteractive
& "C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\install-github-remote.ps1" -WhatIf -NonInteractive
```

5. Try to review the users VS Code User Settings. VS Code's Copilot tries to read AI primitives in the 'Claude' and 'Copilot CLI' folders too, so the following settings should be applied to eliminate duplicates.

```json
	"workbench.browser.openLocalhostLinks": true,
	"workbench.browser.enableChatTools": true,
	"chat.agentFilesLocations": {
		".claude/agents": false,
		"~/.claude/agents": false,
		"~/.copilot/agents": false
	},
	"chat.agentSkillsLocations": {
		".claude/skills": false,
		"~/.claude/skills": false
	},
	"chat.instructionsFilesLocations": {
		".claude/rules": false,
		"~/.claude/rules": false,
		"~/.copilot/instructions": false,
		"~/AppData/Roaming/Code/User/instructions": true
	},
```

If you are able to confirm these settings do not match, prompt the user if they want you to apply them automatically explaining that VS Code Copilot Chat extension will show duplicate Agents and also send duplicated context instructions if not set.  If they do not want them set, just tell them exactly what settings should be set to eliminate problems.

## Final Response Format

Do not end with vague bullets such as “AI artifacts installed.”

Instead, produce:

1. A short workflow status table with columns similar to:
   - Step
   - Status
   - Details

2. An artifact/location table derived from the script output with columns similar to:
   - Artifact Type
   - Client
   - Location

3. If something was skipped, blocked, or unchanged, say exactly what and why.

4. If approvals were required, note whether they were platform approvals (for example shell execution / file write approval) rather than KAT Policies asking for terminal input.
