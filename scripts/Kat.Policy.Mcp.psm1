Set-StrictMode -Version Latest

function Get-KatProp {
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

function Test-KatCommandAvailable {
	param([string]$Name)

	return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-KatDryRun {
	return [bool]$WhatIfPreference
}

function Initialize-KatJsonNative {
	if ('KatJsonNative' -as [type]) {
		return
	}

	Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Text.Json;

public static class KatJsonNative
{
    public static string NormalizeJsonC(string content)
    {
        if (content is null)
        {
            throw new ArgumentNullException(nameof(content));
        }

        var options = new JsonDocumentOptions
        {
            CommentHandling = JsonCommentHandling.Skip,
            AllowTrailingCommas = true
        };

        using var document = JsonDocument.Parse(content, options);
        using var stream = new MemoryStream();
        using (var writer = new Utf8JsonWriter(stream))
        {
            document.RootElement.WriteTo(writer);
        }

        return Encoding.UTF8.GetString(stream.ToArray());
    }
}
'@
}

function ConvertTo-KatNormalizedJsonText {
	param([string]$Content)

	Initialize-KatJsonNative
	return [KatJsonNative]::NormalizeJsonC($Content)
}

function ConvertFrom-KatJsonWithComments {
	param([string]$Content)

	return ConvertFrom-Json (ConvertTo-KatNormalizedJsonText -Content $Content)
}

function ConvertFrom-KatJsonWithCommentsAsHashtable {
	param([string]$Content)

	return ConvertFrom-Json (ConvertTo-KatNormalizedJsonText -Content $Content) -AsHashtable
}

function Read-KatJsonDocument {
	param(
		[string]$Path,
		[scriptblock]$DefaultFactory
	)

	if (-not (Test-Path -LiteralPath $Path)) {
		return & $DefaultFactory
	}

	try {
		return ConvertFrom-KatJsonWithComments (Get-Content -LiteralPath $Path -Raw)
	}
	catch {
		throw "Invalid JSON at '$Path'."
	}
}

function Write-KatJsonDocument {
	param(
		[string]$Path,
		[object]$Document
	)

	$parent = Split-Path -Parent $Path
	if (-not [string]::IsNullOrWhiteSpace($parent) -and -not (Test-Path -LiteralPath $parent)) {
		New-Item -ItemType Directory -Path $parent -Force | Out-Null
	}

	$json = $Document | ConvertTo-Json -Depth 100
	Set-Content -LiteralPath $Path -Value $json
}

function Get-OrAddKatObjectProperty {
	param(
		[object]$Object,
		[string]$PropertyName,
		[object]$DefaultValue
	)

	if ($null -eq (Get-KatProp $Object $PropertyName)) {
		$Object | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $DefaultValue -Force
	}

	return (Get-KatProp $Object $PropertyName)
}

function Get-KatModeTransitionLabel {
	param([string]$ExistingType)

	if ([string]::IsNullOrWhiteSpace($ExistingType)) {
		return 'new remote config'
	}

	if ($ExistingType -ieq 'http') {
		return 'already remote (http)'
	}

	return "switching from $ExistingType to http"
}

function Test-KatTruthySettingValue {
	param([string]$Value)

	if ([string]::IsNullOrWhiteSpace($Value)) {
		return $false
	}

	$normalized = $Value.Trim().ToLowerInvariant()
	switch ($normalized) {
		'false' { return $false }
		'f' { return $false }
		'no' { return $false }
		'n' { return $false }
		'0' { return $false }
		'off' { return $false }
		default { return $true }
	}
}

function Test-KatInteractiveHost {
	if (-not [Environment]::UserInteractive) {
		return $false
	}

	if ($Host.Name -notin @('ConsoleHost', 'Visual Studio Code Host', 'Windows PowerShell ISE Host')) {
		return $false
	}

	try {
		return -not [Console]::IsInputRedirected
	}
	catch {
		return $false
	}
}

function Test-KatClaudeVsCodeExtensionInstalled {
	if (-not (Test-KatCommandAvailable -Name 'code')) {
		return $false
	}

	try {
		$extensions = (& code --list-extensions 2>$null)
		foreach ($extension in @($extensions)) {
			if ([string]::IsNullOrWhiteSpace($extension)) {
				continue
			}

			if ($extension -match 'anthropic' -and $extension -match 'claude') {
				return $true
			}
		}
	}
	catch {
		return $false
	}

	return $false
}

function Test-KatClaudeInstalled {
	$claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'
	return (Test-KatCommandAvailable -Name 'claude') -or
		(Test-Path -LiteralPath $claudeConfigPath) -or
		(Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.claude')) -or
		(Test-KatClaudeVsCodeExtensionInstalled)
}

function Test-KatCopilotCliInstalled {
	return (Test-KatCommandAvailable -Name 'copilot') -or (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.copilot'))
}

function Test-KatVsCodeInstalled {
	return (Test-KatCommandAvailable -Name 'code') -or (Test-Path -LiteralPath (Join-Path $env:APPDATA 'Code\User'))
}

function New-KatResultList {
	return ,(New-Object System.Collections.Generic.List[object])
}

function Add-KatResult {
	param(
		[object]$Results,
		[string]$Client,
		[string]$Status,
		[string]$Method,
		[string]$Path,
		[string]$Detail
	)

	$Results.Add([pscustomobject]@{
		Client = $Client
		Status = $Status
		Method = $Method
		Path = $Path
		Detail = $Detail
	})
}

function Invoke-KatClientConfigAction {
	param(
		[object]$Results,
		[string]$Client,
		[string]$ConfigPath,
		[string]$ServersPropertyName,
		[scriptblock]$ResolveExisting,
		[scriptblock]$Action
	)

	try {
		$config = Read-KatJsonDocument -Path $ConfigPath -DefaultFactory { [pscustomobject]@{} }
		$servers = Get-OrAddKatObjectProperty -Object $config -PropertyName $ServersPropertyName -DefaultValue ([pscustomobject]@{})
		$existing = if ($null -ne $ResolveExisting) { & $ResolveExisting $servers } else { $null }

		& $Action $config $servers $existing $ConfigPath
	}
	catch {
		Add-KatResult -Results $Results -Client $Client -Status 'blocked' -Method 'file' -Path $ConfigPath -Detail $_.Exception.Message
	}
}

function Complete-KatFileMutation {
	param(
		[object]$Results,
		[string]$Client,
		[string]$ConfigPath,
		[object]$Document,
		[string]$PreviewDetail,
		[string]$SuccessDetail
	)

	if (Test-KatDryRun) {
		Add-KatResult -Results $Results -Client $Client -Status 'preview' -Method 'file' -Path $ConfigPath -Detail $PreviewDetail
		return $false
	}

	Write-KatJsonDocument -Path $ConfigPath -Document $Document
	Add-KatResult -Results $Results -Client $Client -Status 'ok' -Method 'file' -Path $ConfigPath -Detail $SuccessDetail
	return $true
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
		if ($text.Length -le $Width) {
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
		[bool]$RowDividers = $false,
		[System.Collections.Generic.List[string]]$Footnotes = $null,
		[System.Collections.Generic.List[string]]$FootnoteColors = $null
	)

	if ($Rows.Count -eq 0) {
		return
	}

	$normalizedRows = foreach ($row in $Rows) {
		[pscustomobject]@{
			Cells      = @($row.Cells)
			Color      = if ($null -ne $row.PSObject.Properties['Color']) { [string]$row.Color } else { $null }
			CellColors = if ($null -ne $row.PSObject.Properties['CellColors']) { $row.CellColors } else { $null }
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

		$rowColor      = if (-not [string]::IsNullOrWhiteSpace($row.Color)) { $row.Color } else { $Color }
		$cellColorList = $row.CellColors

		for ($lineIndex = 0; $lineIndex -lt $rowHeight; $lineIndex++) {
			$lineValues = @(for ($columnIndex = 0; $columnIndex -lt $widths.Count; $columnIndex++) {
				$cellLines = @($wrappedCells[$columnIndex].Lines)
				if ($lineIndex -lt $cellLines.Count) { $cellLines[$lineIndex] } else { '' }
			})

			if ($null -ne $cellColorList -and $cellColorList.Count -gt 0) {
				for ($ci = 0; $ci -lt $widths.Count; $ci++) {
					$perCell = if ($ci -lt $cellColorList.Count -and -not [string]::IsNullOrWhiteSpace($cellColorList[$ci])) { [string]$cellColorList[$ci] } else { $null }
					$effectiveColor = if ($null -ne $perCell) { $perCell } else { $rowColor }
					$alignment = if ($ci -lt $Alignments.Count -and -not [string]::IsNullOrWhiteSpace($Alignments[$ci])) { $Alignments[$ci] } else { 'left' }
					Write-Host -NoNewline '|' -ForegroundColor $rowColor
					Write-Host -NoNewline (Format-AsciiCell -Value $lineValues[$ci] -Width $widths[$ci] -Alignment $alignment -Padding $Padding) -ForegroundColor $effectiveColor
				}
				Write-Host '|' -ForegroundColor $rowColor
			}
			else {
				Write-Host (Format-AsciiRow -Values $lineValues -Widths $widths -Alignments $Alignments -Padding $Padding) -ForegroundColor $rowColor
			}
		}

		if ($RowDividers) {
			Write-Host $border -ForegroundColor $rowColor
		}
	}

	if (-not $RowDividers) {
		Write-Host $border -ForegroundColor $Color
	}

	if ($null -ne $Footnotes -and $Footnotes.Count -gt 0) {
		$superscripts = @('¹','²','³','⁴','⁵','⁶','⁷','⁸','⁹')
		for ($fi = 0; $fi -lt $Footnotes.Count; $fi++) {
			$marker = if ($fi -lt $superscripts.Count) { $superscripts[$fi] } else { "[$($fi + 1)]" }
			$fnColor = if ($null -ne $FootnoteColors -and $fi -lt $FootnoteColors.Count -and -not [string]::IsNullOrWhiteSpace($FootnoteColors[$fi])) { $FootnoteColors[$fi] } else { 'DarkCyan' }
			Write-Host "  $marker $($Footnotes[$fi])" -ForegroundColor $fnColor
		}
	}

	Write-Host ''
}

function Write-KatResultSummary {
	param(
		[string]$ServerName,
		[string]$Title = '',
		[object[]]$Results
	)

	if ([string]::IsNullOrWhiteSpace($ServerName)) {
		$ServerName = ($Title -replace '\s*(Remote\s+)?Setup\s+Summary.*$', '' -replace '\s+MCP\s+Server.*$', '').Trim()
		if ([string]::IsNullOrWhiteSpace($ServerName)) { $ServerName = 'Unknown' }
	}

	$clientColumnMap = @{
		'vscode'      = 0
		'copilot-cli' = 1
		'claude'      = 2
	}

	$columnResults = [object[]]@($null, $null, $null)
	foreach ($result in @($Results)) {
		$client = [string](Get-KatProp $result 'Client')
		if ($clientColumnMap.ContainsKey($client) -and $null -eq $columnResults[$clientColumnMap[$client]]) {
			$columnResults[$clientColumnMap[$client]] = $result
		}
	}

	$footnotes      = [System.Collections.Generic.List[string]]::new()
	$footnoteColors = [System.Collections.Generic.List[string]]::new()
	$superscripts   = @('¹','²','³','⁴','⁵','⁶','⁷','⁸','⁹')

	$getCellInfo = {
		param([object]$Result)
		if ($null -eq $Result) { return [pscustomobject]@{ Value = 'excluded'; Color = 'DarkYellow' } }
		$status = [string](Get-KatProp $Result 'Status')
		$detail = [string](Get-KatProp $Result 'Detail')

		$addFootnote = {
			param([string]$Text, [string]$Color = 'DarkCyan')
			$idx = $footnotes.IndexOf($Text)
			if ($idx -lt 0) {
				[void]$footnotes.Add($Text)
				[void]$footnoteColors.Add($Color)
				$idx = $footnotes.Count - 1
			}
			return if ($idx -lt $superscripts.Count) { $superscripts[$idx] } else { "[$($idx + 1)]" }
		}

		switch ($status) {
			'ok' { return [pscustomobject]@{ Value = 'installed'; Color = $null } }
			{ $_ -in @('needs-install', 'preview') } {
				$marker = & $addFootnote $detail 'Yellow'
				return [pscustomobject]@{ Value = "pending$marker"; Color = 'Yellow' }
			}
			'blocked' {
				$marker = & $addFootnote $detail 'Red'
				return [pscustomobject]@{ Value = "blocked$marker"; Color = 'Red' }
			}
			default { return [pscustomobject]@{ Value = 'excluded'; Color = 'DarkYellow' } }
		}
	}

	$vsCodeInfo = & $getCellInfo $columnResults[0]
	$cliInfo    = & $getCellInfo $columnResults[1]
	$claudeInfo = & $getCellInfo $columnResults[2]

	$serverColWidth = [Math]::Max('mcp server'.Length, $ServerName.Length) + 2
	$statusColWidth = 12

	$rows = @([pscustomobject]@{
		Cells      = @($ServerName, $vsCodeInfo.Value, $cliInfo.Value, $claudeInfo.Value)
		CellColors = @($null, $vsCodeInfo.Color, $cliInfo.Color, $claudeInfo.Color)
	})

	Write-AsciiTable `
		-Title '--- MCP Server Deployment Status ---' `
		-Headers @('mcp server', 'vscode', 'cli', 'claude') `
		-Rows $rows `
		-Color 'Green' `
		-FixedWidths @($serverColWidth, $statusColWidth, $statusColWidth, $statusColWidth) `
		-Alignments @('left', 'status', 'status', 'status') `
		-HeaderAlignments @('left', 'center', 'center', 'center') `
		-Footnotes $footnotes `
		-FootnoteColors $footnoteColors
}

function New-KatBootstrapPassThru {
	param(
		[object]$Results,
		[bool]$CredentialAvailable = $false,
		[bool]$GuidanceShown = $false
	)

	$blockedCount = @($Results | Where-Object Status -eq 'blocked').Count
	$needsInstallCount = @($Results | Where-Object Status -eq 'needs-install').Count

	return [pscustomobject]@{
		CredentialAvailable = $CredentialAvailable
		GuidanceShown = $GuidanceShown
		IsCompliant = $blockedCount -eq 0 -and $needsInstallCount -eq 0
		HasBlocked = $blockedCount -gt 0
		RequiresInstall = $needsInstallCount -gt 0
		Results = @($Results)
	}
}

Export-ModuleMember -Function @(
	'Add-KatResult',
	'Complete-KatFileMutation',
	'ConvertFrom-KatJsonWithComments',
	'ConvertFrom-KatJsonWithCommentsAsHashtable',
	'Get-KatModeTransitionLabel',
	'Get-KatProp',
	'Get-OrAddKatObjectProperty',
	'Invoke-KatClientConfigAction',
	'New-KatBootstrapPassThru',
	'New-KatResultList',
	'Read-KatJsonDocument',
	'Test-KatClaudeInstalled',
	'Test-KatClaudeVsCodeExtensionInstalled',
	'Test-KatCommandAvailable',
	'Test-KatCopilotCliInstalled',
	'Test-KatVsCodeInstalled',
	'Test-KatDryRun',
	'Test-KatInteractiveHost',
	'Test-KatTruthySettingValue',
	'Write-AsciiTable',
	'Write-KatJsonDocument',
	'Write-KatResultSummary'
)
