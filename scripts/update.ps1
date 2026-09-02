param(
    [ValidateSet('Normal', 'Detailed')]
    [string]$Verbosity = 'Normal',
    [switch]$NonInteractive,
    [switch]$DisableToolAutoUpgrade,
    [switch]$Overwrite
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$aiRoot = Join-Path $repoRoot 'AI'
$skillRoot = Join-Path $aiRoot 'skills\kat-policies'
$externalManifestPath = Join-Path $aiRoot 'external.primitives.jsonc'
$sharedMetaPath = Join-Path $skillRoot 'meta.jsonc'
$vsCodeSettingsMetaPath = Join-Path $skillRoot 'meta.vscode.settings.jsonc'
$sharedModulePath = Join-Path $PSScriptRoot 'Kat.Policy.Mcp.psm1'

Import-Module $sharedModulePath -Force

$compatibilityMessages = New-Object System.Collections.Generic.List[string]
$blockedPaths = New-Object System.Collections.Generic.List[string]
$skippedPaths = New-Object System.Collections.Generic.List[string]
$deploymentRecords = New-Object System.Collections.Generic.List[object]
$preSyncManagedPaths = New-Object System.Collections.Generic.List[string]
$script:claudeContext7Configured = $null
$script:sharedMeta = $null
$script:vsCodeSettingsMeta = $null
$script:clientInstalled = $null

# AGENTS.md is a shared, human-edited convention file; KAT owns only this delimited region.
$script:katRegionStart = '<!-- kat:start -->'
$script:katRegionEnd = '<!-- kat:end -->'
$script:katRegionPattern = '(?is)[ \t]*<!--\s*kat:start\s*-->.*?<!--\s*kat:end\s*-->[ \t]*'
$script:codexGlobalRoot = Join-Path $env:USERPROFILE '.codex'
$script:codexGlobalSkillRoot = Join-Path $env:USERPROFILE '.agents'

# External primitives are installed by `npx skills`, so KAT must mirror where that CLI actually
# writes. Verified against skills@1.5.23 by reading getAgentBaseDir() and by running the install:
# any agent whose skillsDir is '.agents/skills' is a "universal" agent, and for those the CLI ignores
# its own globalSkillsDir entry and writes the shared ~/.agents/skills instead. github-copilot and
# codex are both universal, so one npx install produces one directory serving both. Only claude-code
# is non-universal and gets a root of its own.
#
# That universal root is not the whole story for Copilot: per the read matrix in Primitives.md,
# ~/.agents/skills is read by VS Code Copilot and Codex, but Copilot CLI resolves ~/.copilot/skills —
# the same root KAT publishes vendored copilot skills to. So the copilot client's real destination is
# ~/.copilot/skills, which KAT mirrors from the universal copy after decorating it, and the universal
# copy is dropped afterwards unless codex actually wanted it.
$script:universalGlobalSkillRoot = Join-Path (Join-Path $env:USERPROFILE '.agents') 'skills'
$script:externalPrimitiveClients = [ordered]@{
    claude = [pscustomobject]@{
        Agent = 'claude-code'
        GlobalRoot = Join-Path $(if ([string]::IsNullOrWhiteSpace($env:CLAUDE_CONFIG_DIR)) { Join-Path $env:USERPROFILE '.claude' } else { $env:CLAUDE_CONFIG_DIR.Trim() }) 'skills'
        Universal = $false
    }
    copilot = [pscustomobject]@{
        Agent = 'github-copilot'
        GlobalRoot = Join-Path (Join-Path $env:USERPROFILE '.copilot') 'skills'
        Universal = $true
    }
    codex = [pscustomobject]@{
        Agent = 'codex'
        GlobalRoot = $script:universalGlobalSkillRoot
        Universal = $true
    }
}

# Provenance marker for external installs. Deliberately NOT the CreatedBy=KAT alternate data stream:
# that stream means "KAT rendered this file and may delete it", and Clear-ManagedRoot would reap the
# install before Install-ExternalPrimitives ever ran. A sidecar also makes the directory un-reusable
# by Test-ReusableManagedDirectory, which is exactly the protection an npx-owned tree needs.
$script:externalPrimitiveSidecarName = '.kat-external.json'

# Skill amendments are appended to this instruction rather than published as one of their own, so the
# shared rules stay in a single file per harness. That instruction's client enablement therefore gates
# amendment delivery — it must reach every client any amendment targets.
$script:amendmentHostInstructionId = 'kat'

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

function Add-SkippedPath {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path) -and -not $skippedPaths.Contains($Path)) {
        $skippedPaths.Add($Path)
    }
}

function Test-SkippedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    foreach ($candidate in @($Path -split '; ')) {
        $candidate = $candidate.Trim()
        if ($skippedPaths.Contains($candidate)) { return $true }
        $prefix = $candidate.TrimEnd('\', '/') + '\'
        foreach ($sp in $skippedPaths) {
            if ($sp.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) { return $true }
        }
    }
    return $false
}

function Add-DeploymentRecord {
    param(
        [string]$Category,
        [string]$Id,
        [string]$Target,
        [string]$Status,
        [string]$Path = $null,
        [string]$Detail = $null,
        [string]$MatrixValue = $null,
        [string]$MatrixScoped = $null
    )

    $deploymentRecords.Add([pscustomobject]@{
        Category = $Category
        Id = $Id
        Target = $Target
        Status = $Status
        Path = $Path
        Detail = $Detail
        MatrixValue = $MatrixValue
        MatrixScoped = $MatrixScoped
    })
}

function Get-SharedMeta {
    if ($null -eq $script:sharedMeta) {
        $script:sharedMeta = Read-CanonicalMeta -Path $sharedMetaPath
    }

    return $script:sharedMeta
}

function Get-SharedModelMappings {
    return Get-Prop (Get-Prop (Get-SharedMeta) 'mappings') 'models'
}

function Get-SharedToolMappings {
    return Get-Prop (Get-Prop (Get-SharedMeta) 'mappings') 'tools'
}

function Get-SharedMcpSettings {
    return Get-Prop (Get-SharedMeta) 'mcp'
}

function Get-VsCodeSettingsMeta {
    if ($null -eq $script:vsCodeSettingsMeta) {
        $script:vsCodeSettingsMeta = Read-KatJsonDocument -Path $vsCodeSettingsMetaPath -DefaultFactory {
            [pscustomobject]@{
                settings = [pscustomobject]@{}
            }
        }
    }

    return $script:vsCodeSettingsMeta
}

function Get-DesiredVsCodeSettings {
    return Get-Prop (Get-VsCodeSettingsMeta) 'settings'
}

function Test-SettingsValueMatch {
    param(
        [object]$Actual,
        [object]$Expected
    )

    if ($null -eq $Expected) {
        return $null -eq $Actual
    }

    if ($Expected -is [string] -or $Expected -is [ValueType]) {
        return $Actual -eq $Expected
    }

    if ($Expected -is [System.Collections.IEnumerable] -and $Expected -isnot [string] -and -not ($Expected.PSObject.Properties.Count -gt 0)) {
        $expectedItems = @($Expected)
        $actualItems = @($Actual)
        if ($expectedItems.Count -ne $actualItems.Count) {
            return $false
        }

        for ($index = 0; $index -lt $expectedItems.Count; $index++) {
            if (-not (Test-SettingsValueMatch -Actual $actualItems[$index] -Expected $expectedItems[$index])) {
                return $false
            }
        }

        return $true
    }

    $expectedProperties = if ($Expected -is [System.Collections.IDictionary]) {
        @($Expected.GetEnumerator() | ForEach-Object {
            [pscustomobject]@{
                Name = [string]$_.Key
                Value = $_.Value
            }
        })
    }
    else {
        @($Expected.PSObject.Properties)
    }
    if ($expectedProperties.Count -eq 0) {
        return $Actual -eq $Expected
    }

    if ($null -eq $Actual) {
        return $false
    }

    foreach ($property in $expectedProperties) {
        if ($Actual -is [System.Collections.IDictionary]) {
            $hasKey = $false
            $actualValue = $null
            foreach ($key in @($Actual.Keys)) {
                if ([string]$key -ceq [string]$property.Name) {
                    $actualValue = $Actual[$key]
                    $hasKey = $true
                    break
                }
            }

            if (-not $hasKey) {
                return $false
            }
        }
        else {
            $actualProperty = $Actual.PSObject.Properties[$property.Name]
            if ($null -eq $actualProperty) {
                return $false
            }

            $actualValue = $actualProperty.Value
        }

        if (-not (Test-SettingsValueMatch -Actual $actualValue -Expected $property.Value)) {
            return $false
        }
    }

    return $true
}

function Get-VsCodeSettingsDifferences {
    param(
        [object]$CurrentSettings,
        [object]$DesiredSettings
    )

    $differences = New-Object System.Collections.Generic.List[string]
    if ($null -eq $DesiredSettings) {
        return @($differences.ToArray())
    }

    foreach ($property in @($DesiredSettings.PSObject.Properties)) {
        $currentValue = if ($CurrentSettings -is [System.Collections.IDictionary]) {
            $match = $null
            foreach ($key in @($CurrentSettings.Keys)) {
                if ([string]$key -ceq [string]$property.Name) {
                    $match = $CurrentSettings[$key]
                    break
                }
            }
            $match
        }
        else {
            Get-Prop $CurrentSettings $property.Name
        }
        if (-not (Test-SettingsValueMatch -Actual $currentValue -Expected $property.Value)) {
            $differences.Add($property.Name)
        }
    }

    return @($differences.ToArray())
}

function Sync-VsCodeSettingsSafeguards {
    $desiredSettings = Get-DesiredVsCodeSettings
    if ($null -eq $desiredSettings -or @($desiredSettings.PSObject.Properties).Count -eq 0) {
        return
    }

    $settingsPath = Join-Path $env:APPDATA 'Code\User\settings.json'
    try {
        if (Test-Path -LiteralPath $settingsPath) {
            $currentSettings = ConvertFrom-KatJsonWithCommentsAsHashtable (Get-Content -LiteralPath $settingsPath -Raw)
        }
        else {
            $currentSettings = [ordered]@{}
        }
    }
    catch {
        Add-DeploymentRecord -Category 'config' -Id 'VS Code Copilot Chat settings' -Target 'vscodeSettings' -Status 'blocked' -Path $settingsPath -Detail "VS Code settings file is not valid JSON: $($_.Exception.Message)"
        return
    }

    $differences = @(Get-VsCodeSettingsDifferences -CurrentSettings $currentSettings -DesiredSettings $desiredSettings)

    if ($differences.Count -eq 0) {
        Add-DeploymentRecord -Category 'config' -Id 'VS Code Copilot Chat settings' -Target 'vscodeSettings' -Status 'ok' -Path $settingsPath -Detail 'already compliant'
        return
    }

    $detail = "Missing or mismatched settings: $differenceSummary."

    foreach ($property in @($desiredSettings.PSObject.Properties)) {
        if ($currentSettings -is [System.Collections.IDictionary]) {
            $currentSettings[[string]$property.Name] = $property.Value
        }
        else {
            $currentSettings | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
        }
    }

    Write-KatJsonDocument -Path $settingsPath -Document $currentSettings
    Add-DeploymentRecord -Category 'config' -Id 'VS Code Copilot Chat settings' -Target 'vscodeSettings' -Status 'ok' -Path $settingsPath -Detail ('updated: ' + $differenceSummary)
}

function Test-McpClientEnabled {
    param(
        [object]$McpConfig,
        [ValidateSet('vscode', 'cli', 'claude')]
        [string]$Client
    )

    if ($null -eq $McpConfig) { return $false }

    if ($Client -eq 'claude') {
        return ConvertTo-BoolValue (Get-Prop $McpConfig 'claude') $false
    }

    $topLevel = Get-Prop $McpConfig 'copilot'
    if ($null -ne $topLevel) {
        if (ConvertTo-BoolValue $topLevel $false) { return $true }
        return ConvertTo-BoolValue (Get-Prop $McpConfig "copilot.$Client") $false
    }
    $subProp = Get-Prop $McpConfig "copilot.$Client"
    if ($null -ne $subProp) {
        return ConvertTo-BoolValue $subProp $false
    }
    return $false
}

function Test-McpParityRequested {
    param([string]$ServerKey)

    $serverConfig = Get-Prop (Get-SharedMcpSettings) $ServerKey
    if ($null -eq $serverConfig) { return $false }

    return (Test-McpClientEnabled -McpConfig $serverConfig -Client 'vscode') -or
           (Test-McpClientEnabled -McpConfig $serverConfig -Client 'cli') -or
           (Test-McpClientEnabled -McpConfig $serverConfig -Client 'claude')
}

function Get-EnabledRepositories {
    param([object]$Meta)

    $enabled = Get-Prop $Meta 'enabled'
    return (ConvertTo-StringArray (Get-Prop $enabled 'repositories'))
}

function Get-AgentRepositoryManagedContexts {
    param([object[]]$Definitions)

    $contextsByRoot = @{}

    foreach ($definition in $Definitions) {
        foreach ($repositoryRoot in $definition.Repositories) {
            if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
                continue
            }

            if (-not $contextsByRoot.ContainsKey($repositoryRoot)) {
                $contextsByRoot[$repositoryRoot] = New-Object System.Collections.Generic.List[string]
            }

            foreach ($scanRoot in @(
                    (Join-Path $repositoryRoot '.github\agents'),
                    (Join-Path $repositoryRoot '.claude\agents')))
            {
                if (-not $contextsByRoot[$repositoryRoot].Contains($scanRoot)) {
                    $contextsByRoot[$repositoryRoot].Add($scanRoot)
                }
            }
        }
    }

    return @($contextsByRoot.Keys | Sort-Object | ForEach-Object {
        @{
            Root = $_
            ScanRoots = @($contextsByRoot[$_])
            CollapseEmptyToRoot = $_
        }
    })
}

function Get-InstructionRepositoryManagedContexts {
    param([object[]]$Definitions)

    $contextsByRoot = @{}

    foreach ($definition in $Definitions) {
        foreach ($repositoryRoot in $definition.Repositories) {
            if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
                continue
            }

            if (-not $contextsByRoot.ContainsKey($repositoryRoot)) {
                $contextsByRoot[$repositoryRoot] = New-Object System.Collections.Generic.List[string]
            }

            foreach ($scanRoot in @(
                    (Join-Path $repositoryRoot '.github\instructions'),
                    (Join-Path $repositoryRoot '.claude\instructions'),
                    (Join-Path $repositoryRoot '.claude\rules'),
                    (Join-Path $repositoryRoot '.claude\CLAUDE.md')))
            {
                if (-not $contextsByRoot[$repositoryRoot].Contains($scanRoot)) {
                    $contextsByRoot[$repositoryRoot].Add($scanRoot)
                }
            }
        }
    }

    return @($contextsByRoot.Keys | Sort-Object | ForEach-Object {
        @{
            Root = $_
            ScanRoots = @($contextsByRoot[$_])
            CollapseEmptyToRoot = $_
        }
    })
}

function Get-SkillRepositoryManagedContexts {
    param([object[]]$Definitions)

    $contextsByRoot = @{}

    foreach ($definition in $Definitions) {
        foreach ($repositoryRoot in $definition.Repositories) {
            if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
                continue
            }

            if (-not $contextsByRoot.ContainsKey($repositoryRoot)) {
                $contextsByRoot[$repositoryRoot] = New-Object System.Collections.Generic.List[string]
            }

            foreach ($scanRoot in @(
                    (Join-Path $repositoryRoot '.github\skills'),
                    (Join-Path $repositoryRoot '.claude\skills'),
                    (Join-Path $repositoryRoot '.agents\skills')))
            {
                if (-not $contextsByRoot[$repositoryRoot].Contains($scanRoot)) {
                    $contextsByRoot[$repositoryRoot].Add($scanRoot)
                }
            }
        }
    }

    return @($contextsByRoot.Keys | Sort-Object | ForEach-Object {
        @{
            Root = $_
            ScanRoots = @($contextsByRoot[$_])
            CollapseEmptyToRoot = $_
        }
    })
}

function Get-EnvironmentRoots {
    New-Item -ItemType Directory -Path 'C:\BTR' -Force | Out-Null

    $vscodeRoot = Join-Path $env:APPDATA 'Code\User'
    $copilotRoot = Join-Path $env:USERPROFILE '.copilot'
    $claudeRoot = Join-Path $env:USERPROFILE '.claude'

    $wtPackage = $null
    if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        $wtPackage = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
    }
    $terminalRoot = $null
    if ($wtPackage) {
        $terminalRoot = Join-Path $env:LOCALAPPDATA "Packages\$($wtPackage.PackageFamilyName)\LocalState"
    }
    else {
        Add-Warning 'Windows Terminal not found. Skipping Terminal file sync.'
    }

    return [pscustomobject]@{
        VscodeRoot = $vscodeRoot
        CopilotRoot = $copilotRoot
        ClaudeRoot = $claudeRoot
        TerminalRoot = $terminalRoot
    }
}

function Get-ManagedContexts {
    param(
        [object]$Roots,
        [object[]]$AgentDefinitions,
        [object[]]$InstructionDefinitions,
        [object[]]$SkillDefinitions
    )

    $managedContexts = @(
        @{ Root = 'C:\BTR'; ScanRoots = @((Join-Path 'C:\BTR' '.editorconfig')) },
        @{ Root = $Roots.VscodeRoot; ScanRoots = @((Join-Path $Roots.VscodeRoot 'prompts'), (Join-Path $Roots.VscodeRoot 'instructions')) },
        @{ Root = $Roots.CopilotRoot; ScanRoots = @((Join-Path $Roots.CopilotRoot 'agents'), (Join-Path $Roots.CopilotRoot 'instructions'), (Join-Path $Roots.CopilotRoot 'skills')) },
        @{ Root = $Roots.ClaudeRoot; ScanRoots = @((Join-Path $Roots.ClaudeRoot 'agents'), (Join-Path $Roots.ClaudeRoot 'instructions'), (Join-Path $Roots.ClaudeRoot 'rules'), (Join-Path $Roots.ClaudeRoot 'skills'), (Join-Path $Roots.ClaudeRoot 'CLAUDE.md')) }
    )

    $managedContexts += @(Get-AgentRepositoryManagedContexts -Definitions $AgentDefinitions)
    $managedContexts += @(Get-InstructionRepositoryManagedContexts -Definitions $InstructionDefinitions)
    $managedContexts += @(Get-SkillRepositoryManagedContexts -Definitions $SkillDefinitions)

    if ($Roots.TerminalRoot) {
        $managedContexts += @{ Root = $Roots.TerminalRoot; ScanRoots = @($Roots.TerminalRoot) }
    }

    return @($managedContexts)
}

function Publish-EditorConfig {
    $targetPath = 'C:\BTR\.editorconfig'
    $sourcePath = Join-Path $repoRoot '.editorconfig'

    if ((Test-Path -LiteralPath $targetPath) -and -not (Test-KatMarker -Path $targetPath)) {
        Add-DeploymentRecord -Category 'link' -Id '.editorconfig' -Target 'btr' -Status 'skipped' -Path $targetPath -Detail 'existing file is not KAT-owned; left untouched'
        return
    }

    $editorConfigSucceeded = Copy-ManagedFile -Path $targetPath -SourcePath $sourcePath
    Add-DeploymentRecord -Category 'link' -Id '.editorconfig' -Target 'btr' -Status $(if ($editorConfigSucceeded) { 'ok' } else { 'blocked' }) -Path $targetPath
}

function Publish-TerminalFiles {
    param([object]$Roots)

    $terminalSourcePath = Join-Path $repoRoot 'Terminal'
    $metaPath = Join-Path $terminalSourcePath 'meta.jsonc'

    $filesToProcess = New-Object System.Collections.Generic.List[pscustomobject]

    if (Test-Path -LiteralPath $metaPath) {
        $meta = Read-KatJsonDocument -Path $metaPath -DefaultFactory { [pscustomobject]@{} }
        foreach ($property in @($meta.PSObject.Properties)) {
            if (-not (Test-UserAllowed -Meta $property.Value)) { continue }
            $filesToProcess.Add([pscustomobject]@{
                SourcePath = Join-Path $terminalSourcePath $property.Name
                SourceName = $property.Name
            })
        }
    }
    else {
        $defaultSource = Join-Path $terminalSourcePath 'settings.json'
        if (Test-Path -LiteralPath $defaultSource) {
            $filesToProcess.Add([pscustomobject]@{
                SourcePath = $defaultSource
                SourceName = 'settings.json'
            })
        }
    }

    if ($Roots.TerminalRoot) {
        foreach ($fileEntry in $filesToProcess) {
            if (-not (Test-Path -LiteralPath $fileEntry.SourcePath)) { continue }
            $targetPath = Join-Path $Roots.TerminalRoot 'settings.json'
            # Terminal does not reliably hot-reload symlink targets, so always manage as copied files.
            $targetSucceeded = Copy-ManagedFile -Path $targetPath -SourcePath $fileEntry.SourcePath -ForceOwnedPath $true
            Add-DeploymentRecord -Category 'link' -Id ('Terminal/' + $fileEntry.SourceName) -Target 'terminal' -Status $(if ($targetSucceeded) { 'ok' } else { 'blocked' }) -Path $targetPath
        }
        return
    }

    foreach ($fileEntry in $filesToProcess) {
        Add-DeploymentRecord -Category 'link' -Id ('Terminal/' + $fileEntry.SourceName) -Target 'terminal' -Status 'skipped' -Path $null -Detail 'windows-terminal-not-found'
    }
}

