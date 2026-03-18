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

$script:context7Url = 'https://mcp.context7.com/mcp'
$script:sharedEnvReference = '${CONTEXT7_API_KEY}'
$script:vsCodeEnvReference = '${env:CONTEXT7_API_KEY}'
$script:results = New-Object System.Collections.Generic.List[object]

function Add-Result {
    param(
        [string]$Client,
        [string]$Status,
        [string]$Method,
        [string]$Path,
        [string]$Detail
    )

    $script:results.Add([pscustomobject]@{
        Client = $Client
        Status = $Status
        Method = $Method
        Path = $Path
        Detail = $Detail
    })
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

function Test-CommandAvailable {
    param([string]$Name)

    return $null -ne (Get-Command $Name -ErrorAction SilentlyContinue)
}

function Test-IsDryRun {
    return [bool]$WhatIfPreference
}

function Test-IsInteractiveHost {
    return [Environment]::UserInteractive -and $Host.Name -ne 'ServerRemoteHost'
}

function Read-JsonDocument {
    param(
        [string]$Path,
        [scriptblock]$DefaultFactory
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return & $DefaultFactory
    }

    try {
        return ConvertFrom-Json (Get-Content -LiteralPath $Path -Raw)
    }
    catch {
        throw "Invalid JSON at '$Path'."
    }
}

function Write-JsonDocument {
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

function Get-OrAddObjectProperty {
    param(
        [object]$Object,
        [string]$PropertyName,
        [object]$DefaultValue
    )

    if ($null -eq (Get-Prop $Object $PropertyName)) {
        $Object | Add-Member -NotePropertyName $PropertyName -NotePropertyValue $DefaultValue -Force
    }

    return (Get-Prop $Object $PropertyName)
}

function Test-Context7ApiKeyEnvAvailable {
    $scopes = @('Process', 'User', 'Machine')
    foreach ($scope in $scopes) {
        $value = [Environment]::GetEnvironmentVariable('CONTEXT7_API_KEY', $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $true
        }
    }

    return $false
}

function Get-ModeTransitionLabel {
    param([string]$ExistingType)

    if ([string]::IsNullOrWhiteSpace($ExistingType)) {
        return 'new remote config'
    }

    if ($ExistingType -ieq 'http') {
        return 'already remote (http)'
    }

    return "switching from $ExistingType to http"
}

function Show-MissingApiKeyInstructions {
    Write-Host ''
    Write-Host 'KAT Policies did not install Context7 MCP because CONTEXT7_API_KEY is missing.' -ForegroundColor Yellow
    Write-Host ''
    Write-Host 'To fix this:'
    Write-Host '  1. Go to https://context7.com and sign in (or create an account).'
    Write-Host '  2. In your account profile, create a new API key named "KAT API Key".'
    Write-Host '  3. Store the API key securely.'
    Write-Host '  4. Set CONTEXT7_API_KEY in your environment:'
    Write-Host '     [Environment]::SetEnvironmentVariable("CONTEXT7_API_KEY", "<your-key>", "User")'
    Write-Host '  5. Open a new terminal and rerun this command:'
    Write-Host ('     & "{0}"' -f $PSCommandPath)
    Write-Host ''
}

function Ensure-Context7ApiKeyAvailable {
    if (Test-Context7ApiKeyEnvAvailable) {
        return $true
    }

    if ($CheckOnly) {
        Add-Result -Client 'environment' -Status 'blocked' -Method 'env' -Path '-' -Detail 'CONTEXT7_API_KEY is missing in Process/User/Machine scope.'
        return $false
    }

    while (-not (Test-Context7ApiKeyEnvAvailable)) {
        Show-MissingApiKeyInstructions

        if (-not (Test-IsInteractiveHost)) {
            throw 'CONTEXT7_API_KEY is not set in Process, User, or Machine scope. Set it first.'
        }

        $choice = Read-Host 'Select [1] Continue after setting key, [2] Cancel'
        switch ($choice) {
            '1' { }
            '2' { throw 'Context7 installation cancelled by user because CONTEXT7_API_KEY is missing.' }
            default {
                Write-Host 'Invalid option. Enter 1 or 2.' -ForegroundColor Yellow
            }
        }
    }

    return $true
}

function Remove-VsCodeContext7InputDefinition {
    param([object]$Config)

    $inputsValue = Get-Prop $Config 'inputs'
    if ($null -eq $inputsValue) {
        return
    }

    $cleanInputs = @()
    foreach ($input in @($inputsValue)) {
        if ([string](Get-Prop $input 'id') -ne 'CONTEXT7_API_KEY') {
            $cleanInputs += $input
        }
    }

    $Config | Add-Member -NotePropertyName 'inputs' -NotePropertyValue $cleanInputs -Force
}

function Set-VsCodeContext7 {
    if ($SkipVsCode) {
        Add-Result -Client 'vscode' -Status 'skipped' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $vscodeUserRoot = Join-Path $env:APPDATA 'Code\User'
    $codeInstalled = (Test-CommandAvailable -Name 'code') -or (Test-Path -LiteralPath $vscodeUserRoot)
    if (-not $codeInstalled) {
        Add-Result -Client 'vscode' -Status 'skipped' -Method 'none' -Path '-' -Detail 'VS Code not detected.'
        return
    }

    $mcpPath = Join-Path $vscodeUserRoot 'mcp.json'

    try {
        $config = Read-JsonDocument -Path $mcpPath -DefaultFactory { [pscustomobject]@{} }
        $servers = Get-OrAddObjectProperty -Object $config -PropertyName 'servers' -DefaultValue ([pscustomobject]@{})
        $existing = Get-Prop $servers 'io.github.upstash/context7'

        $existingType = [string](Get-Prop $existing 'type')
        $existingUrl = [string](Get-Prop $existing 'url')
        $existingHeader = [string](Get-Prop (Get-Prop $existing 'headers') 'CONTEXT7_API_KEY')
        $modeTransition = Get-ModeTransitionLabel -ExistingType $existingType

        $isCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $script:context7Url -and
            $existingHeader -eq $script:vsCodeEnvReference

        if ($isCompliant) {
            Add-Result -Client 'vscode' -Status 'ok' -Method 'file' -Path $mcpPath -Detail 'Already configured for remote Context7 using environment variable reference.'
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'vscode' -Status 'needs-install' -Method 'file' -Path $mcpPath -Detail ("Needs remote Context7 configuration ($modeTransition).")
            return
        }

        $server = [ordered]@{
            type = 'http'
            url = $script:context7Url
            headers = [ordered]@{
                CONTEXT7_API_KEY = $script:vsCodeEnvReference
            }
        }

        $gallery = [string](Get-Prop $existing 'gallery')
        $version = [string](Get-Prop $existing 'version')
        if (-not [string]::IsNullOrWhiteSpace($gallery)) {
            $server['gallery'] = $gallery
        }

        if (-not [string]::IsNullOrWhiteSpace($version)) {
            $server['version'] = $version
        }

        $servers | Add-Member -NotePropertyName 'io.github.upstash/context7' -NotePropertyValue ([pscustomobject]$server) -Force
        Remove-VsCodeContext7InputDefinition -Config $config

        if (Test-IsDryRun) {
            Add-Result -Client 'vscode' -Status 'preview' -Method 'file' -Path $mcpPath -Detail ("Would configure remote Context7 ($modeTransition) using $script:vsCodeEnvReference.")
            return
        }

        Write-JsonDocument -Path $mcpPath -Document $config
        Add-Result -Client 'vscode' -Status 'ok' -Method 'file' -Path $mcpPath -Detail ("Configured remote Context7 ($modeTransition) using $script:vsCodeEnvReference.")
    }
    catch {
        Add-Result -Client 'vscode' -Status 'blocked' -Method 'file' -Path $mcpPath -Detail $_.Exception.Message
    }
}

function Set-CopilotCliContext7 {
    if ($SkipCopilotCli) {
        Add-Result -Client 'copilot-cli' -Status 'skipped' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $copilotRoot = Join-Path $env:USERPROFILE '.copilot'
    $copilotInstalled = (Test-CommandAvailable -Name 'copilot') -or (Test-Path -LiteralPath $copilotRoot)
    if (-not $copilotInstalled) {
        Add-Result -Client 'copilot-cli' -Status 'skipped' -Method 'none' -Path '-' -Detail 'Copilot CLI not detected.'
        return
    }

    $mcpConfigPath = Join-Path $copilotRoot 'mcp-config.json'

    try {
        $config = Read-JsonDocument -Path $mcpConfigPath -DefaultFactory { [pscustomobject]@{} }
        $mcpServers = Get-OrAddObjectProperty -Object $config -PropertyName 'mcpServers' -DefaultValue ([pscustomobject]@{})
        $existing = Get-Prop $mcpServers 'context7'

        $existingType = [string](Get-Prop $existing 'type')
        $existingUrl = [string](Get-Prop $existing 'url')
        $existingHeader = [string](Get-Prop (Get-Prop $existing 'headers') 'CONTEXT7_API_KEY')
        $existingTools = @((Get-Prop $existing 'tools'))
        $modeTransition = Get-ModeTransitionLabel -ExistingType $existingType

        $isCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $script:context7Url -and
            $existingHeader -eq $script:sharedEnvReference -and
            ($existingTools -contains '*')

        if ($isCompliant) {
            Add-Result -Client 'copilot-cli' -Status 'ok' -Method 'file' -Path $mcpConfigPath -Detail 'Already configured for remote Context7 using environment variable reference.'
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'copilot-cli' -Status 'needs-install' -Method 'file' -Path $mcpConfigPath -Detail ("Needs remote Context7 configuration ($modeTransition).")
            return
        }

        $mcpServers | Add-Member -NotePropertyName 'context7' -NotePropertyValue ([pscustomobject]@{
                type = 'http'
                url = $script:context7Url
                headers = [pscustomobject]@{
                    CONTEXT7_API_KEY = $script:sharedEnvReference
                }
                tools = @('*')
            }) -Force

        if (Test-IsDryRun) {
            Add-Result -Client 'copilot-cli' -Status 'preview' -Method 'file' -Path $mcpConfigPath -Detail ("Would configure remote Context7 ($modeTransition) using $script:sharedEnvReference.")
            return
        }

        Write-JsonDocument -Path $mcpConfigPath -Document $config
        Add-Result -Client 'copilot-cli' -Status 'ok' -Method 'file' -Path $mcpConfigPath -Detail ("Configured remote Context7 ($modeTransition) using $script:sharedEnvReference.")
    }
    catch {
        Add-Result -Client 'copilot-cli' -Status 'blocked' -Method 'file' -Path $mcpConfigPath -Detail $_.Exception.Message
    }
}

function Test-ClaudeVsCodeExtensionInstalled {
    if (-not (Test-CommandAvailable -Name 'code')) {
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

function Set-ClaudeContext7 {
    if ($SkipClaude) {
        Add-Result -Client 'claude' -Status 'skipped' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'
    $claudeInstalled = (Test-CommandAvailable -Name 'claude') -or (Test-Path -LiteralPath $claudeConfigPath) -or (Test-Path -LiteralPath (Join-Path $env:USERPROFILE '.claude')) -or (Test-ClaudeVsCodeExtensionInstalled)
    if (-not $claudeInstalled) {
        Add-Result -Client 'claude' -Status 'skipped' -Method 'none' -Path '-' -Detail 'Claude CLI/extension not detected.'
        return
    }

    try {
        $config = Read-JsonDocument -Path $claudeConfigPath -DefaultFactory { [pscustomobject]@{} }
        $mcpServers = Get-OrAddObjectProperty -Object $config -PropertyName 'mcpServers' -DefaultValue ([pscustomobject]@{})
        $existing = Get-Prop $mcpServers 'context7'

        $existingType = [string](Get-Prop $existing 'type')
        $existingUrl = [string](Get-Prop $existing 'url')
        $existingHeader = [string](Get-Prop (Get-Prop $existing 'headers') 'CONTEXT7_API_KEY')
        $modeTransition = Get-ModeTransitionLabel -ExistingType $existingType

        $isCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $script:context7Url -and
            $existingHeader -eq $script:sharedEnvReference

        if ($isCompliant) {
            Add-Result -Client 'claude' -Status 'ok' -Method 'file' -Path $claudeConfigPath -Detail 'Already configured for remote Context7 using environment variable reference.'
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'claude' -Status 'needs-install' -Method 'file' -Path $claudeConfigPath -Detail ("Needs remote Context7 configuration ($modeTransition).")
            return
        }

        $mcpServers | Add-Member -NotePropertyName 'context7' -NotePropertyValue ([pscustomobject]@{
                type = 'http'
                url = $script:context7Url
                headers = [pscustomobject]@{
                    CONTEXT7_API_KEY = $script:sharedEnvReference
                }
            }) -Force

        if (Test-IsDryRun) {
            Add-Result -Client 'claude' -Status 'preview' -Method 'file' -Path $claudeConfigPath -Detail ("Would configure remote Context7 ($modeTransition) using $script:sharedEnvReference.")
            return
        }

        Write-JsonDocument -Path $claudeConfigPath -Document $config
        Add-Result -Client 'claude' -Status 'ok' -Method 'file' -Path $claudeConfigPath -Detail ("Configured remote Context7 ($modeTransition) using $script:sharedEnvReference.")
    }
    catch {
        Add-Result -Client 'claude' -Status 'blocked' -Method 'file' -Path $claudeConfigPath -Detail $_.Exception.Message
    }
}

function Write-ResultSummary {
    Write-Host '--- Context7 Remote Setup Summary ---' -ForegroundColor Cyan

    foreach ($result in $script:results) {
        $statusColor = switch ($result.Status) {
            'ok' { 'Green' }
            'preview' { 'Cyan' }
            'needs-install' { 'Yellow' }
            'skipped' { 'Yellow' }
            default { 'Red' }
        }

        $pathText = if ([string]::IsNullOrWhiteSpace($result.Path)) { '-' } else { $result.Path }
        Write-Host ("[{0}] {1} ({2})" -f $result.Status.ToUpperInvariant(), $result.Client, $result.Method) -ForegroundColor $statusColor
        Write-Host ("  path: {0}" -f $pathText)
        Write-Host ("  detail: {0}" -f $result.Detail)
    }
}

$apiKeyReady = Ensure-Context7ApiKeyAvailable

Set-VsCodeContext7
Set-CopilotCliContext7
Set-ClaudeContext7
Write-ResultSummary

$blockedCount = @($script:results | Where-Object Status -eq 'blocked').Count
$needsInstallCount = @($script:results | Where-Object Status -eq 'needs-install').Count
$isCompliant = $blockedCount -eq 0 -and $needsInstallCount -eq 0

if ($PassThru) {
    return [pscustomobject]@{
        ApiKeyAvailable = $apiKeyReady
        IsCompliant = $isCompliant
        HasBlocked = $blockedCount -gt 0
        RequiresInstall = $needsInstallCount -gt 0
        Results = @($script:results.ToArray())
    }
}

if (-not $CheckOnly -and $blockedCount -gt 0) {
    throw 'Context7 remote bootstrap did not complete successfully. See blocked entries above.'
}
