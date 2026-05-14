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

function ConvertFrom-KatJsonWithComments {
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
	return [Environment]::UserInteractive -and $Host.Name -ne 'ServerRemoteHost'
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

function Write-KatResultSummary {
	param(
		[string]$Title,
		[object[]]$Results
	)

	Write-Host '' # Blank line for spacing
	# Write-Host ("--- {0} ---" -f $Title) -ForegroundColor Cyan

	foreach ($result in @($Results)) {
		$statusColor = switch ($result.Status) {
			'ok' { 'Green' }
			'preview' { 'Cyan' }
			'needs-install' { 'Yellow' }
			'no-client' { 'DarkYellow' }
			'user-skip' { 'Yellow' }
			'skipped' { 'Yellow' }
			default { 'Red' }
		}

		$pathText = if ([string]::IsNullOrWhiteSpace($result.Path)) { '-' } else { $result.Path }
		Write-Host ("[{0}] {1} ({2})" -f $result.Status.ToUpperInvariant(), $result.Client, $result.Method) -ForegroundColor $statusColor
		Write-Host ("  path: {0}" -f $pathText)
		Write-Host ("  detail: {0}" -f $result.Detail)
	}

	Write-Host '' # Blank line for spacing
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
	'Test-KatDryRun',
	'Test-KatInteractiveHost',
	'Test-KatTruthySettingValue',
	'Write-KatJsonDocument',
	'Write-KatResultSummary'
)