function Publish-Agents {
    param(
        [object]$Roots,
        [object[]]$Definitions
    )

    foreach ($definition in $Definitions) {
        $enabled = $definition.Enabled
        $id = $definition.Id
        $agentRepositories = @($definition.Repositories)
        $agentMatrixValue = if ($agentRepositories.Count -gt 0) { 'repository' } else { 'global' }
        $repoMissing = $false

        if (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'vscode') {
            $content = ConvertTo-CopilotAgentDocument -Meta $definition.Meta -Body $definition.Body -Client 'vscode'
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true
            $repoMissing = $false
            $missingRepoPaths = [System.Collections.Generic.List[string]]::new()

            if ($agentRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.VscodeRoot 'prompts') ($id + '.agent.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content -ValidationLabel "Agent '$id' for VS Code"
            }
            else {
                foreach ($agentRepositoryRoot in $agentRepositories) {
                    if (-not (Test-Path -LiteralPath $agentRepositoryRoot -PathType Container)) {
                        $succeeded = $false
                        $repoMissing = $true
                        $missingRepoPaths.Add($agentRepositoryRoot)
                        continue
                    }

                    $path = Join-Path (Join-Path $agentRepositoryRoot '.github\agents') ($id + '.agent.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true -ValidationLabel "Agent '$id' for VS Code") -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($agentRepositories.Count -gt 0) { $agentRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } elseif ($agentRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $(if ($succeeded) { $agentMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status 'disabled' -MatrixValue 'excluded'
        }

        if (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'cli') {
            if ($agentRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.CopilotRoot 'agents') ($id + '.agent.md')
                $content = ConvertTo-CopilotAgentDocument -Meta $definition.Meta -Body $definition.Body -Client 'copilotCli'
                $succeeded = Write-ManagedFile -Path $path -Content $content -ValidationLabel "Agent '$id' for Claude"
                Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path -MatrixValue $(if ($succeeded) { 'global' } else { $null })
            }
            else {
                # Repo-scoped: copilotCli reads .github/agents/ — covered by the vscode deployment above
                Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status $(if ($repoMissing) { 'blocked' } else { 'ok' }) -MatrixValue $(if ($repoMissing) { $null } else { 'repository' }) -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } else { $null })
            }
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status 'disabled' -MatrixValue 'excluded'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $claudeTarget = [string](Get-Prop $definition.ClaudeMeta 'target')
            if (-not [string]::IsNullOrWhiteSpace($claudeTarget)) {
                Add-Warning "${id}: claude.target is ignored for canonical agent metadata."
            }

            $content = ConvertTo-ClaudeAgentDocument -Meta $definition.Meta -Body $definition.Body
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true
            $repoMissing = $false
            $missingRepoPaths = [System.Collections.Generic.List[string]]::new()

            if ($agentRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.ClaudeRoot 'agents') ($id + '.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content -ValidationLabel "Instruction '$id' for VS Code"
            }
            else {
                foreach ($agentRepositoryRoot in $agentRepositories) {
                    if (-not (Test-Path -LiteralPath $agentRepositoryRoot -PathType Container)) {
                        $succeeded = $false
                        $repoMissing = $true
                        $missingRepoPaths.Add($agentRepositoryRoot)
                        continue
                    }

                    $path = Join-Path (Join-Path (Join-Path $agentRepositoryRoot '.claude') 'agents') ($id + '.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true -ValidationLabel "Instruction '$id' for VS Code") -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($agentRepositories.Count -gt 0) { $agentRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } elseif ($agentRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $(if ($succeeded) { $agentMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status 'disabled' -MatrixValue 'excluded'
        }

        # Agents are out of scope for codex: there is no cheap mapping from .agent.md to the Codex subagent format.
        if (ConvertTo-BoolValue (Get-Prop $enabled 'codex') $false) {
            Add-Warning "${id}: enabled.codex is set but agents are out of scope for Codex; no .agent.md to Codex subagent mapping exists."
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'codex' -Status 'unsupported' -Detail 'agents are out of scope for Codex; no .agent.md to Codex subagent mapping exists'
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'codex' -Status 'disabled' -MatrixValue 'excluded'
        }
    }
}

function Get-CodexAgentsFilePath {
    param([string]$RepositoryRoot)

    if ([string]::IsNullOrWhiteSpace($RepositoryRoot)) {
        return Join-Path $script:codexGlobalRoot 'AGENTS.md'
    }

    return Join-Path $RepositoryRoot 'AGENTS.md'
}

function New-CodexInstructionSection {
    param(
        [object]$Definition,
        [string[]]$Scope
    )

    $id = $Definition.Id
    $body = Resolve-ClientMarkdown -Content $Definition.Body -Client 'codex'
    $body = Resolve-BodyReplacements -Content $body -Meta $Definition.Meta -Client 'codex'

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("###### $id instructions ######")
    $lines.Add('')

    # Codex has no applyTo/glob equivalent — an AGENTS.md body is unconditionally active for its whole subtree.
    $scopePatterns = @(@($Scope) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne '**' })
    if ($scopePatterns.Count -gt 0) {
        $formattedScope = (@($scopePatterns | ForEach-Object { '`' + $_ + '`' })) -join ', '
        $lines.Add("The following applies when working on files matching $formattedScope.")
        $lines.Add('')
        Add-Warning "${id}: Codex has no glob scoping, so instructions.scope was rendered as a prose preamble in AGENTS.md. This is a soft gate, not enforcement."
    }

    $lines.Add(([string]$body).Trim())

    return ($lines -join "`r`n")
}

function Publish-Instructions {
    param(
        [object]$Roots,
        [object[]]$Definitions
    )

    $claudeInstructionTargets = New-Object System.Collections.Generic.List[object]
    # AGENTS.md is written once per file with every enabled instruction, so codex output is collected
    # across the definition loop and flushed afterwards.
    $codexCandidatePaths = New-Object System.Collections.Generic.List[string]
    $codexSectionsByPath = @{}
    $codexResultsById = @{}

    foreach ($definition in $Definitions) {
        $enabled = $definition.Enabled
        $id = $definition.Id
        $instructionRepositories = @($definition.Repositories)
        $instructionScope = @(Get-InstructionScope -Meta $definition.Meta)
        $isClaudeGlobalInstruction = $instructionScope.Count -eq 0
        $instructionMatrixValue = if ($instructionRepositories.Count -gt 0) { 'repository' } else { 'global' }
        $instructionScopedValue = if ($instructionScope.Count -gt 0) { 'yes' } else { 'no' }
        $repoMissing = $false
        # Instructions concatenate rather than de-duplicate, so a repo-scoped instruction published to
        # both AGENTS.md and .github/instructions reaches Copilot twice. Copilot reads AGENTS.md at both
        # surfaces, so the AGENTS.md copy alone keeps coverage intact. Global scope is unaffected: codex
        # writes to ~/.codex/AGENTS.md, which Copilot never reads.
        $codexServesCopilot = $instructionRepositories.Count -gt 0 -and (Test-CodexEnabled -Enabled $enabled)
        $codexServesCopilotDetail = 'codex enabled: AGENTS.md serves Copilot; .github/instructions omitted to avoid duplicate rules'

        if ($codexServesCopilot) {
            foreach ($copilotTarget in @('vscode', 'copilotCli')) {
                $subClient = if ($copilotTarget -eq 'vscode') { 'vscode' } else { 'cli' }
                if (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient $subClient) {
                    Add-DeploymentRecord -Category 'instruction' -Id $id -Target $copilotTarget -Status 'skipped' -Detail $codexServesCopilotDetail -MatrixScoped $instructionScopedValue
                }
                else {
                    Add-DeploymentRecord -Category 'instruction' -Id $id -Target $copilotTarget -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
                }
            }
        }
        elseif (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'vscode') {
            $content = ConvertTo-CopilotInstructionDocument -Meta $definition.Meta -Body $definition.Body -Client 'vscode'
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true
            $repoMissing = $false
            $missingRepoPaths = [System.Collections.Generic.List[string]]::new()

            if ($instructionRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.VscodeRoot 'instructions') ($id + '.instructions.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content -ValidationLabel "Instruction '$id' for Copilot CLI"
            }
            else {
                foreach ($instructionRepositoryRoot in $instructionRepositories) {
                    if (-not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                        $succeeded = $false
                        $repoMissing = $true
                        $missingRepoPaths.Add($instructionRepositoryRoot)
                        continue
                    }

                    $path = Join-Path (Join-Path $instructionRepositoryRoot '.github\instructions') ($id + '.instructions.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true -ValidationLabel "Instruction '$id' for Copilot CLI") -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($instructionRepositories.Count -gt 0) { $instructionRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } elseif ($instructionRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $instructionMatrixValue -MatrixScoped $instructionScopedValue
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
        }

        if ($codexServesCopilot) {
            # Recorded alongside the vscode target above.
        }
        elseif (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'cli') {
            if ($instructionRepositories.Count -gt 0) {
                # Repo-scoped: copilotCli reads .github/instructions/ — covered by the vscode deployment above
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status $(if ($repoMissing) { 'blocked' } else { 'ok' }) -MatrixValue $(if ($repoMissing) { $null } else { 'repository' }) -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } else { $null }) -MatrixScoped $instructionScopedValue
            }
            else {
                $path = Join-Path (Join-Path $Roots.CopilotRoot 'instructions') ($id + '.instructions.md')
                $content = ConvertTo-CopilotInstructionDocument -Meta $definition.Meta -Body $definition.Body -Client 'copilotCli'
                $succeeded = Write-ManagedFile -Path $path -Content $content -ValidationLabel "Instruction '$id' for Claude"
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path -MatrixValue 'global' -MatrixScoped $instructionScopedValue
            }
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true
            $repoMissing = $false
            $missingRepoPaths = [System.Collections.Generic.List[string]]::new()

            if ($instructionRepositories.Count -eq 0) {
                if ($isClaudeGlobalInstruction) {
                    $path = Join-Path (Join-Path $Roots.ClaudeRoot 'instructions') ($id + '.md')
                    $publishTargets.Add($path)
                    $claudeBody = Resolve-ClientMarkdown -Content $definition.Body -Client 'claude'
                    $claudeBody = Resolve-BodyReplacements -Content $claudeBody -Meta $definition.Meta -Client 'claude'
                    $succeeded = Write-ManagedFile -Path $path -Content $claudeBody -ValidationLabel "Instruction '$id' for Claude"
                    if ($succeeded) {
                        $claudeInstructionTargets.Add([pscustomobject]@{
                                Id = $id
                                Root = $Roots.ClaudeRoot
                            })
                    }
                }
                else {
                    $path = Join-Path (Join-Path $Roots.ClaudeRoot 'rules') ($id + '.md')
                    $publishTargets.Add($path)
                    $content = ConvertTo-ClaudeRuleDocument -Meta $definition.Meta -Body $definition.Body
                    $succeeded = Write-ManagedFile -Path $path -Content $content -ValidationLabel "Rule '$id' for Claude"
                }
            }
            else {
                foreach ($instructionRepositoryRoot in $instructionRepositories) {
                    if (-not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                        $succeeded = $false
                        $repoMissing = $true
                        $missingRepoPaths.Add($instructionRepositoryRoot)
                        continue
                    }

                    if ($isClaudeGlobalInstruction) {
                        $path = Join-Path (Join-Path $instructionRepositoryRoot '.claude\instructions') ($id + '.md')
                        $publishTargets.Add($path)
                        $claudeBody = Resolve-ClientMarkdown -Content $definition.Body -Client 'claude'
                        $claudeBody = Resolve-BodyReplacements -Content $claudeBody -Meta $definition.Meta -Client 'claude'
                        $targetSucceeded = Write-ManagedFile -Path $path -Content $claudeBody -ForceOwnedPath $true -ValidationLabel "Instruction '$id' for Claude"
                        if ($targetSucceeded) {
                            $claudeInstructionTargets.Add([pscustomobject]@{
                                    Id = $id
                                    Root = (Join-Path $instructionRepositoryRoot '.claude')
                                })
                        }
                    }
                    else {
                        $path = Join-Path (Join-Path $instructionRepositoryRoot '.claude\rules') ($id + '.md')
                        $publishTargets.Add($path)
                        $content = ConvertTo-ClaudeRuleDocument -Meta $definition.Meta -Body $definition.Body
                        $targetSucceeded = Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true -ValidationLabel "Rule '$id' for Claude"
                    }

                    $succeeded = $targetSucceeded -and $succeeded
                }
            }

            $targetName = if ($isClaudeGlobalInstruction) { 'claudeGlobalInstruction' } else { 'claudePathInstruction' }
            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($instructionRepositories.Count -gt 0) { $instructionRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target $targetName -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } elseif ($instructionRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $instructionMatrixValue -MatrixScoped $instructionScopedValue
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target $(if ($isClaudeGlobalInstruction) { 'claudePathInstruction' } else { 'claudeGlobalInstruction' }) -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeGlobalInstruction' -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudePathInstruction' -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
        }

        $codexTargetPaths = if ($instructionRepositories.Count -eq 0) {
            @(Get-CodexAgentsFilePath)
        }
        else {
            @($instructionRepositories | ForEach-Object { Get-CodexAgentsFilePath -RepositoryRoot $_ })
        }

        foreach ($codexTargetPath in $codexTargetPaths) {
            if (-not $codexCandidatePaths.Contains($codexTargetPath)) {
                $codexCandidatePaths.Add($codexTargetPath)
            }
        }

        # codex is strictly opt-in: AGENTS.md is a shared merge target, so it never defaults to true.
        if (ConvertTo-BoolValue (Get-Prop $enabled 'codex') $false) {
            $codexSection = New-CodexInstructionSection -Definition $definition -Scope $instructionScope
            $codexPaths = New-Object System.Collections.Generic.List[string]
            $missingCodexRepoPaths = New-Object System.Collections.Generic.List[string]

            if ($instructionRepositories.Count -eq 0) {
                $codexPaths.Add((Get-CodexAgentsFilePath))
            }
            else {
                foreach ($instructionRepositoryRoot in $instructionRepositories) {
                    if (-not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                        $missingCodexRepoPaths.Add($instructionRepositoryRoot)
                        continue
                    }

                    $codexPaths.Add((Get-CodexAgentsFilePath -RepositoryRoot $instructionRepositoryRoot))
                }
            }

            foreach ($codexPath in $codexPaths) {
                if (-not $codexSectionsByPath.ContainsKey($codexPath)) {
                    $codexSectionsByPath[$codexPath] = [System.Collections.Generic.List[object]]::new()
                }

                $codexSectionsByPath[$codexPath].Add([pscustomobject]@{
                    Id = $id
                    Section = $codexSection
                })
            }

            $codexResultsById[$id] = [pscustomobject]@{
                Paths = @($codexPaths.ToArray())
                MissingRepositories = @($missingCodexRepoPaths.ToArray())
                MatrixValue = $instructionMatrixValue
                MatrixScoped = $instructionScopedValue
            }
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'codex' -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
        }
    }

    # Cleanup is targeted: AGENTS.md sits at a repository root, which can never be an ownable managed root.
    $codexPathSucceeded = @{}
    foreach ($codexPath in $codexCandidatePaths) {
        $codexEntries = @()
        if ($codexSectionsByPath.ContainsKey($codexPath)) {
            $codexEntries = @($codexSectionsByPath[$codexPath].ToArray())
        }

        if ($codexEntries.Count -eq 0) {
            [void](Write-ManagedRegionFile -Path $codexPath)
            continue
        }

        $codexBlock = (@($codexEntries | Sort-Object Id | ForEach-Object { $_.Section })) -join "`r`n`r`n"
        $codexPathSucceeded[$codexPath] = Write-ManagedRegionFile -Path $codexPath -Content $codexBlock -ValidationLabel 'Codex instructions'
    }

    foreach ($codexId in ($codexResultsById.Keys | Sort-Object)) {
        $codexResult = $codexResultsById[$codexId]
        $codexSucceeded = $codexResult.MissingRepositories.Count -eq 0 -and $codexResult.Paths.Count -gt 0

        foreach ($codexPath in $codexResult.Paths) {
            if (-not ($codexPathSucceeded.ContainsKey($codexPath) -and $codexPathSucceeded[$codexPath])) {
                $codexSucceeded = $false
            }
        }

        Add-DeploymentRecord `
            -Category 'instruction' `
            -Id $codexId `
            -Target 'codex' `
            -Status $(if ($codexSucceeded) { 'ok' } else { 'blocked' }) `
            -Path $(if ($codexResult.Paths.Count -gt 0) { $codexResult.Paths -join '; ' } else { $null }) `
            -Detail $(if ($codexResult.MissingRepositories.Count -gt 0) { "destination '$($codexResult.MissingRepositories -join '; ')' does not exist" } else { $null }) `
            -MatrixValue $(if ($codexSucceeded) { $codexResult.MatrixValue } else { $null }) `
            -MatrixScoped $codexResult.MatrixScoped
    }

    return [pscustomobject]@{
        ClaudeInstructionTargets = @($claudeInstructionTargets.ToArray())
    }
}

function Get-CodexGlobalSkillPath {
    param([string]$Id)

    return Join-Path (Join-Path $script:codexGlobalSkillRoot 'skills') $Id
}

function Publish-Skills {
    param(
        [object]$Roots,
        [object[]]$Definitions
    )

    foreach ($definition in $Definitions) {
        $enabled = $definition.Enabled
        $id = $definition.Id
        $skillRepositories = @($definition.Repositories)
        $skillMatrixValue = if ($skillRepositories.Count -gt 0) { 'repository' } else { 'global' }

        if ((Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'vscode') -or (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'cli')) {
            $copilotDefinition = New-CopilotSkillDefinition -SkillDefinition $definition
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true
            $repoMissing = $false
            $missingRepoPaths = [System.Collections.Generic.List[string]]::new()

            $copilotRoots = if ($skillRepositories.Count -eq 0) {
                @($Roots.CopilotRoot)
            }
            else {
                @($skillRepositories | ForEach-Object { Join-Path $_ '.github' })
            }

            foreach ($copilotRoot in $copilotRoots) {
                if ($skillRepositories.Count -gt 0 -and -not (Test-Path -LiteralPath (Split-Path $copilotRoot -Parent) -PathType Container)) {
                    $repoMissing = $true
                    $succeeded = $false
                    $missingRepoPaths.Add((Split-Path $copilotRoot -Parent))
                    continue
                }

                $targetDirectory = if ($copilotRoot.Equals($Roots.CopilotRoot, [StringComparison]::OrdinalIgnoreCase)) {
                    Join-Path (Join-Path $copilotRoot 'skills') $id
                }
                else {
                    Join-Path (Join-Path $copilotRoot 'skills') $id
                }

                $publishTargets.Add($targetDirectory)
                $succeeded = (Install-RenderedSkill -Root $copilotRoot -SkillDefinition $copilotDefinition -Target 'copilot') -and $succeeded

                foreach ($commandDefinition in (Get-CopilotCommandSkillDefinitions -SkillDefinition $definition)) {
                    $legacyCommandFolderId = [string](Get-Prop $commandDefinition 'LegacyFolderId')
                    if (-not [string]::IsNullOrWhiteSpace($legacyCommandFolderId) -and
                        (-not $legacyCommandFolderId.Equals($commandDefinition.Id, [StringComparison]::OrdinalIgnoreCase))) {
                        $legacyCommandPath = Join-Path (Join-Path $copilotRoot 'skills') $legacyCommandFolderId
                        if (Test-Path -LiteralPath $legacyCommandPath) {
                            $legacyRemoved = Remove-KatManagedPath -Path $legacyCommandPath -RepositoryRoot $repoRoot
                            if (-not $legacyRemoved) {
                                Add-BlockedPath $legacyCommandPath
                                $succeeded = $false
                            }
                        }
                    }

                    $commandSucceeded = Install-RenderedSkill -Root $copilotRoot -SkillDefinition $commandDefinition -Target 'copilot'
                    $commandArtifactId = [string](Get-Prop $commandDefinition.Meta 'name')
                    if ([string]::IsNullOrWhiteSpace($commandArtifactId)) {
                        $commandArtifactId = $commandDefinition.Id
                    }

                    $commandPath = Join-Path (Join-Path $copilotRoot 'skills') $commandDefinition.Id
                    Add-DeploymentRecord -Category 'skill' -Id $commandArtifactId -Target 'copilot' -Status $(if ($commandSucceeded) { 'ok' } else { 'blocked' }) -Path $commandPath -Detail $(if ($skillRepositories.Count -gt 1) { "paths=$($copilotRoots.Count)" } else { $null }) -MatrixValue $(if ($commandSucceeded) { $skillMatrixValue } else { $null })
                    $succeeded = $commandSucceeded -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } elseif ($skillRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $(if ($succeeded) { $skillMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status 'disabled' -MatrixValue 'excluded'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $claudeDefinition = New-ClaudeSkillDefinition -SkillDefinition $definition
            $commandsSucceeded = $true
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $skillSucceeded = $true
            $repoMissing = $false
            $missingRepoPaths = [System.Collections.Generic.List[string]]::new()

            $claudeRoots = if ($skillRepositories.Count -eq 0) {
                @($Roots.ClaudeRoot)
            }
            else {
                @($skillRepositories | ForEach-Object { Join-Path $_ '.claude' })
            }

            foreach ($claudeRoot in $claudeRoots) {
                if ($skillRepositories.Count -gt 0 -and -not (Test-Path -LiteralPath (Split-Path $claudeRoot -Parent) -PathType Container)) {
                    $repoMissing = $true
                    $skillSucceeded = $false
                    $missingRepoPaths.Add((Split-Path $claudeRoot -Parent))
                    continue
                }

                $skillPath = Join-Path (Join-Path $claudeRoot 'skills') $id
                $publishTargets.Add($skillPath)
                $targetSkillSucceeded = Install-RenderedSkill -Root $claudeRoot -SkillDefinition $claudeDefinition -Target 'claude'
                $skillSucceeded = $targetSkillSucceeded -and $skillSucceeded

                if ($definition.CommandFiles.Count -gt 0) {
                    foreach ($commandFile in $definition.CommandFiles) {
                        $commandName = [System.IO.Path]::GetFileNameWithoutExtension($commandFile.Name)
                        $commandArtifactId = "${id}.$commandName"
                        $commandPath = Join-Path (Join-Path (Join-Path (Join-Path $claudeRoot 'skills') $id) 'commands') $commandFile.Name
                        $commandSucceeded = $false

                        if ($targetSkillSucceeded) {
                            $commandContent = Resolve-ClientMarkdown -Content (Get-Content -LiteralPath $commandFile.FullName -Raw) -Client 'claude'
                            $commandContent = Resolve-BodyReplacements -Content $commandContent -Meta $definition.Meta -Client 'claude'
                            $commandSucceeded = Write-ManagedFile -Path $commandPath -Content $commandContent -ValidationLabel "Skill command '$commandArtifactId' for Claude"
                        }

                        $commandsSucceeded = $commandsSucceeded -and $commandSucceeded
                        Add-DeploymentRecord -Category 'skill' -Id $commandArtifactId -Target 'claude' -Status $(if ($commandSucceeded) { 'ok' } else { 'blocked' }) -Path $commandPath -Detail $(if ($targetSkillSucceeded) { $null } else { 'skill-publish-failed' }) -MatrixValue $(if ($commandSucceeded) { $skillMatrixValue } else { $null })
                    }
                }
            }

            if ($definition.CommandFiles.Count -gt 0 -and -not $commandsSucceeded -and -not $repoMissing) {
                Add-Warning "${id}: One or more Claude commands were not published. See the deployment matrix for details."
            }

            $claudeSucceeded = $skillSucceeded -and $commandsSucceeded
            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status $(if ($claudeSucceeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } elseif ($claudeSucceeded) { $(if ($skillRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) } elseif (-not $skillSucceeded) { 'skill-publish-failed' } else { 'command-publish-failed' }) -MatrixValue $(if ($claudeSucceeded) { $skillMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status 'disabled' -MatrixValue 'excluded'
        }

        $codexEnabled = ConvertTo-BoolValue (Get-Prop $enabled 'codex') $false
        $codexIsGlobal = $skillRepositories.Count -eq 0

        if ($codexEnabled) {
            $codexDefinition = New-CodexSkillDefinition -SkillDefinition $definition
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $codexSucceeded = $true
            $repoMissing = $false
            $missingRepoPaths = [System.Collections.Generic.List[string]]::new()

            $codexRoots = if ($codexIsGlobal) {
                @($script:codexGlobalSkillRoot)
            }
            else {
                @($skillRepositories | ForEach-Object { Join-Path $_ '.agents' })
            }

            foreach ($codexRoot in $codexRoots) {
                if (-not $codexIsGlobal -and -not (Test-Path -LiteralPath (Split-Path $codexRoot -Parent) -PathType Container)) {
                    $repoMissing = $true
                    $codexSucceeded = $false
                    $missingRepoPaths.Add((Split-Path $codexRoot -Parent))
                    continue
                }

                $publishTargets.Add((Join-Path (Join-Path $codexRoot 'skills') $id))
                $codexSucceeded = (Install-RenderedSkill -Root $codexRoot -SkillDefinition $codexDefinition -Target 'codex') -and $codexSucceeded
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'codex' -Status $(if ($codexSucceeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { "destination '$($missingRepoPaths -join '; ')' does not exist" } elseif ($skillRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $(if ($codexSucceeded) { $skillMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'codex' -Status 'disabled' -MatrixValue 'excluded'
        }

        # Targeted cleanup: %USERPROFILE%\.agents\skills can never be a managed root, so only ids that
        # codex stopped publishing globally are removed — and only when KAT owns every file in them.
        if (-not ($codexEnabled -and $codexIsGlobal)) {
            $codexGlobalPath = Get-CodexGlobalSkillPath -Id $id
            if (Test-Path -LiteralPath $codexGlobalPath) {
                if (Remove-KatManagedPath -Path $codexGlobalPath -RepositoryRoot $repoRoot) {
                    Add-DeploymentRecord -Category 'skill' -Id $id -Target 'codex' -Status 'removed' -Path $codexGlobalPath
                }
                elseif (Test-KatManagedRemnant -Path $codexGlobalPath) {
                    Add-BlockedPath $codexGlobalPath
                    Add-DeploymentRecord -Category 'skill' -Id $id -Target 'codex' -Status 'blocked' -Path $codexGlobalPath -Detail 'previously published codex skill could not be removed'
                }
            }
        }
    }
}

function Test-KatManagedRemnant {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if ($null -eq $item) {
        return $false
    }

    if (-not $item.PSIsContainer) {
        return (Test-LegacyManagedItem -Item $item -RepositoryRoot $repoRoot)
    }

    foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -Recurse -ErrorAction SilentlyContinue)) {
        if (Test-LegacyManagedItem -Item $child -RepositoryRoot $repoRoot) {
            return $true
        }
    }

    return $false
}

function Get-ExternalPrimitiveDefinitions {
    $manifest = Read-KatJsonDocument -Path $externalManifestPath -DefaultFactory { [pscustomobject]@{} }

    $definitions = New-Object System.Collections.Generic.List[object]
    foreach ($property in @($manifest.PSObject.Properties | Sort-Object Name)) {
        $meta = $property.Value
        if ($null -eq $meta) {
            continue
        }

        if (-not (Test-UserAllowed -Meta $meta)) {
            continue
        }

        # `clients` is the current shape; `client` stays readable as a single-target shorthand.
        $clients = ConvertTo-StringArray (Get-Prop $meta 'clients')
        if ($clients.Count -eq 0) {
            $singleClient = [string](Get-Prop $meta 'client')
            if (-not [string]::IsNullOrWhiteSpace($singleClient)) {
                $clients = @($singleClient)
            }
        }

        $clients = @($clients |
            ForEach-Object { [string]$_ } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
            ForEach-Object { $_.Trim().ToLowerInvariant() } |
            Select-Object -Unique)

        # The manifest key is the KAT id we deploy under; `skill` is what upstream calls it, which is
        # also the directory `npx skills add` creates before the post-install rename.
        $upstreamSkill = [string](Get-Prop $meta 'skill')
        if ([string]::IsNullOrWhiteSpace($upstreamSkill)) {
            $upstreamSkill = $property.Name
        }

        $scope = [string](Get-Prop $meta 'scope')
        if ([string]::IsNullOrWhiteSpace($scope)) {
            $scope = 'global'
        }

        $definitions.Add([pscustomobject]@{
            Id = $property.Name
            Meta = $meta
            Enabled = ConvertTo-BoolValue (Get-Prop $meta 'enabled') $true
            Clients = @($clients)
            Source = [string](Get-Prop $meta 'source')
            Skill = $upstreamSkill.Trim()
            Scope = $scope.Trim().ToLowerInvariant()
            LegacyCommand = [string](Get-Prop $meta 'command')
            Amendments = Get-Prop $meta 'amendments'
        })
    }

    return @($definitions.ToArray())
}

function Get-ExternalPrimitiveClient {
    param([string]$Client)

    if ([string]::IsNullOrWhiteSpace($Client)) {
        return $null
    }

    $key = $Client.Trim().ToLowerInvariant()
    if (-not $script:externalPrimitiveClients.Contains($key)) {
        return $null
    }

    return $script:externalPrimitiveClients[$key]
}

function Test-ExternalPrimitiveClientInstalled {
    param(
        [ValidateSet('copilot', 'claude', 'codex')]
        [string]$Client
    )

    if ($null -eq $script:clientInstalled) {
        return $true
    }

    switch ($Client) {
        'copilot' {
            return $script:clientInstalled.vscode -or $script:clientInstalled.copilotCli
        }
        'claude' {
            return $script:clientInstalled.claude
        }
        'codex' {
            return $script:clientInstalled.codex
        }
    }

    return $false
}

function Get-ExternalPrimitiveInstallRoot {
    param(
        [ValidateSet('copilot', 'claude', 'codex')]
        [string]$Client
    )

    $clientInfo = Get-ExternalPrimitiveClient -Client $Client
    if ($null -eq $clientInfo) {
        return $null
    }

    return $clientInfo.GlobalRoot
}

function Get-ExternalPrimitiveInstallPath {
    param(
        [ValidateSet('copilot', 'claude', 'codex')]
        [string]$Client,
        [string]$Id
    )

    $root = Get-ExternalPrimitiveInstallRoot -Client $Client
    if ([string]::IsNullOrWhiteSpace($root)) {
        return $null
    }

    return Join-Path $root $Id
}

function New-ExternalPrimitiveCommand {
    param(
        [string]$Source,
        [string]$Skill,
        [string[]]$Clients
    )

    # `--copy` is mandatory, not incidental: the CLI otherwise symlinks each agent directory back to
    # one shared cache, so decoration would write into every other consumer's copy — and a symlinked
    # directory reads as a reparse point, which Test-LegacyManagedItem treats as KAT-managed and reaps.
    $arguments = New-Object System.Collections.Generic.List[string]
    $arguments.Add('--yes')
    $arguments.Add('skills')
    $arguments.Add('add')
    $arguments.Add($Source)
    $arguments.Add('--skill')
    $arguments.Add($Skill)

    # The CLI rejects a comma-joined agent list; repeated -a is the only multi-target form it accepts.
    foreach ($client in $Clients) {
        $clientInfo = Get-ExternalPrimitiveClient -Client $client
        if ($null -eq $clientInfo) { continue }
        $arguments.Add('--agent')
        $arguments.Add($clientInfo.Agent)
    }

    $arguments.Add('--global')
    $arguments.Add('--yes')
    $arguments.Add('--copy')

    return 'npx ' + ($arguments.ToArray() -join ' ')
}

function Remove-ExternalPrimitiveInstall {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $true
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

    try {
        Remove-Item -LiteralPath $Path -Recurse -Force -Confirm:$false -ErrorAction Stop
        return $true
    }
    catch {
        Add-BlockedPath $Path
        return $false
    }
}

function Set-MarkdownFrontmatterScalars {
    param(
        [string]$Path,
        [System.Collections.IDictionary]$Values
    )

    # Deliberately line-surgical rather than a parse/re-emit round trip: Split-MarkdownFrontmatter
    # keeps only top-level scalars, so rebuilding from it would silently drop upstream's nested
    # blocks (metadata:, lists). We touch only the keys we own and leave every other byte alone.
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $content = Get-Content -LiteralPath $Path -Raw
    $match = [regex]::Match($content, '\A---\r?\n(?<fm>[\s\S]*?)\r?\n---(?<rest>\r?\n[\s\S]*)\z')
    if (-not $match.Success) {
        return $false
    }

    $newline = if ($content -match "`r`n") { "`r`n" } else { "`n" }
    $lines = [System.Collections.Generic.List[string]]::new()
    foreach ($line in ($match.Groups['fm'].Value -split "`r?`n")) {
        $lines.Add($line)
    }

    foreach ($key in @($Values.Keys)) {
        $value = $Values[$key]
        $index = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match ("^" + [regex]::Escape($key) + "\s*:")) {
                $index = $i
                break
            }
        }

        if ($index -ge 0) {
            # A key whose value is a nested block spans lines we cannot safely rewrite one at a time.
            $inlineValue = ($lines[$index] -replace ("^" + [regex]::Escape($key) + "\s*:\s*"), '')
            $nextIsIndented = ($index + 1 -lt $lines.Count) -and ($lines[$index + 1] -match '^\s+\S')
            if ([string]::IsNullOrWhiteSpace($inlineValue) -and $nextIsIndented) {
                Add-Warning "external primitive: '$key' is a nested block in $Path; decoration skipped for that key."
                continue
            }
        }

        if ($null -eq $value) {
            if ($index -ge 0) {
                $lines.RemoveAt($index)
            }
            continue
        }

        $rendered = $key + ': ' + (Format-YamlScalar $value)
        if ($index -ge 0) {
            $lines[$index] = $rendered
        }
        else {
            $lines.Add($rendered)
        }
    }

    $rebuilt = '---' + $newline + (($lines.ToArray()) -join $newline) + $newline + '---' + $match.Groups['rest'].Value
    if ($rebuilt -ceq $content) {
        return $true
    }

    Set-Content -LiteralPath $Path -Value $rebuilt -NoNewline -Encoding utf8
    return $true
}

function Get-ExternalPrimitiveDecorations {
    param(
        [object]$Meta,
        [string]$Id,
        [ValidateSet('copilot', 'claude', 'codex')]
        [string]$Client
    )

    $values = [ordered]@{}

    # The rename gives the directory the KAT id; frontmatter `name` has to follow or the harnesses
    # advertise a name that no longer matches the folder the user finds it in.
    $name = [string](Get-Prop $Meta 'name')
    if ([string]::IsNullOrWhiteSpace($name)) { $name = $Id }
    $values['name'] = $name

    foreach ($field in @('description', 'argument-hint')) {
        $value = [string](Get-Prop $Meta $field)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values[$field] = $value
        }
    }

    # Codex reads name + description only, and expresses invocation intent in agents/openai.yaml.
    if ($Client -eq 'codex') {
        $values.Remove('argument-hint')
        return $values
    }

    foreach ($field in @('license', 'compatibility', 'context')) {
        $value = [string](Get-Prop $Meta $field)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            $values[$field] = $value
        }
    }

    # Same vocabulary ConvertTo-SkillDocument renders for vendored skills, so a skill reads the same
    # whether it is vendored or external. $null means "delete the key upstream shipped".
    $skillMeta = Get-Prop $Meta 'skills'
    foreach ($pair in @(
        @{ Prop = 'modelInvocable'; Key = 'disable-model-invocation'; Present = $true },
        @{ Prop = 'userInvocable'; Key = 'user-invocable'; Present = $false })) {
        $configured = Get-Prop $skillMeta $pair.Prop
        if ($null -eq $configured) { continue }
        $values[$pair.Key] = if (ConvertTo-BoolValue $configured $true) { $null } else { $pair.Present }
    }

    return $values
}

function Set-ExternalPrimitiveOpenAiInvocation {
    param(
        [string]$InstallPath,
        [object]$Meta
    )

    # Codex has no frontmatter equivalent for implicit invocation; agents/openai.yaml is the only place
    # it can be expressed. Upstream often ships the file already, so patch rather than author one.
    $skillMeta = Get-Prop $Meta 'skills'
    $configured = Get-Prop $skillMeta 'modelInvocable'
    if ($null -eq $configured) {
        return
    }

    $yamlPath = Join-Path (Join-Path $InstallPath 'agents') 'openai.yaml'
    if (-not (Test-Path -LiteralPath $yamlPath -PathType Leaf)) {
        return
    }

    $desired = if (ConvertTo-BoolValue $configured $true) { 'true' } else { 'false' }
    $content = Get-Content -LiteralPath $yamlPath -Raw
    $newline = if ($content -match "`r`n") { "`r`n" } else { "`n" }

    if ($content -match '(?m)^allow_implicit_invocation\s*:') {
        $updated = [regex]::Replace($content, '(?m)^allow_implicit_invocation\s*:.*$', "allow_implicit_invocation: $desired")
    }
    else {
        $updated = $content.TrimEnd() + $newline + "allow_implicit_invocation: $desired" + $newline
    }

    if ($updated -cne $content) {
        Set-Content -LiteralPath $yamlPath -Value $updated -NoNewline -Encoding utf8
    }
}

function Write-ExternalPrimitiveSidecar {
    param(
        [string]$InstallPath,
        [object]$Definition,
        [string[]]$Clients
    )

    # `npx skills` records no provenance in the installed directory — `skills list` reads its source
    # labels from the lockfile, not the tree — so KAT stamps its own, and the file doubles as the
    # marker that keeps Test-ReusableManagedDirectory from ever treating the tree as disposable.
    $sidecar = [ordered]@{
        managedBy = 'KAT'
        id = $Definition.Id
        source = $Definition.Source
        upstreamSkill = $Definition.Skill
        clients = @($Clients)
        scope = $Definition.Scope
        installedUtc = (Get-Date).ToUniversalTime().ToString('o')
    }

    try {
        $json = $sidecar | ConvertTo-Json -Depth 4
        Set-Content -LiteralPath (Join-Path $InstallPath $script:externalPrimitiveSidecarName) -Value $json -Encoding utf8
    }
    catch {
        # Provenance is best-effort; a failure here must not fail the install.
    }
}

function Get-AmendmentSources {
    param(
        [object[]]$ExternalPrimitiveDefinitions,
        [object[]]$SkillDefinitions
    )

    # Externals and vendored skills declare amendments the same way; they only differ in how each one
    # says which clients it reaches. Normalise both to {Id, Amendments, Clients} so the renderer below
    # does not care which kind it is looking at.
    $sources = New-Object System.Collections.Generic.List[object]

    foreach ($definition in @($ExternalPrimitiveDefinitions)) {
        if ($null -eq $definition -or -not $definition.Enabled) { continue }
        if ($null -eq $definition.Amendments) { continue }

        $sources.Add([pscustomobject]@{
            Id = $definition.Id
            Amendments = $definition.Amendments
            Clients = @($definition.Clients)
        })
    }

    foreach ($definition in @($SkillDefinitions)) {
        if ($null -eq $definition) { continue }

        $amendments = Get-Prop $definition.Meta 'amendments'
        if ($null -eq $amendments) { continue }

        $enabled = $definition.Enabled
        $clients = New-Object System.Collections.Generic.List[string]
        if ((Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'vscode') -or (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'cli')) {
            $clients.Add('copilot')
        }
        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) { $clients.Add('claude') }
        if (Test-CodexEnabled -Enabled $enabled) { $clients.Add('codex') }

        $sources.Add([pscustomobject]@{
            Id = [string](Get-Prop $definition 'Id')
            Amendments = $amendments
            Clients = @($clients.ToArray())
        })
    }

    return $sources.ToArray()
}

function New-SkillAmendmentSection {
    param([object[]]$Definitions)

    # An external skill's body is upstream's, so the only way to correct its behaviour is from the
    # outside. Instructions are that lever: they concatenate rather than replace, so a line here
    # overrides what the skill says without KAT ever owning the skill's prose. Amendments live next
    # to the entry they amend — in external.primitives.jsonc or a vendored skill's meta.jsonc — so
    # the override is findable from the thing it overrides.
    #
    # Vendored skills can amend too, and the reason is codex: bodyReplacements.codex is banned (D2)
    # because codex skill output is co-read by Copilot, so a body has no way to address codex alone.
    # A *global* codex instruction lands in ~/.codex/AGENTS.md, which Copilot does not read, making an
    # amendment the only safe channel for codex-only guidance.
    $sections = New-Object System.Collections.Generic.List[string]
    $clientsWithAmendments = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($definition in @($Definitions | Sort-Object { $_.Id })) {
        if ($null -eq $definition) { continue }

        $amendments = $definition.Amendments
        if ($null -eq $amendments) { continue }

        $deployedClients = @($definition.Clients)
        $lines = New-Object System.Collections.Generic.List[string]

        # 'all' first, then per-client. A per-client key is only honoured where the skill actually
        # deploys — an amendment for a client that never receives the skill is dead text.
        foreach ($rule in (ConvertTo-StringArray (Get-Prop $amendments 'all'))) {
            $lines.Add("- $rule")
        }

        foreach ($client in @('claude', 'copilot', 'codex')) {
            $clientRules = ConvertTo-StringArray (Get-Prop $amendments $client)
            if ($clientRules.Count -eq 0) { continue }

            if ($deployedClients -notcontains $client) {
                Add-Warning "external primitive '$($definition.Id)': amendments.$client is set but the entry does not deploy to $client; those lines were dropped."
                continue
            }

            [void]$clientsWithAmendments.Add($client)
            $lines.Add("<!-- ${client}:start -->")
            foreach ($rule in $clientRules) {
                $lines.Add("- $rule")
            }
            $lines.Add("<!-- ${client}:end -->")
        }

        if ($lines.Count -eq 0) { continue }

        $sections.Add("### $($definition.Id)")
        $sections.Add('')
        foreach ($line in $lines) { $sections.Add($line) }
        $sections.Add('')
    }

    if ($sections.Count -eq 0) {
        return $null
    }

    $body = @(
        '## Skill Amendments'
        ''
        'These skills are installed from upstream repositories, or are shipped to harnesses whose'
        'behaviour their body cannot address. The rules below override what those skills say. Where'
        'they conflict, these win.'
        ''
    ) + $sections.ToArray()

    return (($body -join "`r`n").TrimEnd())
}

function Add-SkillAmendmentSection {
    param(
        [object[]]$InstructionDefinitions,
        [object[]]$AmendmentSources
    )

    $section = New-SkillAmendmentSection -Definitions $AmendmentSources
    if ($null -eq $section) {
        return
    }

    # Amendments ride the kat instruction rather than an artifact of their own, so there is one place
    # to read the shared rules and one @import to keep track of. That makes the kat instruction's own
    # client enablement the gate: an amendment for a client kat does not reach is never delivered.
    $target = @($InstructionDefinitions | Where-Object { [string](Get-Prop $_ 'Id') -eq $script:amendmentHostInstructionId })
    if ($target.Count -eq 0) {
        Add-Warning "skill amendments were declared but instruction '$($script:amendmentHostInstructionId)' does not exist, so they were not published."
        return
    }

    $hostEnabled = $target[0].Enabled
    foreach ($client in @('claude', 'copilot', 'codex')) {
        $reaches = switch ($client) {
            'claude' { ConvertTo-BoolValue (Get-Prop $hostEnabled 'claude') $true }
            'copilot' { (Test-CopilotSubClientEnabled -Enabled $hostEnabled -SubClient 'vscode') -or (Test-CopilotSubClientEnabled -Enabled $hostEnabled -SubClient 'cli') }
            'codex' { Test-CodexEnabled -Enabled $hostEnabled }
        }

        if (-not $reaches -and $section -match ('(?i)<!--\s*' + [regex]::Escape($client) + ':start\s*-->')) {
            Add-Warning "skill amendments target $client, but instruction '$($script:amendmentHostInstructionId)' is not enabled for $client, so those lines are never delivered."
        }
    }

    $target[0].Body = ($target[0].Body.TrimEnd() + "`r`n`r`n" + $section + "`r`n")
}

function Remove-OrphanedExternalPrimitives {
    param([object[]]$Definitions)

    # Renaming a manifest entry strands its previous install: the rename step consumes the directory
    # npx wrote, but the Copilot mirror is KAT's own copy under the *old* id and nothing reclaims it.
    # The same happens when an entry is deleted outright, or when a user drops out of applyForUsers.
    # Sidecar provenance is what makes this safe to sweep — only directories KAT stamped are touched.
    $knownIds = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in @($Definitions)) {
        if ($null -eq $definition) { continue }
        [void]$knownIds.Add([string](Get-Prop $definition 'Id'))
    }

    $roots = @($script:universalGlobalSkillRoot) + @($script:externalPrimitiveClients.Keys | ForEach-Object { $script:externalPrimitiveClients[$_].GlobalRoot })
    foreach ($root in ($roots | Select-Object -Unique)) {
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        foreach ($directory in @(Get-ChildItem -LiteralPath $root -Directory -Force -ErrorAction SilentlyContinue)) {
            $sidecarPath = Join-Path $directory.FullName $script:externalPrimitiveSidecarName
            if (-not (Test-Path -LiteralPath $sidecarPath -PathType Leaf)) { continue }

            $sidecar = $null
            try { $sidecar = Get-Content -LiteralPath $sidecarPath -Raw | ConvertFrom-Json } catch { continue }
            if ([string](Get-Prop $sidecar 'managedBy') -ne 'KAT') { continue }

            $sidecarId = [string](Get-Prop $sidecar 'id')
            if ([string]::IsNullOrWhiteSpace($sidecarId) -or $knownIds.Contains($sidecarId)) { continue }

            if (Remove-ExternalPrimitiveInstall -Path $directory.FullName) {
                Add-DeploymentRecord -Category 'skill' -Id $sidecarId -Target 'claude' -Status 'removed' -Path $directory.FullName -Detail 'external primitive no longer in the manifest.'
            }
        }
    }
}

function Get-CommandOutputSummary {
    param(
        [object[]]$Output,
        [int]$MaxLength = 320
    )

    $lines = @($Output | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($lines.Count -eq 0) {
        return $null
    }

    $summary = (($lines | Select-Object -Last 6) -join ' ') -replace '\s+', ' '
    $summary = $summary.Trim()
    if ($summary.Length -gt $MaxLength) {
        return ($summary.Substring(0, $MaxLength - 3) + '...')
    }

    return $summary
}

function Invoke-ExternalPrimitiveCommand {
    param(
        [string]$Command,
        [string]$WorkingDirectory
    )

    $output = @()
    $exitCode = 0

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $output = @(& $env:ComSpec /d /c $Command 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    }
    finally {
        Pop-Location
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
        Detail = Get-CommandOutputSummary -Output $output
    }
}

function Get-ToolCommandPath {
    param([string]$Name)

    $command = Get-Command -Name $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($null -eq $command) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [string]$command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$command.Path)) {
        return [string]$command.Path
    }

    return $null
}

function Invoke-WingetCommand {
    param([string[]]$Arguments)

    $output = @()
    $exitCode = 0

    try {
        $output = @(& winget @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = @($_.Exception.Message)
        $exitCode = 1
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = @($output)
        Detail = Get-CommandOutputSummary -Output $output
    }
}

function Get-WingetFailureDetail {
    param(
        [int]$ExitCode,
        [string]$Summary
    )

    $normalizedSummary = if ($null -eq $Summary) { '' } else { $Summary.Trim() }
    $lowerSummary = $normalizedSummary.ToLowerInvariant()

    if ($lowerSummary -match 'no package found|not found|no available package') {
        return "winget failed ($ExitCode): package lookup failed. $normalizedSummary"
    }

    if ($lowerSummary -match 'network|connection|timeout|source') {
        return "winget failed ($ExitCode): network/source issue. $normalizedSummary"
    }

    if ($lowerSummary -match 'access is denied|administrator|elevation|permission') {
        return "winget failed ($ExitCode): permission/elevation issue. $normalizedSummary"
    }

    if (-not [string]::IsNullOrWhiteSpace($normalizedSummary)) {
        return "winget failed ($ExitCode): $normalizedSummary"
    }

    return "winget failed ($ExitCode)."
}

function Ensure-RipgrepTool {
    $toolId = 'BurntSushi.ripgrep.MSVC'
    $toolName = 'ripgrep'
    $toolDescription = 'Very fast text search CLI, better large-repo performance, which reduces failed/slow tool attempts.'
    $toolMethod = 'winget'
    $toolPath = Get-ToolCommandPath -Name 'rg'

    if (-not (Get-Command -Name 'winget' -ErrorAction SilentlyContinue)) {
        Add-DeploymentRecord -Category 'tool' -Id $toolName -Target 'local' -Status 'blocked' -Path $toolPath -Detail 'winget is not installed; cannot manage ripgrep.' -MatrixValue $toolMethod -MatrixScoped $toolDescription
        return
    }

    if ([string]::IsNullOrWhiteSpace($toolPath)) {
        $installArgs = @(
            'install',
            '--id', $toolId,
            '--exact',
            '--source', 'winget',
            '--accept-source-agreements',
            '--accept-package-agreements',
            '--disable-interactivity'
        )

        $installResult = Invoke-WingetCommand -Arguments $installArgs
        $toolPath = Get-ToolCommandPath -Name 'rg'
        if ([string]::IsNullOrWhiteSpace($toolPath)) {
            $detail = Get-WingetFailureDetail -ExitCode $installResult.ExitCode -Summary $installResult.Detail
            Add-DeploymentRecord -Category 'tool' -Id $toolName -Target 'local' -Status 'blocked' -Path $null -Detail $detail -MatrixValue $toolMethod -MatrixScoped $toolDescription
            return
        }
    }

    if ($DisableToolAutoUpgrade) {
        Add-DeploymentRecord -Category 'tool' -Id $toolName -Target 'local' -Status 'ok' -Path $toolPath -Detail 'Auto-upgrade disabled by -DisableToolAutoUpgrade.' -MatrixValue $toolMethod -MatrixScoped $toolDescription
        return
    }

    $upgradeArgs = @(
        'upgrade',
        '--id', $toolId,
        '--exact',
        '--source', 'winget',
        '--accept-source-agreements',
        '--accept-package-agreements',
        '--disable-interactivity'
    )

    $upgradeResult = Invoke-WingetCommand -Arguments $upgradeArgs
    $toolPath = Get-ToolCommandPath -Name 'rg'
    $upgradeSummary = if ($null -eq $upgradeResult.Detail) { '' } else { ([string]$upgradeResult.Detail).ToLowerInvariant() }

    if ($upgradeSummary -match 'no available upgrade found|no newer package versions are available') {
        Add-DeploymentRecord -Category 'tool' -Id $toolName -Target 'local' -Status 'ok' -Path $toolPath -Detail 'Already up to date.' -MatrixValue $toolMethod -MatrixScoped $toolDescription
        return
    }

    if ($upgradeResult.ExitCode -eq 0) {
        Add-DeploymentRecord -Category 'tool' -Id $toolName -Target 'local' -Status 'ok' -Path $toolPath -Detail $(if ([string]::IsNullOrWhiteSpace($upgradeResult.Detail)) { 'Upgrade check completed.' } else { $upgradeResult.Detail }) -MatrixValue $toolMethod -MatrixScoped $toolDescription
        return
    }

    $upgradeFailureDetail = Get-WingetFailureDetail -ExitCode $upgradeResult.ExitCode -Summary $upgradeResult.Detail
    Add-DeploymentRecord -Category 'tool' -Id $toolName -Target 'local' -Status 'blocked' -Path $toolPath -Detail $upgradeFailureDetail -MatrixValue $toolMethod -MatrixScoped $toolDescription
}

function Install-ExternalPrimitives {
    param([object[]]$Definitions)

    Remove-OrphanedExternalPrimitives -Definitions $Definitions

    $allClients = @($script:externalPrimitiveClients.Keys)

    foreach ($definition in $Definitions) {
        $id = $definition.Id
        $enabled = [bool]$definition.Enabled
        $requestedClients = @($definition.Clients)
        $validClients = @($requestedClients | Where-Object { $allClients -contains $_ })
        $invalidClients = @($requestedClients | Where-Object { $allClients -notcontains $_ })

        foreach ($targetClient in $allClients) {
            if ($validClients -notcontains $targetClient) {
                Add-DeploymentRecord -Category 'skill' -Id $id -Target $targetClient -Status 'disabled' -MatrixValue 'excluded'
            }
        }

        if ($invalidClients.Count -gt 0) {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status 'blocked' -Detail "client '$($invalidClients -join ', ')' is invalid."
            continue
        }

        if ($validClients.Count -eq 0) {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status 'blocked' -Detail 'clients is required.'
            continue
        }

        # Uninstall runs against every client the entry names, whether or not that harness is present:
        # a harness uninstalled after its skills were deployed must still get its tree cleaned up.
        # Copilot and codex share one directory, so remove it once and report it against both.
        if (-not $enabled) {
            $removedRoots = @{}
            foreach ($client in $validClients) {
                $installPath = Get-ExternalPrimitiveInstallPath -Client $client -Id $id
                if (-not $removedRoots.ContainsKey($installPath)) {
                    $wasInstalled = Test-Path -LiteralPath $installPath
                    $removed = if ($wasInstalled) { Remove-ExternalPrimitiveInstall -Path $installPath } else { $false }
                    $removedRoots[$installPath] = [pscustomobject]@{ Was = $wasInstalled; Removed = $removed }
                }

                # npx always writes the universal root for a universal agent, so sweep it too even
                # though an enabled sync would already have dropped it for a copilot-only entry.
                if ((Get-ExternalPrimitiveClient -Client $client).Universal) {
                    [void](Remove-ExternalPrimitiveInstall -Path (Join-Path $script:universalGlobalSkillRoot $id))
                }

                $state = $removedRoots[$installPath]
                $stillInstalled = Test-Path -LiteralPath $installPath
                Add-DeploymentRecord `
                    -Category 'skill' `
                    -Id $id `
                    -Target $client `
                    -Status $(if ($stillInstalled) { 'blocked' } elseif ($state.Was -and $state.Removed) { 'removed' } else { 'disabled' }) `
                    -Path $(if ($state.Was) { $installPath } else { $null }) `
                    -MatrixValue $(if ($state.Was) { $null } else { 'excluded' }) `
                    -Detail $(if ($stillInstalled) { 'installed external primitive remains present.' } else { $null })
            }
            continue
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$definition.LegacyCommand)) {
            foreach ($client in $validClients) {
                Add-DeploymentRecord -Category 'skill' -Id $id -Target $client -Status 'blocked' -Detail "'command' is no longer supported; declare 'source' and 'skill' instead."
            }
            continue
        }

        if ($definition.Scope -ne 'global') {
            foreach ($client in $validClients) {
                Add-DeploymentRecord -Category 'skill' -Id $id -Target $client -Status 'blocked' -Detail "scope '$($definition.Scope)' is not supported; only 'global' is."
            }
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$definition.Source)) {
            foreach ($client in $validClients) {
                Add-DeploymentRecord -Category 'skill' -Id $id -Target $client -Status 'blocked' -Detail 'source is required.'
            }
            continue
        }

        $installClients = @($validClients | Where-Object { Test-ExternalPrimitiveClientInstalled -Client $_ })
        foreach ($client in $validClients) {
            if ($installClients -notcontains $client) {
                Add-DeploymentRecord -Category 'skill' -Id $id -Target $client -Status 'disabled' -MatrixValue 'excluded'
            }
        }

        if ($installClients.Count -eq 0) {
            continue
        }

        # One invocation covers every target: the CLI takes repeated -a and writes each agent's root
        # itself, so KAT never has to know more than the table it mirrors from that same CLI.
        $command = New-ExternalPrimitiveCommand -Source $definition.Source -Skill $definition.Skill -Clients $installClients
        $commandResult = Invoke-ExternalPrimitiveCommand -Command $command -WorkingDirectory $repoRoot
        $commandSucceeded = $commandResult.ExitCode -eq 0

        if (-not $commandSucceeded) {
            $detail = if (-not [string]::IsNullOrWhiteSpace($commandResult.Detail)) {
                "command failed ($($commandResult.ExitCode)): $($commandResult.Detail)"
            }
            else {
                "command failed ($($commandResult.ExitCode))."
            }

            foreach ($client in $installClients) {
                Add-DeploymentRecord -Category 'skill' -Id $id -Target $client -Status 'blocked' -Path (Get-ExternalPrimitiveInstallPath -Client $client -Id $id) -Detail $detail
            }
            continue
        }

        $wantsUniversal = @($installClients | Where-Object { (Get-ExternalPrimitiveClient -Client $_).Universal }).Count -gt 0
        $universalPath = Join-Path $script:universalGlobalSkillRoot $id
        $failures = @{}

        # npx wrote at most two directories — the claude root, and the shared universal root — each
        # under upstream's own name. Rename into the KAT id so the prefix that namespaces these for
        # the team survives, and so vendored and external ids stay one set of names.
        $stagedRoots = [ordered]@{}
        if ($installClients -contains 'claude') {
            $stagedRoots[(Get-ExternalPrimitiveInstallRoot -Client 'claude')] = 'claude'
        }
        if ($wantsUniversal) {
            # One file serves both universal clients, so render the fuller form unless codex owns the
            # directory alone — the same rule ConvertTo-SkillDocument follows for its co-scanned
            # copies. Codex simply ignores the keys it does not know.
            $stagedRoots[$script:universalGlobalSkillRoot] = if ($installClients -contains 'copilot') { 'copilot' } else { 'codex' }
        }

        foreach ($stagedRoot in @($stagedRoots.Keys)) {
            $stagedPath = Join-Path $stagedRoot $id
            $upstreamPath = Join-Path $stagedRoot $definition.Skill

            if ($upstreamPath -ne $stagedPath -and (Test-Path -LiteralPath $upstreamPath)) {
                if (-not (Remove-ExternalPrimitiveInstall -Path $stagedPath)) {
                    $failures[$stagedRoot] = 'existing install could not be replaced.'
                    continue
                }

                try {
                    Move-Item -LiteralPath $upstreamPath -Destination $stagedPath -Force -ErrorAction Stop
                }
                catch {
                    $failures[$stagedRoot] = "rename from '$($definition.Skill)' failed: $($_.Exception.Message)"
                    continue
                }
            }

            if (-not (Test-Path -LiteralPath $stagedPath -PathType Container)) {
                $failures[$stagedRoot] = "install reported success but '$($definition.Skill)' was not found in the target root."
                continue
            }

            # Decoration is a render step, not stored state: the install above overwrites SKILL.md from
            # upstream HEAD every sync, so patching after every install is what keeps it from drifting.
            # An editor holding SKILL.md open is a transient, per-entry problem — report it and let the
            # rest of the sync finish rather than aborting every remaining artifact.
            try {
                $decorations = Get-ExternalPrimitiveDecorations -Meta $definition.Meta -Id $id -Client $stagedRoots[$stagedRoot]
                if (-not (Set-MarkdownFrontmatterScalars -Path (Join-Path $stagedPath 'SKILL.md') -Values $decorations)) {
                    Add-Warning "external primitive '$id': SKILL.md in $stagedPath has no frontmatter; decoration was skipped."
                }

                if ($installClients -contains 'codex') {
                    Set-ExternalPrimitiveOpenAiInvocation -InstallPath $stagedPath -Meta $definition.Meta
                }
            }
            catch {
                $failures[$stagedRoot] = "decoration failed: $($_.Exception.Message)"
                continue
            }

            Write-ExternalPrimitiveSidecar -InstallPath $stagedPath -Definition $definition -Clients $installClients
        }

        # Copilot CLI resolves ~/.copilot/skills, which npx will not write for a universal agent, so
        # mirror the finished universal copy there. Byte-identical by construction, which is what the
        # co-scanning rule requires of trees Copilot may pick a winner from.
        $copilotPath = Get-ExternalPrimitiveInstallPath -Client 'copilot' -Id $id
        if ($installClients -contains 'copilot' -and -not $failures.ContainsKey($script:universalGlobalSkillRoot)) {
            if (Remove-ExternalPrimitiveInstall -Path $copilotPath) {
                try {
                    New-Directory (Split-Path $copilotPath -Parent)
                    Copy-Item -LiteralPath $universalPath -Destination $copilotPath -Recurse -Force -ErrorAction Stop
                }
                catch {
                    $failures[(Get-ExternalPrimitiveInstallRoot -Client 'copilot')] = "mirror to Copilot CLI root failed: $($_.Exception.Message)"
                }
            }
            else {
                $failures[(Get-ExternalPrimitiveInstallRoot -Client 'copilot')] = 'existing Copilot CLI install could not be replaced.'
            }
        }

        # The universal copy exists only because npx always writes it for a universal agent. Codex is
        # the one client that actually reads it, so drop it when codex was not asked for — otherwise a
        # copilot-only entry would silently surface in Codex too.
        if ($wantsUniversal -and $installClients -notcontains 'codex') {
            [void](Remove-ExternalPrimitiveInstall -Path $universalPath)
        }

        foreach ($client in $installClients) {
            $clientRoot = Get-ExternalPrimitiveInstallRoot -Client $client
            $clientPath = Join-Path $clientRoot $id
            $failure = if ($failures.ContainsKey($clientRoot)) { $failures[$clientRoot] } elseif ($client -eq 'copilot' -and $failures.ContainsKey($script:universalGlobalSkillRoot)) { $failures[$script:universalGlobalSkillRoot] } else { $null }

            Add-DeploymentRecord `
                -Category 'skill' `
                -Id $id `
                -Target $client `
                -Status $(if ($null -eq $failure) { 'ok' } else { 'blocked' }) `
                -Path $clientPath `
                -Detail $failure `
                -MatrixValue $(if ($null -eq $failure) { 'global' } else { $null })
        }
    }
}

function Publish-ClaudeDocument {
    param(
        [object]$Roots,
        [object]$InstructionPublishResult,
        [object[]]$Definitions
    )

    $definitionsById = @{}
    foreach ($definition in $Definitions) {
        $definitionsById[$definition.Id] = $definition
    }

    $claudeImportsByRoot = @{}
    foreach ($instructionTarget in $InstructionPublishResult.ClaudeInstructionTargets) {
        $definition = $definitionsById[$instructionTarget.Id]
        if ($null -eq $definition) {
            continue
        }

        $targetRoot = [string]$instructionTarget.Root

        if (-not $claudeImportsByRoot.ContainsKey($targetRoot)) {
            $claudeImportsByRoot[$targetRoot] = New-Object System.Collections.Generic.List[string]
        }

        $claudeImportsByRoot[$targetRoot].Add($instructionTarget.Id)
    }

    foreach ($targetRoot in ($claudeImportsByRoot.Keys | Sort-Object)) {
        $instructionIds = @($claudeImportsByRoot[$targetRoot] | Sort-Object -Unique)
        $claudeDocument = @(
            '# Generated by KAT Policies',
            '',
            "Edit canonical instructions under $repoRoot\\AI\\instructions.",
            ''
        ) + ($instructionIds | ForEach-Object { "@instructions/$_.md" })
        $claudeDocumentPath = Join-Path $targetRoot 'CLAUDE.md'
        $repoTargetedClaudeDocument = -not $targetRoot.Equals($Roots.ClaudeRoot, [StringComparison]::OrdinalIgnoreCase)
        $claudeDocumentSucceeded = Write-ManagedFile -Path $claudeDocumentPath -Content ($claudeDocument -join "`r`n") -ForceOwnedPath $repoTargetedClaudeDocument -ValidationLabel 'Claude instruction import index'
        Add-DeploymentRecord -Category 'link' -Id 'CLAUDE.md' -Target 'claudeDoc' -Status $(if ($claudeDocumentSucceeded) { 'ok' } else { 'blocked' }) -Path $claudeDocumentPath -Detail ("imports=" + $instructionIds.Count)
        if (-not $repoTargetedClaudeDocument) {
            Add-DeploymentRecord -Category 'instruction' -Id 'Instruction Import Index' -Target 'vscode'                  -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped 'no'
            Add-DeploymentRecord -Category 'instruction' -Id 'Instruction Import Index' -Target 'copilotCli'              -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped 'no'
            Add-DeploymentRecord -Category 'instruction' -Id 'Instruction Import Index' -Target 'claudeGlobalInstruction' -Status $(if ($claudeDocumentSucceeded) { 'ok' } else { 'blocked' }) -MatrixValue $(if ($claudeDocumentSucceeded) { 'global' } else { $null }) -MatrixScoped 'no'
            Add-DeploymentRecord -Category 'instruction' -Id 'Instruction Import Index' -Target 'claudePathInstruction'   -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped 'no'
        }
    }
}

function Get-RemovedPathInfo {
    param([string]$Path)

    $fileName   = [System.IO.Path]::GetFileName($Path)
    $dirName    = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName($Path))
    $parentDir  = [System.IO.Path]::GetFileName([System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($Path)))

    $id = $fileName -replace '\.agent\.md$', '' -replace '\.md$', ''

    # Agents in prompts folder (VSCode global agents use .agent.md)
    if ($dirName -eq 'prompts' -and $fileName -match '\.agent\.md$') {
        return [pscustomobject]@{ Category = 'agent'; Id = $id; Target = 'vscode' }
    }

    # Agents folder. A skill may own an 'agents' subfolder (helper agents, or the codex
    # agents/openai.yaml sidecar), so anything under a skills tree belongs to the skill.
    if (($dirName -eq 'agents' -or $parentDir -eq 'agents') -and $Path -notmatch '\\skills\\') {
        if ($Path -match '\\\.claude\\') {
            return [pscustomobject]@{ Category = 'agent'; Id = $id; Target = 'claude' }
        }
        if ($Path -match '\\\.copilot\\') {
            return [pscustomobject]@{ Category = 'agent'; Id = $id; Target = 'copilotCli' }
        }
        return [pscustomobject]@{ Category = 'agent'; Id = $id; Target = 'vscode' }
    }

    # Instructions / rules
    if ($dirName -eq 'instructions' -or $dirName -eq 'rules') {
        if ($Path -match '\\\.claude\\') {
            $target = if ($dirName -eq 'rules') { 'claudePathInstruction' } else { 'claudeGlobalInstruction' }
            return [pscustomobject]@{ Category = 'instruction'; Id = $id; Target = $target }
        }
        if ($Path -match '\\\.copilot\\') {
            return [pscustomobject]@{ Category = 'instruction'; Id = $id; Target = 'copilotCli' }
        }
        return [pscustomobject]@{ Category = 'instruction'; Id = $id; Target = 'vscode' }
    }

    # Skills — id is first path component after 'skills\'
    if ($Path -match '\\skills\\([^\\]+)') {
        $skillId = $Matches[1]
        if ($Path -match '\\\.agents\\') {
            return [pscustomobject]@{ Category = 'skill'; Id = $skillId; Target = 'codex' }
        }
        if ($Path -match '\\\.claude\\') {
            return [pscustomobject]@{ Category = 'skill'; Id = $skillId; Target = 'claude' }
        }
        return [pscustomobject]@{ Category = 'skill'; Id = $skillId; Target = 'copilot' }
    }

    # Links
    if ($fileName -eq '.editorconfig') {
        return [pscustomobject]@{ Category = 'link'; Id = '.editorconfig'; Target = 'btr' }
    }

    return $null
}

function Register-RemovedRecords {
    if ($preSyncManagedPaths.Count -eq 0) { return }

    $deployedPaths = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($record in ($deploymentRecords | Where-Object Status -eq 'ok')) {
        if ([string]::IsNullOrWhiteSpace($record.Path)) { continue }
        foreach ($part in ($record.Path -split ';\s*')) {
            $part = $part.Trim()
            if (-not [string]::IsNullOrWhiteSpace($part)) {
                $null = $deployedPaths.Add($part)
            }
        }
    }

    $seenKeys = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $preSyncManagedPaths) {
        if ($deployedPaths.Contains($path)) { continue }

        $info = Get-RemovedPathInfo -Path $path
        if ($null -eq $info) { continue }

        $key = "$($info.Category)|$($info.Id)|$($info.Target)"
        if (-not $seenKeys.Add($key)) { continue }

        if (Test-Path -LiteralPath $path) {
            $hasOkRecord = $null -ne ($deploymentRecords | Where-Object {
                $_.Category -eq $info.Category -and $_.Id -eq $info.Id -and $_.Target -eq $info.Target -and $_.Status -eq 'ok'
            } | Select-Object -First 1)
            if ($hasOkRecord) { continue }
            Add-BlockedPath $path
            Add-DeploymentRecord -Category $info.Category -Id $info.Id -Target $info.Target -Status 'blocked' -Path $path -Detail 'file not removed (close VS Code)'
        }
        else {
            Add-DeploymentRecord -Category $info.Category -Id $info.Id -Target $info.Target -Status 'removed' -Path $path
        }
    }
}

function Get-FootnoteMarker {
    param(
        [System.Collections.Generic.List[string]]$Footnotes,
        [string]$Detail,
        [System.Collections.Generic.List[string]]$FootnoteColors = $null,
        [string]$Color = $null
    )

    $superscripts = @('¹','²','³','⁴','⁵','⁶','⁷','⁸','⁹')
    $existing = $Footnotes.IndexOf($Detail)
    if ($existing -ge 0) {
        $num = $existing + 1
    }
    else {
        [void]$Footnotes.Add($Detail)
        if ($null -ne $FootnoteColors) { [void]$FootnoteColors.Add($Color) }
        $num = $Footnotes.Count
    }

    return ($num -le $superscripts.Count) ? $superscripts[$num - 1] : "[$num]"
}

function Get-CellDisplayValue {
    param(
        [object]$Record,
        [System.Collections.Generic.List[string]]$Footnotes,
        [System.Collections.Generic.List[string]]$FootnoteColors = $null
    )

    if ($null -eq $Record) {
        return 'excluded'
    }

    switch ($Record.Status) {
        'removed'  { return 'removed' }
        'disabled' { return 'excluded' }
        'blocked'  {
            if (Test-SkippedPath ([string]$Record.Path)) {
                $detail = 'file is no longer read-only; run update.ps1 with -Overwrite to replace'
                $marker = Get-FootnoteMarker -Footnotes $Footnotes -Detail $detail -FootnoteColors $FootnoteColors -Color 'DarkYellow'
                return "skipped$marker"
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$Record.Detail)) {
                $marker = Get-FootnoteMarker -Footnotes $Footnotes -Detail ([string]$Record.Detail) -FootnoteColors $FootnoteColors -Color 'Red'
                return "blocked$marker"
            }
            return 'blocked'
        }
        'skipped'  {
            $detail = if (-not [string]::IsNullOrWhiteSpace([string]$Record.Detail)) { [string]$Record.Detail } else { 'skipped' }
            $marker = Get-FootnoteMarker -Footnotes $Footnotes -Detail $detail -FootnoteColors $FootnoteColors -Color 'DarkYellow'
            return "skipped$marker"
        }
        'unsupported' {
            # Something was explicitly asked for that this client cannot receive — distinct from 'excluded'.
            $detail = if (-not [string]::IsNullOrWhiteSpace([string]$Record.Detail)) { [string]$Record.Detail } else { 'not supported for this client' }
            $marker = Get-FootnoteMarker -Footnotes $Footnotes -Detail $detail -FootnoteColors $FootnoteColors -Color 'DarkYellow'
            return "unsupported$marker"
        }
        'ok'       {
            if (-not [string]::IsNullOrWhiteSpace([string]$Record.MatrixValue)) {
                return [string]$Record.MatrixValue
            }
            return 'global'
        }
        default    {
            if (-not [string]::IsNullOrWhiteSpace([string]$Record.MatrixValue)) {
                return [string]$Record.MatrixValue
            }
            return $Record.Status
        }
    }
}

function Format-ManagedPath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Path }

    if (-not [string]::IsNullOrWhiteSpace($env:APPDATA) -and $Path.StartsWith($env:APPDATA, [StringComparison]::OrdinalIgnoreCase)) {
        return '%APPDATA%' + $Path.Substring($env:APPDATA.Length)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA) -and $Path.StartsWith($env:LOCALAPPDATA, [StringComparison]::OrdinalIgnoreCase)) {
        return '%LOCALAPPDATA%' + $Path.Substring($env:LOCALAPPDATA.Length)
    }

    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and $Path.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        return '%USERPROFILE%' + $Path.Substring($env:USERPROFILE.Length)
    }

    return $Path
}

function Write-McpDeploymentMatrix {
    param([int]$ArtifactWidth)

    $mcpRecords = @($deploymentRecords | Where-Object Category -eq 'mcp')
    if ($mcpRecords.Count -eq 0) { return }

    $groups         = $mcpRecords | Group-Object Id | Sort-Object Name
    $statusColWidth = 13
    $mcpActiveTargetDefs = @(
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.vscode)     { [pscustomobject]@{ Target = 'vscode';     Header = 'vscode' } }
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.copilotCli) { [pscustomobject]@{ Target = 'copilotCli'; Header = 'cli'    } }
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.claude)     { [pscustomobject]@{ Target = 'claude';     Header = 'claude' } }
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.codex)      { [pscustomobject]@{ Target = 'codex';      Header = 'codex'  } }
    )
    $mcpDisplayTargets = @($mcpActiveTargetDefs | ForEach-Object { $_.Target })
    $footnotes      = [System.Collections.Generic.List[string]]::new()
    $footnoteColors = [System.Collections.Generic.List[string]]::new()

    $rows = foreach ($group in $groups) {
        $cells      = @($group.Name)
        $cellColors = @($null)

        foreach ($target in $mcpDisplayTargets) {
            $record = $group.Group | Where-Object Target -eq $target | Select-Object -First 1
            $displayValue = if ($null -eq $record) {
                'excluded'
            } elseif ($record.Status -eq 'ok') {
                'installed'
            } elseif ($record.Status -eq 'unsupported') {
                $detail = if (-not [string]::IsNullOrWhiteSpace([string]$record.Detail)) { [string]$record.Detail } else { 'not supported for this client' }
                $marker = Get-FootnoteMarker -Footnotes $footnotes -Detail $detail -FootnoteColors $footnoteColors -Color 'DarkYellow'
                "unsupported$marker"
            } else {
                $detail = [string]$record.Detail
                if (-not [string]::IsNullOrWhiteSpace($detail)) {
                    $marker = Get-FootnoteMarker -Footnotes $footnotes -Detail $detail -FootnoteColors $footnoteColors -Color 'Red'
                    "blocked$marker"
                } else {
                    'blocked'
                }
            }

            $cells      += $displayValue
            $cellColors += if ($displayValue -like 'blocked*') { 'Red' } elseif ($displayValue -like 'skipped*') { 'DarkYellow' } elseif ($displayValue -like 'unsupported*') { 'DarkYellow' } elseif ($displayValue -eq 'excluded') { 'DarkYellow' } else { $null }
        }

        if ($cells.Count -gt 1 -and -not @($cells[1..($cells.Count - 1)] | Where-Object { [string]$_ -ne 'excluded' })) { continue }

        [pscustomobject]@{ Cells = $cells; CellColors = $cellColors }
    }

    Write-AsciiTable `
        -Title '--- MCP Server Deployment Status ---' `
        -Headers (@('mcp server') + @($mcpActiveTargetDefs | ForEach-Object { $_.Header })) `
        -Rows $rows `
        -Color 'Green' `
        -FixedWidths (@($ArtifactWidth) + @($mcpActiveTargetDefs | ForEach-Object { $statusColWidth })) `
        -Alignments (@('left') + @($mcpActiveTargetDefs | ForEach-Object { 'status' })) `
        -HeaderAlignments (@('left') + @($mcpActiveTargetDefs | ForEach-Object { 'center' })) `
        -Footnotes $footnotes `
        -FootnoteColors $footnoteColors
}

function Write-SyncReport {
    Write-Host ''

    # Global artifact column width across all categories + MCP server names.
    # +1 for the ¹ repo marker that may be appended, +2 for cell padding.
    $globalMaxNameLen = @(
        @('agent', 'instruction', 'skill') | ForEach-Object {
            $cat = $_
            @($deploymentRecords | Where-Object Category -eq $cat | Group-Object Id) | ForEach-Object { $_.Name.Length }
        }
        @($deploymentRecords | Where-Object Category -eq 'mcp' | Group-Object Id) | ForEach-Object { $_.Name.Length }
    ) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    if ($null -eq $globalMaxNameLen) { $globalMaxNameLen = 0 }
    $globalArtifactWidth = [Math]::Max('artifact'.Length, [Math]::Max('mcp server'.Length, $globalMaxNameLen) + 3)

    Write-McpDeploymentMatrix -ArtifactWidth $globalArtifactWidth
    Write-ConfigurationLocationsTable
    Write-InstalledToolsTable
    Write-DeploymentMatrix -ArtifactWidth $globalArtifactWidth
    Write-CompatibilitySummary -ArtifactWidth $globalArtifactWidth
    Write-ArtifactLocationsTable

    if ($skippedPaths.Count -gt 0) {
        Write-Host '--- Manual Actions Required ---' -ForegroundColor DarkYellow
        Write-Host '- These files are no longer read-only (may have been manually modified) and were skipped. Run update.ps1 with -Overwrite to replace:' -ForegroundColor DarkYellow
        $skippedPaths | Sort-Object -Unique | ForEach-Object {
            Write-Host "   - $_" -ForegroundColor DarkYellow
        }
    }

    if ($blockedPaths.Count -gt 0) {
        Write-Host '--- Manual Cleanup Required ---' -ForegroundColor Red
        Write-Host '- Delete these paths to finalize KAT Policies synchronization:' -ForegroundColor Red
        $blockedPaths | Sort-Object -Unique | ForEach-Object {
            $reason = Get-ManualCleanupReason -Path $_
            $suffix = if ([string]::IsNullOrWhiteSpace($reason)) { '' } else { " ($reason)" }
            Write-Host "   - $_$suffix" -ForegroundColor Red
        }
    }
}

function Get-ManualCleanupReason {
    param([string]$Path)

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
    if ($null -eq $item) {
        return 'path no longer exists'
    }

    if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        if (Test-ReusableManagedDirectory -Path $Path -RepositoryRoot $repoRoot) {
            return 'directory could not be removed automatically'
        }

        return 'directory contains files not owned by KAT Policies'
    }

    if (-not (Test-LegacyManagedItem -Item $item -RepositoryRoot $repoRoot)) {
        return 'file is not owned by KAT Policies'
    }

    return 'path could not be removed automatically'
}

function Write-InstalledToolsTable {
    $toolRecords = @($deploymentRecords | Where-Object Category -eq 'tool')
    if ($toolRecords.Count -eq 0) {
        return
    }

    $groups = $toolRecords | Group-Object Id | Sort-Object Name
    $footnotes = [System.Collections.Generic.List[string]]::new()
    $footnoteColors = [System.Collections.Generic.List[string]]::new()

    $rows = foreach ($group in $groups) {
        $record = $group.Group | Sort-Object {
            switch ($_.Status) {
                'ok' { 0 }
                'blocked' { 1 }
                'skipped' { 2 }
                default { 3 }
            }
        } | Select-Object -First 1

        $name = [string]$group.Name
        $method = if (-not [string]::IsNullOrWhiteSpace([string]$record.MatrixValue)) { [string]$record.MatrixValue } else { 'n/a' }
        $description = if (-not [string]::IsNullOrWhiteSpace([string]$record.MatrixScoped)) { [string]$record.MatrixScoped } else { 'Managed tool' }

        if ($record.Status -in @('blocked', 'skipped') -and -not [string]::IsNullOrWhiteSpace([string]$record.Detail)) {
            $marker = Get-FootnoteMarker -Footnotes $footnotes -Detail ([string]$record.Detail) -FootnoteColors $footnoteColors -Color 'Red'
            $description = "$description$marker"
        }

        $statusColor = if ($record.Status -in @('blocked', 'skipped')) { 'Red' } else { $null }
        [pscustomobject]@{
            Cells = @($name, $method, $description)
            CellColors = @($statusColor, $statusColor, $statusColor)
        }
    }

    Write-AsciiTable `
        -Title '--- Installed Tools ---' `
        -Headers @('Name', 'Install Method', 'Description') `
        -Rows $rows `
        -Color 'Green' `
        -Alignments @('left', 'center', 'left') `
        -HeaderAlignments @('left', 'center', 'left') `
        -Footnotes $footnotes `
        -FootnoteColors $footnoteColors
}


function Add-McpDeploymentRecords {
    param(
        [string]$ProductName,
        [object]$PassThruResult
    )

    $clientTargetMap = @{
        'vscode'      = 'vscode'
        'copilot-cli' = 'copilotCli'
        'claude'      = 'claude'
        'environment' = 'install'
    }

    foreach ($result in @((Get-Prop $PassThruResult 'Results'))) {
        if ($null -eq $result) { continue }

        $client = [string](Get-Prop $result 'Client')
        $target = $clientTargetMap[$client]
        if ($null -eq $target) { continue }

        $status = [string](Get-Prop $result 'Status')
        $path   = [string](Get-Prop $result 'Path')
        $detail = [string](Get-Prop $result 'Detail')

        $mappedStatus = switch ($status) {
            'ok'      { 'ok' }
            'blocked' { 'blocked' }
            default   { 'disabled' }
        }

        if ([string]::IsNullOrWhiteSpace($path) -or $path -eq '-') {
            if ($mappedStatus -ne 'blocked') { continue }
        }

        Add-DeploymentRecord -Category 'mcp' -Id $ProductName -Target $target -Status $mappedStatus -Path $path -Detail $detail
    }
}

function Write-BootstrapNoClientWarnings {
    param(
        [string]$ProductName,
        [object]$CheckResult
    )

    $checkResults = @((Get-Prop $CheckResult 'Results'))
    foreach ($result in $checkResults) {
        if ($null -eq $result) {
            continue
        }

        $status = [string](Get-Prop $result 'Status')
        if ($status -ine 'no-client') {
            continue
        }

        $client = [string](Get-Prop $result 'Client')
        if ([string]::IsNullOrWhiteSpace($client)) {
            $client = 'unknown client'
        }

        $isAlreadyCovered = $null -ne $script:clientInstalled -and (
            ($client -ieq 'claude'      -and -not $script:clientInstalled.claude) -or
            ($client -ieq 'copilot-cli' -and -not $script:clientInstalled.copilotCli)
        )
        if ($isAlreadyCovered) { continue }

        Add-Warning "$ProductName MCP setup: skipped $client because no client installation was detected."
    }
}

function Add-CodexMcpUnsupportedRecords {
    param([object]$McpSettings)

    # Codex configures MCP through config.toml; the three install-*.ps1 helpers are JSON-based.
    foreach ($mcpServer in @(
            [pscustomobject]@{ Key = 'context7';  ProductName = 'Context7'  },
            [pscustomobject]@{ Key = 'github';    ProductName = 'GitHub'    },
            [pscustomobject]@{ Key = 'katledger'; ProductName = 'KatLedger' })) {

        $serverConfig = Get-Prop $McpSettings $mcpServer.Key
        if ($null -eq $serverConfig) { continue }
        if (-not (ConvertTo-BoolValue (Get-Prop $serverConfig 'codex') $false)) { continue }

        Add-Warning "$($mcpServer.ProductName) MCP setup: codex is out of scope. Codex configures MCP servers in config.toml, which KAT Policies does not manage."
        Add-DeploymentRecord -Category 'mcp' -Id $mcpServer.ProductName -Target 'codex' -Status 'unsupported' -Detail 'Codex configures MCP servers in config.toml, which KAT Policies does not manage'
    }
}

function Invoke-McpBootstrap {
    param(
        [Parameter(Mandatory)][string]$ProductName,
        [Parameter(Mandatory)][string]$HelperScript,
        [Parameter(Mandatory)][object]$McpConfig
    )

    $helperScriptPath = Join-Path $PSScriptRoot $HelperScript
    if (-not (Test-Path -LiteralPath $helperScriptPath)) {
        throw "$ProductName bootstrap helper script is missing: $helperScriptPath"
    }

    $skipParams = @{}
    if (-not (Test-McpClientEnabled -McpConfig $McpConfig -Client 'vscode')) { $skipParams['SkipVsCode'] = $true }
    if (-not (Test-McpClientEnabled -McpConfig $McpConfig -Client 'cli'))    { $skipParams['SkipCopilotCli'] = $true }
    if (-not (Test-McpClientEnabled -McpConfig $McpConfig -Client 'claude')) { $skipParams['SkipClaude'] = $true }
    if ($NonInteractive) { $skipParams['NonInteractive'] = $true }

    $checkResult = & $helperScriptPath @skipParams -CheckOnly -PassThru

    $isCompliant = [bool](Get-Prop $checkResult 'IsCompliant' $false)
    $hasBlocked = [bool](Get-Prop $checkResult 'HasBlocked' $false)
    $needsInstall = [bool](Get-Prop $checkResult 'NeedsInstall' $false)

    Write-BootstrapNoClientWarnings -ProductName $ProductName -CheckResult $checkResult

    if ($isCompliant -and -not $hasBlocked -and -not $needsInstall) {
        Add-McpDeploymentRecords -ProductName $ProductName -PassThruResult $checkResult
        return
    }

    if ($NonInteractive -and $hasBlocked -and -not $needsInstall) {
        Add-McpDeploymentRecords -ProductName $ProductName -PassThruResult $checkResult
        return
    }

    $applyResult = & $helperScriptPath @skipParams -PassThru
    Add-McpDeploymentRecords -ProductName $ProductName -PassThruResult $applyResult
}

function Invoke-PolicySync {
    $script:clientInstalled = @{
        vscode     = Test-KatVsCodeInstalled
        copilotCli = Test-KatCopilotCliInstalled
        claude     = Test-KatClaudeInstalled
        codex      = Test-KatCodexInstalled
    }

    $roots = Get-EnvironmentRoots
    $agentDefinitions = Get-AgentDefinitions
    $instructionDefinitions = Get-InstructionDefinitions
    $skillDefinitions = Get-SkillDefinitionsWithContent
    $skillHelperAgentDefinitions = @($skillDefinitions | ForEach-Object { @($_.HelperAgentDefinitions) })
    $allAgentDefinitions = @($agentDefinitions) + @($skillHelperAgentDefinitions)
    $externalPrimitiveDefinitions = Get-ExternalPrimitiveDefinitions
    $mcpSettings = Get-SharedMcpSettings

    # Amendments render as one more global instruction, so they flow through the same publish path,
    # the same client markers, and the same cross-harness audit as every hand-authored instruction.
    $amendmentSources = Get-AmendmentSources -ExternalPrimitiveDefinitions $externalPrimitiveDefinitions -SkillDefinitions $skillDefinitions
    Add-SkillAmendmentSection -InstructionDefinitions $instructionDefinitions -AmendmentSources $amendmentSources

    # Runs before any managed root is cleared: a policy violation must not leave the trees half-published.
    Assert-CrossHarnessPolicy -SkillDefinitions $skillDefinitions -InstructionDefinitions $instructionDefinitions -AgentDefinitions $allAgentDefinitions -ExternalPrimitiveDefinitions $externalPrimitiveDefinitions

    try {
        $managedContexts = Get-ManagedContexts -Roots $roots -AgentDefinitions $allAgentDefinitions -InstructionDefinitions $instructionDefinitions -SkillDefinitions $skillDefinitions
        foreach ($context in $managedContexts) {
            $collapseEmptyToRoot = $null
            if ($context -is [System.Collections.IDictionary] -and $context.Contains('CollapseEmptyToRoot')) {
                $collapseEmptyToRoot = $context['CollapseEmptyToRoot']
            }

            Clear-ManagedRoot -Root $context.Root -ScanRoots $context.ScanRoots -RepositoryRoot $repoRoot -CollapseEmptyToRoot $collapseEmptyToRoot
        }

        Publish-EditorConfig
        Publish-TerminalFiles -Roots $roots
        Publish-Agents -Roots $roots -Definitions $allAgentDefinitions
        $instructionPublishResult = Publish-Instructions -Roots $roots -Definitions $instructionDefinitions
        Publish-Skills -Roots $roots -Definitions $skillDefinitions
        Install-ExternalPrimitives -Definitions $externalPrimitiveDefinitions
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.claude) {
            Publish-ClaudeDocument -Roots $roots -InstructionPublishResult $instructionPublishResult -Definitions $instructionDefinitions
        }
        Sync-VsCodeSettingsSafeguards
        Ensure-RipgrepTool

        Add-CodexMcpUnsupportedRecords -McpSettings $mcpSettings

        if (Test-McpParityRequested -ServerKey 'context7') {
            Invoke-McpBootstrap -ProductName 'Context7' -HelperScript 'install-context7-remote.ps1' -McpConfig (Get-Prop $mcpSettings 'context7')
        }

        if (Test-McpParityRequested -ServerKey 'github') {
            Invoke-McpBootstrap -ProductName 'GitHub' -HelperScript 'install-github-remote.ps1' -McpConfig (Get-Prop $mcpSettings 'github')
        }

        if (Test-McpParityRequested -ServerKey 'katledger') {
            Invoke-McpBootstrap -ProductName 'KatLedger' -HelperScript 'install-katledger.ps1' -McpConfig (Get-Prop $mcpSettings 'katledger')
        }
    }
    finally {
        Register-RemovedRecords
        Write-SyncReport
    }
}

function Write-DeploymentMatrix {
	param([int]$ArtifactWidth)

    if ($deploymentRecords.Count -eq 0) {
        return
    }

    $categoryLabels = @{
        agent       = 'Agents'
        instruction = 'Instructions'
        skill       = 'Skills'
    }

    $statusColWidth  = 13
    $activeTargetDefs = @(
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.vscode)     { [pscustomobject]@{ Target = 'vscode';     Header = 'vscode' } }
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.copilotCli) { [pscustomobject]@{ Target = 'copilotCli'; Header = 'cli'    } }
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.claude)     { [pscustomobject]@{ Target = 'claude';     Header = 'claude' } }
        if ($null -eq $script:clientInstalled -or $script:clientInstalled.codex)      { [pscustomobject]@{ Target = 'codex';      Header = 'codex'  } }
    )
    $displayTargets = @($activeTargetDefs | ForEach-Object { $_.Target })
    $displayHeaders = @('artifact') + @($activeTargetDefs | ForEach-Object { $_.Header })

    function Get-InstructionRecord {
        param([object[]]$Records, [string]$Target)

        if ($Target -eq 'claude') {
            $record = @($Records | Where-Object { $_.Target -in @('claudeGlobalInstruction', 'claudePathInstruction') -and $_.Status -ne 'disabled' } | Select-Object -First 1)
            if ($record.Count -eq 0) {
                $record = @($Records | Where-Object { $_.Target -in @('claudeGlobalInstruction', 'claudePathInstruction') } | Select-Object -First 1)
            }
            return ($record.Count -gt 0) ? $record[0] : $null
        }
        return Select-DisplayRecord -Records @($Records | Where-Object Target -eq $Target)
    }

    function Select-DisplayRecord {
        param([object[]]$Records)
        return $Records | Sort-Object { switch ($_.Status) { 'ok' { 0 } 'removed' { 1 } 'blocked' { 2 } default { 3 } } } | Select-Object -First 1
    }

    Write-Host '--- AI Artifact Deployment Matrix ---' -ForegroundColor Cyan

    $hasArtifacts = $false
    foreach ($category in @('agent', 'instruction', 'skill')) {
        $records = @($deploymentRecords | Where-Object Category -eq $category)
        if ($records.Count -eq 0) { continue }

        $groups          = $records | Group-Object Id | Sort-Object Name
        $artifactWidth   = $ArtifactWidth
        $fixedWidths     = @($artifactWidth) + @($activeTargetDefs | ForEach-Object { $statusColWidth })
        $alignments      = @('left') + @($activeTargetDefs | ForEach-Object { 'status' })
        $headerAligns    = @('left') + @($activeTargetDefs | ForEach-Object { 'center' })
        $tableFootnotes      = [System.Collections.Generic.List[string]]::new()
        $tableFootnoteColors = [System.Collections.Generic.List[string]]::new()
        if (@($records | Where-Object { [string]$_.MatrixValue -eq 'repository' }).Count -gt 0) {
            [void]$tableFootnotes.Add($(if ($Verbosity -eq 'Detailed') { 'repository-scoped: see Artifact Locations table for deployment paths' } else { 'repository-scoped: run with -Verbosity Detailed to see deployment paths' }))
            [void]$tableFootnoteColors.Add('DarkCyan')
        }

        $rows = foreach ($group in $groups) {
            if (-not @($group.Group | Where-Object { $_.Status -ne 'disabled' }).Count) { continue }

            $cells = @($group.Name)
            foreach ($displayTarget in $displayTargets) {
                if ($category -eq 'instruction') {
                    $record = Get-InstructionRecord -Records $group.Group -Target $displayTarget
                }
                elseif ($category -eq 'skill' -and $displayTarget -in @('vscode', 'copilotCli')) {
                    $record = Select-DisplayRecord -Records @($group.Group | Where-Object Target -eq 'copilot')
                }
                else {
                    $record = Select-DisplayRecord -Records @($group.Group | Where-Object Target -eq $displayTarget)
                }
                $cells += (Get-CellDisplayValue -Record $record -Footnotes $tableFootnotes -FootnoteColors $tableFootnoteColors)
            }

            if ($cells.Count -gt 1 -and -not @($cells[1..($cells.Count - 1)] | Where-Object { [string]$_ -ne 'excluded' })) { continue }

            $rowIsRepoScoped = @($cells | Select-Object -Skip 1 | Where-Object { [string]$_ -eq 'repository' }).Count -gt 0
            if ($rowIsRepoScoped) {
                $cells = @(([string]$cells[0] + '¹')) + @($cells[1..($cells.Count - 1)])
            }

            $cellColors = @($null) # artifact column — no special color
            for ($ci = 1; $ci -lt $cells.Count; $ci++) {
                $v = [string]$cells[$ci]
                $cellColors += if ($v -like 'blocked*') { 'Red' } elseif ($v -like 'skipped*') { 'DarkYellow' } elseif ($v -like 'unsupported*') { 'DarkYellow' } elseif ($v -in @('excluded', 'removed')) { 'DarkYellow' } else { $null }
            }

            [pscustomobject]@{ Cells = $cells; CellColors = $cellColors }
        }

        # Having records is not the same as having rows: a category whose every artifact is disabled
        # or excluded filters down to nothing above, and a heading over an empty table says less than
        # printing no section at all.
        $rows = @($rows)
        if ($rows.Count -eq 0) { continue }

		if (-not $hasArtifacts) {
			Write-Host ''
	        $hasArtifacts = $true
		}

        Write-AsciiTable -Title $categoryLabels[$category] -Headers $displayHeaders -Rows $rows -Color 'Cyan' -FixedWidths $fixedWidths -Alignments $alignments -HeaderAlignments $headerAligns -Footnotes $tableFootnotes -FootnoteColors $tableFootnoteColors
    }
	
	if (-not $hasArtifacts) {
		Write-Host '--- No artifacts were deployed ---' -ForegroundColor DarkYellow
	}
}

function Write-ArtifactLocationsTable {
    if ($Verbosity -ne 'Detailed') {
        return
    }

    if ($deploymentRecords.Count -eq 0) {
        return
    }

    $categoryLabels = @{
        agent       = 'Agent'
        instruction = 'Instruction'
        skill       = 'Skill'
    }
    $targetLabels = @{
        vscode                  = 'VSCode'
        copilotCli              = 'CLI'
        claude                  = 'Claude'
        claudeGlobalInstruction = 'Claude'
        claudePathInstruction   = 'Claude'
        copilot                 = 'Copilot'
        claudeDoc               = 'Claude'
        codex                   = 'Codex'
    }
    $categoryOrder = @('agent', 'instruction', 'skill')
    $targetOrders = @{
        agent       = @('vscode', 'copilotCli', 'claude')
        instruction = @('vscode', 'copilotCli', 'claudeGlobalInstruction', 'claudePathInstruction', 'codex')
        skill       = @('copilot', 'claude', 'codex')
    }

    $rows = @()
    $seenKeys = [System.Collections.Generic.HashSet[string]]::new()

    foreach ($category in $categoryOrder) {
        $categoryLabel = $categoryLabels[$category]

        foreach ($target in $targetOrders[$category]) {
            $records = @($deploymentRecords | Where-Object {
                $_.Category -eq $category -and
                $_.Target -eq $target -and
                $_.Status -eq 'ok' -and
                -not [string]::IsNullOrWhiteSpace($_.Path)
            })

            if ($records.Count -eq 0) { continue }

            $allPaths = @($records | ForEach-Object {
                $_.Path -split ';\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            })

            $uniqueDirs = @($allPaths | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique)
            $defaultLabel = $targetLabels[$target]

            foreach ($dir in $uniqueDirs) {
                $isGlobal = $dir.StartsWith($env:USERPROFILE, [System.StringComparison]::OrdinalIgnoreCase) -or
                            $dir.StartsWith($env:APPDATA, [System.StringComparison]::OrdinalIgnoreCase)
                $typeLabel = if ($isGlobal) { $defaultLabel } else { 'Scoped' }
                $key = "$category|$typeLabel|$dir"
                if ($seenKeys.Add($key)) {
                    $rows += [pscustomobject]@{ Cells = @($categoryLabel, $typeLabel, (Format-ManagedPath -Path $dir)) }
                }
            }
        }
    }

    # MCP Config rows: vscode/cli/claude config paths merged across all HTTP servers, deduplicated by client+dir
    $mcpClientLabels = @{ vscode = 'VSCode'; copilotCli = 'CLI'; claude = 'Claude' }
    $mcpClientOrder  = @('vscode', 'copilotCli', 'claude')

    foreach ($target in $mcpClientOrder) {
        $records = @($deploymentRecords | Where-Object {
            $_.Category -eq 'mcp' -and
            $_.Target -eq $target -and
            $_.Status -eq 'ok' -and
            -not [string]::IsNullOrWhiteSpace($_.Path)
        })
        if ($records.Count -eq 0) { continue }

        $allPaths = @($records | ForEach-Object {
            $_.Path -split ';\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        })
        $uniqueDirs = @($allPaths | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique)
        $clientLabel = $mcpClientLabels[$target]

        foreach ($dir in $uniqueDirs) {
            $key = "mcp-config|$clientLabel|$dir"
            if ($seenKeys.Add($key)) {
                $rows += [pscustomobject]@{ Cells = @('MCP Config', $clientLabel, (Format-ManagedPath -Path $dir)) }
            }
        }
    }

    # MCP Install rows: per-server install directories (e.g. KatLedger binary location)
    $mcpInstallRecords = @($deploymentRecords | Where-Object {
        $_.Category -eq 'mcp' -and $_.Target -eq 'install' -and
        $_.Status -eq 'ok' -and -not [string]::IsNullOrWhiteSpace($_.Path)
    })
    foreach ($group in ($mcpInstallRecords | Group-Object Id | Sort-Object Name)) {
        $allPaths = @($group.Group | ForEach-Object {
            $_.Path -split ';\s*' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        })
        $uniqueDirs = @($allPaths | ForEach-Object { Split-Path $_ -Parent } | Sort-Object -Unique)

        foreach ($dir in $uniqueDirs) {
            $key = "mcp-install|$($group.Name)|$dir"
            if ($seenKeys.Add($key)) {
                $rows += [pscustomobject]@{ Cells = @("$($group.Name) MCP", 'N/A', (Format-ManagedPath -Path $dir)) }
            }
        }
    }

    # Instruction Import Index — uses the claudeDoc link record path so it renders with a distinct type label
    foreach ($record in @($deploymentRecords | Where-Object {
        $_.Category -eq 'link' -and $_.Target -eq 'claudeDoc' -and $_.Status -eq 'ok' -and -not [string]::IsNullOrWhiteSpace($_.Path)
    })) {
        $dir = Split-Path ([string]$record.Path) -Parent
        $key = "instruction-index|Claude|$dir"
        if ($seenKeys.Add($key)) {
            $rows += [pscustomobject]@{ Cells = @('Instruction Index', 'Claude', (Format-ManagedPath -Path $dir)) }
        }
    }

    if ($rows.Count -eq 0) { return }

    $getArtifactRank = {
        param([string]$Label)
        switch ($Label) {
            'Agent'             { return 0 }
            'Instruction'       { return 1 }
            'Instruction Index' { return 2 }
            'Skill'             { return 3 }
            'MCP Config'        { return 4 }
            default {
                if ($Label -like '* MCP') { return 5 }
                return 99
            }
        }
    }
    $typeOrder = @{ 'N/A' = 0; VSCode = 1; CLI = 2; Claude = 3; Scoped = 4; Copilot = 5; Codex = 6 }

    $sortedRows = $rows | Sort-Object {
        $aRank = & $getArtifactRank $_.Cells[0]
        $tRank = if ($typeOrder.ContainsKey($_.Cells[1])) { $typeOrder[$_.Cells[1]] } else { 99 }
        '{0:D2}|{1:D2}|{2}|{3}' -f $aRank, $tRank, $_.Cells[0], $_.Cells[2]
    }

    Write-AsciiTable -Title 'Artifact Locations' -Headers @('artifact type', 'client', 'location') -Rows $sortedRows -Color 'Cyan' -Alignments @('left', 'center', 'left') -HeaderAlignments @('left', 'center', 'left')
}


function Write-ConfigurationLocationsTable {
    $footnotes      = [System.Collections.Generic.List[string]]::new()
    $footnoteColors = [System.Collections.Generic.List[string]]::new()
    $rows = [System.Collections.Generic.List[object]]::new()
    $configurationTargets = @(
        [pscustomobject]@{ Category = 'link'; Target = 'btr';             Type = '.editorconfig';           SuccessStatus = 'installed' }
        [pscustomobject]@{ Category = 'link'; Target = 'terminal';        Type = 'Windows Terminal';       SuccessStatus = 'installed' }
        [pscustomobject]@{ Category = 'config'; Target = 'vscodeSettings'; Type = 'VS Code Copilot Chat'; SuccessStatus = 'configured' }
    )

    foreach ($configurationTarget in $configurationTargets) {
        $records = @($deploymentRecords | Where-Object {
            $_.Category -eq $configurationTarget.Category -and
            $_.Target -eq $configurationTarget.Target
        })
        if ($records.Count -eq 0) { continue }

        $blockedRecord = $records | Where-Object Status -eq 'blocked' | Select-Object -First 1
        $skippedRecord = $records | Where-Object Status -eq 'skipped' | Select-Object -First 1
        $okRecord = $records | Where-Object Status -eq 'ok' | Select-Object -First 1

        if ($null -ne $blockedRecord) {
            $detail = [string]$blockedRecord.Detail
            $displayStatus = if (-not [string]::IsNullOrWhiteSpace($detail)) {
                "blocked$(Get-FootnoteMarker -Footnotes $footnotes -Detail $detail -FootnoteColors $footnoteColors -Color 'Red')"
            } else { 'blocked' }
            $statusColor = 'Red'
        }
        elseif ($null -ne $skippedRecord -and $null -eq $okRecord) {
            $detail = [string]$skippedRecord.Detail
            $skipDetail = if (-not [string]::IsNullOrWhiteSpace($detail)) { $detail } else { 'skipped' }
            $displayStatus = "skipped$(Get-FootnoteMarker -Footnotes $footnotes -Detail $skipDetail -FootnoteColors $footnoteColors -Color 'DarkYellow')"
            $statusColor = 'DarkYellow'
        }
        else {
            $detail = if ($null -ne $okRecord) { [string]$okRecord.Detail } else { '' }
            if ($configurationTarget.Category -eq 'config' -and $detail -eq 'already compliant') {
                $displayStatus = 'compliant'
            }
            else {
                $displayStatus = $configurationTarget.SuccessStatus
            }
            $statusColor = $null
        }

        $location = '-'
        $recordForLocation = if ($null -ne $okRecord) { $okRecord } elseif ($null -ne $blockedRecord) { $blockedRecord } else { $skippedRecord }
        if ($null -ne $recordForLocation) {
            $path = [string]$recordForLocation.Path
            if (-not [string]::IsNullOrWhiteSpace($path)) {
                $location = Format-ManagedPath -Path $path
            }
        }

        $cells = @($configurationTarget.Type, $displayStatus, $location)
        $cellColors = @($null, $statusColor, $null)

        $rows.Add([pscustomobject]@{
            Cells      = $cells
            CellColors = $cellColors
        })
    }

    if ($rows.Count -eq 0) { return }

    $headers = @('type', 'status', 'location')
    $alignments = @('left', 'status', 'left')
    $headerAlignments = @('left', 'center', 'left')

    Write-AsciiTable `
        -Title '--- Configuration Locations ---' `
        -Headers $headers `
        -Rows $rows `
        -Color 'Green' `
        -Alignments $alignments `
        -HeaderAlignments $headerAlignments `
        -Footnotes $footnotes `
        -FootnoteColors $footnoteColors
}

function Write-CompatibilitySummary {
	param([int]$ArtifactWidth)

    $notInstalledRows = @(
        if ($null -ne $script:clientInstalled -and -not $script:clientInstalled.claude) {
            [pscustomobject]@{ Cells = @('claude primitives', 'Claude Code not installed. All primitives skipped.') }
        }
        if ($null -ne $script:clientInstalled -and -not $script:clientInstalled.copilotCli) {
            [pscustomobject]@{ Cells = @('copilot cli primitives', 'Copilot CLI not installed. All primitives skipped.') }
        }
        if ($null -ne $script:clientInstalled -and -not $script:clientInstalled.vscode) {
            [pscustomobject]@{ Cells = @('vscode primitives', 'GitHub Copilot (VS Code) not installed. All primitives skipped.') }
        }
        if ($null -ne $script:clientInstalled -and -not $script:clientInstalled.codex) {
            [pscustomobject]@{ Cells = @('codex primitives', 'Codex CLI not installed. Codex columns are hidden from the deployment matrix.') }
        }
    )

    if ($compatibilityMessages.Count -eq 0 -and $notInstalledRows.Count -eq 0) {
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

    $rollupRows = @(
        foreach ($label in $rollups.Keys) {
        $items = @($rollups[$label])
        if ($items.Count -eq 0) {
            continue
        }

        [pscustomobject]@{
            Cells = @(($items -join "`n"), "$label ($($items.Count))")
        }
        }
    )

    if ($otherMessages.Count -gt 0) {
        $rollupRows += [pscustomobject]@{
            Cells = @((($otherMessages | Sort-Object -Unique) -join "`n"), "Other ($($otherMessages.Count))")
        }
    }

    $summaryRows = @($notInstalledRows) + $rollupRows

    if (@($summaryRows).Count -gt 0) {
		Write-Host 'Compatibility Summary' -ForegroundColor DarkYellow
        Write-AsciiTable -Title '' -Headers @('artifact', 'category') -Rows $summaryRows -Color 'DarkYellow' -RowDividers $true -FixedWidths @($ArtifactWidth, 0)
    }
}

