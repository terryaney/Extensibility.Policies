Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$devMode = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
if ($devMode.AllowDevelopmentWithoutDevLicense -ne 1) {
    Write-Warning "Developer Mode is not enabled. Run the following from an elevated PowerShell to enable Developer Mode and allow symlink creation:`n`n" +
        'reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1'
    exit -1
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$aiRoot = Join-Path $repoRoot 'AI'

$compatibilityMessages = New-Object System.Collections.Generic.List[string]
$blockedPaths = New-Object System.Collections.Generic.List[string]
$deploymentRecords = New-Object System.Collections.Generic.List[object]
$script:claudeContext7Configured = $null

function Add-Warning {
    param([string]$Message)

    if (-not [string]::IsNullOrWhiteSpace($Message) -and -not $compatibilityMessages.Contains($Message)) {
        $compatibilityMessages.Add($Message)
    }
}

function Add-BlockedPath {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not $blockedPaths.Contains($Path)) {
        $blockedPaths.Add($Path)
    }
}

function Add-DeploymentRecord {
    param(
        [string]$Category,
        [string]$Id,
        [string]$Target,
        [string]$Status,
        [string]$Path = $null,
        [string]$Detail = $null
    )

    $deploymentRecords.Add([pscustomobject]@{
        Category = $Category
        Id = $Id
        Target = $Target
        Status = $Status
        Path = $Path
        Detail = $Detail
    })
}

function Invoke-PolicySync {
    New-Item -ItemType Directory -Path 'C:\BTR' -Force | Out-Null

    $vscodeRoot = Join-Path $env:APPDATA 'Code\User'
    $copilotRoot = Join-Path $env:USERPROFILE '.copilot'
    $claudeRoot = Join-Path $env:USERPROFILE '.claude'

    $wtPackage = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
    $terminalRoot = $null
    if ($wtPackage) {
        $terminalRoot = Join-Path $env:LOCALAPPDATA "Packages\$($wtPackage.PackageFamilyName)\LocalState"
    }
    else {
        Add-Warning 'Windows Terminal not found. Skipping Terminal file sync.'
    }

    $managedContexts = @(
        @{ Root = 'C:\BTR'; ScanRoots = @((Join-Path 'C:\BTR' '.editorconfig')) },
        @{ Root = $vscodeRoot; ScanRoots = @((Join-Path $vscodeRoot 'prompts'), (Join-Path $vscodeRoot 'instructions')) },
        @{ Root = $copilotRoot; ScanRoots = @((Join-Path $copilotRoot 'agents'), (Join-Path $copilotRoot 'instructions'), (Join-Path $copilotRoot 'skills')) },
        @{ Root = $claudeRoot; ScanRoots = @((Join-Path $claudeRoot 'agents'), (Join-Path $claudeRoot 'instructions'), (Join-Path $claudeRoot 'rules'), (Join-Path $claudeRoot 'skills'), (Join-Path $claudeRoot 'commands'), (Join-Path $claudeRoot 'CLAUDE.md')) }
    )

    if ($terminalRoot) {
        $managedContexts += @{ Root = $terminalRoot; ScanRoots = @($terminalRoot) }
    }

    foreach ($context in $managedContexts) {
        Clear-ManagedRoot -Root $context.Root -ScanRoots $context.ScanRoots -RepositoryRoot $repoRoot
    }

    $editorConfigPath = 'C:\BTR\.editorconfig'
    $editorConfigSucceeded = Write-ManagedSymlink -Path $editorConfigPath -Target (Join-Path $repoRoot '.editorconfig')
    Add-DeploymentRecord -Category 'link' -Id '.editorconfig' -Target 'btr' -Status $(if ($editorConfigSucceeded) { 'ok' } else { 'blocked' }) -Path $editorConfigPath

    if ($terminalRoot) {
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Terminal') -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring((Join-Path $repoRoot 'Terminal').Length).TrimStart('\')
            $targetPath = Join-Path $terminalRoot $relativePath
            $targetSucceeded = Copy-ManagedFile -Path $targetPath -SourcePath $_.FullName
            Add-DeploymentRecord -Category 'link' -Id ('Terminal/' + ($relativePath -replace '\\', '/')) -Target 'terminal' -Status $(if ($targetSucceeded) { 'ok' } else { 'blocked' }) -Path $targetPath
        }
    }
    else {
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Terminal') -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $relativePath = $_.FullName.Substring((Join-Path $repoRoot 'Terminal').Length).TrimStart('\')
            Add-DeploymentRecord -Category 'link' -Id ('Terminal/' + ($relativePath -replace '\\', '/')) -Target 'terminal' -Status 'skipped' -Path $null -Detail 'windows-terminal-not-found'
        }
    }

    foreach ($agentDir in Get-AgentDirectories) {
        $meta = Read-CanonicalMeta -Path (Get-CanonicalMetaPath -Directory $agentDir)
        $body = Get-Content -LiteralPath (Join-Path $agentDir.FullName 'body.md') -Raw
        $enabled = Get-Prop $meta 'enabled'
        $id = Get-Prop $meta 'id' $agentDir.Name
        $claudeMeta = Get-Prop $meta 'claude'

        if (ConvertTo-BoolValue (Get-Prop $enabled 'vscode') $true) {
            $path = Join-Path (Join-Path $vscodeRoot 'prompts') ($id + '.agent.md')
            $content = ConvertTo-CopilotAgentDocument -Meta $meta -Body $body -Client 'vscode'
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilotCli') $true) {
            $path = Join-Path (Join-Path $copilotRoot 'agents') ($id + '.agent.md')
            $content = ConvertTo-CopilotAgentDocument -Meta $meta -Body $body -Client 'copilotCli'
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $claudeTarget = Get-Prop $claudeMeta 'target' 'agent'
            $claudeFolder = if ($claudeTarget -eq 'command') { 'commands' } else { 'agents' }
            $path = Join-Path (Join-Path $claudeRoot $claudeFolder) ($id + '.md')
            $content = ConvertTo-ClaudeAgentDocument -Meta $meta -Body $body
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status 'disabled'
        }
    }

    $claudeImports = New-Object System.Collections.Generic.List[string]
    $claudeImportIds = New-Object System.Collections.Generic.List[string]
    foreach ($instructionDir in Get-InstructionDirectories) {
        $meta = Read-CanonicalMeta -Path (Get-CanonicalMetaPath -Directory $instructionDir)
        $body = Get-Content -LiteralPath (Join-Path $instructionDir.FullName 'body.md') -Raw
        $enabled = Get-Prop $meta 'enabled'
        $id = Get-Prop $meta 'id' $instructionDir.Name

        if (ConvertTo-BoolValue (Get-Prop $enabled 'vscode') $true) {
            $path = Join-Path (Join-Path $vscodeRoot 'instructions') ($id + '.instructions.md')
            $content = ConvertTo-CopilotInstructionDocument -Meta $meta -Body $body
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilotCli') $true) {
            $path = Join-Path (Join-Path $copilotRoot 'instructions') ($id + '.instructions.md')
            $content = ConvertTo-CopilotInstructionDocument -Meta $meta -Body $body
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claudeInstruction') $true) {
            $path = Join-Path (Join-Path $claudeRoot 'instructions') ($id + '.md')
            $succeeded = Write-ManagedFile -Path $path -Content $body
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeInstruction' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeInstruction' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claudeRule') $true) {
            $path = Join-Path (Join-Path $claudeRoot 'rules') ($id + '.md')
            $content = ConvertTo-ClaudeRuleDocument -Meta $meta -Body $body
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeRule' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeRule' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claudeImport') $true) {
            $claudeImports.Add("@instructions/$id.md")
            $claudeImportIds.Add($id)
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeImport' -Status 'disabled'
        }
    }

    foreach ($skillDir in Get-SkillDirectories) {
        $meta = Get-SkillMeta -Directory $skillDir
        $enabled = Get-Prop $meta 'enabled'
        $id = Get-Prop $meta 'id' $skillDir.Name
        $claudeMeta = Get-Prop $meta 'claude'

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilot') $true) {
            $succeeded = Install-RenderedSkill -Root $copilotRoot -SkillDirectory $skillDir -Meta $meta
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path (Join-Path (Join-Path $copilotRoot 'skills') $id)
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $succeeded = Install-RenderedSkill -Root $claudeRoot -SkillDirectory $skillDir -Meta $meta
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path (Join-Path (Join-Path $claudeRoot 'skills') $id)

            if (ConvertTo-BoolValue (Get-Prop $claudeMeta 'exposeCommands') (Test-Path -LiteralPath (Join-Path $skillDir.FullName 'commands'))) {
                $commandsDir = Join-Path $skillDir.FullName 'commands'
                if (Test-Path -LiteralPath $commandsDir) {
                    Get-ChildItem -LiteralPath $commandsDir -File -Filter '*.md' | ForEach-Object {
                        $path = Join-Path (Join-Path $claudeRoot 'commands') $_.Name
                        Write-ManagedSymlink -Path $path -Target $_.FullName | Out-Null
                    }
                }
            }
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status 'disabled'
        }
    }

    $claudeDocument = @(
        '# Generated by KAT Policies',
        '',
        "Edit canonical instructions under $repoRoot\\AI\\instructions.",
        ''
    ) + ($claudeImports | Sort-Object -Unique)
    $claudeDocumentPath = Join-Path $claudeRoot 'CLAUDE.md'
    $claudeDocumentSucceeded = Write-ManagedFile -Path $claudeDocumentPath -Content ($claudeDocument -join "`r`n")
    Add-DeploymentRecord -Category 'link' -Id 'CLAUDE.md' -Target 'claudeDoc' -Status $(if ($claudeDocumentSucceeded) { 'ok' } else { 'blocked' }) -Path $claudeDocumentPath -Detail ("imports=" + $claudeImportIds.Count)
    foreach ($instructionId in $claudeImportIds) {
        Add-DeploymentRecord -Category 'instruction' -Id $instructionId -Target 'claudeImport' -Status $(if ($claudeDocumentSucceeded) { 'ok' } else { 'blocked' }) -Path $claudeDocumentPath
    }

    Write-Host 'KAT policies synchronized.' -ForegroundColor Green
	Write-Host ''

    Write-DeploymentMatrix
    Write-CompatibilitySummary

    if ($blockedPaths.Count -gt 0) {
        Write-Host 'Manual cleanup required. Delete these pre-existing paths if you want KAT Policies to take ownership:' -ForegroundColor Red
        $blockedPaths | Sort-Object -Unique | ForEach-Object {
            Write-Host " - $_" -ForegroundColor Red
        }
    }
}

