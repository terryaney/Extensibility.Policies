[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipVsCode,
    [switch]$SkipCopilotCli,
    [switch]$SkipClaude,
    [switch]$CheckOnly,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSBoundParameters.ContainsKey('WhatIf')) {
    $WhatIfPreference = $true
}

$sharedModulePath = Join-Path $PSScriptRoot 'Kat.Policy.Mcp.psm1'
Import-Module $sharedModulePath -Force

$script:serverName = 'kat/ledger'
$script:toolNames = @(
    'kat/ledger/execute',
    'kat/ledger/query',
    'kat/ledger/query_one'
)
$script:releaseOwner = 'terryaney'
$script:releaseRepo = 'Mcp.KatLedger'
$script:releaseTag = 'v0.2.1'
$script:releaseAssetName = 'KatLedger-win-x64.zip'
$script:releaseRepository = '{0}/{1}' -f $script:releaseOwner, $script:releaseRepo
$script:katRoot = Join-Path $env:USERPROFILE '.kat'
$script:installRoot = Join-Path $script:katRoot 'KatLedger'
$script:exePath = Join-Path $script:installRoot 'KatLedger.exe'
$script:canonicalDbPath = Join-Path $script:installRoot 'KatLedger.db'
$script:manifestPath = Join-Path $script:installRoot 'install-manifest.json'
$script:downloadPath = Join-Path $script:katRoot $script:releaseAssetName
$script:stagingRoot = Join-Path $script:katRoot 'KatLedger.stage'
$script:preservedInstallEntries = @(
    'KatLedger.db',
    'KatLedger.db-shm',
    'KatLedger.db-wal'
)
$script:results = New-KatResultList

function Add-Result {
    param(
        [string]$Client,
        [string]$Status,
        [string]$Method,
        [string]$Path,
        [string]$Detail
    )

    Add-KatResult -Results $script:results -Client $Client -Status $Status -Method $Method -Path $Path -Detail $Detail
}

function Get-NormalizedCommandPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }

    $trimmed = $Path.Trim().Trim('"')
    try {
        return [System.IO.Path]::GetFullPath($trimmed).TrimEnd('\').ToLowerInvariant()
    }
    catch {
        return $trimmed.ToLowerInvariant()
    }
}

function Get-KatLedgerModeTransitionLabel {
    param([string]$ExistingType)

    if ([string]::IsNullOrWhiteSpace($ExistingType)) {
        return 'new local config'
    }

    if ($ExistingType -ieq 'stdio') {
        return 'already local (stdio)'
    }

    return "switching from $ExistingType to stdio"
}

function Get-CompactMessage {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }

    return (($Text -split '\r?\n' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join ' ').Trim()
}

function Test-KatLedgerCommandMatch {
    param([string]$Command)

    return (Get-NormalizedCommandPath $Command) -eq (Get-NormalizedCommandPath $script:exePath)
}

function Test-KatLedgerArgsMatch {
    param([object[]]$CommandArgs)

    return @($CommandArgs).Count -eq 0
}

function Test-KatLedgerToolsMatch {
    param([object[]]$Tools)

    $expected = @($script:toolNames | ForEach-Object { [string]$_ } | Sort-Object -Unique)
    $actual = @(@($Tools) | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Sort-Object -Unique)

    if ($actual.Count -ne $expected.Count) {
        return $false
    }

    return $null -eq (Compare-Object -ReferenceObject $expected -DifferenceObject $actual)
}

function Get-KatLedgerReleaseAssetUrl {
    return ('https://github.com/{0}/releases/download/{1}/{2}' -f $script:releaseRepository, $script:releaseTag, $script:releaseAssetName)
}

function Get-KatLedgerExpectedReleaseLabel {
    return ('{0} {1} asset {2}' -f $script:releaseRepository, $script:releaseTag, $script:releaseAssetName)
}

function Get-KatLedgerInstalledManifest {
    if (-not (Test-Path -LiteralPath $script:manifestPath)) {
        return $null
    }

    try {
        return ConvertFrom-KatJsonWithComments (Get-Content -LiteralPath $script:manifestPath -Raw)
    }
    catch {
        return $null
    }
}

function Test-KatLedgerInstalledManifestMatch {
    param([object]$Manifest)

    if ($null -eq $Manifest) {
        return $false
    }

    return [string](Get-KatProp $Manifest 'repository') -eq $script:releaseRepository -and
        [string](Get-KatProp $Manifest 'tag') -eq $script:releaseTag -and
        [string](Get-KatProp $Manifest 'asset') -eq $script:releaseAssetName
}