function Remove-AlternateDataStream {
    param(
        [string]$Path,
        [string]$StreamName
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return $true
    }

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

    $resolvedPath = (Resolve-Path -LiteralPath $Path -ErrorAction Ignore).Path
    if ([string]::IsNullOrWhiteSpace($resolvedPath)) {
        return $true
    }

    $streamPath = '\\?\' + $resolvedPath + ':' + $StreamName
    $deleted = [KatNativeMethods]::DeleteFile($streamPath)
    if ($deleted) {
        return $true
    }

    $errorCode = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
    return $errorCode -in @(2, 3)
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

function Test-CopilotSubClientEnabled {
    param(
        [object]$Enabled,
        [ValidateSet('vscode', 'cli')]
        [string]$SubClient
    )

    $topLevel = Get-Prop $Enabled 'copilot'
    if ($null -ne $topLevel) {
        # Explicit top-level: true → always enabled; false → check sub-property
        if (ConvertTo-BoolValue $topLevel $false) { return $true }
        return ConvertTo-BoolValue (Get-Prop $Enabled "copilot.$SubClient") $false
    }
    # Top-level absent: check sub-property; if also absent fall back to true (backward compat)
    $subProp = Get-Prop $Enabled "copilot.$SubClient"
    if ($null -ne $subProp) {
        return ConvertTo-BoolValue $subProp $false
    }
    return $true
}

function Test-UserAllowed {
    param([object]$Meta)

    $allowed = Get-Prop $Meta 'applyForUsers'
    if ($null -eq $allowed) { return $true }
    $allowedArr = @($allowed)
    if ($allowedArr.Count -eq 0) { return $true }
    return $allowedArr -contains $env:USERNAME
}

function Resolve-BodyReplacements {
    param(
        [string]$Content,
        [object]$Meta,
        [ValidateSet('copilot', 'vscode', 'copilotCli', 'claude', 'codex')]
        [string]$Client
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return $Content
    }

    $metaKey = switch ($Client) {
        'vscode'     { 'copilot.vscode' }
        'copilotCli' { 'copilot.cli' }
        'copilot'    { 'copilot' }
        'claude'     { 'claude' }
        'codex'      { 'codex' }
    }

    $replacements = Get-Prop (Get-Prop $Meta 'bodyReplacements') $metaKey
    if ($null -eq $replacements) {
        return $Content
    }

    $resolved = $Content
    foreach ($prop in $replacements.PSObject.Properties) {
        $resolved = $resolved.Replace($prop.Name, $prop.Value)
    }

    return $resolved
}

function Test-CodexEnabled {
    param([object]$Enabled)

    # Mirrors the publish-time default: codex is opt-in everywhere.
    return (ConvertTo-BoolValue (Get-Prop $Enabled 'codex') $false)
}

function Test-CoScannedArtifact {
    param(
        [object]$Enabled,
        [object[]]$Repositories
    )

    # Copilot reads .github/skills, .claude/skills and .agents/skills at repository scope, so every
    # repo-scoped artifact is co-scanned. At global scope ~/.claude/skills is invisible to Copilot, so
    # only codex participation (which adds the Copilot-readable ~/.agents/skills) makes it co-scanned.
    if (@($Repositories).Count -gt 0) { return $true }
    return (Test-CodexEnabled -Enabled $Enabled)
}

function Get-KnownPrimitiveIds {
    param(
        [object[]]$SkillDefinitions,
        [object[]]$InstructionDefinitions,
        [object[]]$AgentDefinitions
    )

    $ids = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($definition in (@($SkillDefinitions) + @($InstructionDefinitions) + @($AgentDefinitions))) {
        if ($null -eq $definition) { continue }
        $id = [string](Get-Prop $definition 'Id')
        if (-not [string]::IsNullOrWhiteSpace($id)) { [void]$ids.Add($id) }
    }

    # Commands are invoked as <skill>:<command> in Claude and <skill>.<command> in Copilot; both
    # resolve back to the same canonical skill id for sigil purposes.
    foreach ($definition in @($SkillDefinitions)) {
        if ($null -eq $definition) { continue }
        $skillId = [string](Get-Prop $definition 'Id')
        foreach ($commandFile in @(Get-Prop $definition 'CommandFiles')) {
            if ($null -eq $commandFile) { continue }
            [void]$ids.Add($skillId + '.' + $commandFile.BaseName)
        }
    }

    return $ids
}

function Get-InvocationSigilMatches {
    param(
        [string]$Content,
        [System.Collections.Generic.HashSet[string]]$KnownIds
    )

    $found = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Content) -or $null -eq $KnownIds) {
        return $found.ToArray()
    }

    # A sigil is a leading / or $ that is not part of a path or URL, followed by a primitive id and an
    # optional :command / .command suffix.
    $pattern = '(?<![\w./\\$-])[/$]([A-Za-z0-9][A-Za-z0-9_-]*)(?:([:.])([A-Za-z0-9][A-Za-z0-9_-]*))?'
    foreach ($match in [regex]::Matches($Content, $pattern)) {
        $head = $match.Groups[1].Value
        $qualified = $head
        if ($match.Groups[3].Success) {
            $qualified = $head + '.' + $match.Groups[3].Value
        }

        if ($KnownIds.Contains($qualified) -or $KnownIds.Contains($head)) {
            $text = $match.Value
            if (-not $found.Contains($text)) { $found.Add($text) }
        }
    }

    return $found.ToArray()
}