function New-AsciiBorder {
    param(
        [int[]]$Widths,
        [int]$Padding = 1
    )

    $segments = foreach ($width in $Widths) {
        '-' * ($width + ($Padding * 2))
    }

    return '+' + ($segments -join '+') + '+'
}

function Split-AsciiCell {
    param(
        [string]$Value,
        [int]$Width
    )

    if ($Width -le 0) {
        return @('')
    }

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $logicalLines = @($text -split "`r?`n")
    $outputLines = New-Object System.Collections.Generic.List[string]

    foreach ($line in $logicalLines) {
        if ([string]::IsNullOrEmpty($line)) {
            $outputLines.Add('')
            continue
        }

        for ($offset = 0; $offset -lt $line.Length; $offset += $Width) {
            $segmentLength = [Math]::Min($Width, $line.Length - $offset)
            $outputLines.Add($line.Substring($offset, $segmentLength))
        }
    }

    if ($outputLines.Count -eq 0) {
        $outputLines.Add('')
    }

    return @($outputLines)
}

function Format-AsciiCell {
    param(
        [string]$Value,
        [int]$Width,
        [ValidateSet('left', 'center', 'status')]
        [string]$Alignment = 'left',
        [int]$Padding = 1
    )

    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    $effectiveAlignment = $Alignment
    if ($Alignment -eq 'status') {
        if ($text -in @('ok', '--', 'off', 'skip')) {
            $effectiveAlignment = 'center'
        }
        else {
            $effectiveAlignment = 'left'
        }
    }

    switch ($effectiveAlignment) {
        'center' {
            $leftPad = [Math]::Floor(($Width - $text.Length) / 2)
            $rightPad = $Width - $text.Length - $leftPad
            return (' ' * $Padding) + (' ' * $leftPad) + $text + (' ' * $rightPad) + (' ' * $Padding)
        }
        default {
            return (' ' * $Padding) + $text.PadRight($Width) + (' ' * $Padding)
        }
    }
}

