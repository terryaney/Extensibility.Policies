Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$aiRoot = Join-Path $repoRoot 'AI'
$sharedMappingsPath = Join-Path $PSScriptRoot 'meta.mappings.jsonc'
$sharedModulePath = Join-Path $PSScriptRoot 'Kat.Policy.Mcp.psm1'

Import-Module $sharedModulePath -Force

$compatibilityMessages = New-Object System.Collections.Generic.List[string]
$blockedPaths = New-Object System.Collections.Generic.List[string]
$deploymentRecords = New-Object System.Collections.Generic.List[object]
$preSyncManagedPaths = New-Object System.Collections.Generic.List[string]
$script:claudeContext7Configured = $null
$script:sharedMetaMappings = $null

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

function Get-SharedMetaMappings {
    if ($null -eq $script:sharedMetaMappings) {
        $script:sharedMetaMappings = Read-CanonicalMeta -Path $sharedMappingsPath
    }

    return $script:sharedMetaMappings
}

function Get-SharedModelMappings {
    return Get-Prop (Get-SharedMetaMappings) 'models'
}

function Get-SharedToolMappings {
    return Get-Prop (Get-SharedMetaMappings) 'tools'
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
                    (Join-Path $repositoryRoot '.claude\skills')))
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
    $editorConfigPath = 'C:\BTR\.editorconfig'
    $editorConfigSucceeded = Copy-ManagedFile -Path $editorConfigPath -SourcePath (Join-Path $repoRoot '.editorconfig') -ForceOwnedPath $true
    Add-DeploymentRecord -Category 'link' -Id '.editorconfig' -Target 'btr' -Status $(if ($editorConfigSucceeded) { 'ok' } else { 'blocked' }) -Path $editorConfigPath
}