function Get-AgentsMarkdownImports {
    param([string]$Content)

    $found = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Content)) {
        return $found.ToArray()
    }

    # Copilot expands @relative/path inside AGENTS.md; Codex has no import mechanism and ingests the
    # line as literal text, so the two clients read different instructions from the same file.
    foreach ($match in [regex]::Matches($Content, '(?m)(?<![\w`])@([./\\][^\s`]+|[A-Za-z0-9_.-]+[/\\][^\s`]+)')) {
        $text = $match.Value
        if (-not $found.Contains($text)) { $found.Add($text) }
    }

    return $found.ToArray()
}

function Assert-CrossHarnessPolicy {
    param(
        [object[]]$SkillDefinitions,
        [object[]]$InstructionDefinitions,
        [object[]]$AgentDefinitions,
        [object[]]$ExternalPrimitiveDefinitions = @()
    )

    $errors = New-Object System.Collections.Generic.List[string]
    $knownIds = Get-KnownPrimitiveIds -SkillDefinitions $SkillDefinitions -InstructionDefinitions $InstructionDefinitions -AgentDefinitions $AgentDefinitions

    # External primitives install into roots KAT also publishes to: ~/.claude/skills for the claude
    # client, and ~/.agents/skills — KAT's codex global root — for copilot and codex, which the CLI
    # collapses into one universal directory. A shared id means two writers own one directory: the
    # vendored publish overwrites the install, and disabling the entry recursive-deletes the whole
    # folder. A skill migrating to external has to leave AI/skills in the same commit.
    $vendoredSkillIds = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($definition in @($SkillDefinitions)) {
        if ($null -eq $definition) { continue }
        [void]$vendoredSkillIds.Add([string](Get-Prop $definition 'Id'))
    }

    foreach ($definition in @($ExternalPrimitiveDefinitions)) {
        if ($null -eq $definition) { continue }
        $externalId = [string](Get-Prop $definition 'Id')
        if ($vendoredSkillIds.Contains($externalId)) {
            $errors.Add("external primitive '$externalId': a vendored skill of the same id exists in AI/skills. Both write the same global skill directory — delete one.")
        }
    }

    $auditable = @(
        @($SkillDefinitions | ForEach-Object { [pscustomobject]@{ Kind = 'skill'; Definition = $_ } })
        @($InstructionDefinitions | ForEach-Object { [pscustomobject]@{ Kind = 'instruction'; Definition = $_ } })
    )

    foreach ($entry in $auditable) {
        $definition = $entry.Definition
        if ($null -eq $definition) { continue }

        $id = [string](Get-Prop $definition 'Id')
        $meta = Get-Prop $definition 'Meta'
        $enabled = Get-Prop $definition 'Enabled'
        $repositories = @(Get-Prop $definition 'Repositories')
        $codexEnabled = Test-CodexEnabled -Enabled $enabled

        # A codex-only substitution cannot stay codex-only: Copilot reads AGENTS.md and .agents/skills.
        if ($null -ne (Get-Prop (Get-Prop $meta 'bodyReplacements') 'codex')) {
            $errors.Add("$($entry.Kind) '$id': bodyReplacements.codex is not allowed — codex output is co-read by Copilot at this path, so the substitution leaks into Copilot's context. Write the body so it needs no substitution. (Agents may still use bodyReplacements.codex; their trees are disjoint.)")
        }

        if (Test-CoScannedArtifact -Enabled $enabled -Repositories $repositories) {
            $sigils = @(Get-InvocationSigilMatches -Content (Get-Prop $definition 'Body') -KnownIds $knownIds)
            if ($sigils.Count -gt 0) {
                $scopeReason = if ($repositories.Count -gt 0) { 'repository-scoped' } else { 'codex-enabled' }
                Add-Warning "$($entry.Kind) '$id': $scopeReason output is co-scanned by Copilot, so invocation syntax must stay neutral — found $($sigils -join ', '). Name the primitive without a sigil instead."
            }
        }

        if ($codexEnabled) {
            foreach ($import in @(Get-AgentsMarkdownImports -Content (Get-Prop $definition 'Body'))) {
                if ($entry.Kind -eq 'instruction') {
                    $errors.Add("instruction '$id': '$import' is an @-import. Copilot expands these inside AGENTS.md and Codex ingests them as literal text, so the two clients would read different instructions. Inline the content instead.")
                }
            }
        }
    }

    foreach ($definition in @($SkillDefinitions)) {
        if ($null -eq $definition) { continue }
        if (-not (Test-CodexEnabled -Enabled (Get-Prop $definition 'Enabled'))) { continue }

        $id = [string](Get-Prop $definition 'Id')
        $meta = Get-Prop $definition 'Meta'
        $skillMeta = Get-Prop $meta 'skills'

        # Codex keeps name + description only. Dropping license/compatibility costs nothing at runtime,
        # so only behavioural fields warn — and VS Code Copilot resolves .agents/skills, so it loses them too.
        $droppedFields = New-Object System.Collections.Generic.List[string]
        if (-not [string]::IsNullOrWhiteSpace([string](Get-Prop $meta 'context'))) { $droppedFields.Add('context') }
        if ($null -ne (Get-Prop $meta 'allowedTools') -or $null -ne (Get-Prop $meta 'allowed-tools')) { $droppedFields.Add('allowed-tools') }
        if (-not (ConvertTo-BoolValue (Get-Prop $skillMeta 'userInvocable') $true)) { $droppedFields.Add('skills.userInvocable') }

        if ($droppedFields.Count -gt 0) {
            Add-Warning "skill '$id': codex drops $($droppedFields -join ', '), and VS Code Copilot resolves the codex copy from .agents/skills — the behaviour is silently absent there."
        }

        foreach ($subfolder in @('commands', 'agents')) {
            if (Test-Path -LiteralPath (Join-Path $definition.Directory.FullName $subfolder)) {
                Add-Warning "skill '$id': '$subfolder/' is not copied to codex output, and VS Code Copilot resolves the codex copy from .agents/skills, so Copilot loses it too."
            }
        }
    }

    if ($errors.Count -gt 0) {
        throw ("Cross-harness policy violations:`r`n  - " + ($errors -join "`r`n  - "))
    }
}