function Format-AsciiRow {
    param(
        [string[]]$Values,
        [int[]]$Widths,
        [string[]]$Alignments,
        [int]$Padding = 1
    )

    $cells = for ($index = 0; $index -lt $Widths.Count; $index++) {
        $value = ''
        if ($index -lt $Values.Count -and $null -ne $Values[$index]) {
            $value = [string]$Values[$index]
        }

        $alignment = 'left'
        if ($index -lt $Alignments.Count -and -not [string]::IsNullOrWhiteSpace($Alignments[$index])) {
            $alignment = $Alignments[$index]
        }

        Format-AsciiCell -Value $value -Width $Widths[$index] -Alignment $alignment -Padding $Padding
    }

    return '|' + ($cells -join '|') + '|'
}

function Write-AsciiTable {
    param(
        [string]$Title,
        [string[]]$Headers,
        [object[]]$Rows,
        [string]$Color = 'Cyan',
        [int[]]$FixedWidths = @(),
        [string[]]$Alignments = @(),
        [int]$Padding = 1,
        [string[]]$HeaderAlignments = @(),
        [bool]$RowDividers = $false
    )

    if ($Rows.Count -eq 0) {
        return
    }

    $normalizedRows = foreach ($row in $Rows) {
        [pscustomobject]@{
            Cells = @($row.Cells)
        }
    }

    $widths = for ($index = 0; $index -lt $Headers.Count; $index++) {
        $fixedWidth = $null
        if ($index -lt $FixedWidths.Count -and $FixedWidths[$index] -gt 0) {
            $fixedWidth = $FixedWidths[$index]
            $maxWidth = $fixedWidth
        }
        else {
            $maxWidth = $Headers[$index].Length
        }

        foreach ($row in $normalizedRows) {
            $rowValues = @($row.Cells)
            $value = ''
            if ($index -lt $rowValues.Count -and $null -ne $rowValues[$index]) {
                $value = [string]$rowValues[$index]
            }

            $lines = if ($null -ne $fixedWidth) { Split-AsciiCell -Value $value -Width $fixedWidth } else { @($value -split "`r?`n") }
            foreach ($line in $lines) {
                if ($line.Length -gt $maxWidth) {
                    $maxWidth = $line.Length
                }
            }
        }

        $maxWidth
    }

    $headerAlignmentValues = if ($HeaderAlignments.Count -gt 0) {
        $HeaderAlignments
    }
    else {
        foreach ($header in $Headers) { 'left' }
    }

    $border = New-AsciiBorder -Widths $widths -Padding $Padding
    if (-not [string]::IsNullOrWhiteSpace($Title)) {
        Write-Host $Title -ForegroundColor $Color
    }
    Write-Host $border -ForegroundColor $Color
    Write-Host (Format-AsciiRow -Values $Headers -Widths $widths -Alignments $headerAlignmentValues -Padding $Padding) -ForegroundColor $Color
    Write-Host $border -ForegroundColor $Color
    foreach ($row in $normalizedRows) {
        $rowCells = @($row.Cells)
        $wrappedCells = for ($index = 0; $index -lt $widths.Count; $index++) {
            $value = ''
            if ($index -lt $rowCells.Count -and $null -ne $rowCells[$index]) {
                $value = [string]$rowCells[$index]
            }

            [pscustomobject]@{
                Lines = @(Split-AsciiCell -Value $value -Width $widths[$index])
            }
        }

        $rowHeight = 1
        foreach ($cell in $wrappedCells) {
            if (@($cell.Lines).Count -gt $rowHeight) {
                $rowHeight = @($cell.Lines).Count
            }
        }

        for ($lineIndex = 0; $lineIndex -lt $rowHeight; $lineIndex++) {
            $lineValues = for ($columnIndex = 0; $columnIndex -lt $widths.Count; $columnIndex++) {
                $cellLines = @($wrappedCells[$columnIndex].Lines)
                if ($lineIndex -lt $cellLines.Count) {
                    $cellLines[$lineIndex]
                }
                else {
                    ''
                }
            }

            Write-Host (Format-AsciiRow -Values $lineValues -Widths $widths -Alignments $Alignments -Padding $Padding) -ForegroundColor $Color
        }

        if ($RowDividers) {
            Write-Host $border -ForegroundColor $Color
        }
    }

    if (-not $RowDividers) {
        Write-Host $border -ForegroundColor $Color
    }
}

