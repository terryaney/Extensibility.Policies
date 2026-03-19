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

$script:githubUrl = 'https://api.githubcopilot.com/mcp/'
$script:defaultGitHubPatEnvName = 'GITHUB_TOKEN'
$script:githubPatEnvNames = @('GITHUB_TOKEN', 'GITHUB_PERSONAL_ACCESS_TOKEN', 'GITHUB_PAT')
$script:githubPatGuidanceShown = $false
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

function Get-GitHubCanonicalUrl {
    param([string]$Url)

    if ([string]::IsNullOrWhiteSpace($Url)) {
        return ''
    }

    $trimmed = $Url.Trim()
    return ($trimmed.TrimEnd('/') + '/')
}

function Get-GitHubPatEnvName {
    $scopes = @('Process', 'User', 'Machine')
    foreach ($scope in $scopes) {
        foreach ($name in $script:githubPatEnvNames) {
            $value = [Environment]::GetEnvironmentVariable($name, $scope)
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return $name
            }
        }
    }

    return $null
}

function Test-GitHubPatEnvAvailable {
    return -not [string]::IsNullOrWhiteSpace((Get-GitHubPatEnvName))
}

function Get-GitHubPatEnvReference {
    $name = Get-GitHubPatEnvName
    if ([string]::IsNullOrWhiteSpace($name)) {
        $name = $script:defaultGitHubPatEnvName
    }

    return ('${' + $name + '}')
}

