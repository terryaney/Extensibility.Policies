$devMode = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock" -Name "AllowDevelopmentWithoutDevLicense" -ErrorAction SilentlyContinue
if ($devMode.AllowDevelopmentWithoutDevLicense -ne 1) {
    Write-Warning "Developer Mode is not enabled. Run the following from an elevated PowerShell to enable Developer Mode and allow symlink creation:`n`n" +
		"reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1"
	exit -1
}

New-Item -ItemType Directory -Path "C:\BTR" -Force | Out-Null
New-Item -ItemType SymbolicLink -Path "C:\BTR\.editorconfig" -Target "C:\BTR\Policies\.editorconfig" -Force

# Create Terminal symlinks for all files
$wtPackage = Get-AppxPackage -Name "Microsoft.WindowsTerminal"
if ($wtPackage) {
    $wtLocalState = Join-Path $env:LOCALAPPDATA "Packages\$($wtPackage.PackageFamilyName)\LocalState"
    # Use $wtLocalState in your symlink path
	Get-ChildItem -Path "C:\BTR\Policies\Terminal" -Recurse -File | ForEach-Object {
		$relativePath = $_.FullName.Substring("C:\BTR\Policies\Terminal".Length).TrimStart("\")
		$symlinkPath = Join-Path $wtLocalState $relativePath
		$symlinkDir = Split-Path $symlinkPath
		New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
		New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force
	}
} else {
    Write-Warning "Windows Terminal not found. Skipping Terminal symlinks."
}

# Create Claude symlinks for all files
Get-ChildItem -Path "C:\BTR\Policies\Claude" -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring("C:\BTR\Policies\Claude".Length).TrimStart("\")
    $symlinkPath = Join-Path "~\.claude" $relativePath
    $symlinkDir = Split-Path $symlinkPath
    New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
    New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force
}

# Create Copilot symlinks
$copilotSource = "C:\BTR\Policies\Copilot"
$promptsTarget = "$env:APPDATA\Code\User\prompts"
$copilotTarget = "$env:USERPROFILE\.copilot"

# Delete all existing symlinks in target folders, then remove empty subfolders
foreach ($targetDir in @($promptsTarget, $copilotTarget)) {
    if (Test-Path $targetDir) {
        Get-ChildItem -Path $targetDir -Recurse -File |
            Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint } |
            Remove-Item -Force
        Get-ChildItem -Path $targetDir -Recurse -Directory |
            Sort-Object FullName -Descending |
            Where-Object { -not (Get-ChildItem $_.FullName -Force) } |
            Remove-Item -Force
    }
}

Get-ChildItem -Path $copilotSource -Recurse -File | ForEach-Object {
    $relativePath = $_.FullName.Substring($copilotSource.Length).TrimStart("\")
    $firstSegment = $relativePath.Split("\")[0]

    if ($firstSegment -eq "Skills") {
        # Skills → ~/.copilot/skills (strip "Skills\" prefix)
        $skillsRelative = $relativePath.Substring("Skills\".Length)
        $symlinkPath = Join-Path "$copilotTarget\skills" $skillsRelative
        $symlinkDir = Split-Path $symlinkPath
        New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force
    }
    elseif ($firstSegment -eq "Agents") {
        $agentsRelative = $relativePath.Substring("Agents\".Length)

        # Agents → prompts (strip "Agents\" prefix)
        $symlinkPath = Join-Path $promptsTarget $agentsRelative
        $symlinkDir = Split-Path $symlinkPath
        New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force

        # Agents → ~/.copilot/agents (strip "Agents\" prefix)
        $symlinkPath = Join-Path "$copilotTarget\agents" $agentsRelative
        $symlinkDir = Split-Path $symlinkPath
        New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force
    }
    else {
        # Root files → prompts
        $symlinkPath = Join-Path $promptsTarget $relativePath
        $symlinkDir = Split-Path $symlinkPath
        New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force

        # Root files → ~/.copilot
        $symlinkPath = Join-Path $copilotTarget $relativePath
        $symlinkDir = Split-Path $symlinkPath
        New-Item -ItemType Directory -Path $symlinkDir -Force | Out-Null
        New-Item -ItemType SymbolicLink -Path $symlinkPath -Target $_.FullName -Force
    }
}

Write-Host "Copilot symlinks updated." -ForegroundColor Green