function Write-DeploymentMatrix {
    if ($deploymentRecords.Count -eq 0) {
        return
    }

    $categoryLabels = @{
        agent = 'Agents'
        instruction = 'Instructions'
        skill = 'Skills'
        link = 'Links'
    }
    $targetLabels = @{
        vscode = 'vscode'
        copilotCli = 'cli'
        claude = 'claude'
        claudeInstruction = 'cInst'
        claudeRule = 'cRule'
        claudeImport = 'import'
        copilot = 'copilot'
        btr = 'btr'
        terminal = 'terminal'
        claudeDoc = 'claudeDoc'
    }
    $statusLabels = @{
        ok = 'ok'
        blocked = 'blocked'
        disabled = 'off'
        skipped = 'skip'
    }
    $targetOrder = @{
        agent = @('vscode', 'copilotCli', 'claude')
        instruction = @('vscode', 'copilotCli', 'claudeInstruction', 'claudeRule', 'claudeImport')
        skill = @('copilot', 'claude')
        link = @('btr', 'terminal', 'claudeDoc')
    }

    Write-Host '--- Deployment Matrix ---' -ForegroundColor Cyan
	Write-Host ''

    $isFirstTable = $true
    foreach ($category in @('agent', 'instruction', 'skill', 'link')) {
        $records = @($deploymentRecords | Where-Object Category -eq $category)
        if ($records.Count -eq 0) {
            continue
        }

        if (-not $isFirstTable) {
            Write-Host ''
        }

        $groups = $records | Group-Object Id | Sort-Object Name
        $headers = @('artifact') + @($targetOrder[$category] | ForEach-Object { $targetLabels[$_] })
        $rows = foreach ($group in $groups) {
            $values = @($group.Name)
            foreach ($target in $targetOrder[$category]) {
                $record = $group.Group | Where-Object Target -eq $target | Select-Object -First 1
                if ($null -eq $record) {
                    $values += '--'
                    continue
                }

                $status = $statusLabels[$record.Status]
                if ([string]::IsNullOrWhiteSpace($status)) {
                    $status = $record.Status
                }

                if (-not [string]::IsNullOrWhiteSpace($record.Detail) -and $record.Status -ne 'ok') {
                    $status = "$status($($record.Detail))"
                }

                $values += $status
            }

            [pscustomobject]@{
                Cells = $values
            }
        }

        $fixedWidths = @(40)
        $alignments = @('left')
        foreach ($target in $targetOrder[$category]) {
            $fixedWidths += 12
            $alignments += 'status'
        }

        $headerAlignments = @('left')
        foreach ($target in $targetOrder[$category]) {
            $headerAlignments += 'center'
        }

        Write-AsciiTable -Title $categoryLabels[$category] -Headers $headers -Rows $rows -Color 'Cyan' -FixedWidths $fixedWidths -Alignments $alignments -HeaderAlignments $headerAlignments
        $isFirstTable = $false
    }
	Write-Host ''
}

function Write-CompatibilitySummary {
    if ($compatibilityMessages.Count -eq 0) {
        return
    }

    $rollups = [ordered]@{
        'Context7-to-Claude gaps' = New-Object System.Collections.Generic.SortedSet[string]
        'Copilot orchestration omitted in Claude' = New-Object System.Collections.Generic.SortedSet[string]
        'GitHub tools mapped to Bash/WebFetch' = New-Object System.Collections.Generic.SortedSet[string]
        'VS Code-only tools ignored in Claude' = New-Object System.Collections.Generic.SortedSet[string]
    }
    $otherMessages = New-Object System.Collections.Generic.List[string]

    foreach ($message in ($compatibilityMessages | Sort-Object -Unique)) {
        if ($message -notmatch '^([^:]+):\s*(.+)$') {
            $otherMessages.Add($message)
            continue
        }

        $artifact = $Matches[1]
        $detail = $Matches[2]
        switch -Wildcard ($detail) {
            'Context7 has no native Claude tool equivalent*' {
                $null = $rollups['Context7-to-Claude gaps'].Add($artifact)
            }
            'Copilot orchestration fields were omitted from Claude rendering*' {
                $null = $rollups['Copilot orchestration omitted in Claude'].Add($artifact)
            }
            'GitHub-specific Copilot tools were mapped to Claude Bash/WebFetch*' {
                $null = $rollups['GitHub tools mapped to Bash/WebFetch'].Add($artifact)
            }
            'VS Code-only tools are ignored for Claude rendering.' {
                $null = $rollups['VS Code-only tools ignored in Claude'].Add($artifact)
            }
            default {
                $otherMessages.Add($message)
            }
        }
    }

    Write-Host '--- Compatibility Summary ---' -ForegroundColor Yellow
    $summaryRows = foreach ($label in $rollups.Keys) {
        $items = @($rollups[$label])
        if ($items.Count -eq 0) {
            continue
        }

        [pscustomobject]@{
            Cells = @("$label ($($items.Count))", ($items -join "`n"))
        }
    }

    if ($otherMessages.Count -gt 0) {
        $summaryRows += [pscustomobject]@{
            Cells = @("Other ($($otherMessages.Count))", (($otherMessages | Sort-Object -Unique) -join "`n"))
        }
    }

    if (@($summaryRows).Count -gt 0) {
        Write-AsciiTable -Title '' -Headers @('category', 'artifact') -Rows $summaryRows -Color 'Yellow' -Padding 2 -RowDividers $true
        Write-Host ''
    }
}

function Remove-AlternateDataStream {
    param(
        [string]$Path,
        [string]$StreamName
    )

    if (-not ('KatNativeMethods' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class KatNativeMethods {
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool DeleteFile(string lpFileName);
}
'@
    }

    try {
        $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
        $streamPath = '\\?\' + $resolvedPath + ':' + $StreamName
        $deleted = [KatNativeMethods]::DeleteFile($streamPath)
        if ($deleted) {
            return $true
        }

        $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        return $errorCode -in @(2, 3)
    }
    catch {
        return $false
    }
}

function Get-Prop {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) {
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) {
        return $Default
    }

    return $property.Value
}

function ConvertTo-BoolValue {
    param(
        [object]$Value,
        [bool]$Default = $false
    )

    if ($null -eq $Value) {
        return $Default
    }

    if ($Value -is [bool]) {
        return $Value
    }

    return [System.Convert]::ToBoolean($Value)
}

function ConvertTo-StringArray {
    param([object]$Value)

    if ($null -eq $Value) {
        return ,@()
    }

    if ($Value -is [string]) {
        if ([string]::IsNullOrWhiteSpace($Value)) {
            return ,@()
        }

        return ,@($Value)
    }

    $items = New-Object System.Collections.Generic.List[string]
    foreach ($item in $Value) {
        if ($null -ne $item) {
            $text = [string]$item
            if (-not [string]::IsNullOrWhiteSpace($text)) {
                $items.Add($text)
            }
        }
    }

    return ,($items.ToArray())
}

function New-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Get-LinkTargetPath {
    param([System.IO.FileSystemInfo]$Item)

    $targets = ConvertTo-StringArray (Get-Prop $Item 'Target')
    if ($targets.Count -eq 0) {
        return $null
    }

    $target = $targets[0]
    try {
        return (Resolve-Path -LiteralPath $target -ErrorAction Stop).Path
    }
    catch {
        return $target
    }
}

