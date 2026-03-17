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

2.  Attempt to do a `git pull` in the `C:\BTR\Extensibility\Policies` folder to get the latest policy files.  If this fails (e.g., due to merge conflicts, uncommitted changes, etc.), output a warning that the latest files were not pulled from the repository and the reason why the pull failed.

3.  Execute the following script to synchronize all target locations with the latest KAT Policy files. Use this exact path directly — do not search for the script or substitute a different path.

```powershell
& "C:\BTR\Extensibility\Policies\AI\skills\kat-policies\scripts\update.ps1"
```

4. Try to review the users VS Code User Settings.  VS Code's Copilot tries to read AI primitives in the 'Claude' and 'Copilot CLI' folders too, so the following settings should be applied to eliminate duplicates.

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