function Get-UnresolvedPlaceholderTokens {
    param([string]$Content)

    if ([string]::IsNullOrWhiteSpace($Content)) {
        return @()
    }

    return @([regex]::Matches($Content, '\{\{KAT_[A-Z0-9_.-]+\}\}', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase) | ForEach-Object {
        $_.Value
    } | Sort-Object -Unique)
}

function Resolve-SkillAgentPlaceholders {
    param(
        [string]$Content,
        [object]$SkillDefinition,
        [ValidateSet('copilot', 'claude')]
        [string]$Client
    )

    if ([string]::IsNullOrWhiteSpace($Content) -or $Client -ne 'copilot' -or $null -eq $SkillDefinition) {
        return $Content
    }

    $helperDefinitions = @($SkillDefinition.HelperAgentDefinitions)
    if ($helperDefinitions.Count -eq 0) {
        return $Content
    }

    $resolved = $Content
    foreach ($helperDefinition in $helperDefinitions) {
        $helperName = [string](Get-Prop $helperDefinition 'HelperName')
        $helperId = [string](Get-Prop $helperDefinition 'Id')
        if ([string]::IsNullOrWhiteSpace($helperName) -or [string]::IsNullOrWhiteSpace($helperId)) {
            continue
        }

        $resolved = $resolved.Replace("{{KAT_SKILL_AGENT.$helperName}}", $helperId)
    }

    return $resolved
}

