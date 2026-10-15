[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [switch]$SkipVsCode,
    [switch]$SkipCopilotCli,
    [switch]$SkipClaude,
    [switch]$CheckOnly,
    [switch]$NonInteractive,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($PSBoundParameters.ContainsKey('WhatIf')) {
    $WhatIfPreference = $true
}

$sharedModulePath = Join-Path $PSScriptRoot 'Kat.Policy.Mcp.psm1'
Import-Module $sharedModulePath -Force

$script:serverName = 'playwright'
$script:command = 'npx'
$script:commandArgs = @('-y', '@playwright/mcp@latest')
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

function New-PlaywrightServerDefinition {
    param(
        [string]$Type,
        [switch]$IncludeTools
    )

    $server = [ordered]@{
        command = $script:command
        args = @($script:commandArgs)
    }

    if (-not [string]::IsNullOrWhiteSpace($Type)) {
        $server['type'] = $Type
    }

    if ($IncludeTools) {
        $server['tools'] = @('*')
    }

    return [pscustomobject]$server
}

function Set-PlaywrightClient {
    param(
        [ValidateSet('vscode', 'copilot-cli', 'claude')]
        [string]$Client,
        [string]$ConfigPath,
        [string]$ServersPropertyName,
        [string]$Type,
        [switch]$IncludeTools,
        [switch]$Skip
    )

    if ($Skip) {
        Add-Result -Client $Client -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $clientInstalled = switch ($Client) {
        'vscode' { Test-KatVsCodeInstalled }
        'copilot-cli' { Test-KatCopilotCliInstalled }
        'claude' { Test-KatClaudeInstalled }
    }
    if (-not $clientInstalled) {
        $detail = switch ($Client) {
            'vscode' { 'VS Code user profile was not detected.' }
            'copilot-cli' { 'Copilot CLI is not installed; no client artifacts were created.' }
            'claude' { 'Claude CLI/extension not detected.' }
        }
        Add-Result -Client $Client -Status 'no-client' -Method 'none' -Path '-' -Detail $detail
        return
    }

    Invoke-KatClientConfigAction -Results $script:results -Client $Client -ConfigPath $ConfigPath -ServersPropertyName $ServersPropertyName -ResolveExisting {
        param($servers)
        return Get-KatProp $servers $script:serverName
    } -Action {
        param($config, $servers, $existing, $configPath)

        $existingCommand = [string](Get-KatProp $existing 'command')
        $existingArgs = @(Get-KatProp $existing 'args')
        $existingType = [string](Get-KatProp $existing 'type')
        $expectedTools = @()
        if ($IncludeTools) {
            $expectedTools = @('*')
        }
        $existingTools = @(Get-KatProp $existing 'tools')
        $toolsMatch = ($existingTools -join [char]0) -ceq ($expectedTools -join [char]0)
        $typeMatch = [string]::IsNullOrWhiteSpace($Type) -or $existingType -ieq $Type
        $isCompliant = $typeMatch -and
            $existingCommand -ieq $script:command -and
            ($existingArgs -join [char]0) -ceq ($script:commandArgs -join [char]0) -and
            $toolsMatch

        if ($isCompliant) {
            Add-Result -Client $Client -Status 'ok' -Method 'file' -Path $configPath -Detail 'Already configured for the Microsoft Playwright MCP server.'
            return
        }

        if ($CheckOnly) {
            Add-Result -Client $Client -Status 'needs-install' -Method 'file' -Path $configPath -Detail 'Needs Microsoft Playwright MCP configuration.'
            return
        }

        if ($WhatIfPreference) {
            Add-Result -Client $Client -Status 'preview' -Method 'file' -Path $configPath -Detail 'Would configure the Microsoft Playwright MCP server using npx.'
            return
        }

        $servers | Add-Member -NotePropertyName $script:serverName -NotePropertyValue (New-PlaywrightServerDefinition -Type $Type -IncludeTools:$IncludeTools) -Force
        [void](Complete-KatFileMutation -Results $script:results -Client $Client -ConfigPath $configPath -Document $config -PreviewDetail 'Would configure the Microsoft Playwright MCP server using npx.' -SuccessDetail 'Configured the Microsoft Playwright MCP server using npx.')
    }
}

if (-not (Test-KatCommandAvailable -Name 'npx')) {
    Add-Result -Client 'environment' -Status 'blocked' -Method 'command' -Path $script:command -Detail 'npx is required to run the Microsoft Playwright MCP server. Install Node.js 18 or newer.'
}

$vscodeConfigPath = Join-Path (Join-Path $env:APPDATA 'Code\User') 'mcp.json'
Set-PlaywrightClient -Client 'vscode' -ConfigPath $vscodeConfigPath -ServersPropertyName 'servers' -Type 'stdio' -Skip:$SkipVsCode

$copilotConfigPath = Join-Path (Join-Path $env:USERPROFILE '.copilot') 'mcp-config.json'
Set-PlaywrightClient -Client 'copilot-cli' -ConfigPath $copilotConfigPath -ServersPropertyName 'mcpServers' -Type 'local' -IncludeTools -Skip:$SkipCopilotCli

$claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'
Set-PlaywrightClient -Client 'claude' -ConfigPath $claudeConfigPath -ServersPropertyName 'mcpServers' -Type 'stdio' -Skip:$SkipClaude

if (-not $PassThru) {
    Write-KatResultSummary -ServerName 'Playwright' -Results @($script:results.ToArray())
}

if ($PassThru) {
    return (New-KatBootstrapPassThru -Results @($script:results.ToArray()) -CredentialAvailable $true)
}

if (-not $CheckOnly -and @($script:results | Where-Object Status -eq 'blocked').Count -gt 0) {
    throw 'Playwright MCP bootstrap did not complete successfully. See blocked entries above.'
}