function Test-KatMarker {
    param([string]$Path)

    try {
        $stream = Get-Item -LiteralPath $Path -Stream CreatedBy -ErrorAction Stop
        if ($stream) {
            return (Get-Content -LiteralPath $Path -Stream CreatedBy -ErrorAction SilentlyContinue) -eq 'KAT'
        }
    }
    catch {
        # No alternate stream means the path is not KAT-marked.
    }

    return $false
}

function Clear-KatMarker {
    param([string]$Path)

    [void](Remove-AlternateDataStream -Path $Path -StreamName 'CreatedBy')
}

function Test-LegacyManagedItem {
    param(
        [System.IO.FileSystemInfo]$Item,
        [string]$RepositoryRoot
    )

    if (-not $Item.PSIsContainer -and (Test-KatMarker -Path $Item.FullName)) {
        return $true
    }

    if ($Item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        $targetPath = Get-LinkTargetPath $Item
        if ($targetPath -and $targetPath.StartsWith($RepositoryRoot, [StringComparison]::OrdinalIgnoreCase)) {
            return $true
        }
    }

    return $false
}

function Test-ReusableManagedDirectory {
    param(
        [string]$Path,
        [string]$RepositoryRoot
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
        return $false
    }

    $children = @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue)
    if ($children.Count -eq 0) {
        return $true
    }

    foreach ($child in $children) {
        if (-not (Test-LegacyManagedItem -Item $child -RepositoryRoot $RepositoryRoot)) {
            return $false
        }
    }

    return $true
}

function Remove-KatManagedPath {
    param(
        [string]$Path,
        [string]$RepositoryRoot
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    if ($null -eq $item) {
        return $true
    }

    $canReplace = $false
    if ($item.PSIsContainer) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $canReplace = (Test-LegacyManagedItem -Item $item -RepositoryRoot $RepositoryRoot)
        }
        else {
            $canReplace = Test-ReusableManagedDirectory -Path $Path -RepositoryRoot $RepositoryRoot
        }
    }
    else {
        $canReplace = (Test-LegacyManagedItem -Item $item -RepositoryRoot $RepositoryRoot)
    }

    if (-not $canReplace) {
        return $false
    }

    Remove-Item -LiteralPath $Path -Force -Recurse -Confirm:$false -ErrorAction SilentlyContinue
    return -not (Test-Path -LiteralPath $Path)
}

function Get-LegacyManagedPaths {
    param(
        [string[]]$ScanRoots,
        [string]$RepositoryRoot
    )

    $paths = New-Object System.Collections.Generic.List[string]

    foreach ($scanRoot in $ScanRoots) {
        if (-not (Test-Path -LiteralPath $scanRoot)) {
            continue
        }

        $item = Get-Item -LiteralPath $scanRoot -Force -ErrorAction SilentlyContinue
        if ($null -ne $item -and (Test-LegacyManagedItem -Item $item -RepositoryRoot $RepositoryRoot)) {
            $paths.Add($item.FullName)
        }

        Get-ChildItem -LiteralPath $scanRoot -Force -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
            if (Test-LegacyManagedItem -Item $_ -RepositoryRoot $RepositoryRoot) {
                $paths.Add($_.FullName)
            }
        }
    }

    return $paths | Sort-Object -Unique
}

function Remove-EmptyDirectories {
    param([string[]]$ScanRoots)

    foreach ($scanRoot in $ScanRoots) {
        if (-not (Test-Path -LiteralPath $scanRoot)) {
            continue
        }

        Get-ChildItem -LiteralPath $scanRoot -Force -Recurse -Directory -ErrorAction SilentlyContinue |
            Sort-Object FullName -Descending |
            ForEach-Object {
                if (-not (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $_.FullName -Force -Confirm:$false -ErrorAction SilentlyContinue
                }
            }
    }
}

function Clear-ManagedRoot {
    param(
        [string]$Root,
        [string[]]$ScanRoots,
        [string]$RepositoryRoot
    )

    $pathsToRemove = @(Get-LegacyManagedPaths -ScanRoots $ScanRoots -RepositoryRoot $RepositoryRoot)
    $pathsToRemove |
        Sort-Object Length -Descending -Unique |
        ForEach-Object {
            if (Test-Path -LiteralPath $_) {
                Remove-Item -LiteralPath $_ -Force -Recurse -Confirm:$false -ErrorAction SilentlyContinue
            }
        }

    $manifestPath = Join-Path $Root '.kat-managed.json'
    if (Test-Path -LiteralPath $manifestPath) {
        Remove-Item -LiteralPath $manifestPath -Force -Confirm:$false -ErrorAction SilentlyContinue
    }

    Remove-EmptyDirectories -ScanRoots $ScanRoots
}

function Write-CreatedByStream {
    param([string]$Path)

    try {
        Set-Content -LiteralPath $Path -Stream CreatedBy -Value 'KAT'
    }
    catch {
        # Alternate data streams are best-effort only.
    }
}

function Set-ManagedReadOnly {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        $item.IsReadOnly = $true
    }
    catch {
        # Read-only is best-effort only.
    }
}

function Write-ManagedFile {
    param(
        [string]$Path,
        [string]$Content
    )

    New-Directory (Split-Path -Parent $Path)
    if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
        Add-BlockedPath $Path
        return $false
    }

    Set-Content -LiteralPath $Path -Value $Content -NoNewline
    Write-CreatedByStream -Path $Path
    Set-ManagedReadOnly -Path $Path
    return $true
}

function Write-ManagedSymlink {
    param(
        [string]$Path,
        [string]$Target
    )

    New-Directory (Split-Path -Parent $Path)
    if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
        Add-BlockedPath $Path
        return $false
    }

    New-Item -ItemType SymbolicLink -Path $Path -Target $Target -Force | Out-Null
    return $true
}

function Copy-ManagedFile {
    param(
        [string]$Path,
        [string]$SourcePath
    )

    New-Directory (Split-Path -Parent $Path)
    if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
        Add-BlockedPath $Path
        return $false
    }

    try {
        Copy-Item -LiteralPath $SourcePath -Destination $Path -Force
        Write-CreatedByStream -Path $Path
        Set-ManagedReadOnly -Path $Path
        return $true
    }
    catch {
        Add-BlockedPath $Path
        return $false
    }
}