function Get-ConfiguredSkillAllowedTools {
    param(
        [object]$Meta,
        [ValidateSet('copilot', 'claude')]
        [string]$Client
    )

    $allowedTools = Get-Prop $Meta 'allowedTools'
    if ($null -eq $allowedTools) {
        return @()
    }

    $clientProperty = $allowedTools.PSObject.Properties[$Client]
    if ($null -ne $clientProperty) {
        return ConvertTo-StringArray $clientProperty.Value
    }

    return ConvertTo-StringArray $allowedTools
}

function ConvertTo-StringArray {
    # Returns a comma-wrapped array so an empty result survives the return pipeline instead of
    # collapsing to $null. That wrapper makes `@(ConvertTo-StringArray $x)` WRONG at every call site:
    # @() captures the wrapper rather than flattening it, yielding a one-element array holding the
    # array — for empty, single, and multi-value input alike. Assign or pass it directly.
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

    $stream = Get-Item -LiteralPath $Path -Stream CreatedBy -ErrorAction Ignore
    if ($stream) {
        return (Get-Content -LiteralPath $Path -Stream CreatedBy -ErrorAction Ignore) -eq 'KAT'
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
        return $true
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

    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
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

    try {
        Remove-Item -LiteralPath $Path -Force -Recurse -Confirm:$false -ErrorAction Stop 2>$null
    }
    catch {
        if (-not (Test-Path -LiteralPath $Path)) {
            return $true
        }

        throw
    }

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

        $item = Get-Item -LiteralPath $scanRoot -Force -ErrorAction Ignore
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

function Remove-EmptyAncestors {
    param(
        [string]$Path,
        [string]$StopAt
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($StopAt)) {
        return
    }

    $current = $Path
    while (-not [string]::IsNullOrWhiteSpace($current) -and
        $current.StartsWith($StopAt, [StringComparison]::OrdinalIgnoreCase) -and
        $current.Length -gt $StopAt.Length) {

        $item = Get-Item -LiteralPath $current -Force -ErrorAction Ignore
        if ($null -ne $item -and $item.PSIsContainer) {
            $hasChildren = $null -ne (Get-ChildItem -LiteralPath $current -Force -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($hasChildren) {
                break
            }

            Remove-Item -LiteralPath $current -Force -Confirm:$false -ErrorAction SilentlyContinue
        }

        $next = Split-Path -Parent $current
        if ($next -eq $current) {
            break
        }

        $current = $next
    }
}

function Clear-ManagedRoot {
    param(
        [string]$Root,
        [string[]]$ScanRoots,
        [string]$RepositoryRoot,
        [string]$CollapseEmptyToRoot = $null
    )

    $pathsToRemove = @(Get-LegacyManagedPaths -ScanRoots $ScanRoots -RepositoryRoot $RepositoryRoot)

    foreach ($removedPath in $pathsToRemove) {
        if (-not $preSyncManagedPaths.Contains($removedPath)) {
            $preSyncManagedPaths.Add($removedPath)
        }
    }

    foreach ($p in ($pathsToRemove | Sort-Object Length -Descending)) {
        $item = Get-Item -LiteralPath $p -Force -ErrorAction Ignore
        if ($null -ne $item) {
            [void](Remove-KatManagedPath -Path $p -RepositoryRoot $RepositoryRoot)
        }
    }

    Remove-EmptyDirectories -ScanRoots $ScanRoots

    if (-not [string]::IsNullOrWhiteSpace($CollapseEmptyToRoot)) {
        foreach ($scanRoot in $ScanRoots) {
            Remove-EmptyAncestors -Path $scanRoot -StopAt $CollapseEmptyToRoot
        }
    }
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
        [string]$Content,
        [bool]$ForceOwnedPath = $false,
        [string]$ValidationLabel = $null
    )

    New-Directory (Split-Path -Parent $Path)
    if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
        $existingItem = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
        $isUserModified = $null -ne $existingItem -and -not $existingItem.PSIsContainer -and -not $existingItem.IsReadOnly
        if ($isUserModified -and $Overwrite) {
            try {
                Remove-Item -LiteralPath $Path -Force -Recurse -Confirm:$false -ErrorAction Stop
            }
            catch {
                Add-BlockedPath $Path
                return $false
            }
        }
        elseif ($isUserModified) {
            Add-SkippedPath $Path
            return $false
        }
        elseif ($ForceOwnedPath) {
            try {
                Remove-Item -LiteralPath $Path -Force -Recurse -Confirm:$false -ErrorAction Stop
            }
            catch {
                Add-BlockedPath $Path
                return $false
            }
        }
        else {
            Add-BlockedPath $Path
            return $false
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($ValidationLabel)) {
        $unresolvedTokens = @(Get-UnresolvedPlaceholderTokens -Content $Content)
        if ($unresolvedTokens.Count -gt 0) {
            Add-Warning "${ValidationLabel}: unresolved placeholders remain ($($unresolvedTokens -join ', '))."
            Add-BlockedPath $Path
            return $false
        }
    }

    Set-Content -LiteralPath $Path -Value $Content -NoNewline
    Write-CreatedByStream -Path $Path
    Set-ManagedReadOnly -Path $Path
    return $true
}

function Set-ManagedWritable {
    param([string]$Path)

    try {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        if ($item.IsReadOnly) {
            $item.IsReadOnly = $false
        }
    }
    catch {
        # Clearing read-only is best-effort only.
    }
}

function Get-ManagedRegionMatch {
    param([string]$Content)

    if ([string]::IsNullOrEmpty($Content)) {
        return $null
    }

    $match = [regex]::Match($Content, $script:katRegionPattern)
    if (-not $match.Success) {
        return $null
    }

    return $match
}

function Remove-ManagedRegionText {
    param([string]$Content)

    $result = if ($null -eq $Content) { '' } else { [string]$Content }
    while ($true) {
        $match = Get-ManagedRegionMatch -Content $result
        if ($null -eq $match) { break }

        $result = $result.Substring(0, $match.Index) + $result.Substring($match.Index + $match.Length)
    }

    return [regex]::Replace($result, '(\r?\n){3,}', "`r`n`r`n")
}

# Merge-aware writer for cross-vendor files (AGENTS.md) that KAT co-owns with humans.
# KAT owns only the text between <!-- kat:start --> and <!-- kat:end -->; everything else is preserved.
# Passing an empty/absent Content strips the region entirely, deleting the file when nothing else remains.
function Write-ManagedRegionFile {
    param(
        [string]$Path,
        [string]$Content = $null,
        [string]$ValidationLabel = $null
    )

    $isStrip = [string]::IsNullOrWhiteSpace($Content)
    $fileExists = Test-Path -LiteralPath $Path -PathType Leaf

    if (-not $fileExists -and (Test-Path -LiteralPath $Path)) {
        Add-BlockedPath $Path
        return $false
    }

    $existingContent = ''
    if ($fileExists) {
        $existingContent = [string](Get-Content -LiteralPath $Path -Raw -ErrorAction Ignore)
        if ($null -eq $existingContent) { $existingContent = '' }
    }

    # A file with no KAT region and nothing to add is simply not ours — never report it.
    if ($isStrip -and (-not $fileExists -or $null -eq (Get-ManagedRegionMatch -Content $existingContent))) {
        return $true
    }

    if ($fileExists -and -not (Test-KatMarker -Path $Path) -and -not $Overwrite) {
        $existingItem = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
        if ($null -ne $existingItem -and $existingItem.IsReadOnly) {
            Add-BlockedPath $Path
        }
        else {
            Add-SkippedPath $Path
        }

        return $false
    }

    if ($isStrip) {
        $stripped = Remove-ManagedRegionText -Content $existingContent
        if ([string]::IsNullOrWhiteSpace($stripped)) {
            try {
                Set-ManagedWritable -Path $Path
                Remove-Item -LiteralPath $Path -Force -Confirm:$false -ErrorAction Stop
                return $true
            }
            catch {
                Add-BlockedPath $Path
                return $false
            }
        }

        try {
            Set-ManagedWritable -Path $Path
            Set-Content -LiteralPath $Path -Value ($stripped.TrimEnd() + "`r`n") -NoNewline
        }
        catch {
            Add-BlockedPath $Path
            return $false
        }

        # KAT no longer contributes to this file, so relinquish ownership of it.
        Clear-KatMarker -Path $Path
        Set-ManagedWritable -Path $Path
        return $true
    }

    if (-not [string]::IsNullOrWhiteSpace($ValidationLabel)) {
        $unresolvedTokens = @(Get-UnresolvedPlaceholderTokens -Content $Content)
        if ($unresolvedTokens.Count -gt 0) {
            Add-Warning "${ValidationLabel}: unresolved placeholders remain ($($unresolvedTokens -join ', '))."
            Add-BlockedPath $Path
            return $false
        }
    }

    $block = $script:katRegionStart + "`r`n" + $Content.Trim() + "`r`n" + $script:katRegionEnd
    $regionMatch = Get-ManagedRegionMatch -Content $existingContent

    $updatedContent = if ($null -ne $regionMatch) {
        $existingContent.Substring(0, $regionMatch.Index) + $block + $existingContent.Substring($regionMatch.Index + $regionMatch.Length)
    }
    elseif (-not [string]::IsNullOrWhiteSpace($existingContent)) {
        $existingContent.TrimEnd() + "`r`n`r`n" + $block
    }
    else {
        $block
    }

    New-Directory (Split-Path -Parent $Path)

    try {
        if ($fileExists) {
            Set-ManagedWritable -Path $Path
        }

        Set-Content -LiteralPath $Path -Value ($updatedContent.TrimEnd() + "`r`n") -NoNewline
    }
    catch {
        Add-BlockedPath $Path
        return $false
    }

    Write-CreatedByStream -Path $Path
    Set-ManagedReadOnly -Path $Path
    return $true
}

function Copy-ManagedFile {
    param(
        [string]$Path,
        [string]$SourcePath,
        [bool]$ForceOwnedPath = $false
    )

    New-Directory (Split-Path -Parent $Path)
    if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
        $existingItem = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
        $isUserModified = $null -ne $existingItem -and -not $existingItem.PSIsContainer -and -not $existingItem.IsReadOnly
        if ($isUserModified -and $Overwrite) {
            try {
                Remove-Item -LiteralPath $Path -Force -Recurse -Confirm:$false -ErrorAction Stop
            }
            catch {
                Add-BlockedPath $Path
                return $false
            }
        }
        elseif ($isUserModified) {
            Add-SkippedPath $Path
            return $false
        }
        elseif ($ForceOwnedPath) {
            try {
                Remove-Item -LiteralPath $Path -Force -Recurse -Confirm:$false -ErrorAction Stop
            }
            catch {
                Add-BlockedPath $Path
                return $false
            }
        }
        else {
            Add-BlockedPath $Path
            return $false
        }
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

function Get-ConfiguredCanonicalTools {
    param([object]$Meta)

    $agentsMeta = Get-Prop $Meta 'agents'
    return (ConvertTo-StringArray (Get-Prop $agentsMeta 'tools'))
}


function Resolve-ModelForClient {
    param(
        [object]$Meta,
        [string]$Client
    )

    $agentsMeta = Get-Prop $Meta 'agents'
    if ($null -eq $agentsMeta) {
        return $null
    }

    $canonicalModel = [string](Get-Prop $agentsMeta 'model')
    if ([string]::IsNullOrWhiteSpace($canonicalModel)) {
        return $null
    }

    if ($Client -eq 'vscode') {
        return $canonicalModel
    }

    $mappedModels = Get-SharedModelMappings
    $mappedModel = Get-Prop (Get-Prop $mappedModels $canonicalModel) $Client
    if ([string]::IsNullOrWhiteSpace([string]$mappedModel)) {
        return $null
    }

    return [string]$mappedModel
}

function Resolve-ToolMappingForClient {
    param(
        [string]$ToolId,
        [string]$Client
    )

    $toolMappings = Get-SharedToolMappings
    if ($null -eq $toolMappings) {
        return [pscustomobject]@{
            Found = $false
            Values = @()
        }
    }

    $mapping = Get-Prop $toolMappings $ToolId
    if ($null -eq $mapping) {
        foreach ($mappingProperty in @($toolMappings.PSObject.Properties | Sort-Object { $_.Name.Length } -Descending)) {
            if ($ToolId -like $mappingProperty.Name) {
                $mapping = $mappingProperty.Value
                break
            }
        }
    }

    if ($null -eq $mapping) {
        return [pscustomobject]@{
            Found = $false
            Values = @()
        }
    }

    $clientMapping = Get-Prop $mapping $Client
    if ($null -eq $clientMapping) {
        return [pscustomobject]@{
            Found = $false
            Values = @()
        }
    }

    if ($clientMapping -is [bool]) {
        return [pscustomobject]@{
            Found = $true
            Values = @()
        }
    }

    return [pscustomobject]@{
        Found = $true
        Values = ConvertTo-StringArray $clientMapping
    }
}

function Get-ConfiguredToolsForClient {
    param(
        [object]$Meta,
        [string]$Client
    )

    $resolvedTools = New-Object System.Collections.Generic.List[string]
    $seenTools = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($toolId in (Get-ConfiguredCanonicalTools -Meta $Meta)) {
        $mapping = Resolve-ToolMappingForClient -ToolId $toolId -Client $Client
        $toolValues = if ($mapping.Found) {
            @($mapping.Values)
        }
        elseif ($Client -eq 'claude') {
            Add-Warning "$(Get-Prop $Meta 'id'): No Claude tool mapping defined for canonical tool '$toolId'."
            @()
        }
        else {
            @($toolId)
        }

        if ($Client -eq 'claude' -and $toolId -like 'io.github.upstash/context7/*') {
            if (-not (Test-ClaudeContext7Configured)) {
                Add-Warning "$(Get-Prop $Meta 'id'): Context7 has no native Claude tool equivalent. Install a matching MCP server if you want parity."
                $toolValues = @()
            }
        }

        foreach ($toolValue in (ConvertTo-StringArray $toolValues)) {
            if ([string]::IsNullOrWhiteSpace($toolValue)) {
                continue
            }

            if ($Client -eq 'claude' -and $toolValue -like 'persistent:*') {
                continue
            }

            if ($seenTools.Add($toolValue)) {
                $resolvedTools.Add($toolValue)
            }
        }
    }

    return ,($resolvedTools.ToArray())
}

function Get-ClaudeMemoryScope {
    param([object]$Meta)

    $claudeMeta = Get-Prop $Meta 'claude'
    $memoryScope = [string](Get-Prop $claudeMeta 'memory')
    if (-not [string]::IsNullOrWhiteSpace($memoryScope)) {
        return $memoryScope
    }

    foreach ($toolId in (Get-ConfiguredCanonicalTools -Meta $Meta)) {
        $mapping = Resolve-ToolMappingForClient -ToolId $toolId -Client 'claude'
        if (-not $mapping.Found) {
            continue
        }

        foreach ($toolValue in (ConvertTo-StringArray $mapping.Values)) {
            $memoryMatch = [regex]::Match([string]$toolValue, '^persistent:(?<scope>.+)$')
            if ($memoryMatch.Success) {
                return $memoryMatch.Groups['scope'].Value
            }
        }
    }

    return $null
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
        $config = Read-KatJsonDocument -Path $claudeConfigPath -DefaultFactory { [pscustomobject]@{} }
        $mcpServers = Get-Prop $config 'mcpServers'
        if ($null -ne $mcpServers) {
            $script:claudeContext7Configured = $null -ne (Get-Prop $mcpServers 'context7')
        }
    }
    catch {
        $script:claudeContext7Configured = $false
    }

    return $script:claudeContext7Configured
}

function Get-InstructionScope {
    param([object]$Meta)

    $instructionMeta = Get-Prop $Meta 'instructions'
    return (ConvertTo-StringArray (Get-Prop $instructionMeta 'scope'))
}

function Read-CanonicalMeta {
    param([string]$Path)

    return Read-KatJsonDocument -Path $Path -DefaultFactory { [pscustomobject]@{} }
}

function Resolve-ClientMarkdown {
    param(
        [string]$Content,
        # 'copilot' = shared (vscode + cli): keeps copilot, copilot-vscode, copilot-cli; removes claude
        # 'vscode'     = keeps copilot, copilot-vscode; removes copilot-cli, claude
        # 'copilotCli' = keeps copilot, copilot-cli; removes copilot-vscode, claude
        # 'claude'     = keeps claude; removes all copilot variants
        # 'codex'      = keeps codex; removes claude and all copilot variants
        [ValidateSet('copilot', 'vscode', 'copilotCli', 'claude', 'codex')]
        [string]$Client
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return $Content
    }

    $keepTags = switch ($Client) {
        'claude'     { @('claude') }
        'codex'      { @('codex') }
        'vscode'     { @('copilot', 'copilot-vscode') }
        'copilotCli' { @('copilot', 'copilot-cli') }
        'copilot'    { @('copilot', 'copilot-vscode', 'copilot-cli') }
    }

    $allTags = @('copilot', 'copilot-vscode', 'copilot-cli', 'claude', 'codex')
    $lineEnding = if ($Content -match '\r\n') { "`r`n" } else { "`n" }
    $lines = $Content -split '\r?\n'
    $result = New-Object System.Collections.Generic.List[string]
    $activeBlocks = @{}

    foreach ($line in $lines) {
        $isMarkerLine = $false

        foreach ($tag in $allTags) {
            $escapedTag = [regex]::Escape($tag)
            if ($line -match ('(?i)<!--\s*' + $escapedTag + ':start\s*-->')) {
                $activeBlocks[$tag] = if ($keepTags -contains $tag) { 'keep' } else { 'remove' }
                $isMarkerLine = $true
            }
            if ($line -match ('(?i)<!--\s*' + $escapedTag + ':end\s*-->')) {
                $activeBlocks.Remove($tag)
                $isMarkerLine = $true
            }
        }

        if (-not $isMarkerLine) {
            if (-not ($activeBlocks.Values -contains 'remove')) {
                $result.Add($line)
            }
        }
    }

    return $result -join $lineEnding
}

function Split-MarkdownFrontmatter {
    param([string]$Content)

    $text = if ($null -eq $Content) { '' } else { [string]$Content }
    $match = [regex]::Match(
        $text,
        '\A---\r?\n(?<frontmatter>.*?)\r?\n---\r?\n?(?<body>[\s\S]*)\z',
        [System.Text.RegularExpressions.RegexOptions]::Singleline)

    if (-not $match.Success) {
        return [pscustomobject]@{
            Frontmatter = @{}
            Body = $text
        }
    }

    $frontmatter = [ordered]@{}
    foreach ($line in ($match.Groups['frontmatter'].Value -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $lineMatch = [regex]::Match($line, '^(?<key>[A-Za-z0-9_-]+)\s*:\s*(?<value>.*)$')
        if (-not $lineMatch.Success) {
            continue
        }

        $value = $lineMatch.Groups['value'].Value.Trim()
        if (($value.StartsWith("'") -and $value.EndsWith("'")) -or ($value.StartsWith('"') -and $value.EndsWith('"'))) {
            $value = $value.Substring(1, $value.Length - 2)
        }

        $frontmatter[$lineMatch.Groups['key'].Value] = $value
    }

    return [pscustomobject]@{
        Frontmatter = $frontmatter
        Body = $match.Groups['body'].Value
    }
}

function Get-SkillExcludedItemNames {
    param(
        [object]$Meta,
        [ValidateSet('copilot', 'claude', 'codex')]
        [string]$Client
    )

    $skillMeta = Get-Prop $Meta 'skills'
    $excludeItems = Get-Prop $skillMeta 'excludeItems'
    return ConvertTo-StringArray (Get-Prop $excludeItems $Client)
}

function New-CopilotSkillDefinition {
    param([object]$SkillDefinition)

    $body = Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'copilot'
    $body = Resolve-BodyReplacements -Content $body -Meta $SkillDefinition.Meta -Client 'copilot'
    $body = Resolve-SkillAgentPlaceholders -Content $body -SkillDefinition $SkillDefinition -Client 'copilot'
    return [pscustomobject]@{
        Directory = $SkillDefinition.Directory
        Meta = $SkillDefinition.Meta
        Body = $body
        AllowedTools = @(Get-ConfiguredSkillAllowedTools -Meta $SkillDefinition.Meta -Client 'copilot')
        Enabled = $SkillDefinition.Enabled
        Id = $SkillDefinition.Id
        ClaudeMeta = $SkillDefinition.ClaudeMeta
        CommandFiles = $SkillDefinition.CommandFiles
        HelperAgentDefinitions = @($SkillDefinition.HelperAgentDefinitions)
        ExcludedItemNames = @('commands', 'agents')
    }
}

function New-ClaudeSkillDefinition {
    param([object]$SkillDefinition)

    $body = Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'claude'
    $body = Resolve-BodyReplacements -Content $body -Meta $SkillDefinition.Meta -Client 'claude'
    return [pscustomobject]@{
        Directory = $SkillDefinition.Directory
        Meta = $SkillDefinition.Meta
        Body = $body
        AllowedTools = @(Get-ConfiguredSkillAllowedTools -Meta $SkillDefinition.Meta -Client 'claude')
        Enabled = $SkillDefinition.Enabled
        Id = $SkillDefinition.Id
        ClaudeMeta = $SkillDefinition.ClaudeMeta
        CommandFiles = $SkillDefinition.CommandFiles
        ExcludedItemNames = @('commands')
    }
}

function New-CodexSkillDefinition {
    param([object]$SkillDefinition)

    $body = Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'codex'
    $body = Resolve-BodyReplacements -Content $body -Meta $SkillDefinition.Meta -Client 'codex'
    return [pscustomobject]@{
        Directory = $SkillDefinition.Directory
        Meta = $SkillDefinition.Meta
        Body = $body
        # Codex reads only name + description from SKILL.md frontmatter, so allowed-tools are dropped.
        AllowedTools = @()
        Enabled = $SkillDefinition.Enabled
        Id = $SkillDefinition.Id
        ClaudeMeta = $SkillDefinition.ClaudeMeta
        CommandFiles = $SkillDefinition.CommandFiles
        ExcludedItemNames = @('commands', 'agents')
    }
}

function Get-CopilotCommandSkillDefinitions {
    param([object]$SkillDefinition)

    $baseBody = Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'copilot'
    $baseBody = (Resolve-BodyReplacements -Content $baseBody -Meta $SkillDefinition.Meta -Client 'copilot').TrimEnd()
    $baseBody = Resolve-SkillAgentPlaceholders -Content $baseBody -SkillDefinition $SkillDefinition -Client 'copilot'
    $skillMeta = Get-Prop $SkillDefinition.Meta 'skills'
    $excludedCommands = ConvertTo-StringArray (Get-Prop (Get-Prop $skillMeta 'excludeCommands') 'copilot')

    foreach ($commandFile in $SkillDefinition.CommandFiles) {
        $commandName = [System.IO.Path]::GetFileNameWithoutExtension($commandFile.Name)
        if ($excludedCommands -icontains $commandName) {
            continue
        }

        $commandDisplayName = $SkillDefinition.Id + '.' + $commandName
        $commandFolderId = $commandDisplayName
        $resolvedCommandContent = Resolve-ClientMarkdown -Content (Get-Content -LiteralPath $commandFile.FullName -Raw) -Client 'copilot'
        $resolvedCommandContent = Resolve-BodyReplacements -Content $resolvedCommandContent -Meta $SkillDefinition.Meta -Client 'copilot'
        $resolvedCommandContent = Resolve-SkillAgentPlaceholders -Content $resolvedCommandContent -SkillDefinition $SkillDefinition -Client 'copilot'
        $commandDocument = Split-MarkdownFrontmatter -Content $resolvedCommandContent

        $meta = [ordered]@{
            id = $commandFolderId
            name = $commandDisplayName
            description = if (-not [string]::IsNullOrWhiteSpace([string]$commandDocument.Frontmatter['description'])) {
                [string]$commandDocument.Frontmatter['description']
            }
            else {
                $SkillDefinition.Meta.description
            }
        }

        # foreach ($field in @('license', 'compatibility', 'metadata')) {
		foreach ($field in @('license', 'compatibility')) {
            $value = Get-Prop $SkillDefinition.Meta $field
            if ($null -ne $value) {
                $meta[$field] = $value
            }
        }

        $combinedBody = @(
            $baseBody,
            '',
            '## Command Workflow',
            '',
            ($commandDocument.Body.TrimStart())
        ) -join "`r`n"

        [pscustomobject]@{
            Directory = $SkillDefinition.Directory
            Meta = [pscustomobject]$meta
            Body = $combinedBody
            Enabled = [pscustomobject]@{
                copilot = $true
                claude = $false
            }
            Id = $commandFolderId
            LegacyFolderId = $SkillDefinition.Id + '-' + $commandName
            ClaudeMeta = $null
            CommandFiles = @()
            HelperAgentDefinitions = @($SkillDefinition.HelperAgentDefinitions)
            ExcludedItemNames = @('commands', 'agents')
        }
    }
}

function Get-SkillHelperAgentDefinitions {
    param([object]$SkillDefinition)

    $agentsDir = Join-Path $SkillDefinition.Directory.FullName 'agents'
    $agentsMetaPath = Join-Path $agentsDir 'meta.jsonc'
    if (-not (Test-Path -LiteralPath $agentsMetaPath)) {
        return @()
    }

    $helpersMeta = Read-KatJsonDocument -Path $agentsMetaPath -DefaultFactory { [pscustomobject]@{} }
    $definitions = New-Object System.Collections.Generic.List[object]

    foreach ($property in @($helpersMeta.PSObject.Properties | Sort-Object Name)) {
        $helperName = [string]$property.Name
        $helperMeta = $property.Value
        if ([string]::IsNullOrWhiteSpace($helperName) -or $null -eq $helperMeta) {
            continue
        }

        $bodyPath = Join-Path $agentsDir ($helperName + '.md')
        if (-not (Test-Path -LiteralPath $bodyPath)) {
            Add-Warning "$($SkillDefinition.Id): helper agent '$helperName' is defined in agents\meta.jsonc but missing $bodyPath."
            continue
        }

        $publishedId = "$($SkillDefinition.Id)-$helperName"
        $helperAgentsMeta = Get-Prop $helperMeta 'agents'
        $effectiveAgentsMeta = [pscustomobject]@{}
        if ($null -ne $helperAgentsMeta) {
            foreach ($metaProperty in @($helperAgentsMeta.PSObject.Properties)) {
                $effectiveAgentsMeta | Add-Member -NotePropertyName $metaProperty.Name -NotePropertyValue $metaProperty.Value -Force
            }
        }
        $effectiveAgentsMeta | Add-Member -NotePropertyName 'userInvocable' -NotePropertyValue $false -Force

        $meta = [pscustomobject]@{
            id = $publishedId
            name = $publishedId
            description = [string](Get-Prop $helperMeta 'description' $publishedId)
            enabled = [pscustomobject]@{
                'copilot.vscode' = $true
                'copilot.cli' = $true
                claude = $false
            }
            agents = $effectiveAgentsMeta
        }

        $definitions.Add([pscustomobject]@{
            Directory = Get-Item -LiteralPath $agentsDir
            Meta = $meta
            Body = Get-Content -LiteralPath $bodyPath -Raw
            Enabled = Get-Prop $meta 'enabled'
            Id = $publishedId
            HelperName = $helperName
            ClaudeMeta = $null
            Repositories = @($SkillDefinition.Repositories)
        })
    }

    return @($definitions.ToArray())
}

function ConvertTo-CopilotAgentDocument {
    param(
        [object]$Meta,
        [string]$Body,
        [string]$Client
    )

    $resolvedBody = Resolve-ClientMarkdown -Content $Body -Client $Client
    $resolvedBody = Resolve-BodyReplacements -Content $resolvedBody -Meta $Meta -Client $Client
    $frontmatter = New-Object System.Collections.Generic.List[string]
    $frontmatter.Add('name: ' + (Format-YamlScalar (Get-Prop $Meta 'name')))
    $frontmatter.Add('description: ' + (Format-YamlScalar (Get-Prop $Meta 'description')))

    $model = Resolve-ModelForClient -Meta $Meta -Client $Client
    if (-not [string]::IsNullOrWhiteSpace([string]$model)) {
        $frontmatter.Add('model: ' + (Format-YamlScalar $model))
    }

    $agentsMeta = Get-Prop $Meta 'agents'
    if ($Client -eq 'vscode') {
        $subAgents = ConvertTo-StringArray (Get-Prop $agentsMeta 'subAgents')
        if ($subAgents.Count -gt 0) {
            $frontmatter.Add('agents: ' + (Format-YamlInlineArray $subAgents))
        }
    }

    $copilotTools = Get-ConfiguredToolsForClient -Meta $Meta -Client $Client
    if ($copilotTools.Count -gt 0) {
        $frontmatter.Add('tools: ' + (Format-YamlInlineArray $copilotTools))
    }

    if ($null -ne (Get-Prop $agentsMeta 'userInvocable')) {
        $frontmatter.Add('user-invocable: ' + ((ConvertTo-BoolValue (Get-Prop $agentsMeta 'userInvocable') $true).ToString().ToLower()))
    }

    if ($Client -eq 'vscode') {
        $handoffs = Get-Prop $agentsMeta 'handoffs'
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

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $resolvedBody
}

function ConvertTo-ClaudeAgentDocument {
    param(
        [object]$Meta,
        [string]$Body
    )

    $resolvedBody = Resolve-ClientMarkdown -Content $Body -Client 'claude'
    $resolvedBody = Resolve-BodyReplacements -Content $resolvedBody -Meta $Meta -Client 'claude'
    $frontmatter = New-Object System.Collections.Generic.List[string]
    $frontmatter.Add('name: ' + (Format-YamlScalar (Get-Prop $Meta 'name')))
    $frontmatter.Add('description: ' + (Format-YamlScalar (Get-Prop $Meta 'description')))

    $model = Resolve-ModelForClient -Meta $Meta -Client 'claude'
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

    $agentsMeta = Get-Prop $Meta 'agents'
    if ((ConvertTo-StringArray (Get-Prop $agentsMeta 'subAgents')).Count -gt 0 -or $null -ne (Get-Prop $agentsMeta 'handoffs')) {
        Add-Warning "$(Get-Prop $Meta 'id'): Copilot orchestration fields were omitted from Claude rendering because there is no compatible native frontmatter equivalent."
    }

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $resolvedBody
}

function ConvertTo-CopilotInstructionDocument {
    param(
        [object]$Meta,
        [string]$Body,
        [ValidateSet('vscode', 'copilotCli', 'copilot')]
        [string]$Client = 'copilot'
    )

    $resolvedBody = Resolve-ClientMarkdown -Content $Body -Client $Client
    $resolvedBody = Resolve-BodyReplacements -Content $resolvedBody -Meta $Meta -Client $Client
    $scope = @(Get-InstructionScope -Meta $Meta)
    $applyTo = if ($scope.Count -eq 0) { '**' } else { $scope -join ', ' }
    $frontmatter = @('applyTo: ' + (Format-YamlScalar $applyTo))
    return New-DocumentContent -FrontmatterLines $frontmatter -Body $resolvedBody
}

function ConvertTo-ClaudeRuleDocument {
    param(
        [object]$Meta,
        [string]$Body
    )

    $resolvedBody = Resolve-ClientMarkdown -Content $Body -Client 'claude'
    $resolvedBody = Resolve-BodyReplacements -Content $resolvedBody -Meta $Meta -Client 'claude'
    $frontmatter = New-Object System.Collections.Generic.List[string]
    $frontmatter.Add('description: ' + (Format-YamlScalar (Get-Prop $Meta 'description')))
    $frontmatter.Add('paths:')
    foreach ($pathPattern in (Get-InstructionScope -Meta $Meta)) {
        $frontmatter.Add('  - ' + (Format-YamlScalar $pathPattern))
    }

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $resolvedBody
}

function ConvertTo-SkillDocument {
    param(
        [object]$Meta,
        [string]$Body,
        [string[]]$AllowedTools = @(),
        [ValidateSet('default', 'codex')]
        [string]$Client = 'default'
    )

    # Codex documents its SKILL.md frontmatter as name + description only, and ignores anything else.
    $frontmatterFields = if ($Client -eq 'codex') {
        @('name', 'description')
    }
    else {
        @('name', 'description', 'license', 'compatibility', 'context')
    }

    $frontmatter = New-Object System.Collections.Generic.List[string]
    foreach ($field in $frontmatterFields) {
        $value = Get-Prop $Meta $field
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $frontmatter.Add($field + ': ' + (Format-YamlScalar $value))
        }
    }

    if ($Client -ne 'codex') {
        # Claude Code extensions. Emitted for the Copilot copy too so the renders stay byte-identical
        # where Copilot co-scans both trees; Codex expresses modelInvocable in agents/openai.yaml instead.
        $skillMeta = Get-Prop $Meta 'skills'
        if (-not (ConvertTo-BoolValue (Get-Prop $skillMeta 'modelInvocable') $true)) {
            $frontmatter.Add('disable-model-invocation: true')
        }
        if (-not (ConvertTo-BoolValue (Get-Prop $skillMeta 'userInvocable') $true)) {
            $frontmatter.Add('user-invocable: false')
        }
    }

    # $metadata = Get-Prop $Meta 'metadata'
    # if ($null -ne $metadata -and @($metadata.PSObject.Properties).Count -gt 0) {
    #     $frontmatter.Add('metadata:')
    #     foreach ($property in @($metadata.PSObject.Properties)) {
    #         $frontmatter.Add('  ' + $property.Name + ': ' + (Format-YamlScalar $property.Value))
    #     }
    # }

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

function Test-IsCanonicalAgentDirectory {
    param([System.IO.DirectoryInfo]$Directory)

    return (Test-Path -LiteralPath (Join-Path $Directory.FullName 'body.md')) -and
        (Test-Path -LiteralPath (Get-CanonicalMetaPath -Directory $Directory))
}

function Get-NestedAgentDirectories {
    param([System.IO.DirectoryInfo]$Directory)

    foreach ($childDirectory in (Get-ChildItem -LiteralPath $Directory.FullName -Directory | Sort-Object Name)) {
        if (Test-IsCanonicalAgentDirectory -Directory $childDirectory) {
            $childDirectory
            continue
        }

        foreach ($agentDirectory in Get-NestedAgentDirectories -Directory $childDirectory) {
            $agentDirectory
        }
    }
}

function Get-AgentDirectories {
    $agentsRootPath = Join-Path $aiRoot 'agents'
    if (-not (Test-Path -LiteralPath $agentsRootPath -PathType Container)) {
        return
    }

    $agentsRoot = Get-Item -LiteralPath $agentsRootPath
    Get-NestedAgentDirectories -Directory $agentsRoot
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
    }
}

function Get-AgentDefinitions {
    foreach ($agentDir in Get-AgentDirectories) {
        $meta = Read-CanonicalMeta -Path (Get-CanonicalMetaPath -Directory $agentDir)
        if (-not (Test-UserAllowed -Meta $meta)) { continue }

        [pscustomobject]@{
            Directory = $agentDir
            Meta = $meta
            Body = Get-Content -LiteralPath (Join-Path $agentDir.FullName 'body.md') -Raw
            Enabled = Get-Prop $meta 'enabled'
            Id = Get-Prop $meta 'id' $agentDir.Name
            ClaudeMeta = Get-Prop $meta 'claude'
            Repositories = @(Get-EnabledRepositories -Meta $meta)
        }
    }
}

function Get-InstructionDefinitions {
    foreach ($instructionDir in Get-InstructionDirectories) {
        $meta = Read-CanonicalMeta -Path (Get-CanonicalMetaPath -Directory $instructionDir)
        if (-not (Test-UserAllowed -Meta $meta)) { continue }

        [pscustomobject]@{
            Directory = $instructionDir
            Meta = $meta
            Body = Get-Content -LiteralPath (Join-Path $instructionDir.FullName 'body.md') -Raw
            Enabled = Get-Prop $meta 'enabled'
            Id = Get-Prop $meta 'id' $instructionDir.Name
            Repositories = @(Get-EnabledRepositories -Meta $meta)
        }
    }
}

function Get-SkillDefinitionsWithContent {
    foreach ($skillDir in Get-SkillDirectories) {
        $meta = Get-SkillMeta -Directory $skillDir
        if (-not (Test-UserAllowed -Meta $meta)) { continue }
        $commandsDir = Join-Path $skillDir.FullName 'commands'
        $commandFiles = @()
        if (Test-Path -LiteralPath $commandsDir) {
            $commandFiles = @(Get-ChildItem -LiteralPath $commandsDir -File -Filter '*.md' | Sort-Object Name)
        }
        $repositories = @(Get-EnabledRepositories -Meta $meta)

        $skillDefinition = [pscustomobject]@{
            Directory = $skillDir
            Meta = $meta
            Body = Get-Content -LiteralPath (Join-Path $skillDir.FullName 'SKILL.md') -Raw
            Enabled = Get-Prop $meta 'enabled'
            Id = Get-Prop $meta 'id' $skillDir.Name
            ClaudeMeta = Get-Prop $meta 'claude'
            Repositories = $repositories
            CommandFiles = $commandFiles
            HelperAgentDefinitions = @()
        }
        $skillDefinition.HelperAgentDefinitions = @(Get-SkillHelperAgentDefinitions -SkillDefinition $skillDefinition)

        $skillDefinition
    }
}

function New-ManagedDirectory {
    param(
        [string]$Path,
        [bool]$RequireManagedContent = $false
    )

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction Ignore
        if ($null -eq $item) {
            Add-BlockedPath $Path
            return $false
        }

        if ($item.PSIsContainer -and -not ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            if ($RequireManagedContent -and -not (Test-ReusableManagedDirectory -Path $Path -RepositoryRoot $repoRoot)) {
                Add-BlockedPath $Path
                return $false
            }

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
        [object]$SkillDefinition,
        [string]$Target
    )

    function Install-ManagedSkillItem {
        param(
            [System.IO.FileSystemInfo]$SourceItem,
            [string]$DestinationPath
        )

        if ($SourceItem.PSIsContainer) {
            if (-not (New-ManagedDirectory -Path $DestinationPath -RequireManagedContent $false)) {
                return $false
            }

            $allChildItemsSucceeded = $true
            Get-ChildItem -LiteralPath $SourceItem.FullName -Force | ForEach-Object {
                $childPath = Join-Path $DestinationPath $_.Name
                $childSucceeded = Install-ManagedSkillItem -SourceItem $_ -DestinationPath $childPath
                $allChildItemsSucceeded = $allChildItemsSucceeded -and $childSucceeded
            }

            return $allChildItemsSucceeded
        }

        return (Copy-ManagedFile -Path $DestinationPath -SourcePath $SourceItem.FullName)
    }

    $id = $SkillDefinition.Id
    $targetDirectory = Join-Path (Join-Path $Root 'skills') $id

    if (-not (New-ManagedDirectory -Path $targetDirectory -RequireManagedContent $false)) {
        return $false
    }

    $renderedSkill = ConvertTo-SkillDocument -Meta $SkillDefinition.Meta -Body $SkillDefinition.Body -AllowedTools (ConvertTo-StringArray (Get-Prop $SkillDefinition 'AllowedTools')) -Client $(if ($Target -eq 'codex') { 'codex' } else { 'default' })
    $allSucceeded = Write-ManagedFile -Path (Join-Path $targetDirectory 'SKILL.md') -Content $renderedSkill -ValidationLabel "Skill '$id'"

    $excludedItemNames = @('SKILL.md', 'meta.json', 'meta.jsonc', 'meta.vscode.settings.jsonc')
    if ($Target -in @('copilot', 'codex')) {
        $excludedItemNames += 'commands'
    }

    if ($Target -in @('copilot', 'claude', 'codex')) {
        foreach ($excludedItemName in (Get-SkillExcludedItemNames -Meta $SkillDefinition.Meta -Client $Target)) {
            $excludedItemNames += $excludedItemName
        }
    }

    $additionalExcludedItemNames = @()
    $excludedItemNamesProperty = $SkillDefinition.PSObject.Properties['ExcludedItemNames']
    if ($null -ne $excludedItemNamesProperty) {
        $additionalExcludedItemNames = ConvertTo-StringArray $excludedItemNamesProperty.Value
    }

    if ($additionalExcludedItemNames.Count -gt 0) {
        foreach ($excludedItemName in $additionalExcludedItemNames) {
            $excludedItemNames += $excludedItemName
        }
    }

    $excludedItemNames = @($excludedItemNames | Select-Object -Unique)

    # Codex has no frontmatter equivalent for disable-model-invocation; agents/openai.yaml is the only
    # place to say it. The folder is otherwise excluded from codex output, so it is written last and
    # kept out of the exclusion sweep below.
    $codexPolicyFile = $null
    if ($Target -eq 'codex' -and -not (ConvertTo-BoolValue (Get-Prop (Get-Prop $SkillDefinition.Meta 'skills') 'modelInvocable') $true)) {
        $codexPolicyFile = Join-Path (Join-Path $targetDirectory 'agents') 'openai.yaml'
    }

    foreach ($excludedItemName in ($excludedItemNames | Where-Object { $_ -notin @('SKILL.md', 'meta.json', 'meta.jsonc') -and -not ($null -ne $codexPolicyFile -and $_ -eq 'agents') })) {
        $excludedPath = Join-Path $targetDirectory $excludedItemName
        if (Test-Path -LiteralPath $excludedPath) {
            if (-not (Remove-KatManagedPath -Path $excludedPath -RepositoryRoot $repoRoot)) {
                Add-BlockedPath $excludedPath
                $allSucceeded = $false
            }
        }
    }

    Get-ChildItem -LiteralPath $SkillDefinition.Directory.FullName -Force | Where-Object {
        $_.Name -notin $excludedItemNames
    } | ForEach-Object {
        $targetPath = Join-Path $targetDirectory $_.Name
        $copySucceeded = Install-ManagedSkillItem -SourceItem $_ -DestinationPath $targetPath
        $allSucceeded = $allSucceeded -and $copySucceeded
    }

    if ($null -ne $codexPolicyFile) {
        if (New-ManagedDirectory -Path (Split-Path -Parent $codexPolicyFile) -RequireManagedContent $false) {
            $policyContent = @(
                'policy:',
                '  allow_implicit_invocation: false'
            ) -join "`r`n"
            $allSucceeded = (Write-ManagedFile -Path $codexPolicyFile -Content $policyContent -ValidationLabel "Skill '$id' codex policy") -and $allSucceeded
        }
        else {
            $allSucceeded = $false
        }
    }

    return $allSucceeded
}

Invoke-PolicySync
$global:LASTEXITCODE = 0
