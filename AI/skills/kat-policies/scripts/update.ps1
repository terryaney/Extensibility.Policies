Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$aiRoot = Join-Path $repoRoot 'AI'
$sharedMappingsPath = Join-Path $PSScriptRoot 'meta.mappings.jsonc'

$compatibilityMessages = New-Object System.Collections.Generic.List[string]
$blockedPaths = New-Object System.Collections.Generic.List[string]
$deploymentRecords = New-Object System.Collections.Generic.List[object]
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

    $wtPackage = Get-AppxPackage -Name 'Microsoft.WindowsTerminal' -ErrorAction SilentlyContinue
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
        @{ Root = $Roots.ClaudeRoot; ScanRoots = @((Join-Path $Roots.ClaudeRoot 'agents'), (Join-Path $Roots.ClaudeRoot 'instructions'), (Join-Path $Roots.ClaudeRoot 'rules'), (Join-Path $Roots.ClaudeRoot 'skills'), (Join-Path $Roots.ClaudeRoot 'commands'), (Join-Path $Roots.ClaudeRoot 'CLAUDE.md')) }
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

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilot') $true) {
            $content = ConvertTo-CopilotAgentDocument -Meta $definition.Meta -Body $definition.Body -Client 'vscode'
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true

            if ($agentRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.VscodeRoot 'prompts') ($id + '.agent.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content
            }
            else {
                foreach ($agentRepositoryRoot in $agentRepositories) {
                    if (-not (Test-Path -LiteralPath $agentRepositoryRoot -PathType Container)) {
                        Add-BlockedPath $agentRepositoryRoot
                        $succeeded = $false
                        continue
                    }

                    $path = Join-Path (Join-Path $agentRepositoryRoot '.github\agents') ($id + '.agent.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true) -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($agentRepositories.Count -gt 0) { $agentRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($agentRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilot') $true) {
            $path = Join-Path (Join-Path $Roots.CopilotRoot 'agents') ($id + '.agent.md')
            $content = ConvertTo-CopilotAgentDocument -Meta $definition.Meta -Body $definition.Body -Client 'copilotCli'
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $claudeTarget = [string](Get-Prop $definition.ClaudeMeta 'target')
            if (-not [string]::IsNullOrWhiteSpace($claudeTarget)) {
                Add-Warning "${id}: claude.target is ignored for canonical agent metadata."
            }

            $content = ConvertTo-ClaudeAgentDocument -Meta $definition.Meta -Body $definition.Body
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true

            if ($agentRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.ClaudeRoot 'agents') ($id + '.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content
            }
            else {
                foreach ($agentRepositoryRoot in $agentRepositories) {
                    if (-not (Test-Path -LiteralPath $agentRepositoryRoot -PathType Container)) {
                        Add-BlockedPath $agentRepositoryRoot
                        $succeeded = $false
                        continue
                    }

                    $path = Join-Path (Join-Path (Join-Path $agentRepositoryRoot '.claude') 'agents') ($id + '.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true) -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($agentRepositories.Count -gt 0) { $agentRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($agentRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status 'disabled'
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
        $instructionMatrixValue = if ($instructionRepositories.Count -gt 0) { 'repo' } else { 'global' }
        $instructionScopedValue = if ($instructionScope.Count -gt 0) { 'yes' } else { 'no' }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilot') $true) {
            $content = ConvertTo-CopilotInstructionDocument -Meta $definition.Meta -Body $definition.Body
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true

            if ($instructionRepositories.Count -eq 0) {
                $path = Join-Path (Join-Path $Roots.VscodeRoot 'instructions') ($id + '.instructions.md')
                $publishTargets.Add($path)
                $succeeded = Write-ManagedFile -Path $path -Content $content
            }
            else {
                foreach ($instructionRepositoryRoot in $instructionRepositories) {
                    if (-not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                        Add-BlockedPath $instructionRepositoryRoot
                        $succeeded = $false
                        continue
                    }

                    $path = Join-Path (Join-Path $instructionRepositoryRoot '.github\instructions') ($id + '.instructions.md')
                    $publishTargets.Add($path)
                    $succeeded = (Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $true) -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } elseif ($instructionRepositories.Count -gt 0) { $instructionRepositories -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($instructionRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $instructionMatrixValue -MatrixScoped $instructionScopedValue
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status 'disabled' -MatrixValue 'off' -MatrixScoped $instructionScopedValue
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilot') $true) {
            if ($instructionRepositories.Count -gt 0) {
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status 'skipped' -Detail 'repo-scoped-copilot-cli-not-supported' -MatrixValue 'repo' -MatrixScoped $instructionScopedValue
            }
            else {
                $path = Join-Path (Join-Path $Roots.CopilotRoot 'instructions') ($id + '.instructions.md')
                $content = ConvertTo-CopilotInstructionDocument -Meta $definition.Meta -Body $definition.Body
                $succeeded = Write-ManagedFile -Path $path -Content $content
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path -MatrixValue 'global' -MatrixScoped $instructionScopedValue
            }
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status 'disabled' -MatrixValue 'off' -MatrixScoped $instructionScopedValue
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $publishTargets = New-Object System.Collections.Generic.List[string]
            $succeeded = $true

            if ($instructionRepositories.Count -eq 0) {
                if ($isClaudeGlobalInstruction) {
                    $path = Join-Path (Join-Path $Roots.ClaudeRoot 'instructions') ($id + '.md')
                    $publishTargets.Add($path)
                    $succeeded = Write-ManagedFile -Path $path -Content $definition.Body
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
                        Add-BlockedPath $instructionRepositoryRoot
                        $succeeded = $false
                        continue
                    }

                    if ($isClaudeGlobalInstruction) {
                        $path = Join-Path (Join-Path $instructionRepositoryRoot '.claude\instructions') ($id + '.md')
                        $publishTargets.Add($path)
                        $targetSucceeded = Write-ManagedFile -Path $path -Content $definition.Body -ForceOwnedPath $true
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
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target $targetName -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($instructionRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) -MatrixValue $instructionMatrixValue -MatrixScoped $instructionScopedValue
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target $(if ($isClaudeGlobalInstruction) { 'claudePathInstruction' } else { 'claudeGlobalInstruction' }) -Status 'disabled' -MatrixValue 'off' -MatrixScoped $instructionScopedValue
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeGlobalInstruction' -Status 'disabled' -MatrixValue 'off' -MatrixScoped $instructionScopedValue
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudePathInstruction' -Status 'disabled' -MatrixValue 'off' -MatrixScoped $instructionScopedValue
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

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilot') $true) {
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
                    Add-DeploymentRecord -Category 'skill' -Id $commandArtifactId -Target 'copilot' -Status $(if ($commandSucceeded) { 'ok' } else { 'blocked' }) -Path $commandPath -Detail $(if ($skillRepositories.Count -gt 1) { "paths=$($copilotRoots.Count)" } else { $null })
                    $succeeded = $commandSucceeded -and $succeeded
                }
            }

            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($skillRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null })
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status 'disabled'
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
                            $commandSucceeded = Write-ManagedFile -Path $commandPath -Content $commandContent
                        }

                        $commandsSucceeded = $commandsSucceeded -and $commandSucceeded
                        Add-DeploymentRecord -Category 'skill' -Id $commandArtifactId -Target 'claude' -Status $(if ($commandSucceeded) { 'ok' } else { 'blocked' }) -Path $commandPath -Detail $(if ($targetSkillSucceeded) { $null } else { 'skill-publish-failed' })
                    }
                }
            }

            if ($definition.CommandFiles.Count -gt 0 -and -not $commandsSucceeded) {
                Add-Warning "${id}: One or more Claude commands were not published. See the deployment matrix for details."
            }

            $claudeSucceeded = $skillSucceeded -and $commandsSucceeded
            $deploymentPath = if ($publishTargets.Count -gt 0) { $publishTargets -join '; ' } else { $null }
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status $(if ($claudeSucceeded) { 'ok' } else { 'blocked' }) -Path $deploymentPath -Detail $(if ($claudeSucceeded) { $(if ($skillRepositories.Count -gt 1) { "paths=$($publishTargets.Count)" } else { $null }) } elseif (-not $skillSucceeded) { 'skill-publish-failed' } else { 'command-publish-failed' })
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status 'disabled'
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

function Write-SyncReport {
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

function Invoke-PolicySync {
    $roots = Get-EnvironmentRoots
    $agentDefinitions = Get-AgentDefinitions
    $instructionDefinitions = Get-InstructionDefinitions
    $skillDefinitions = Get-SkillDefinitionsWithContent

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
    Write-SyncReport
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
        copilot = 'copilot'
        status = 'status'
    }
    $statusLabels = @{
        ok = 'ok'
        blocked = 'blocked'
        disabled = 'off'
        skipped = 'skip'
    }
    $targetOrder = @{
        agent = @('vscode', 'copilotCli', 'claude')
        instruction = @('vscode', 'copilotCli', 'claude')
        skill = @('copilot', 'claude')
        link = @('status')
    }

    function Get-DeploymentCellValue {
        param(
            [object]$Record,
            [hashtable]$Labels
        )

        if ($null -eq $Record) {
            return '--'
        }

        $status = $Labels[$record.Status]
        if ([string]::IsNullOrWhiteSpace($status)) {
            $status = $record.Status
        }

        if (-not [string]::IsNullOrWhiteSpace($record.Detail) -and $record.Status -ne 'ok') {
            $status = "$status($($record.Detail))"
        }

        return $status
    }

    function Get-InstructionMatrixValue {
        param(
            [object[]]$Records,
            [string]$Target
        )

        $record = $null
        if ($Target -eq 'claude') {
            $record = @($Records | Where-Object { $_.Target -in @('claudeGlobalInstruction', 'claudePathInstruction') -and $_.Status -ne 'disabled' } | Select-Object -First 1)
            if ($record.Count -eq 0) {
                $record = @($Records | Where-Object { $_.Target -in @('claudeGlobalInstruction', 'claudePathInstruction') } | Select-Object -First 1)
            }
        }
        else {
            $record = @($Records | Where-Object Target -eq $Target | Select-Object -First 1)
        }

        if ($record.Count -eq 0) {
            return '--'
        }

        if (-not [string]::IsNullOrWhiteSpace([string]$record[0].MatrixValue)) {
            return [string]$record[0].MatrixValue
        }

        return $(if ($record[0].Status -eq 'disabled') { 'off' } else { '--' })
    }

    function Get-InstructionScopedValue {
        param([object[]]$Records)

        $record = @($Records | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.MatrixScoped) } | Select-Object -First 1)
        if ($record.Count -eq 0) {
            return '--'
        }

        return [string]$record[0].MatrixScoped
    }

    function Get-InstructionArtifactWidth {
        param([object[]]$Groups)

        $longestArtifactLength = 0
        foreach ($group in $Groups) {
            if ($group.Name.Length -gt $longestArtifactLength) {
                $longestArtifactLength = $group.Name.Length
            }
        }

        return [Math]::Max('artifact'.Length, $longestArtifactLength + 2)
    }

    function Get-LinkGroupStatusValue {
        param([object[]]$Records)

        $blockedRecord = @($Records | Where-Object Status -eq 'blocked' | Select-Object -First 1)
        if ($blockedRecord.Count -gt 0) {
            return Get-DeploymentCellValue -Record $blockedRecord[0] -Labels $statusLabels
        }

        $skippedRecord = @($Records | Where-Object Status -eq 'skipped' | Select-Object -First 1)
        if ($skippedRecord.Count -gt 0) {
            return Get-DeploymentCellValue -Record $skippedRecord[0] -Labels $statusLabels
        }

        $disabledRecord = @($Records | Where-Object Status -eq 'disabled' | Select-Object -First 1)
        if ($disabledRecord.Count -gt 0 -and $Records.Count -eq $disabledRecord.Count) {
            return Get-DeploymentCellValue -Record $disabledRecord[0] -Labels $statusLabels
        }

        $okRecord = @($Records | Where-Object Status -eq 'ok' | Select-Object -First 1)
        if ($okRecord.Count -gt 0) {
            return Get-DeploymentCellValue -Record $okRecord[0] -Labels $statusLabels
        }

        return Get-DeploymentCellValue -Record ($Records | Select-Object -First 1) -Labels $statusLabels
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
        $rows = @()
        $fixedWidths = @(40)
        $alignments = @('left')
        $headerAlignments = @('left')

        switch ($category) {
            'instruction' {
                $headers = @('artifact', 'vscode', 'cli', 'claude', 'scoped')
                $rows = foreach ($group in $groups) {
                    [pscustomobject]@{
                        Cells = @(
                            $group.Name
                            (Get-InstructionMatrixValue -Records $group.Group -Target 'vscode')
                            (Get-InstructionMatrixValue -Records $group.Group -Target 'copilotCli')
                            (Get-InstructionMatrixValue -Records $group.Group -Target 'claude')
                            (Get-InstructionScopedValue -Records $group.Group)
                        )
                    }
                }
                $fixedWidths = @((Get-InstructionArtifactWidth -Groups $groups), 8, 8, 8, 8)
                $alignments = @('left', 'status', 'status', 'status', 'status')
                $headerAlignments = @('left', 'center', 'center', 'center', 'center')
            }
            'link' {
                $headers = @('artifact', 'status')
                $rows = foreach ($group in $groups) {
                    [pscustomobject]@{
                        Cells = @(
                            $group.Name
                            (Get-LinkGroupStatusValue -Records $group.Group)
                        )
                    }
                }
                $fixedWidths = @(40, 24)
                $alignments = @('left', 'status')
                $headerAlignments = @('left', 'center')
            }
            default {
                $rows = foreach ($group in $groups) {
                    $values = @($group.Name)
                    foreach ($target in $targetOrder[$category]) {
                        $record = $group.Group | Where-Object Target -eq $target | Select-Object -First 1
                        $values += (Get-DeploymentCellValue -Record $record -Labels $statusLabels)
                    }

                    [pscustomobject]@{
                        Cells = $values
                    }
                }

                foreach ($target in $targetOrder[$category]) {
                    $fixedWidths += 12
                    $alignments += 'status'
                    $headerAlignments += 'center'
                }
            }
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
    $pathsToRemove |
        Sort-Object Length -Descending -Unique |
        ForEach-Object {
            if ($null -ne (Get-Item -LiteralPath $_ -Force -ErrorAction SilentlyContinue)) {
                Remove-Item -LiteralPath $_ -Force -Recurse -Confirm:$false -ErrorAction SilentlyContinue
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

function Get-InstructionScope {
    param([object]$Meta)

    $instructionMeta = Get-Prop $Meta 'instructions'
    return (ConvertTo-StringArray (Get-Prop $instructionMeta 'scope'))
}

function Read-CanonicalMeta {
    param([string]$Path)

    return ConvertFrom-JsonWithComments (Get-Content -LiteralPath $Path -Raw)
}

function Resolve-ClientMarkdown {
    param(
        [string]$Content,
        [ValidateSet('copilot', 'claude')]
        [string]$Client
    )

    if ([string]::IsNullOrEmpty($Content)) {
        return $Content
    }

    $resolved = [string]$Content
    $otherClient = if ($Client -eq 'copilot') { 'claude' } else { 'copilot' }
    $regexOptions = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
    $otherClientPattern = '<!--\s*' + [regex]::Escape($otherClient) + ':start\s*-->.*?<!--\s*' + [regex]::Escape($otherClient) + ':end\s*-->\r?\n?'
    $clientPattern = '<!--\s*' + [regex]::Escape($Client) + ':start\s*-->(.*?)<!--\s*' + [regex]::Escape($Client) + ':end\s*-->'

    $resolved = [regex]::Replace(
        $resolved,
        $otherClientPattern,
        '',
        $regexOptions)

    $resolved = [regex]::Replace(
        $resolved,
        $clientPattern,
        '$1',
        $regexOptions)

    return $resolved
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

    return [pscustomobject]@{
        Directory = $SkillDefinition.Directory
        Meta = $SkillDefinition.Meta
        Body = Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'copilot'
        Enabled = $SkillDefinition.Enabled
        Id = $SkillDefinition.Id
        ClaudeMeta = $SkillDefinition.ClaudeMeta
        CommandFiles = $SkillDefinition.CommandFiles
        ExcludedItemNames = @('commands')
    }
}

function New-ClaudeSkillDefinition {
    param([object]$SkillDefinition)

    return [pscustomobject]@{
        Directory = $SkillDefinition.Directory
        Meta = $SkillDefinition.Meta
        Body = Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'claude'
        Enabled = $SkillDefinition.Enabled
        Id = $SkillDefinition.Id
        ClaudeMeta = $SkillDefinition.ClaudeMeta
        CommandFiles = $SkillDefinition.CommandFiles
        ExcludedItemNames = @('commands')
    }
}

function Get-CopilotCommandSkillDefinitions {
    param([object]$SkillDefinition)

    $baseBody = (Resolve-ClientMarkdown -Content $SkillDefinition.Body -Client 'copilot').TrimEnd()
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

        foreach ($field in @('license', 'compatibility', 'metadata')) {
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

    $resolvedBody = Resolve-ClientMarkdown -Content $Body -Client 'copilot'
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
        [string]$Body
    )

    $scope = @(Get-InstructionScope -Meta $Meta)
    $applyTo = if ($scope.Count -eq 0) { '**' } else { $scope -join ', ' }
    $frontmatter = @('applyTo: ' + (Format-YamlScalar $applyTo))
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
    foreach ($pathPattern in (Get-InstructionScope -Meta $Meta)) {
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