function Format-YamlScalar {
    param([object]$Value)

    if ($Value -is [bool]) {
        return $Value.ToString().ToLower()
    }

    $text = ''
    if ($null -ne $Value) {
        $text = [string]$Value
    }

    return "'" + ($text -replace "'", "''") + "'"
}

function Format-YamlInlineArray {
    param([string[]]$Values)

    if ($Values.Count -eq 0) {
        return '[]'
    }

    $formattedValues = $Values | ForEach-Object { Format-YamlScalar $_ }
    return '[' + ($formattedValues -join ', ') + ']'
}

function New-DocumentContent {
    param(
        [string[]]$FrontmatterLines,
        [string]$Body
    )

    $document = @('---') + $FrontmatterLines + '---'
    if ([string]::IsNullOrEmpty($Body)) {
        return $document -join "`r`n"
    }

    if ($Body.StartsWith("`r") -or $Body.StartsWith("`n")) {
        return ($document -join "`r`n") + $Body
    }

    return ($document + '' + $Body) -join "`r`n"
}

function ConvertFrom-JsonWithComments {
    param([string]$Content)

    $builder = New-Object System.Text.StringBuilder
    $inString = $false
    $isEscaped = $false
    $inLineComment = $false
    $inBlockComment = $false

    for ($index = 0; $index -lt $Content.Length; $index++) {
        $character = $Content[$index]
        $nextCharacter = if ($index + 1 -lt $Content.Length) { $Content[$index + 1] } else { [char]0 }

        if ($inLineComment) {
            if ($character -eq "`r" -or $character -eq "`n") {
                $inLineComment = $false
                [void]$builder.Append($character)
            }
            continue
        }

        if ($inBlockComment) {
            if ($character -eq '*' -and $nextCharacter -eq '/') {
                $inBlockComment = $false
                $index++
            }
            continue
        }

        if ($inString) {
            [void]$builder.Append($character)
            if ($isEscaped) {
                $isEscaped = $false
                continue
            }

            if ($character -eq '\\') {
                $isEscaped = $true
                continue
            }

            if ($character -eq '"') {
                $inString = $false
            }
            continue
        }

        if ($character -eq '/' -and $nextCharacter -eq '/') {
            $inLineComment = $true
            $index++
            continue
        }

        if ($character -eq '/' -and $nextCharacter -eq '*') {
            $inBlockComment = $true
            $index++
            continue
        }

        [void]$builder.Append($character)
        if ($character -eq '"') {
            $inString = $true
        }
    }

    return ConvertFrom-Json $builder.ToString()
}

function Test-LegacyToolConfiguration {
    param([object]$Tools)

    if ($null -eq $Tools) {
        return $false
    }

    return ($null -ne $Tools.PSObject.Properties['copilot']) -or ($null -ne $Tools.PSObject.Properties['claude'])
}

function Get-ConfiguredToolsForClient {
    param(
        [object]$Meta,
        [string]$Client
    )

    $tools = Get-Prop $Meta 'tools'
    if ($null -eq $tools) {
        return ,@()
    }

    if (Test-LegacyToolConfiguration -Tools $tools) {
        switch ($Client) {
            'vscode' {
                return ,(ConvertTo-StringArray (Get-Prop $tools 'copilot'))
            }
            'copilotCli' {
                return ,(ConvertTo-StringArray (Get-Prop $tools 'copilot'))
            }
            'claude' {
                return ,(Get-ClaudeToolMappings -Meta $Meta -ArtifactLabel (Get-Prop $Meta 'id'))
            }
            default {
                return ,@()
            }
        }
    }

    $resolvedTools = New-Object System.Collections.Generic.List[string]
    foreach ($toolProperty in @($tools.PSObject.Properties)) {
        $toolName = $toolProperty.Name
        $definition = $toolProperty.Value
        $hasClientProperty = $false
        $mappedValue = $null

        if ($null -ne $definition) {
            $clientProperty = $definition.PSObject.Properties[$Client]
            if ($null -ne $clientProperty) {
                $hasClientProperty = $true
                $mappedValue = $clientProperty.Value
            }
        }

        if ($Client -eq 'claude') {
            $toolValues = if ($hasClientProperty) { ConvertTo-StringArray $mappedValue } else { @() }
        }
        else {
            $toolValues = if ($hasClientProperty) { ConvertTo-StringArray $mappedValue } else { @($toolName) }
        }

        foreach ($toolValue in $toolValues) {
            if (-not $resolvedTools.Contains($toolValue)) {
                $resolvedTools.Add($toolValue)
            }
        }
    }

    return ,($resolvedTools.ToArray())
}

function Get-ClaudeMemoryScope {
    param([object]$Meta)

    $claudeMeta = Get-Prop $Meta 'claude'
    $memoryScope = Get-Prop $claudeMeta 'memory'
    if ([string]::IsNullOrWhiteSpace([string]$memoryScope)) {
        return $null
    }

    return [string]$memoryScope
}

function Test-ClaudeContext7Configured {
    if ($null -ne $script:claudeContext7Configured) {
        return $script:claudeContext7Configured
    }

    $script:claudeContext7Configured = $false
    $claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-Path -LiteralPath $claudeConfigPath)) {
        return $script:claudeContext7Configured
    }

    try {
        $config = ConvertFrom-Json (Get-Content -LiteralPath $claudeConfigPath -Raw)
        $mcpServers = $config.PSObject.Properties['mcpServers']
        if ($null -ne $mcpServers -and $null -ne $mcpServers.Value) {
            $script:claudeContext7Configured = $null -ne $mcpServers.Value.PSObject.Properties['context7']
        }
    }
    catch {
        $script:claudeContext7Configured = $false
    }

    return $script:claudeContext7Configured
}