function Get-KatLedgerInstalledManifestLabel {
    param([object]$Manifest)

    if ($null -eq $Manifest) {
        return 'no install manifest'
    }

    $repository = [string](Get-KatProp $Manifest 'repository')
    $tag = [string](Get-KatProp $Manifest 'tag')
    $asset = [string](Get-KatProp $Manifest 'asset')

    if ([string]::IsNullOrWhiteSpace($repository) -and [string]::IsNullOrWhiteSpace($tag) -and [string]::IsNullOrWhiteSpace($asset)) {
        return 'empty install manifest'
    }

    return ('{0} {1} asset {2}' -f $repository, $tag, $asset).Trim()
}

function Remove-KatLedgerStagingArtifacts {
    foreach ($path in @($script:downloadPath, $script:stagingRoot)) {
        if (Test-Path -LiteralPath $path) {
            Remove-Item -LiteralPath $path -Recurse -Force
        }
    }
}

function Get-KatLedgerStagedSourceRoot {
    param([string]$StagingRoot)

    $stagedExe = Get-ChildItem -LiteralPath $StagingRoot -Filter 'KatLedger.exe' -File -Recurse | Select-Object -First 1
    if ($null -eq $stagedExe) {
        throw "Downloaded asset did not contain KatLedger.exe under $StagingRoot."
    }

    return $stagedExe.DirectoryName
}

function Clear-KatLedgerInstallRoot {
    if (-not (Test-Path -LiteralPath $script:installRoot)) {
        return
    }

    foreach ($child in @(Get-ChildItem -LiteralPath $script:installRoot -Force)) {
        if ($script:preservedInstallEntries -contains $child.Name) {
            continue
        }

        Remove-Item -LiteralPath $child.FullName -Recurse -Force
    }
}

function Install-KatLedgerRelease {
    $assetUrl = Get-KatLedgerReleaseAssetUrl

    New-Item -ItemType Directory -Path $script:katRoot -Force | Out-Null
    Remove-KatLedgerStagingArtifacts

    try {
        Invoke-WebRequest -Uri $assetUrl -OutFile $script:downloadPath
        Expand-Archive -LiteralPath $script:downloadPath -DestinationPath $script:stagingRoot -Force

        $sourceRoot = Get-KatLedgerStagedSourceRoot -StagingRoot $script:stagingRoot
        New-Item -ItemType Directory -Path $script:installRoot -Force | Out-Null
        Clear-KatLedgerInstallRoot

        foreach ($item in @(Get-ChildItem -LiteralPath $sourceRoot -Force)) {
            Copy-Item -LiteralPath $item.FullName -Destination $script:installRoot -Recurse -Force
        }

        if (-not (Test-Path -LiteralPath $script:exePath)) {
            throw "Downloaded asset did not produce $script:exePath."
        }

        $manifest = [pscustomobject]@{
            repository = $script:releaseRepository
            tag = $script:releaseTag
            asset = $script:releaseAssetName
            assetUrl = $assetUrl
            installedAtUtc = [DateTimeOffset]::UtcNow.ToString('O')
        }
        Write-KatJsonDocument -Path $script:manifestPath -Document $manifest
    }
    finally {
        Remove-KatLedgerStagingArtifacts
    }
}

