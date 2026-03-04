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

# Delete all existing symlinks and KAT-managed agent copies in target folders, then remove empty subfolders
foreach ($targetDir in @($promptsTarget, $copilotTarget)) {
    if (Test-Path $targetDir) {
        Get-ChildItem -Path $targetDir -Recurse -File | Where-Object {
            ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) -or
            (Get-Item -Path $_.FullName -Stream CreatedBy -ErrorAction SilentlyContinue)
        } | Remove-Item -Force
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

        # Agents → prompts (copy as-is for VS Code)
        $copyPath = Join-Path $promptsTarget $agentsRelative
        $copyDir = Split-Path $copyPath
        New-Item -ItemType Directory -Path $copyDir -Force | Out-Null
        Copy-Item -Path $_.FullName -Destination $copyPath -Force
        Set-Content -Path $copyPath -Stream CreatedBy -Value "KAT"

        # Agents → ~/.copilot/agents (copy with model name mapping for CLI)
        $copyPath = Join-Path "$copilotTarget\agents" $agentsRelative
        $copyDir = Split-Path $copyPath
        New-Item -ItemType Directory -Path $copyDir -Force | Out-Null
        $content = Get-Content -Path $_.FullName -Raw
        # Map VS Code model names to CLI model names
        $content = $content -replace 'model:\s*GPT-5\.3-Codex \(copilot\)', 'model: gpt-5.3-codex'
        $content = $content -replace 'model:\s*Gemini 3 Pro \(Preview\) \(copilot\)', 'model: gemini-3-pro-preview'
        $content = $content -replace 'model:\s*Claude Opus 4\.6 \(copilot\)', 'model: claude-opus-4.6'
        $content = $content -replace 'model:\s*Claude Sonnet 4\.6 \(copilot\)', 'model: claude-sonnet-4.6'
        # Strip VS Code-only YAML fields: agents and handoffs (including nested lines)
        $content = $content -replace '(?m)^agents:\s*\[.*\]\r?\n', ''
        $content = $content -replace '(?ms)^handoffs:\r?\n(^\s+.*\r?\n)*', ''
        Set-Content -Path $copyPath -Value $content -NoNewline
        Set-Content -Path $copyPath -Stream CreatedBy -Value "KAT"
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