function Get-ClaudeToolMappings {
    param(
        [object]$Meta,
        [string]$ArtifactLabel
    )

    $tools = Get-Prop $Meta 'tools'
    $claudeTools = Get-Prop $tools 'claude'
    if ($null -ne $claudeTools -and $claudeTools -isnot [string]) {
        return ,(ConvertTo-StringArray $claudeTools)
    }

    if ($claudeTools -is [string] -and $claudeTools -ne 'auto') {
        return ,(ConvertTo-StringArray $claudeTools)
    }

    $mapped = New-Object System.Collections.Generic.List[string]
    foreach ($tool in (ConvertTo-StringArray (Get-Prop $tools 'copilot'))) {
        switch -Regex ($tool) {
            '^read($|/)' {
                if (-not $mapped.Contains('Read')) { $mapped.Add('Read') }
            }
            '^search$' {
                if (-not $mapped.Contains('Grep')) { $mapped.Add('Grep') }
                if (-not $mapped.Contains('Glob')) { $mapped.Add('Glob') }
            }
            '^edit$' {
                if (-not $mapped.Contains('Edit')) { $mapped.Add('Edit') }
            }
            '^execute$' {
                if (-not $mapped.Contains('Bash')) { $mapped.Add('Bash') }
            }
            '^web($|/)' {
                if (-not $mapped.Contains('WebFetch')) { $mapped.Add('WebFetch') }
            }
            '^todo$' {
                if (-not $mapped.Contains('TodoWrite')) { $mapped.Add('TodoWrite') }
            }
            '^agent$' {
                if (-not $mapped.Contains('Task')) { $mapped.Add('Task') }
            }
            '^github/' {
                if (-not $mapped.Contains('Bash')) { $mapped.Add('Bash') }
                if (-not $mapped.Contains('WebFetch')) { $mapped.Add('WebFetch') }
                Add-Warning "${ArtifactLabel}: GitHub-specific Copilot tools were mapped to Claude Bash/WebFetch. Install GitHub CLI or a GitHub MCP server if you need closer parity."
            }
            '^io\.github\.upstash/context7/' {
                if (Test-ClaudeContext7Configured) {
                    if (-not $mapped.Contains('mcp__context7__resolve-library-id')) { $mapped.Add('mcp__context7__resolve-library-id') }
                    if (-not $mapped.Contains('mcp__context7__get-library-docs')) { $mapped.Add('mcp__context7__get-library-docs') }
                }
                else {
                    Add-Warning "${ArtifactLabel}: Context7 has no native Claude tool equivalent. Install a matching MCP server and override tools.claude in meta.json if you want parity."
                }
            }
            '^vscode($|/)' {
                Add-Warning "${ArtifactLabel}: VS Code-only tools are ignored for Claude rendering."
            }
            default {
                Add-Warning "${ArtifactLabel}: No Claude tool mapping defined for Copilot tool '$tool'."
            }
        }
    }

    return ,($mapped.ToArray())
}

function Read-CanonicalMeta {
    param([string]$Path)

    return ConvertFrom-JsonWithComments (Get-Content -LiteralPath $Path -Raw)
}

function ConvertTo-CopilotAgentDocument {
    param(
        [object]$Meta,
        [string]$Body,
        [string]$Client
    )

    $frontmatter = New-Object System.Collections.Generic.List[string]
    $frontmatter.Add('name: ' + (Format-YamlScalar (Get-Prop $Meta 'name')))
    $frontmatter.Add('description: ' + (Format-YamlScalar (Get-Prop $Meta 'description')))

    $models = Get-Prop $Meta 'models'
    $model = if ($Client -eq 'vscode') { Get-Prop $models 'vscode' } else { Get-Prop $models 'copilotCli' }
    if (-not [string]::IsNullOrWhiteSpace([string]$model)) {
        $frontmatter.Add('model: ' + (Format-YamlScalar $model))
    }

    if ($Client -eq 'vscode') {
        $agents = ConvertTo-StringArray (Get-Prop (Get-Prop $Meta 'copilot') 'agents')
        if ($agents.Count -gt 0) {
            $frontmatter.Add('agents: ' + (Format-YamlInlineArray $agents))
        }
    }

    $copilotTools = Get-ConfiguredToolsForClient -Meta $Meta -Client $Client
    if ($copilotTools.Count -gt 0) {
        $frontmatter.Add('tools: ' + (Format-YamlInlineArray $copilotTools))
    }

    $copilotMeta = Get-Prop $Meta 'copilot'
    if ($null -ne (Get-Prop $copilotMeta 'userInvocable')) {
        $frontmatter.Add('user-invocable: ' + ((ConvertTo-BoolValue (Get-Prop $copilotMeta 'userInvocable') $true).ToString().ToLower()))
    }

    if ($Client -eq 'vscode') {
        $handoffs = Get-Prop $copilotMeta 'handoffs'
        if ($null -ne $handoffs) {
            $handoffItems = @($handoffs)
            if ($handoffItems.Count -gt 0) {
                $frontmatter.Add('handoffs:')
                foreach ($handoff in $handoffItems) {
                    $frontmatter.Add('  - label: ' + (Format-YamlScalar (Get-Prop $handoff 'label')))
                    $frontmatter.Add('    agent: ' + (Format-YamlScalar (Get-Prop $handoff 'agent')))
                    $frontmatter.Add('    prompt: ' + (Format-YamlScalar (Get-Prop $handoff 'prompt')))
                    $frontmatter.Add('    send: ' + ((ConvertTo-BoolValue (Get-Prop $handoff 'send') $false).ToString().ToLower()))
                }
            }
        }
    }

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $Body
}