function New-KatLedgerRuntimeState {
    $assetUrl = Get-KatLedgerReleaseAssetUrl
    $expectedRelease = Get-KatLedgerExpectedReleaseLabel
    $hasExe = Test-Path -LiteralPath $script:exePath
    $installedManifest = Get-KatLedgerInstalledManifest
    $manifestMatches = Test-KatLedgerInstalledManifestMatch -Manifest $installedManifest
    $installRequired = (-not $hasExe) -or (-not $manifestMatches)

    if (-not $installRequired) {
        $detail = "Release executable is available at $script:exePath, install root is $script:installRoot, and server-owned DB path is $script:canonicalDbPath."
        Add-Result -Client 'environment' -Status 'ok' -Method 'file' -Path $script:exePath -Detail $detail
        return [pscustomobject]@{
            Ready = $true
            Configurable = $true
            Blocked = $false
            Detail = $detail
        }
    }

    $requirementDetail = if ($installRequired -and -not $hasExe) {
        "Release executable is missing at $script:exePath."
    }
    else {
        "Installed KatLedger release metadata is not compliant. Expected $expectedRelease but found $(Get-KatLedgerInstalledManifestLabel -Manifest $installedManifest)."
    }

    if ($CheckOnly) {
        $detail = "$requirementDetail Expected download URL: $assetUrl"
        Add-Result -Client 'environment' -Status 'needs-install' -Method 'release' -Path $script:exePath -Detail $detail
        return [pscustomobject]@{
            Ready = $false
            Configurable = $false
            Blocked = $false
            Detail = $detail
        }
    }

    if (Test-KatDryRun) {
        $detail = "Would download $expectedRelease from $assetUrl and deploy it to $script:installRoot so $script:exePath owns DB path $script:canonicalDbPath."

        Add-Result -Client 'environment' -Status 'preview' -Method 'release' -Path $script:exePath -Detail $detail
        return [pscustomobject]@{
            Ready = $false
            Configurable = $true
            Blocked = $false
            Detail = $detail
        }
    }

    try {
        Install-KatLedgerRelease
    }
    catch {
        $detail = "KatLedger runtime preparation failed. Expected release source is $assetUrl. $(Get-CompactMessage $_.Exception.Message)"
        Add-Result -Client 'environment' -Status 'blocked' -Method 'release' -Path $script:exePath -Detail $detail
        return [pscustomobject]@{
            Ready = $false
            Configurable = $false
            Blocked = $true
            Detail = $detail
        }
    }

    if (-not (Test-Path -LiteralPath $script:exePath)) {
        $detail = "KatLedger release install completed but $script:exePath was not produced from $assetUrl."
        Add-Result -Client 'environment' -Status 'blocked' -Method 'release' -Path $script:exePath -Detail $detail
        return [pscustomobject]@{
            Ready = $false
            Configurable = $false
            Blocked = $true
            Detail = $detail
        }
    }

    $detail = if ($installRequired) {
        "Installed $expectedRelease from $assetUrl to $script:installRoot. Executable path is $script:exePath and server-owned DB path is $script:canonicalDbPath."
    }
    else {
        "KatLedger release at $script:exePath is already current and owns DB path $script:canonicalDbPath."
    }

    Add-Result -Client 'environment' -Status 'ok' -Method 'release' -Path $script:exePath -Detail $detail
    return [pscustomobject]@{
        Ready = $true
        Configurable = $true
        Blocked = $false
        Detail = $detail
    }
}

function Get-KatLedgerCheckOnlyStatus {
    param([object]$RuntimeState)

    if ($RuntimeState.Blocked) {
        return 'blocked'
    }

    return 'needs-install'
}

function Get-KatLedgerCheckOnlyDetail {
    param(
        [object]$RuntimeState,
        [string]$ModeTransition,
        [switch]$ToolsMismatch
    )

    $detail = "Needs local KatLedger stdio configuration ($ModeTransition) pointing at $script:exePath."
    if ($ToolsMismatch) {
        $detail += " Copilot CLI tools must be exactly: $($script:toolNames -join ', ')."
    }

    if ($RuntimeState.Ready) {
        return $detail
    }

    if ($RuntimeState.Blocked) {
        return "$detail Runtime is blocked: $($RuntimeState.Detail)"
    }

    return "$detail Runtime is not ready: $($RuntimeState.Detail)"
}

function New-KatLedgerServerDefinition {
    param(
        [object]$Existing,
        [switch]$IncludeTools
    )

    $server = [ordered]@{
        type = 'stdio'
        command = $script:exePath
        args = @()
    }

    if ($IncludeTools) {
        $server['tools'] = @($script:toolNames)
    }

    $gallery = [string](Get-KatProp $Existing 'gallery')
    $version = [string](Get-KatProp $Existing 'version')
    if (-not [string]::IsNullOrWhiteSpace($gallery)) {
        $server['gallery'] = $gallery
    }

    if (-not [string]::IsNullOrWhiteSpace($version)) {
        $server['version'] = $version
    }

    return [pscustomobject]$server
}

function Test-VsCodeInstalled {
    $vscodeUserRoot = Join-Path $env:APPDATA 'Code\User'
    return (Test-KatCommandAvailable -Name 'code') -or (Test-Path -LiteralPath $vscodeUserRoot)
}

