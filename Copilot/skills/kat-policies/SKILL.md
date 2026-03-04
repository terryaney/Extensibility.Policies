---
name: kat-policies
description: Update all the AI features (commands, skills, agents, etc.) for Claude and Copilot when a user asks to update KAT Policies (or Policy files).
---

# KAT Policies

Use the KAT Policies skill to remove all existing symbolic links in target destination folders and create new ones based on the latest KAT Policy files.

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

2.  Attempt to do a `git pull` in the `C:\BTR\Policies` folder to get the latest policy files.  If this fails (e.g., due to merge conflicts, uncommitted changes, etc.), output a warning that the latest files were not pulled from the repository and the reason why the pull failed.

3.  Execute the [script](./scripts/update.ps1) to synchronize all the symbolic links with the latest KAT Policy files.