function ConvertTo-ClaudeAgentDocument {
    param(
        [object]$Meta,
        [string]$Body
    )

    $frontmatter = New-Object System.Collections.Generic.List[string]
    $frontmatter.Add('name: ' + (Format-YamlScalar (Get-Prop $Meta 'name')))
    $frontmatter.Add('description: ' + (Format-YamlScalar (Get-Prop $Meta 'description')))

    $model = Get-Prop (Get-Prop $Meta 'models') 'claude'
    if (-not [string]::IsNullOrWhiteSpace([string]$model)) {
        $frontmatter.Add('model: ' + (Format-YamlScalar $model))
    }

    $claudeTools = Get-ConfiguredToolsForClient -Meta $Meta -Client 'claude'
    if ($claudeTools.Count -gt 0) {
        $frontmatter.Add('tools: ' + (Format-YamlInlineArray $claudeTools))
    }

    $memoryScope = Get-ClaudeMemoryScope -Meta $Meta
    if (-not [string]::IsNullOrWhiteSpace($memoryScope)) {
        $frontmatter.Add('memory: ' + (Format-YamlScalar $memoryScope))
    }

    $copilotMeta = Get-Prop $Meta 'copilot'
    if ((ConvertTo-StringArray (Get-Prop $copilotMeta 'agents')).Count -gt 0 -or $null -ne (Get-Prop $copilotMeta 'handoffs')) {
        Add-Warning "$(Get-Prop $Meta 'id'): Copilot orchestration fields were omitted from Claude rendering because there is no compatible native frontmatter equivalent."
    }

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $Body
}

function ConvertTo-CopilotInstructionDocument {
    param(
        [object]$Meta,
        [string]$Body
    )

    $scope = Get-Prop (Get-Prop $Meta 'scope') 'copilot' '**'
    $frontmatter = @('applyTo: ' + (Format-YamlScalar $scope))
    return New-DocumentContent -FrontmatterLines $frontmatter -Body $Body
}

function ConvertTo-ClaudeRuleDocument {
    param(
        [object]$Meta,
        [string]$Body
    )

    $frontmatter = New-Object System.Collections.Generic.List[string]
    $frontmatter.Add('description: ' + (Format-YamlScalar (Get-Prop $Meta 'description')))
    $frontmatter.Add('paths:')
    foreach ($pathPattern in (ConvertTo-StringArray (Get-Prop (Get-Prop $Meta 'scope') 'claude'))) {
        $frontmatter.Add('  - ' + (Format-YamlScalar $pathPattern))
    }

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $Body
}

function ConvertTo-SkillDocument {
    param(
        [object]$Meta,
        [string]$Body
    )

    $frontmatter = New-Object System.Collections.Generic.List[string]
    foreach ($field in @('name', 'description', 'license', 'compatibility')) {
        $value = Get-Prop $Meta $field
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $frontmatter.Add($field + ': ' + (Format-YamlScalar $value))
        }
    }

    $metadata = Get-Prop $Meta 'metadata'
    if ($null -ne $metadata -and @($metadata.PSObject.Properties).Count -gt 0) {
        $frontmatter.Add('metadata:')
        foreach ($property in @($metadata.PSObject.Properties)) {
            $frontmatter.Add('  ' + $property.Name + ': ' + (Format-YamlScalar $property.Value))
        }
    }

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $Body
}

function Get-CanonicalMetaPath {
    param([System.IO.DirectoryInfo]$Directory)

    $jsoncPath = Join-Path $Directory.FullName 'meta.jsonc'
    if (Test-Path -LiteralPath $jsoncPath) {
        return $jsoncPath
    }

    return (Join-Path $Directory.FullName 'meta.json')
}

function Get-AgentDirectories {
    Get-ChildItem -LiteralPath (Join-Path $aiRoot 'agents') -Directory |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'body.md')) -and
            (Test-Path -LiteralPath (Get-CanonicalMetaPath -Directory $_))
        } |
        Sort-Object Name
}

function Get-InstructionDirectories {
    Get-ChildItem -LiteralPath (Join-Path $aiRoot 'instructions') -Directory |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'body.md')) -and
            (Test-Path -LiteralPath (Get-CanonicalMetaPath -Directory $_))
        } |
        Sort-Object Name
}

function Get-SkillDirectories {
    Get-ChildItem -LiteralPath (Join-Path $aiRoot 'skills') -Directory |
        Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'SKILL.md') } |
        Sort-Object Name
}

function Get-SkillMeta {
    param([System.IO.DirectoryInfo]$Directory)

    $metaPath = Get-CanonicalMetaPath -Directory $Directory
    if (Test-Path -LiteralPath $metaPath) {
        return Read-CanonicalMeta -Path $metaPath
    }

    return [pscustomobject]@{
        id = $Directory.Name
        name = $Directory.Name
        description = $Directory.Name
        enabled = [pscustomobject]@{
            copilot = $true
            claude = $true
        }
        claude = [pscustomobject]@{
            exposeCommands = (Test-Path -LiteralPath (Join-Path $Directory.FullName 'commands'))
        }
    }
}

function New-ManagedDirectory {
    param(
        [string]$Path
    )

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        if ($null -eq $item) {
            Add-BlockedPath $Path
            return $false
        }

        if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            Clear-KatMarker -Path $Path
            return $true
        }

        if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
            Add-BlockedPath $Path
            return $false
        }
    }

    New-Item -ItemType Directory -Path $Path -Force | Out-Null
    return $true
}

function Install-RenderedSkill {
    param(
        [string]$Root,
        [System.IO.DirectoryInfo]$SkillDirectory,
        [object]$Meta
    )

    $id = Get-Prop $Meta 'id' $SkillDirectory.Name
    $targetDirectory = Join-Path (Join-Path $Root 'skills') $id
    if (-not (New-ManagedDirectory -Path $targetDirectory)) {
        return $false
    }

    $body = Get-Content -LiteralPath (Join-Path $SkillDirectory.FullName 'SKILL.md') -Raw
    $renderedSkill = ConvertTo-SkillDocument -Meta $Meta -Body $body
    $allSucceeded = Write-ManagedFile -Path (Join-Path $targetDirectory 'SKILL.md') -Content $renderedSkill

    Get-ChildItem -LiteralPath $SkillDirectory.FullName -Force | Where-Object {
        $_.Name -notin @('SKILL.md', 'meta.json', 'meta.jsonc')
    } | ForEach-Object {
        $targetPath = Join-Path $targetDirectory $_.Name
        $linkSucceeded = Write-ManagedSymlink -Path $targetPath -Target $_.FullName
        $allSucceeded = $allSucceeded -and $linkSucceeded
    }

    return $allSucceeded
}

Invoke-PolicySync