function Set-VsCodeKatLedger {
    param([object]$RuntimeState)

    if ($SkipVsCode) {
        Add-Result -Client 'vscode' -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    if (-not (Test-VsCodeInstalled)) {
        Add-Result -Client 'vscode' -Status 'no-client' -Method 'none' -Path '-' -Detail 'VS Code user profile was not detected.'
        return
    }

    $vscodeUserRoot = Join-Path $env:APPDATA 'Code\User'
    $mcpPath = Join-Path $vscodeUserRoot 'mcp.json'

    Invoke-KatClientConfigAction -Results $script:results -Client 'vscode' -ConfigPath $mcpPath -ServersPropertyName 'servers' -ResolveExisting {
        param($servers)
        return Get-KatProp $servers $script:serverName
    } -Action {
        param($config, $servers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingCommand = [string](Get-KatProp $existing 'command')
        $existingArgs = @((Get-KatProp $existing 'args'))
        $modeTransition = Get-KatLedgerModeTransitionLabel -ExistingType $existingType

        $isCompliant = $RuntimeState.Ready -and
            $existingType -ieq 'stdio' -and
            (Test-KatLedgerCommandMatch $existingCommand) -and
            (Test-KatLedgerArgsMatch $existingArgs)

        if ($isCompliant) {
            Add-Result -Client 'vscode' -Status 'ok' -Method 'file' -Path $configPath -Detail "Already configured for local KatLedger stdio using $script:exePath."
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'vscode' -Status (Get-KatLedgerCheckOnlyStatus -RuntimeState $RuntimeState) -Method 'file' -Path $configPath -Detail (Get-KatLedgerCheckOnlyDetail -RuntimeState $RuntimeState -ModeTransition $modeTransition)
            return
        }

        if (-not $RuntimeState.Configurable) {
            Add-Result -Client 'vscode' -Status 'blocked' -Method 'file' -Path $configPath -Detail "KatLedger runtime is unavailable, so VS Code config was not updated. $($RuntimeState.Detail)"
            return
        }

        $servers | Add-Member -NotePropertyName $script:serverName -NotePropertyValue (New-KatLedgerServerDefinition -Existing $existing) -Force
        [void](Complete-KatFileMutation -Results $script:results -Client 'vscode' -ConfigPath $configPath -Document $config -PreviewDetail "Would configure local KatLedger stdio server ($modeTransition) to run $script:exePath." -SuccessDetail "Configured local KatLedger stdio server ($modeTransition) to run $script:exePath.")
    }
}

function Set-CopilotCliKatLedger {
    param([object]$RuntimeState)

    if ($SkipCopilotCli) {
        Add-Result -Client 'copilot-cli' -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $copilotRoot = Join-Path $env:USERPROFILE '.copilot'
    $copilotInstalled = (Test-KatCommandAvailable -Name 'copilot') -or (Test-Path -LiteralPath $copilotRoot)
    if (-not $copilotInstalled) {
        Add-Result -Client 'copilot-cli' -Status 'no-client' -Method 'none' -Path '-' -Detail 'Copilot CLI is not installed; no client artifacts were created.'
        return
    }

    $mcpConfigPath = Join-Path $copilotRoot 'mcp-config.json'

    Invoke-KatClientConfigAction -Results $script:results -Client 'copilot-cli' -ConfigPath $mcpConfigPath -ServersPropertyName 'mcpServers' -ResolveExisting {
        param($mcpServers)
        return Get-KatProp $mcpServers $script:serverName
    } -Action {
        param($config, $mcpServers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingCommand = [string](Get-KatProp $existing 'command')
        $existingArgs = @((Get-KatProp $existing 'args'))
        $existingTools = @((Get-KatProp $existing 'tools'))
        $modeTransition = Get-KatLedgerModeTransitionLabel -ExistingType $existingType
        $toolsMatch = Test-KatLedgerToolsMatch $existingTools

        $isCompliant = $RuntimeState.Ready -and
            $existingType -ieq 'stdio' -and
            (Test-KatLedgerCommandMatch $existingCommand) -and
            (Test-KatLedgerArgsMatch $existingArgs) -and
            $toolsMatch

        if ($isCompliant) {
            Add-Result -Client 'copilot-cli' -Status 'ok' -Method 'file' -Path $configPath -Detail "Already configured for local KatLedger stdio using $script:exePath with scoped tools."
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'copilot-cli' -Status (Get-KatLedgerCheckOnlyStatus -RuntimeState $RuntimeState) -Method 'file' -Path $configPath -Detail (Get-KatLedgerCheckOnlyDetail -RuntimeState $RuntimeState -ModeTransition $modeTransition -ToolsMismatch:(-not $toolsMatch))
            return
        }

        if (-not $RuntimeState.Configurable) {
            Add-Result -Client 'copilot-cli' -Status 'blocked' -Method 'file' -Path $configPath -Detail "KatLedger runtime is unavailable, so Copilot CLI config was not updated. $($RuntimeState.Detail)"
            return
        }

        $mcpServers | Add-Member -NotePropertyName $script:serverName -NotePropertyValue (New-KatLedgerServerDefinition -Existing $existing -IncludeTools) -Force
        [void](Complete-KatFileMutation -Results $script:results -Client 'copilot-cli' -ConfigPath $configPath -Document $config -PreviewDetail "Would configure local KatLedger stdio server ($modeTransition) to run $script:exePath with tools $($script:toolNames -join ', ')." -SuccessDetail "Configured local KatLedger stdio server ($modeTransition) to run $script:exePath with scoped tools.")
    }
}

function Set-ClaudeKatLedger {
    param([object]$RuntimeState)

    if ($SkipClaude) {
        Add-Result -Client 'claude' -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    if (-not (Test-KatClaudeInstalled)) {
        Add-Result -Client 'claude' -Status 'no-client' -Method 'none' -Path '-' -Detail 'Claude CLI/extension not detected.'
        return
    }

    $claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'

    Invoke-KatClientConfigAction -Results $script:results -Client 'claude' -ConfigPath $claudeConfigPath -ServersPropertyName 'mcpServers' -ResolveExisting {
        param($mcpServers)
        return Get-KatProp $mcpServers $script:serverName
    } -Action {
        param($config, $mcpServers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingCommand = [string](Get-KatProp $existing 'command')
        $existingArgs = @((Get-KatProp $existing 'args'))
        $modeTransition = Get-KatLedgerModeTransitionLabel -ExistingType $existingType

        $isCompliant = $RuntimeState.Ready -and
            $existingType -ieq 'stdio' -and
            (Test-KatLedgerCommandMatch $existingCommand) -and
            (Test-KatLedgerArgsMatch $existingArgs)

        if ($isCompliant) {
            Add-Result -Client 'claude' -Status 'ok' -Method 'file' -Path $configPath -Detail "Already configured for local KatLedger stdio using $script:exePath."
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'claude' -Status (Get-KatLedgerCheckOnlyStatus -RuntimeState $RuntimeState) -Method 'file' -Path $configPath -Detail (Get-KatLedgerCheckOnlyDetail -RuntimeState $RuntimeState -ModeTransition $modeTransition)
            return
        }

        if (-not $RuntimeState.Configurable) {
            Add-Result -Client 'claude' -Status 'blocked' -Method 'file' -Path $configPath -Detail "KatLedger runtime is unavailable, so Claude config was not updated. $($RuntimeState.Detail)"
            return
        }

        $mcpServers | Add-Member -NotePropertyName $script:serverName -NotePropertyValue (New-KatLedgerServerDefinition -Existing $existing) -Force
        [void](Complete-KatFileMutation -Results $script:results -Client 'claude' -ConfigPath $configPath -Document $config -PreviewDetail "Would configure local KatLedger stdio server ($modeTransition) to run $script:exePath." -SuccessDetail "Configured local KatLedger stdio server ($modeTransition) to run $script:exePath.")
    }
}

$runtimeState = New-KatLedgerRuntimeState

Set-VsCodeKatLedger -RuntimeState $runtimeState
Set-CopilotCliKatLedger -RuntimeState $runtimeState
Set-ClaudeKatLedger -RuntimeState $runtimeState
if (-not $PassThru) {
    Write-KatResultSummary -ServerName 'KatLedger' -Results @($script:results.ToArray())
}

if ($PassThru) {
    return (New-KatBootstrapPassThru -Results @($script:results.ToArray()) -CredentialAvailable $runtimeState.Ready)
}

if (-not $CheckOnly -and @($script:results | Where-Object Status -eq 'blocked').Count -gt 0) {
    throw 'KatLedger bootstrap did not complete successfully. See blocked entries above.'
}

