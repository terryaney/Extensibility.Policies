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

$sharedModulePath = Join-Path $PSScriptRoot 'Kat.Policy.Mcp.psm1'
Import-Module $sharedModulePath -Force

$script:context7Url = 'https://mcp.context7.com/mcp'
$script:sharedEnvReference = '${CONTEXT7_API_KEY}'
$script:vsCodeEnvReference = '${env:CONTEXT7_API_KEY}'
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

function Confirm-Context7ApiKeyAvailable {
    if (Test-Context7ApiKeyEnvAvailable) {
        return $true
    }

    if ($CheckOnly) {
        Add-Result -Client 'environment' -Status 'blocked' -Method 'env' -Path '-' -Detail 'CONTEXT7_API_KEY is missing in Process/User/Machine scope.'
        return $false
    }

    while (-not (Test-Context7ApiKeyEnvAvailable)) {
        Show-MissingApiKeyInstructions

        if (-not (Test-KatInteractiveHost)) {
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

    $inputsValue = Get-KatProp $Config 'inputs'
    if ($null -eq $inputsValue) {
        return
    }

    $cleanInputs = @()
    foreach ($inputDefinition in @($inputsValue)) {
        if ([string](Get-KatProp $inputDefinition 'id') -ne 'CONTEXT7_API_KEY') {
            $cleanInputs += $inputDefinition
        }
    }

    $Config | Add-Member -NotePropertyName 'inputs' -NotePropertyValue $cleanInputs -Force
}

function Set-VsCodeContext7 {
    if ($SkipVsCode) {
        Add-Result -Client 'vscode' -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $vscodeUserRoot = Join-Path $env:APPDATA 'Code\User'
    $mcpPath = Join-Path $vscodeUserRoot 'mcp.json'

    Invoke-KatClientConfigAction -Results $script:results -Client 'vscode' -ConfigPath $mcpPath -ServersPropertyName 'servers' -ResolveExisting {
        param($servers)
        return Get-KatProp $servers 'io.github.upstash/context7'
    } -Action {
        param($config, $servers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingUrl = [string](Get-KatProp $existing 'url')
        $existingHeader = [string](Get-KatProp (Get-KatProp $existing 'headers') 'CONTEXT7_API_KEY')
        $modeTransition = Get-KatModeTransitionLabel -ExistingType $existingType

        $isCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $script:context7Url -and
            $existingHeader -eq $script:vsCodeEnvReference

        if ($isCompliant) {
            Add-Result -Client 'vscode' -Status 'ok' -Method 'file' -Path $configPath -Detail 'Already configured for remote Context7 using environment variable reference.'
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'vscode' -Status 'needs-install' -Method 'file' -Path $configPath -Detail ("Needs remote Context7 configuration ($modeTransition).")
            return
        }

        $server = [ordered]@{
            type = 'http'
            url = $script:context7Url
            headers = [ordered]@{
                CONTEXT7_API_KEY = $script:vsCodeEnvReference
            }
        }

        $gallery = [string](Get-KatProp $existing 'gallery')
        $version = [string](Get-KatProp $existing 'version')
        if (-not [string]::IsNullOrWhiteSpace($gallery)) {
            $server['gallery'] = $gallery
        }

        if (-not [string]::IsNullOrWhiteSpace($version)) {
            $server['version'] = $version
        }

        $servers | Add-Member -NotePropertyName 'io.github.upstash/context7' -NotePropertyValue ([pscustomobject]$server) -Force
        Remove-VsCodeContext7InputDefinition -Config $config

        [void](Complete-KatFileMutation -Results $script:results -Client 'vscode' -ConfigPath $configPath -Document $config -PreviewDetail ("Would configure remote Context7 ($modeTransition) using $script:vsCodeEnvReference.") -SuccessDetail ("Configured remote Context7 ($modeTransition) using $script:vsCodeEnvReference."))
    }
}

function Set-CopilotCliContext7 {
    if ($SkipCopilotCli) {
        Add-Result -Client 'copilot-cli' -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $copilotRoot = Join-Path $env:USERPROFILE '.copilot'
    $copilotInstalled = (Test-KatCommandAvailable -Name 'copilot') -or (Test-Path -LiteralPath $copilotRoot)
    if (-not $copilotInstalled) {
        Add-Result -Client 'copilot-cli' -Status 'no-client' -Method 'none' -Path '-' -Detail 'Copilot CLI not detected.'
        return
    }

    $mcpConfigPath = Join-Path $copilotRoot 'mcp-config.json'

    Invoke-KatClientConfigAction -Results $script:results -Client 'copilot-cli' -ConfigPath $mcpConfigPath -ServersPropertyName 'mcpServers' -ResolveExisting {
        param($mcpServers)
        return Get-KatProp $mcpServers 'context7'
    } -Action {
        param($config, $mcpServers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingUrl = [string](Get-KatProp $existing 'url')
        $existingHeader = [string](Get-KatProp (Get-KatProp $existing 'headers') 'CONTEXT7_API_KEY')
        $existingTools = @((Get-KatProp $existing 'tools'))
        $modeTransition = Get-KatModeTransitionLabel -ExistingType $existingType

        $isCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $script:context7Url -and
            $existingHeader -eq $script:sharedEnvReference -and
            ($existingTools -contains '*')

        if ($isCompliant) {
            Add-Result -Client 'copilot-cli' -Status 'ok' -Method 'file' -Path $configPath -Detail 'Already configured for remote Context7 using environment variable reference.'
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'copilot-cli' -Status 'needs-install' -Method 'file' -Path $configPath -Detail ("Needs remote Context7 configuration ($modeTransition).")
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

        [void](Complete-KatFileMutation -Results $script:results -Client 'copilot-cli' -ConfigPath $configPath -Document $config -PreviewDetail ("Would configure remote Context7 ($modeTransition) using $script:sharedEnvReference.") -SuccessDetail ("Configured remote Context7 ($modeTransition) using $script:sharedEnvReference."))
    }
}

function Set-ClaudeContext7 {
    if ($SkipClaude) {
        Add-Result -Client 'claude' -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'
    if (-not (Test-KatClaudeInstalled)) {
        Add-Result -Client 'claude' -Status 'no-client' -Method 'none' -Path '-' -Detail 'Claude CLI/extension not detected.'
        return
    }

    Invoke-KatClientConfigAction -Results $script:results -Client 'claude' -ConfigPath $claudeConfigPath -ServersPropertyName 'mcpServers' -ResolveExisting {
        param($mcpServers)
        return Get-KatProp $mcpServers 'context7'
    } -Action {
        param($config, $mcpServers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingUrl = [string](Get-KatProp $existing 'url')
        $existingHeader = [string](Get-KatProp (Get-KatProp $existing 'headers') 'CONTEXT7_API_KEY')
        $modeTransition = Get-KatModeTransitionLabel -ExistingType $existingType

        $isCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $script:context7Url -and
            $existingHeader -eq $script:sharedEnvReference

        if ($isCompliant) {
            Add-Result -Client 'claude' -Status 'ok' -Method 'file' -Path $configPath -Detail 'Already configured for remote Context7 using environment variable reference.'
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'claude' -Status 'needs-install' -Method 'file' -Path $configPath -Detail ("Needs remote Context7 configuration ($modeTransition).")
            return
        }

        $mcpServers | Add-Member -NotePropertyName 'context7' -NotePropertyValue ([pscustomobject]@{
                type = 'http'
                url = $script:context7Url
                headers = [pscustomobject]@{
                    CONTEXT7_API_KEY = $script:sharedEnvReference
                }
            }) -Force

        [void](Complete-KatFileMutation -Results $script:results -Client 'claude' -ConfigPath $configPath -Document $config -PreviewDetail ("Would configure remote Context7 ($modeTransition) using $script:sharedEnvReference.") -SuccessDetail ("Configured remote Context7 ($modeTransition) using $script:sharedEnvReference."))
    }
}

$apiKeyReady = Confirm-Context7ApiKeyAvailable

Set-VsCodeContext7
Set-CopilotCliContext7
Set-ClaudeContext7
Write-KatResultSummary -Title 'Context7 Remote Setup Summary' -Results @($script:results.ToArray())

if ($PassThru) {
    return (New-KatBootstrapPassThru -Results @($script:results.ToArray()) -CredentialAvailable $apiKeyReady)
}

if (-not $CheckOnly -and @($script:results | Where-Object Status -eq 'blocked').Count -gt 0) {
    throw 'Context7 remote bootstrap did not complete successfully. See blocked entries above.'
}