function Show-MissingGitHubPatInstructions {
    param([string]$Reason)

    if ($script:githubPatGuidanceShown) {
        return
    }

    $script:githubPatGuidanceShown = $true

    Write-Host ''
    Write-Host 'KAT Policies could not find GitHub PAT auth in environment variables.' -ForegroundColor Yellow
    if (-not [string]::IsNullOrWhiteSpace($Reason)) {
        Write-Host "Reason: $Reason" -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'GitHub auth is still required for this setup.' -ForegroundColor Yellow
    Write-Host 'To create and configure a GitHub PAT:'
    Write-Host '  1. Open: https://github.com/settings/tokens/new'
    Write-Host '  2. Create a token (classic is the simplest option for this workflow).'
    Write-Host '  3. Grant scopes: repo (add read:org/workflow if your workflows need them).'
    Write-Host '  4. Set this env var in User scope:'
    Write-Host '     [Environment]::SetEnvironmentVariable("GITHUB_TOKEN", "<your-token>", "User")'
    Write-Host '  5. Open a new terminal and rerun this command:'
    Write-Host ('     & "{0}"' -f $PSCommandPath)
    Write-Host ''
}

function Get-AuthModeDescription {
    param([object]$Headers)

    $authorization = [string](Get-KatProp $Headers 'Authorization')
    if ([string]::IsNullOrWhiteSpace($authorization)) {
        return 'host OAuth (no PAT header)'
    }

    if ($authorization -match '\$\{[^}]+\}') {
        return 'PAT via environment variable reference'
    }

    return 'PAT via literal Authorization header'
}

function Set-VsCodeGitHubRemote {
    if ($SkipVsCode) {
        Add-Result -Client 'vscode' -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    $vscodeUserRoot = Join-Path $env:APPDATA 'Code\User'
    $mcpPath = Join-Path $vscodeUserRoot 'mcp.json'
    $serverName = 'io.github.github/github-mcp-server'

    Invoke-KatClientConfigAction -Results $script:results -Client 'vscode' -ConfigPath $mcpPath -ServersPropertyName 'servers' -ResolveExisting {
        param($servers)
        return Get-KatProp $servers $serverName
    } -Action {
        param($config, $servers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingUrl = Get-GitHubCanonicalUrl ([string](Get-KatProp $existing 'url'))
        $existingHeaders = Get-KatProp $existing 'headers'
        $existingReadonlyHeader = [string](Get-KatProp $existingHeaders 'X-MCP-Readonly')
        $modeTransition = Get-KatModeTransitionLabel -ExistingType $existingType
        $targetUrl = Get-GitHubCanonicalUrl $script:githubUrl
        $isReadOnlyByHeader = Test-KatTruthySettingValue $existingReadonlyHeader

        $isCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $targetUrl -and
            -not $isReadOnlyByHeader

        if ($isCompliant) {
            $authMode = Get-AuthModeDescription -Headers $existingHeaders
            Add-Result -Client 'vscode' -Status 'ok' -Method 'file' -Path $configPath -Detail "Already configured for remote GitHub MCP using $authMode."
            return
        }

        if ($CheckOnly) {
            Add-Result -Client 'vscode' -Status 'needs-install' -Method 'file' -Path $configPath -Detail "Needs remote GitHub MCP configuration ($modeTransition)."
            return
        }

        $server = [ordered]@{
            type = 'http'
            url = $script:githubUrl
        }

        if ($null -ne $existingHeaders) {
            $headerMap = [ordered]@{}
            foreach ($property in @($existingHeaders.PSObject.Properties)) {
                $headerName = [string]$property.Name
                if ([string]::IsNullOrWhiteSpace($headerName) -or $headerName -ieq 'X-MCP-Readonly') {
                    continue
                }

                $headerMap[$headerName] = [string]$property.Value
            }

            if ($headerMap.Count -gt 0) {
                $server['headers'] = [pscustomobject]$headerMap
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

        $servers | Add-Member -NotePropertyName $serverName -NotePropertyValue ([pscustomobject]$server) -Force

        $configuredHeaders = if ($server.Contains('headers')) { $server['headers'] } else { $null }
        $authMode = Get-AuthModeDescription -Headers $configuredHeaders
        [void](Complete-KatFileMutation -Results $script:results -Client 'vscode' -ConfigPath $configPath -Document $config -PreviewDetail "Would configure remote GitHub MCP ($modeTransition)." -SuccessDetail "Configured remote GitHub MCP ($modeTransition) using $authMode.")
    }
}

function Set-CopilotCliGitHubRemote {
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
        $existing = Get-KatProp $mcpServers 'github-mcp-server'
        if ($null -eq $existing) {
            $existing = Get-KatProp $mcpServers 'github'
        }

        return $existing
    } -Action {
        param($config, $mcpServers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingUrl = Get-GitHubCanonicalUrl ([string](Get-KatProp $existing 'url'))
        $targetUrl = Get-GitHubCanonicalUrl $script:githubUrl
        $existingHeaders = Get-KatProp $existing 'headers'
        $existingAuthorization = [string](Get-KatProp $existingHeaders 'Authorization')
        $existingReadonlyHeader = [string](Get-KatProp $existingHeaders 'X-MCP-Readonly')
        $existingTools = @((Get-KatProp $existing 'tools'))

        $isReadOnlyByUrl = $existingUrl -like '*/readonly/'
        $isReadOnlyByHeader = Test-KatTruthySettingValue $existingReadonlyHeader
        $hasAllTools = $existingTools -contains '*'

        $isCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $targetUrl -and
            -not $isReadOnlyByUrl -and
            -not $isReadOnlyByHeader -and
            $hasAllTools

        if ($isCompliant) {
            $authMode = Get-AuthModeDescription -Headers (Get-KatProp $existing 'headers')
            Add-Result -Client 'copilot-cli' -Status 'ok' -Method 'file' -Path $configPath -Detail "Already configured for remote GitHub MCP (non-readonly) using $authMode."
            return
        }

        $patAvailable = Test-GitHubPatEnvAvailable
        $patReference = Get-GitHubPatEnvReference

        if (-not $patAvailable) {
            Show-MissingGitHubPatInstructions -Reason 'Copilot CLI remote override can use host OAuth best effort, but PAT is recommended for reliable authenticated write operations.'
        }

        if ($CheckOnly) {
            if ($patAvailable) {
                Add-Result -Client 'copilot-cli' -Status 'needs-install' -Method 'file' -Path $configPath -Detail "Needs remote non-readonly GitHub MCP override (github-mcp-server) using PAT reference $patReference."
            }
            elseif (-not [string]::IsNullOrWhiteSpace($existingAuthorization)) {
                Add-Result -Client 'copilot-cli' -Status 'needs-install' -Method 'file' -Path $configPath -Detail 'Needs remote non-readonly GitHub MCP override (github-mcp-server) while preserving the existing Authorization header.'
            }
            else {
                Add-Result -Client 'copilot-cli' -Status 'needs-install' -Method 'file' -Path $configPath -Detail 'Needs remote non-readonly GitHub MCP override (github-mcp-server) using host OAuth best effort (no PAT header found).'
            }

            return
        }

        $server = [ordered]@{
            type = 'http'
            url = $script:githubUrl
            tools = @('*')
        }

        $headerMap = [ordered]@{}
        if ($null -ne $existingHeaders) {
            foreach ($property in @($existingHeaders.PSObject.Properties)) {
                $headerName = [string]$property.Name
                if ([string]::IsNullOrWhiteSpace($headerName)) {
                    continue
                }

                if ($headerName -ieq 'Authorization') {
                    continue
                }

                if ($headerName -ieq 'X-MCP-Readonly') {
                    continue
                }

                $headerMap[$headerName] = [string]$property.Value
            }
        }

        if ($patAvailable) {
            $headerMap['Authorization'] = "Bearer $patReference"
        }
        elseif (-not [string]::IsNullOrWhiteSpace($existingAuthorization)) {
            $headerMap['Authorization'] = $existingAuthorization
        }

        if ($headerMap.Count -gt 0) {
            $server['headers'] = [pscustomobject]$headerMap
        }

        $mcpServers | Add-Member -NotePropertyName 'github-mcp-server' -NotePropertyValue ([pscustomobject]$server) -Force

        if ($null -ne (Get-KatProp $mcpServers 'github')) {
            $null = $mcpServers.PSObject.Properties.Remove('github')
        }

        $configuredHeaders = if ($server.Contains('headers')) { $server['headers'] } else { $null }
        $authMode = Get-AuthModeDescription -Headers $configuredHeaders
        $previewDetail = if ($patAvailable) {
            "Would configure remote non-readonly GitHub MCP override (github-mcp-server) using PAT reference $patReference."
        }
        else {
            'Would configure remote non-readonly GitHub MCP override (github-mcp-server) using host OAuth best effort (no PAT header found).'
        }
        $successDetail = if ($patAvailable) {
            "Configured remote non-readonly GitHub MCP override (github-mcp-server) using PAT reference $patReference."
        }
        elseif (-not [string]::IsNullOrWhiteSpace($existingAuthorization)) {
            "Configured remote non-readonly GitHub MCP override (github-mcp-server) while preserving $authMode."
        }
        else {
            'Configured remote non-readonly GitHub MCP override (github-mcp-server) using host OAuth best effort (no PAT header found).'
        }

        [void](Complete-KatFileMutation -Results $script:results -Client 'copilot-cli' -ConfigPath $configPath -Document $config -PreviewDetail $previewDetail -SuccessDetail $successDetail)
    }
}

function Set-ClaudeGitHub {
    if ($SkipClaude) {
        Add-Result -Client 'claude' -Status 'user-skip' -Method 'none' -Path '-' -Detail 'Skipped by parameter.'
        return
    }

    if (-not (Test-KatClaudeInstalled)) {
        Add-Result -Client 'claude' -Status 'no-client' -Method 'none' -Path '-' -Detail 'Claude client is not installed; no client artifacts were created.'
        return
    }

    $claudeConfigPath = Join-Path $env:USERPROFILE '.claude.json'
    $targetUrl = Get-GitHubCanonicalUrl $script:githubUrl

    Invoke-KatClientConfigAction -Results $script:results -Client 'claude' -ConfigPath $claudeConfigPath -ServersPropertyName 'mcpServers' -ResolveExisting {
        param($mcpServers)
        return Get-KatProp $mcpServers 'github'
    } -Action {
        param($config, $mcpServers, $existing, $configPath)

        $existingType = [string](Get-KatProp $existing 'type')
        $existingUrl = Get-GitHubCanonicalUrl ([string](Get-KatProp $existing 'url'))
        $existingHeaders = Get-KatProp $existing 'headers'
        $existingAuthorization = [string](Get-KatProp $existingHeaders 'Authorization')
        $existingReadonlyHeader = [string](Get-KatProp $existingHeaders 'X-MCP-Readonly')
        $existingCommand = [string](Get-KatProp $existing 'command')
        $modeTransition = Get-KatModeTransitionLabel -ExistingType $existingType
        $hasRemoteAuthorization = -not [string]::IsNullOrWhiteSpace($existingAuthorization)
        $isReadOnlyByHeader = Test-KatTruthySettingValue $existingReadonlyHeader

        $isRemoteCompliant = $existingType -ieq 'http' -and
            $existingUrl -eq $targetUrl -and
            $hasRemoteAuthorization -and
            -not $isReadOnlyByHeader

        if ($isRemoteCompliant) {
            $authMode = Get-AuthModeDescription -Headers (Get-KatProp $existing 'headers')
            Add-Result -Client 'claude' -Status 'ok' -Method 'file' -Path $configPath -Detail "Already configured for remote GitHub MCP using $authMode."
            return
        }

        $patReady = Test-GitHubPatEnvAvailable
        $hasLocalConfig = -not [string]::IsNullOrWhiteSpace($existingCommand)

        if (-not $patReady) {
            Show-MissingGitHubPatInstructions -Reason 'Claude remote GitHub MCP requires PAT auth. Existing local fallback can remain, but new remote or Docker fallback setup still requires GITHUB_TOKEN.'
        }

        if ($CheckOnly) {
            if ($patReady) {
                $patReference = Get-GitHubPatEnvReference
                Add-Result -Client 'claude' -Status 'needs-install' -Method 'file' -Path $configPath -Detail "Needs remote GitHub MCP configuration ($modeTransition) using PAT reference $patReference."
            }
            elseif ($hasLocalConfig) {
                Add-Result -Client 'claude' -Status 'ok' -Method 'file' -Path $configPath -Detail 'Remote PAT was not found; existing local Claude GitHub MCP configuration is accepted as fallback.'
            }
            else {
                Add-Result -Client 'claude' -Status 'blocked' -Method 'file' -Path $configPath -Detail 'Remote PAT was not found. Auth is still required; set GITHUB_TOKEN before configuring Claude GitHub MCP.'
            }

            return
        }

        if ($patReady) {
            $patReference = Get-GitHubPatEnvReference
            $mcpServers | Add-Member -NotePropertyName 'github' -NotePropertyValue ([pscustomobject]@{
                    type = 'http'
                    url = $script:githubUrl
                    headers = [pscustomobject]@{
                        Authorization = "Bearer $patReference"
                    }
                }) -Force

            [void](Complete-KatFileMutation -Results $script:results -Client 'claude' -ConfigPath $configPath -Document $config -PreviewDetail "Would configure remote GitHub MCP ($modeTransition) using PAT reference $patReference." -SuccessDetail "Configured remote GitHub MCP ($modeTransition) using PAT reference $patReference.")
            return
        }

        if ($hasLocalConfig) {
            Add-Result -Client 'claude' -Status 'ok' -Method 'file' -Path $configPath -Detail 'Remote PAT was not found; keeping existing local Claude GitHub MCP configuration as fallback.'
            return
        }

        Add-Result -Client 'claude' -Status 'blocked' -Method 'file' -Path $configPath -Detail 'Remote PAT was not found. Auth is still required; set GITHUB_TOKEN before configuring Claude GitHub MCP.'
    }
}

function Write-ResultSummary {
    Write-KatResultSummary -Title 'GitHub Remote Setup Summary' -Results @($script:results.ToArray())
}

Set-VsCodeGitHubRemote
Set-CopilotCliGitHubRemote
Set-ClaudeGitHub
Write-ResultSummary

if ($PassThru) {
    return (New-KatBootstrapPassThru -Results @($script:results.ToArray()) -CredentialAvailable (Test-GitHubPatEnvAvailable) -GuidanceShown $script:githubPatGuidanceShown)
}

if (-not $CheckOnly -and @($script:results | Where-Object Status -eq 'blocked').Count -gt 0) {
    throw 'GitHub remote bootstrap did not complete successfully. See blocked entries above.'
}