function Publish-TerminalFiles {
    param([object]$Roots)

    if ($Roots.TerminalRoot) {
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Terminal') -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring((Join-Path $repoRoot 'Terminal').Length).TrimStart('\')
            $targetPath = Join-Path $Roots.TerminalRoot $relativePath
            # Terminal does not reliably hot-reload symlink targets, so always manage as copied files.
            $targetSucceeded = Copy-ManagedFile -Path $targetPath -SourcePath $_.FullName -ForceOwnedPath $true
            Add-DeploymentRecord -Category 'link' -Id ('Terminal/' + ($relativePath -replace '\\', '/')) -Target 'terminal' -Status $(if ($targetSucceeded) { 'ok' } else { 'blocked' }) -Path $targetPath
        }

        return
    }

    Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Terminal') -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        $relativePath = $_.FullName.Substring((Join-Path $repoRoot 'Terminal').Length).TrimStart('\')
        Add-DeploymentRecord -Category 'link' -Id ('Terminal/' + ($relativePath -replace '\\', '/')) -Target 'terminal' -Status 'skipped' -Path $null -Detail 'windows-terminal-not-found'
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

            if ($agentRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.VscodeRoot 'prompts') ($id + '.agent.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content
            }
            else {
                foreach ($agentRepositoryRoot in $agentRepositories) {
                    if (-not (Test-Path -LiteralPath $agentRepositoryRoot -PathType Container)) {
                        $succeeded = $false
                        $repoMissing = $true
                        continue
                    }

                    $path = Join-Path (Join-Path $agentRepositoryRoot '.github\agents') ($id + '.agent.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true) -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($agentRepositories.Count -gt 0) { $agentRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { 'scoped repository does not exist' } elseif ($agentRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $(if ($succeeded) { $agentMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status 'disabled' -MatrixValue 'excluded'
        }

        if (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'cli') {
            if ($agentRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.CopilotRoot 'agents') ($id + '.agent.md')
                $content = ConvertTo-CopilotAgentDocument -Meta $definition.Meta -Body $definition.Body -Client 'copilotCli'
                $succeeded = Write-ManagedFile -Path $path -Content $content
                Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path -MatrixValue $(if ($succeeded) { 'global' } else { $null })
            }
            else {
                # Repo-scoped: copilotCli reads .github/agents/ — covered by the vscode deployment above
                Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status $(if ($repoMissing) { 'blocked' } else { 'ok' }) -MatrixValue $(if ($repoMissing) { $null } else { 'repository' }) -Detail $(if ($repoMissing) { 'scoped repository does not exist' } else { $null })
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

            if ($agentRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.ClaudeRoot 'agents') ($id + '.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content
            }
            else {
                foreach ($agentRepositoryRoot in $agentRepositories) {
                    if (-not (Test-Path -LiteralPath $agentRepositoryRoot -PathType Container)) {
                        $succeeded = $false
                        $repoMissing = $true
                        continue
                    }

                    $path = Join-Path (Join-Path (Join-Path $agentRepositoryRoot '.claude') 'agents') ($id + '.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true) -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($agentRepositories.Count -gt 0) { $agentRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { 'scoped repository does not exist' } elseif ($agentRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $(if ($succeeded) { $agentMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status 'disabled' -MatrixValue 'excluded'
        }
    }
}

function Publish-Instructions {
    param(
        [object]$Roots,
        [object[]]$Definitions
    )

    $claudeInstructionTargets = New-Object System.Collections.Generic.List[object]

    foreach ($definition in $Definitions) {
        $enabled = $definition.Enabled
        $id = $definition.Id
        $instructionRepositories = @($definition.Repositories)
        $instructionScope = @(Get-InstructionScope -Meta $definition.Meta)
        $isClaudeGlobalInstruction = $instructionScope.Count -eq 0
        $instructionMatrixValue = if ($instructionRepositories.Count -gt 0) { 'repository' } else { 'global' }
        $instructionScopedValue = if ($instructionScope.Count -gt 0) { 'yes' } else { 'no' }
        $repoMissing = $false

        if (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'vscode') {
            $content = ConvertTo-CopilotInstructionDocument -Meta $definition.Meta -Body $definition.Body -Client 'vscode'
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true
            $repoMissing = $false

            if ($instructionRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.VscodeRoot 'instructions') ($id + '.instructions.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content
            }
            else {
                foreach ($instructionRepositoryRoot in $instructionRepositories) {
                    if (-not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                        $succeeded = $false
                        $repoMissing = $true
                        continue
                    }

                    $path = Join-Path (Join-Path $instructionRepositoryRoot '.github\instructions') ($id + '.instructions.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true) -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($instructionRepositories.Count -gt 0) { $instructionRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { 'scoped repository does not exist' } elseif ($instructionRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $instructionMatrixValue -MatrixScoped $instructionScopedValue
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
        }

        if (Test-CopilotSubClientEnabled -Enabled $enabled -SubClient 'cli') {
            if ($instructionRepositories.Count -gt 0) {
                # Repo-scoped: copilotCli reads .github/instructions/ — covered by the vscode deployment above
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status $(if ($repoMissing) { 'blocked' } else { 'ok' }) -MatrixValue $(if ($repoMissing) { $null } else { 'repository' }) -Detail $(if ($repoMissing) { 'scoped repository does not exist' } else { $null }) -MatrixScoped $instructionScopedValue
            }
            else {
                $path = Join-Path (Join-Path $Roots.CopilotRoot 'instructions') ($id + '.instructions.md')
                $content = ConvertTo-CopilotInstructionDocument -Meta $definition.Meta -Body $definition.Body -Client 'copilotCli'
                $succeeded = Write-ManagedFile -Path $path -Content $content
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

            if ($instructionRepositories.Count -eq 0) {
                if ($isClaudeGlobalInstruction) {
                    $path = Join-Path (Join-Path $Roots.ClaudeRoot 'instructions') ($id + '.md')
                    $publishTargets.Add($path)
                    $claudeBody = Resolve-ClientMarkdown -Content $definition.Body -Client 'claude'
                    $claudeBody = Resolve-BodyReplacements -Content $claudeBody -Meta $definition.Meta -Client 'claude'
                    $succeeded = Write-ManagedFile -Path $path -Content $claudeBody
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
                    $succeeded = Write-ManagedFile -Path $path -Content $content
                }
            }
            else {
                foreach ($instructionRepositoryRoot in $instructionRepositories) {
                    if (-not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                        $succeeded = $false
                        $repoMissing = $true
                        continue
                    }

                    if ($isClaudeGlobalInstruction) {
                        $path = Join-Path (Join-Path $instructionRepositoryRoot '.claude\instructions') ($id + '.md')
                        $publishTargets.Add($path)
                        $claudeBody = Resolve-ClientMarkdown -Content $definition.Body -Client 'claude'
                        $claudeBody = Resolve-BodyReplacements -Content $claudeBody -Meta $definition.Meta -Client 'claude'
                        $targetSucceeded = Write-ManagedFile -Path $path -Content $claudeBody -ForceOwnedPath $true
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
                        $targetSucceeded = Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true
                    }

                    $succeeded = $targetSucceeded -and $succeeded
                }
            }

            $targetName = if ($isClaudeGlobalInstruction) { 'claudeGlobalInstruction' } else { 'claudePathInstruction' }
            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($instructionRepositories.Count -gt 0) { $instructionRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target $targetName -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($repoMissing) { 'scoped repository does not exist' } elseif ($instructionRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $instructionMatrixValue -MatrixScoped $instructionScopedValue
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target $(if ($isClaudeGlobalInstruction) { 'claudePathInstruction' } else { 'claudeGlobalInstruction' }) -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeGlobalInstruction' -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudePathInstruction' -Status 'disabled' -MatrixValue 'excluded' -MatrixScoped $instructionScopedValue
        }
    }

    return [pscustomobject]@{
        ClaudeInstructionTargets = @($claudeInstructionTargets.ToArray())
    }
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

            $copilotRoots = if ($skillRepositories.Count -eq 0) {
                @($Roots.CopilotRoot)
            }
            else {
                @($skillRepositories | ForEach-Object { Join-Path $_ '.github' })
            }

            foreach ($copilotRoot in $copilotRoots) {
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
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($skillRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $(if ($succeeded) { $skillMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status 'disabled' -MatrixValue 'excluded'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $claudeDefinition = New-ClaudeSkillDefinition -SkillDefinition $definition
            $commandsSucceeded = $true
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $skillSucceeded = $true

            $claudeRoots = if ($skillRepositories.Count -eq 0) {
                @($Roots.ClaudeRoot)
            }
            else {
                @($skillRepositories | ForEach-Object { Join-Path $_ '.claude' })
            }

            foreach ($claudeRoot in $claudeRoots) {
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
                            $commandSucceeded = Write-ManagedFile -Path $commandPath -Content $commandContent
                        }

                        $commandsSucceeded = $commandsSucceeded -and $commandSucceeded
                        Add-DeploymentRecord -Category 'skill' -Id $commandArtifactId -Target 'claude' -Status $(if ($commandSucceeded) { 'ok' } else { 'blocked' }) -Path $commandPath -Detail $(if ($targetSkillSucceeded) { $null } else { 'skill-publish-failed' }) -MatrixValue $(if ($commandSucceeded) { $skillMatrixValue } else { $null })
                    }
                }
            }

            if ($definition.CommandFiles.Count -gt 0 -and -not $commandsSucceeded) {
                Add-Warning "${id}: One or more Claude commands were not published. See the deployment matrix for details."
            }

            $claudeSucceeded = $skillSucceeded -and $commandsSucceeded
            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status $(if ($claudeSucceeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($claudeSucceeded) { $(if ($skillRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) } elseif (-not $skillSucceeded) { 'skill-publish-failed' } else { 'command-publish-failed' }) -MatrixValue $(if ($claudeSucceeded) { $skillMatrixValue } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status 'disabled' -MatrixValue 'excluded'
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
        $claudeDocumentSucceeded = Write-ManagedFile -Path $claudeDocumentPath -Content ($claudeDocument -join "`r`n") -ForceOwnedPath $repoTargetedClaudeDocument
        Add-DeploymentRecord -Category 'link' -Id 'CLAUDE.md' -Target 'claudeDoc' -Status $(if ($claudeDocumentSucceeded) { 'ok' } else { 'blocked' }) -Path $claudeDocumentPath -Detail ("imports=" + $instructionIds.Count)
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

    # Agents folder
    if ($dirName -eq 'agents' -or $parentDir -eq 'agents') {
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
        [string]$Detail
    )

    $superscripts = @('¹','²','³','⁴','⁵','⁶','⁷','⁸','⁹')
    $existing = $Footnotes.IndexOf($Detail)
    if ($existing -ge 0) {
        $num = $existing + 1
    }
    else {
        [void]$Footnotes.Add($Detail)
        $num = $Footnotes.Count
    }

    return ($num -le $superscripts.Count) ? $superscripts[$num - 1] : "[$num]"
}

function Get-CellDisplayValue {
    param(
        [object]$Record,
        [System.Collections.Generic.List[string]]$Footnotes
    )

    if ($null -eq $Record) {
        return 'excluded'
    }

    switch ($Record.Status) {
        'removed'  { return 'removed' }
        'disabled' { return 'excluded' }
        'blocked'  {
            if (-not [string]::IsNullOrWhiteSpace([string]$Record.Detail)) {
                $marker = Get-FootnoteMarker -Footnotes $Footnotes -Detail ([string]$Record.Detail)
                return "blocked$marker"
            }
            return 'blocked'
        }
        'skipped'  {
            $detail = if (-not [string]::IsNullOrWhiteSpace([string]$Record.Detail)) { [string]$Record.Detail } else { 'skipped' }
            $marker = Get-FootnoteMarker -Footnotes $Footnotes -Detail $detail
            return "blocked$marker"
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

    if ($Path.StartsWith($env:USERPROFILE, [StringComparison]::OrdinalIgnoreCase)) {
        return ([char]0xf7db) + $Path.Substring($env:USERPROFILE.Length)
    }

    return $Path
}

function Write-SyncReport {
    # Write-Host 'KAT policies synchronized.' -ForegroundColor Green
    Write-Host ''

    # Global artifact column width across all categories.
    # +1 for the ¹ repo marker that may be appended, +2 for cell padding.
    $globalMaxNameLen = @(
        @('agent', 'instruction', 'skill') | ForEach-Object {
            $cat = $_
            @($deploymentRecords | Where-Object Category -eq $cat | Group-Object Id) | ForEach-Object { $_.Name.Length }
        }
    ) | Measure-Object -Maximum | Select-Object -ExpandProperty Maximum
    if ($null -eq $globalMaxNameLen) { $globalMaxNameLen = 0 }
    $globalArtifactWidth = [Math]::Max('artifact'.Length, $globalMaxNameLen + 3)

    Write-DeploymentMatrix -ArtifactWidth $globalArtifactWidth
    Write-CompatibilitySummary -ArtifactWidth $globalArtifactWidth
    Write-ArtifactLocationsTable
    Write-SymbolicLinksTable

    if ($blockedPaths.Count -gt 0) {
        Write-Host '--- Manual Cleanup Required ---' -ForegroundColor Red
        Write-Host '- Delete these paths to finalize KAT Policies synchronization:' -ForegroundColor Red
        $blockedPaths | Sort-Object -Unique | ForEach-Object {
            Write-Host "   - $_" -ForegroundColor Red
        }
    }
}

function Test-Context7ParityRequested {
    param([object[]]$AgentDefinitions)

    foreach ($definition in $AgentDefinitions) {
        foreach ($toolId in (Get-ConfiguredCanonicalTools -Meta $definition.Meta)) {
            if ($toolId -like 'io.github.upstash/context7/*') {
                return $true
            }
        }
    }

    return $false
}

function Test-GitHubParityRequested {
    param([object[]]$AgentDefinitions)

    foreach ($definition in $AgentDefinitions) {
        foreach ($toolId in (Get-ConfiguredCanonicalTools -Meta $definition.Meta)) {
            if ($toolId -like 'github/*') {
                return $true
            }
        }
    }

    return $false
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

        Add-Warning "$ProductName MCP setup: skipped $client because no client installation was detected."
    }
}

function Invoke-McpRemoteBootstrap {
    param(
        [Parameter(Mandatory)][string]$ProductName,
        [Parameter(Mandatory)][string]$HelperScript,
        [Parameter(Mandatory)][string]$InstallPrompt
    )

    $helperScriptPath = Join-Path $PSScriptRoot $HelperScript
    if (-not (Test-Path -LiteralPath $helperScriptPath)) {
        throw "$ProductName bootstrap helper script is missing: $helperScriptPath"
    }

    Write-Host ''
    Write-Host "Checking $ProductName MCP Server compliance..." -ForegroundColor Cyan
    $checkResult = & $helperScriptPath -CheckOnly -PassThru

    $isCompliant    = [bool](Get-Prop $checkResult 'IsCompliant' $false)
    $hasBlocked     = [bool](Get-Prop $checkResult 'HasBlocked' $false)
    $requiresInstall = [bool](Get-Prop $checkResult 'RequiresInstall' $false)

    Write-BootstrapNoClientWarnings -ProductName $ProductName -CheckResult $checkResult

    if ($isCompliant) {
        Write-Host "$ProductName MCP Server is already compliant." -ForegroundColor Green
        return
    }

    if ($hasBlocked) {
        Write-Host "$ProductName MCP Server compliance check reported blocked entries. Install may still require manual intervention." -ForegroundColor Yellow
    }

    $shouldInstall = $true
    $isInteractiveHost = [Environment]::UserInteractive -and $Host.Name -ne 'ServerRemoteHost'
    if ($isInteractiveHost) {
        Write-Host ''
        $choice = Read-Host $InstallPrompt
        if ($choice -match '^(n|no)$') {
            $shouldInstall = $false
        }
    }

    if (-not $shouldInstall) {
        Add-Warning "$ProductName MCP Server requested by KAT Policies, but installation was skipped by the user."
        Write-Host "Skipped $ProductName MCP Server installation at user request." -ForegroundColor Yellow
        return
    }

    if ($requiresInstall -or $hasBlocked) {
        Write-Host "Running $ProductName MCP Server installation..." -ForegroundColor Cyan
    }

    $applyResult = & $helperScriptPath -PassThru
    $applyBlocked = [bool](Get-Prop $applyResult 'HasBlocked' $false)
    if ($applyBlocked) {
        throw "$ProductName MCP Server installation did not complete successfully. Review the summary above."
    }
}

function Invoke-PolicySync {
    $roots = Get-EnvironmentRoots
    $agentDefinitions = Get-AgentDefinitions
    $instructionDefinitions = Get-InstructionDefinitions
    $skillDefinitions = Get-SkillDefinitionsWithContent
    $context7ParityRequested = Test-Context7ParityRequested -AgentDefinitions $agentDefinitions
    $githubParityRequested = Test-GitHubParityRequested -AgentDefinitions $agentDefinitions

    $managedContexts = Get-ManagedContexts -Roots $roots -AgentDefinitions $agentDefinitions -InstructionDefinitions $instructionDefinitions -SkillDefinitions $skillDefinitions
    foreach ($context in $managedContexts) {
        $collapseEmptyToRoot = $null
        if ($context -is [System.Collections.IDictionary] -and $context.Contains('CollapseEmptyToRoot')) {
            $collapseEmptyToRoot = $context['CollapseEmptyToRoot']
        }

        Clear-ManagedRoot -Root $context.Root -ScanRoots $context.ScanRoots -RepositoryRoot $repoRoot -CollapseEmptyToRoot $collapseEmptyToRoot
    }

    Publish-EditorConfig
    Publish-TerminalFiles -Roots $roots
    Publish-Agents -Roots $roots -Definitions $agentDefinitions
    $instructionPublishResult = Publish-Instructions -Roots $roots -Definitions $instructionDefinitions
    Publish-Skills -Roots $roots -Definitions $skillDefinitions
    Publish-ClaudeDocument -Roots $roots -InstructionPublishResult $instructionPublishResult -Definitions $instructionDefinitions
    try {
        if ($context7ParityRequested) {
            Invoke-McpRemoteBootstrap -ProductName 'Context7' -HelperScript 'install-context7-remote.ps1' -InstallPrompt 'Context7 MCP Server is not compliant. It must be installed for each client in Remote mode. Install now? [Y/n]'
        }

        if ($githubParityRequested) {
            Invoke-McpRemoteBootstrap -ProductName 'GitHub' -HelperScript 'install-github-remote.ps1' -InstallPrompt 'GitHub MCP Server is not compliant. Install/enforce GitHub MCP remote setup now? [Y/n]'
        }
    }
    finally {
        Register-RemovedRecords
        Write-SyncReport
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
        [System.Collections.Generic.List[string]]$Footnotes = $null
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
            Write-Host "  $marker $($Footnotes[$fi])" -ForegroundColor DarkCyan
        }
    }

    Write-Host ''
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

    $displayTargets  = @('vscode', 'copilotCli', 'claude')
    $displayHeaders  = @('artifact', 'vscode', 'cli', 'claude')
    $statusColWidth  = 12

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

		if (-not $hasArtifacts) {
			Write-Host ''
	        $hasArtifacts = $true
		}

        $groups          = $records | Group-Object Id | Sort-Object Name
        $artifactWidth   = $ArtifactWidth
        $fixedWidths     = @($artifactWidth, $statusColWidth, $statusColWidth, $statusColWidth)
        $alignments      = @('left', 'status', 'status', 'status')
        $headerAligns    = @('left', 'center', 'center', 'center')
        $tableFootnotes  = [System.Collections.Generic.List[string]]::new()
        if (@($records | Where-Object { [string]$_.MatrixValue -eq 'repository' }).Count -gt 0) {
            [void]$tableFootnotes.Add('repository-scoped: see Artifact Locations table for deployment paths')
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
                $cells += (Get-CellDisplayValue -Record $record -Footnotes $tableFootnotes)
            }

            $rowIsRepoScoped = @($cells | Select-Object -Skip 1 | Where-Object { [string]$_ -eq 'repository' }).Count -gt 0
            if ($rowIsRepoScoped) {
                $cells = @(([string]$cells[0] + '¹')) + @($cells[1..($cells.Count - 1)])
            }

            $cellColors = @($null) # artifact column — no special color
            for ($ci = 1; $ci -lt $cells.Count; $ci++) {
                $v = [string]$cells[$ci]
                $cellColors += if ($v -like 'blocked*') { 'Red' } elseif ($v -in @('excluded', 'removed')) { 'DarkYellow' } else { $null }
            }

            [pscustomobject]@{ Cells = $cells; CellColors = $cellColors }
        }

        Write-AsciiTable -Title $categoryLabels[$category] -Headers $displayHeaders -Rows $rows -Color 'Cyan' -FixedWidths $fixedWidths -Alignments $alignments -HeaderAlignments $headerAligns -Footnotes $tableFootnotes
    }
	
	if (-not $hasArtifacts) {
		Write-Host '--- No artifacts were deployed ---' -ForegroundColor DarkYellow
	}
}

function Write-ArtifactLocationsTable {
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
    }
    $categoryOrder = @('agent', 'instruction', 'skill')
    $targetOrders = @{
        agent       = @('vscode', 'copilotCli', 'claude')
        instruction = @('vscode', 'copilotCli', 'claudeGlobalInstruction', 'claudePathInstruction')
        skill       = @('copilot', 'claude')
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

    if ($rows.Count -eq 0) { return }

    $artifactOrder = @{ Agent = 0; Instruction = 1; Skill = 2 }
    $typeOrder     = @{ VSCode = 0; CLI = 1; Claude = 2; Scoped = 3; Copilot = 4 }

    $sortedRows = $rows | Sort-Object {
        $aRank = if ($artifactOrder.ContainsKey($_.Cells[0])) { $artifactOrder[$_.Cells[0]] } else { 99 }
        $tRank = if ($typeOrder.ContainsKey($_.Cells[1])) { $typeOrder[$_.Cells[1]] } else { 99 }
        '{0:D2}|{1:D2}|{2}' -f $aRank, $tRank, $_.Cells[2]
    }

    Write-AsciiTable -Title 'Artifact Locations' -Headers @('artifact type', 'client', 'location') -Rows $sortedRows -Color 'Cyan' -Alignments @('left', 'center', 'left') -HeaderAlignments @('left', 'center', 'left')
}

function Write-SymbolicLinksTable {
    $linkRecords = @($deploymentRecords | Where-Object Category -eq 'link')
    if ($linkRecords.Count -eq 0) { return }

    $tableFootnotes = [System.Collections.Generic.List[string]]::new()

    $rows = foreach ($record in ($linkRecords | Sort-Object Id)) {
        $displayPath = Format-ManagedPath -Path ([string]$record.Path)
        $statusValue = Get-CellDisplayValue -Record $record -Footnotes $tableFootnotes
        if ($statusValue -eq 'global') { $statusValue = 'created' }

        $isRemovedOnly   = $record.Status -eq 'removed'
        $rowColor        = if ($isRemovedOnly) { 'DarkYellow' } else { $null }
        $statusCellColor = if ($statusValue -like 'blocked*') { 'Red' } elseif ($statusValue -in @('excluded', 'removed')) { 'DarkYellow' } else { $null }

        [pscustomobject]@{ Cells = @($displayPath, $statusValue); Color = $rowColor; CellColors = @($null, $statusCellColor) }
    }

    Write-AsciiTable -Title '--- Symbolic Links Summary ---' -Headers @('location', 'status') -Rows $rows -Color 'Green' -Alignments @('left', 'status') -HeaderAlignments @('left', 'center') -Footnotes $tableFootnotes
}

function Write-CompatibilitySummary {
	param([int]$ArtifactWidth)

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

    $summaryRows = foreach ($label in $rollups.Keys) {
        $items = @($rollups[$label])
        if ($items.Count -eq 0) {
            continue
        }

        [pscustomobject]@{
            Cells = @(($items -join "`n"), "$label ($($items.Count))")
        }
    }

    if ($otherMessages.Count -gt 0) {
        $summaryRows += [pscustomobject]@{
            Cells = @(($otherMessages | Sort-Object -Unique) -join "`n", "Other ($($otherMessages.Count))")
        }
    }

    if (@($summaryRows).Count -gt 0) {
		Write-Host '--- Compatibility Summary ---' -ForegroundColor Yellow
        Write-AsciiTable -Title '' -Headers @('artifact', 'category') -Rows $summaryRows -Color 'Yellow' -RowDividers $true -FixedWidths @($ArtifactWidth, 0)
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

function Resolve-BodyReplacements {
    param(
        [string]$Content,
        [object]$Meta,
        [ValidateSet('copilot', 'vscode', 'copilotCli', 'claude')]
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

        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue
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
        $item = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            Remove-Item -LiteralPath $p -Force -Recurse -Confirm:$false -ErrorAction SilentlyContinue
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
        [bool]$ForceOwnedPath = $false
    )

    New-Directory (Split-Path -Parent $Path)
    if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
        if ($ForceOwnedPath) {
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

    Set-Content -LiteralPath $Path -Value $Content -NoNewline
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
        if ($ForceOwnedPath) {
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
        Values = @(ConvertTo-StringArray $clientMapping)
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
        [ValidateSet('copilot', 'vscode', 'copilotCli', 'claude')]
        [string]$Client
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return $Content
    }

    $keepTags = switch ($Client) {
        'claude'     { @('claude') }
        'vscode'     { @('copilot', 'copilot-vscode') }
        'copilotCli' { @('copilot', 'copilot-cli') }
        'copilot'    { @('copilot', 'copilot-vscode', 'copilot-cli') }
    }

    $allTags = @('copilot', 'copilot-vscode', 'copilot-cli', 'claude')
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

function New-CopilotSkillDefinition {
    param([object]$SkillDefinition)

    $body = Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'copilot'
    $body = Resolve-BodyReplacements -Content $body -Meta $SkillDefinition.Meta -Client 'copilot'
    return [pscustomobject]@{
        Directory = $SkillDefinition.Directory
        Meta = $SkillDefinition.Meta
        Body = $body
        Enabled = $SkillDefinition.Enabled
        Id = $SkillDefinition.Id
        ClaudeMeta = $SkillDefinition.ClaudeMeta
        CommandFiles = $SkillDefinition.CommandFiles
        ExcludedItemNames = @('commands')
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
        Enabled = $SkillDefinition.Enabled
        Id = $SkillDefinition.Id
        ClaudeMeta = $SkillDefinition.ClaudeMeta
        CommandFiles = $SkillDefinition.CommandFiles
        ExcludedItemNames = @('commands')
    }
}

function Get-CopilotCommandSkillDefinitions {
    param([object]$SkillDefinition)

    $baseBody = Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'copilot'
    $baseBody = (Resolve-BodyReplacements -Content $baseBody -Meta $SkillDefinition.Meta -Client 'copilot').TrimEnd()
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
            ExcludedItemNames = @('commands')
        }
    }
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
        [string]$Body
    )

    $frontmatter = New-Object System.Collections.Generic.List[string]
    foreach ($field in @('name', 'description', 'license', 'compatibility', 'context')) {
        $value = Get-Prop $Meta $field
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) {
            $frontmatter.Add($field + ': ' + (Format-YamlScalar $value))
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
        $commandsDir = Join-Path $skillDir.FullName 'commands'
        $commandFiles = @()
        if (Test-Path -LiteralPath $commandsDir) {
            $commandFiles = @(Get-ChildItem -LiteralPath $commandsDir -File -Filter '*.md' | Sort-Object Name)
        }

        [pscustomobject]@{
            Directory = $skillDir
            Meta = $meta
            Body = Get-Content -LiteralPath (Join-Path $skillDir.FullName 'SKILL.md') -Raw
            Enabled = Get-Prop $meta 'enabled'
            Id = Get-Prop $meta 'id' $skillDir.Name
            ClaudeMeta = Get-Prop $meta 'claude'
            Repositories = @(Get-EnabledRepositories -Meta $meta)
            CommandFiles = $commandFiles
        }
    }
}

function New-ManagedDirectory {
    param(
        [string]$Path,
        [bool]$RequireManagedContent = $false
    )

    if (Test-Path -LiteralPath $Path) {
        $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
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

    $renderedSkill = ConvertTo-SkillDocument -Meta $SkillDefinition.Meta -Body $SkillDefinition.Body
    $allSucceeded = Write-ManagedFile -Path (Join-Path $targetDirectory 'SKILL.md') -Content $renderedSkill

    $excludedItemNames = @('SKILL.md', 'meta.json', 'meta.jsonc')
    if ($Target -eq 'copilot') {
        $excludedItemNames += 'commands'
    }

    $additionalExcludedItemNames = @()
    $excludedItemNamesProperty = $SkillDefinition.PSObject.Properties['ExcludedItemNames']
    if ($null -ne $excludedItemNamesProperty) {
        $additionalExcludedItemNames = ConvertTo-StringArray $excludedItemNamesProperty.Value
    }

    if ($additionalExcludedItemNames.Count -gt 0) {
        $excludedItemNames += $additionalExcludedItemNames
    }

    $excludedItemNames = @($excludedItemNames | Select-Object -Unique)

    foreach ($excludedItemName in ($excludedItemNames | Where-Object { $_ -notin @('SKILL.md', 'meta.json', 'meta.jsonc') })) {
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

    return $allSucceeded
}

Invoke-PolicySync
