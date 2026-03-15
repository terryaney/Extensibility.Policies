Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$devMode = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -Name 'AllowDevelopmentWithoutDevLicense' -ErrorAction SilentlyContinue
$devModeValue = $null
if ($null -ne $devMode) {
    $devModeProperty = $devMode.PSObject.Properties['AllowDevelopmentWithoutDevLicense']
    if ($null -ne $devModeProperty) {
        $devModeValue = $devModeProperty.Value
    }
}

if ($devModeValue -ne 1) {
    Write-Warning "Developer Mode is not enabled. Run the following from an elevated PowerShell to enable Developer Mode and allow symlink creation:`n`n" +
        'reg add HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock /t REG_DWORD /f /v AllowDevelopmentWithoutDevLicense /d 1'
    exit -1
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..')).Path
$aiRoot = Join-Path $repoRoot 'AI'

$compatibilityMessages = New-Object System.Collections.Generic.List[string]
$blockedPaths = New-Object System.Collections.Generic.List[string]
$deploymentRecords = New-Object System.Collections.Generic.List[object]
$script:claudeContext7Configured = $null

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
        [string]$Detail = $null
    )

    $deploymentRecords.Add([pscustomobject]@{
        Category = $Category
        Id = $Id
        Target = $Target
        Status = $Status
        Path = $Path
        Detail = $Detail
    })
}

function Get-AgentRepositoryRoot {
    param([object]$Meta)

    $publish = Get-Prop $Meta 'publish'
    $repositoryRoot = Get-Prop $publish 'repositoryRoot'
    if ([string]::IsNullOrWhiteSpace([string]$repositoryRoot)) {
        return $null
    }

    return [string]$repositoryRoot
}

function Get-InstructionRepositoryRoot {
    param([object]$Meta)

    $publish = Get-Prop $Meta 'publish'
    $repositoryRoot = Get-Prop $publish 'repositoryRoot'
    if ([string]::IsNullOrWhiteSpace([string]$repositoryRoot)) {
        return $null
    }

    return [string]$repositoryRoot
}

function Get-AgentRepositoryManagedContexts {
    param([object[]]$Definitions)

    $contextsByRoot = @{}

    foreach ($definition in $Definitions) {
        $repositoryRoot = $definition.RepositoryRoot
        if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
            continue
        }

        if (-not $contextsByRoot.ContainsKey($repositoryRoot)) {
            $contextsByRoot[$repositoryRoot] = New-Object System.Collections.Generic.List[string]
        }

        foreach ($scanRoot in @(
                (Join-Path $repositoryRoot '.github\agents'),
                (Join-Path $repositoryRoot '.claude\agents'),
                (Join-Path $repositoryRoot '.claude\commands')))
        {
            if (-not $contextsByRoot[$repositoryRoot].Contains($scanRoot)) {
                $contextsByRoot[$repositoryRoot].Add($scanRoot)
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
        $repositoryRoot = $definition.RepositoryRoot
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
        [object[]]$InstructionDefinitions
    )

    $managedContexts = @(
        @{ Root = 'C:\BTR'; ScanRoots = @((Join-Path 'C:\BTR' '.editorconfig')) },
        @{ Root = $Roots.VscodeRoot; ScanRoots = @((Join-Path $Roots.VscodeRoot 'prompts'), (Join-Path $Roots.VscodeRoot 'instructions')) },
        @{ Root = $Roots.CopilotRoot; ScanRoots = @((Join-Path $Roots.CopilotRoot 'agents'), (Join-Path $Roots.CopilotRoot 'instructions'), (Join-Path $Roots.CopilotRoot 'skills')) },
        @{ Root = $Roots.ClaudeRoot; ScanRoots = @((Join-Path $Roots.ClaudeRoot 'agents'), (Join-Path $Roots.ClaudeRoot 'instructions'), (Join-Path $Roots.ClaudeRoot 'rules'), (Join-Path $Roots.ClaudeRoot 'skills'), (Join-Path $Roots.ClaudeRoot 'commands'), (Join-Path $Roots.ClaudeRoot 'CLAUDE.md')) }
    )

    $managedContexts += @(Get-AgentRepositoryManagedContexts -Definitions $AgentDefinitions)
    $managedContexts += @(Get-InstructionRepositoryManagedContexts -Definitions $InstructionDefinitions)

    if ($Roots.TerminalRoot) {
        $managedContexts += @{ Root = $Roots.TerminalRoot; ScanRoots = @($Roots.TerminalRoot) }
    }

    return @($managedContexts)
}

function Publish-EditorConfig {
    $editorConfigPath = 'C:\BTR\.editorconfig'
    $editorConfigSucceeded = Write-ManagedSymlink -Path $editorConfigPath -Target (Join-Path $repoRoot '.editorconfig')
    Add-DeploymentRecord -Category 'link' -Id '.editorconfig' -Target 'btr' -Status $(if ($editorConfigSucceeded) { 'ok' } else { 'blocked' }) -Path $editorConfigPath
}

function Publish-TerminalFiles {
    param([object]$Roots)

    if ($Roots.TerminalRoot) {
        Get-ChildItem -LiteralPath (Join-Path $repoRoot 'Terminal') -Recurse -File | ForEach-Object {
            $relativePath = $_.FullName.Substring((Join-Path $repoRoot 'Terminal').Length).TrimStart('\')
            $targetPath = Join-Path $Roots.TerminalRoot $relativePath
            $targetSucceeded = Copy-ManagedFile -Path $targetPath -SourcePath $_.FullName
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
        $agentRepositoryRoot = $definition.RepositoryRoot

        if (ConvertTo-BoolValue (Get-Prop $enabled 'vscode') $true) {
            if (-not [string]::IsNullOrWhiteSpace($agentRepositoryRoot) -and -not (Test-Path -LiteralPath $agentRepositoryRoot -PathType Container)) {
                Add-BlockedPath $agentRepositoryRoot
                Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status 'blocked' -Path $agentRepositoryRoot -Detail 'repository-root-not-found'
            }
            else {
                $repoTargetedVscodeAgent = -not [string]::IsNullOrWhiteSpace($agentRepositoryRoot)
                $path = if ([string]::IsNullOrWhiteSpace($agentRepositoryRoot)) {
                    Join-Path (Join-Path $Roots.VscodeRoot 'prompts') ($id + '.agent.md')
                }
                else {
                    Join-Path (Join-Path $agentRepositoryRoot '.github\agents') ($id + '.agent.md')
                }
                $content = ConvertTo-CopilotAgentDocument -Meta $definition.Meta -Body $definition.Body -Client 'vscode'
                $succeeded = Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $repoTargetedVscodeAgent
                Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
            }
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'vscode' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilotCli') $true) {
            $path = Join-Path (Join-Path $Roots.CopilotRoot 'agents') ($id + '.agent.md')
            $content = ConvertTo-CopilotAgentDocument -Meta $definition.Meta -Body $definition.Body -Client 'copilotCli'
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'agent' -Id $id -Target 'copilotCli' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            if (-not [string]::IsNullOrWhiteSpace($agentRepositoryRoot) -and -not (Test-Path -LiteralPath $agentRepositoryRoot -PathType Container)) {
                Add-BlockedPath $agentRepositoryRoot
                Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status 'blocked' -Path $agentRepositoryRoot -Detail 'repository-root-not-found'
            }
            else {
                $repoTargetedClaudeAgent = -not [string]::IsNullOrWhiteSpace($agentRepositoryRoot)
                $claudeTarget = Get-Prop $definition.ClaudeMeta 'target' 'agent'
                $claudeFolder = if ($claudeTarget -eq 'command') { 'commands' } else { 'agents' }
                $path = if ([string]::IsNullOrWhiteSpace($agentRepositoryRoot)) {
                    Join-Path (Join-Path $Roots.ClaudeRoot $claudeFolder) ($id + '.md')
                }
                else {
                    Join-Path (Join-Path (Join-Path $agentRepositoryRoot '.claude') $claudeFolder) ($id + '.md')
                }
                $content = ConvertTo-ClaudeAgentDocument -Meta $definition.Meta -Body $definition.Body
                $succeeded = Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $repoTargetedClaudeAgent
                Add-DeploymentRecord -Category 'agent' -Id $id -Target 'claude' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
            }
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

    $claudeImports = New-Object System.Collections.Generic.List[string]
    $claudeImportIds = New-Object System.Collections.Generic.List[string]

    foreach ($definition in $Definitions) {
        $enabled = $definition.Enabled
        $id = $definition.Id
        $instructionRepositoryRoot = $definition.RepositoryRoot

        if (ConvertTo-BoolValue (Get-Prop $enabled 'vscode') $true) {
            if (-not [string]::IsNullOrWhiteSpace($instructionRepositoryRoot) -and -not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                Add-BlockedPath $instructionRepositoryRoot
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status 'blocked' -Path $instructionRepositoryRoot -Detail 'repository-root-not-found'
            }
            else {
                $repoTargetedVscodeInstruction = -not [string]::IsNullOrWhiteSpace($instructionRepositoryRoot)
                $path = if ([string]::IsNullOrWhiteSpace($instructionRepositoryRoot)) {
                    Join-Path (Join-Path $Roots.VscodeRoot 'instructions') ($id + '.instructions.md')
                }
                else {
                    Join-Path (Join-Path $instructionRepositoryRoot '.github\instructions') ($id + '.instructions.md')
                }
                $content = ConvertTo-CopilotInstructionDocument -Meta $definition.Meta -Body $definition.Body
                $succeeded = Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $repoTargetedVscodeInstruction
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
            }
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'vscode' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilotCli') $true) {
            $path = Join-Path (Join-Path $Roots.CopilotRoot 'instructions') ($id + '.instructions.md')
            $content = ConvertTo-CopilotInstructionDocument -Meta $definition.Meta -Body $definition.Body
            $succeeded = Write-ManagedFile -Path $path -Content $content
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'copilotCli' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claudeInstruction') $true) {
            if (-not [string]::IsNullOrWhiteSpace($instructionRepositoryRoot) -and -not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                Add-BlockedPath $instructionRepositoryRoot
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeInstruction' -Status 'blocked' -Path $instructionRepositoryRoot -Detail 'repository-root-not-found'
            }
            else {
                $repoTargetedClaudeInstruction = -not [string]::IsNullOrWhiteSpace($instructionRepositoryRoot)
                $path = if ([string]::IsNullOrWhiteSpace($instructionRepositoryRoot)) {
                    Join-Path (Join-Path $Roots.ClaudeRoot 'instructions') ($id + '.md')
                }
                else {
                    Join-Path (Join-Path $instructionRepositoryRoot '.claude\instructions') ($id + '.md')
                }
                $succeeded = Write-ManagedFile -Path $path -Content $definition.Body -ForceOwnedPath $repoTargetedClaudeInstruction
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeInstruction' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
            }
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeInstruction' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claudeRule') $true) {
            if (-not [string]::IsNullOrWhiteSpace($instructionRepositoryRoot) -and -not (Test-Path -LiteralPath $instructionRepositoryRoot -PathType Container)) {
                Add-BlockedPath $instructionRepositoryRoot
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeRule' -Status 'blocked' -Path $instructionRepositoryRoot -Detail 'repository-root-not-found'
            }
            else {
                $repoTargetedClaudeRule = -not [string]::IsNullOrWhiteSpace($instructionRepositoryRoot)
                $path = if ([string]::IsNullOrWhiteSpace($instructionRepositoryRoot)) {
                    Join-Path (Join-Path $Roots.ClaudeRoot 'rules') ($id + '.md')
                }
                else {
                    Join-Path (Join-Path $instructionRepositoryRoot '.claude\rules') ($id + '.md')
                }
                $content = ConvertTo-ClaudeRuleDocument -Meta $definition.Meta -Body $definition.Body
                $succeeded = Write-ManagedFile -Path $path -Content $content -ForceOwnedPath $repoTargetedClaudeRule
                Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeRule' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path $path
            }
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeRule' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claudeImport') $true) {
            $claudeImports.Add("@instructions/$id.md")
            $claudeImportIds.Add($id)
        }
        else {
            Add-DeploymentRecord -Category 'instruction' -Id $id -Target 'claudeImport' -Status 'disabled'
        }
    }

    return [pscustomobject]@{
        ClaudeImports = @($claudeImports.ToArray())
        ClaudeImportIds = @($claudeImportIds.ToArray())
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

        if (ConvertTo-BoolValue (Get-Prop $enabled 'copilot') $true) {
            $copilotDefinition = New-CopilotSkillDefinition -SkillDefinition $definition
            $succeeded = Install-RenderedSkill -Root $Roots.CopilotRoot -SkillDefinition $copilotDefinition -Target 'copilot'
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status $(if ($succeeded) { 'ok' } else { 'blocked' }) -Path (Join-Path (Join-Path $Roots.CopilotRoot 'skills') $id)

            foreach ($commandDefinition in (Get-CopilotCommandSkillDefinitions -SkillDefinition $definition)) {
                $commandSucceeded = Install-RenderedSkill -Root $Roots.CopilotRoot -SkillDefinition $commandDefinition -Target 'copilot'
                Add-DeploymentRecord -Category 'skill' -Id $commandDefinition.Id -Target 'copilot' -Status $(if ($commandSucceeded) { 'ok' } else { 'blocked' }) -Path (Join-Path (Join-Path $Roots.CopilotRoot 'skills') $commandDefinition.Id)
            }
        }
        else {
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'copilot' -Status 'disabled'
        }

        if (ConvertTo-BoolValue (Get-Prop $enabled 'claude') $true) {
            $skillPath = Join-Path (Join-Path $Roots.ClaudeRoot 'skills') $id
            $claudeDefinition = New-ClaudeSkillDefinition -SkillDefinition $definition
            $skillSucceeded = Install-RenderedSkill -Root $Roots.ClaudeRoot -SkillDefinition $claudeDefinition -Target 'claude'
            $commandsSucceeded = $true
            $exposeCommands = ConvertTo-BoolValue (Get-Prop $definition.ClaudeMeta 'exposeCommands') ($definition.CommandFiles.Count -gt 0)

            if ($exposeCommands -and $definition.CommandFiles.Count -gt 0) {
                foreach ($commandFile in $definition.CommandFiles) {
                    $commandPath = Join-Path (Join-Path $Roots.ClaudeRoot 'commands') $commandFile.Name
                    $commandSucceeded = $false

                    if ($skillSucceeded) {
                        $commandContent = Resolve-ClientMarkdown -Content (Get-Content -LiteralPath $commandFile.FullName -Raw) -Client 'claude'
                        $commandSucceeded = Write-ManagedFile -Path $commandPath -Content $commandContent
                    }

                    $commandsSucceeded = $commandsSucceeded -and $commandSucceeded
                    Add-DeploymentRecord -Category 'link' -Id ('ClaudeCommand/' + $commandFile.Name) -Target 'claudeCommand' -Status $(if ($commandSucceeded) { 'ok' } else { 'blocked' }) -Path $commandPath -Detail $(if ($skillSucceeded) { $null } else { 'skill-publish-failed' })
                }

                if (-not $commandsSucceeded) {
                    Add-Warning "${id}: One or more Claude commands were not published. See the deployment matrix for details."
                }
            }

            $claudeSucceeded = $skillSucceeded -and $commandsSucceeded
            Add-DeploymentRecord -Category 'skill' -Id $id -Target 'claude' -Status $(if ($claudeSucceeded) { 'ok' } else { 'blocked' }) -Path $skillPath -Detail $(if ($claudeSucceeded) { $null } elseif (-not $skillSucceeded) { 'skill-publish-failed' } else { 'command-publish-failed' })
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
    foreach ($instructionId in $InstructionPublishResult.ClaudeImportIds) {
        $definition = $definitionsById[$instructionId]
        if ($null -eq $definition) {
            continue
        }

        $targetRoot = $Roots.ClaudeRoot
        $repositoryRoot = $definition.RepositoryRoot
        if (-not [string]::IsNullOrWhiteSpace($repositoryRoot)) {
            $targetRoot = Join-Path $repositoryRoot '.claude'
        }

        if (-not $claudeImportsByRoot.ContainsKey($targetRoot)) {
            $claudeImportsByRoot[$targetRoot] = New-Object System.Collections.Generic.List[string]
        }

        $claudeImportsByRoot[$targetRoot].Add($instructionId)
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
        foreach ($instructionId in $instructionIds) {
            Add-DeploymentRecord -Category 'instruction' -Id $instructionId -Target 'claudeImport' -Status $(if ($claudeDocumentSucceeded) { 'ok' } else { 'blocked' }) -Path $claudeDocumentPath
        }
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

    $managedContexts = Get-ManagedContexts -Roots $roots -AgentDefinitions $agentDefinitions -InstructionDefinitions $instructionDefinitions
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
        if ($text -in @('ok', '--', 'off', 'skip')) {
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
        claudeInstruction = 'cInst'
        claudeRule = 'cRule'
        claudeImport = 'import'
        copilot = 'copilot'
        btr = 'btr'
        terminal = 'terminal'
        claudeCommand = 'cCmd'
        claudeDoc = 'claudeDoc'
    }
    $statusLabels = @{
        ok = 'ok'
        blocked = 'blocked'
        disabled = 'off'
        skipped = 'skip'
    }
    $targetOrder = @{
        agent = @('vscode', 'copilotCli', 'claude')
        instruction = @('vscode', 'copilotCli', 'claudeInstruction', 'claudeRule', 'claudeImport')
        skill = @('copilot', 'claude')
        link = @('btr', 'terminal', 'claudeCommand', 'claudeDoc')
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
        $rows = foreach ($group in $groups) {
            $values = @($group.Name)
            foreach ($target in $targetOrder[$category]) {
                $record = $group.Group | Where-Object Target -eq $target | Select-Object -First 1
                if ($null -eq $record) {
                    $values += '--'
                    continue
                }

                $status = $statusLabels[$record.Status]
                if ([string]::IsNullOrWhiteSpace($status)) {
                    $status = $record.Status
                }

                if (-not [string]::IsNullOrWhiteSpace($record.Detail) -and $record.Status -ne 'ok') {
                    $status = "$status($($record.Detail))"
                }

                $values += $status
            }

            [pscustomobject]@{
                Cells = $values
            }
        }

        $fixedWidths = @(40)
        $alignments = @('left')
        foreach ($target in $targetOrder[$category]) {
            $fixedWidths += 12
            $alignments += 'status'
        }

        $headerAlignments = @('left')
        foreach ($target in $targetOrder[$category]) {
            $headerAlignments += 'center'
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

function Write-ManagedSymlink {
    param(
        [string]$Path,
        [string]$Target
    )

    New-Directory (Split-Path -Parent $Path)
    if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
        Add-BlockedPath $Path
        return $false
    }

    New-Item -ItemType SymbolicLink -Path $Path -Target $Target -Force | Out-Null
    return $true
}

function Copy-ManagedFile {
    param(
        [string]$Path,
        [string]$SourcePath
    )

    New-Directory (Split-Path -Parent $Path)
    if (-not (Remove-KatManagedPath -Path $Path -RepositoryRoot $repoRoot)) {
        Add-BlockedPath $Path
        return $false
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

function Test-LegacyToolConfiguration {
    param([object]$Tools)

    if ($null -eq $Tools) {
        return $false
    }

    return ($null -ne $Tools.PSObject.Properties['copilot']) -or ($null -ne $Tools.PSObject.Properties['claude'])
}

function Get-ConfiguredToolsForClient {
    param(
        [object]$Meta,
        [string]$Client
    )

    $tools = Get-Prop $Meta 'tools'
    if ($null -eq $tools) {
        return ,@()
    }

    if (Test-LegacyToolConfiguration -Tools $tools) {
        switch ($Client) {
            'vscode' {
                return ,(ConvertTo-StringArray (Get-Prop $tools 'copilot'))
            }
            'copilotCli' {
                return ,(ConvertTo-StringArray (Get-Prop $tools 'copilot'))
            }
            'claude' {
                return ,(Get-ClaudeToolMappings -Meta $Meta -ArtifactLabel (Get-Prop $Meta 'id'))
            }
            default {
                return ,@()
            }
        }
    }

    $resolvedTools = New-Object System.Collections.Generic.List[string]
    foreach ($toolProperty in @($tools.PSObject.Properties)) {
        $toolName = $toolProperty.Name
        $definition = $toolProperty.Value
        $hasClientProperty = $false
        $mappedValue = $null

        if ($null -ne $definition) {
            $clientProperty = $definition.PSObject.Properties[$Client]
            if ($null -ne $clientProperty) {
                $hasClientProperty = $true
                $mappedValue = $clientProperty.Value
            }
        }

        if ($Client -eq 'claude') {
            $toolValues = if ($hasClientProperty) { ConvertTo-StringArray $mappedValue } else { @() }
        }
        else {
            $toolValues = if ($hasClientProperty) { ConvertTo-StringArray $mappedValue } else { @($toolName) }
        }

        foreach ($toolValue in $toolValues) {
            if (-not $resolvedTools.Contains($toolValue)) {
                $resolvedTools.Add($toolValue)
            }
        }
    }

    return ,($resolvedTools.ToArray())
}

function Get-ClaudeMemoryScope {
    param([object]$Meta)

    $claudeMeta = Get-Prop $Meta 'claude'
    $memoryScope = Get-Prop $claudeMeta 'memory'
    if ([string]::IsNullOrWhiteSpace([string]$memoryScope)) {
        return $null
    }

    return [string]$memoryScope
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

function Get-ClaudeToolMappings {
    param(
        [object]$Meta,
        [string]$ArtifactLabel
    )

    $tools = Get-Prop $Meta 'tools'
    $claudeTools = Get-Prop $tools 'claude'
    if ($null -ne $claudeTools -and $claudeTools -isnot [string]) {
        return ,(ConvertTo-StringArray $claudeTools)
    }

    if ($claudeTools -is [string] -and $claudeTools -ne 'auto') {
        return ,(ConvertTo-StringArray $claudeTools)
    }

    $mapped = New-Object System.Collections.Generic.List[string]
    foreach ($tool in (ConvertTo-StringArray (Get-Prop $tools 'copilot'))) {
        switch -Regex ($tool) {
            '^read($|/)' {
                if (-not $mapped.Contains('Read')) { $mapped.Add('Read') }
            }
            '^search$' {
                if (-not $mapped.Contains('Grep')) { $mapped.Add('Grep') }
                if (-not $mapped.Contains('Glob')) { $mapped.Add('Glob') }
            }
            '^edit$' {
                if (-not $mapped.Contains('Edit')) { $mapped.Add('Edit') }
            }
            '^execute$' {
                if (-not $mapped.Contains('Bash')) { $mapped.Add('Bash') }
            }
            '^web($|/)' {
                if (-not $mapped.Contains('WebFetch')) { $mapped.Add('WebFetch') }
            }
            '^todo$' {
                if (-not $mapped.Contains('TodoWrite')) { $mapped.Add('TodoWrite') }
            }
            '^agent$' {
                if (-not $mapped.Contains('Task')) { $mapped.Add('Task') }
            }
            '^github/' {
                if (-not $mapped.Contains('Bash')) { $mapped.Add('Bash') }
                if (-not $mapped.Contains('WebFetch')) { $mapped.Add('WebFetch') }
                Add-Warning "${ArtifactLabel}: GitHub-specific Copilot tools were mapped to Claude Bash/WebFetch. Install GitHub CLI or a GitHub MCP server if you need closer parity."
            }
            '^io\.github\.upstash/context7/' {
                if (Test-ClaudeContext7Configured) {
                    if (-not $mapped.Contains('mcp__context7__resolve-library-id')) { $mapped.Add('mcp__context7__resolve-library-id') }
                    if (-not $mapped.Contains('mcp__context7__get-library-docs')) { $mapped.Add('mcp__context7__get-library-docs') }
                }
                else {
                    Add-Warning "${ArtifactLabel}: Context7 has no native Claude tool equivalent. Install a matching MCP server and override tools.claude in meta.json if you want parity."
                }
            }
            '^vscode($|/)' {
                Add-Warning "${ArtifactLabel}: VS Code-only tools are ignored for Claude rendering."
            }
            default {
                Add-Warning "${ArtifactLabel}: No Claude tool mapping defined for Copilot tool '$tool'."
            }
        }
    }

    return ,($mapped.ToArray())
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
    $copilotMeta = Get-Prop $SkillDefinition.Meta 'copilot'
    $excludedCommands = ConvertTo-StringArray (Get-Prop $copilotMeta 'excludeCommands')

    foreach ($commandFile in $SkillDefinition.CommandFiles) {
        $commandName = [System.IO.Path]::GetFileNameWithoutExtension($commandFile.Name)
        if ($excludedCommands -icontains $commandName) {
            continue
        }

        $commandId = $SkillDefinition.Id + '-' + $commandName
        $resolvedCommandContent = Resolve-ClientMarkdown -Content (Get-Content -LiteralPath $commandFile.FullName -Raw) -Client 'copilot'
        $commandDocument = Split-MarkdownFrontmatter -Content $resolvedCommandContent

        $meta = [ordered]@{
            id = $commandId
            name = $commandId
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
            Id = $commandId
            ClaudeMeta = $null
            CommandFiles = @()
            ExcludedItemNames = @('commands')
        }
    }
}

function Resolve-ClaudeModel {
    param([object]$Model)

    $modelValue = [string]$Model
    if ([string]::IsNullOrWhiteSpace($modelValue)) {
        return $Model
    }

    if ($modelValue.Equals('default', [StringComparison]::OrdinalIgnoreCase)) {
        return 'sonnet'
    }

    return $Model
}

function ConvertTo-CopilotAgentDocument {
    param(
        [object]$Meta,
        [string]$Body,
        [string]$Client
    )

    $frontmatter = New-Object System.Collections.Generic.List[string]
    $frontmatter.Add('name: ' + (Format-YamlScalar (Get-Prop $Meta 'name')))
    $frontmatter.Add('description: ' + (Format-YamlScalar (Get-Prop $Meta 'description')))

    $models = Get-Prop $Meta 'models'
    $model = if ($Client -eq 'vscode') { Get-Prop $models 'vscode' } else { Get-Prop $models 'copilotCli' }
    if (-not [string]::IsNullOrWhiteSpace([string]$model)) {
        $frontmatter.Add('model: ' + (Format-YamlScalar $model))
    }

    if ($Client -eq 'vscode') {
        $agents = ConvertTo-StringArray (Get-Prop (Get-Prop $Meta 'copilot') 'agents')
        if ($agents.Count -gt 0) {
            $frontmatter.Add('agents: ' + (Format-YamlInlineArray $agents))
        }
    }

    $copilotTools = Get-ConfiguredToolsForClient -Meta $Meta -Client $Client
    if ($copilotTools.Count -gt 0) {
        $frontmatter.Add('tools: ' + (Format-YamlInlineArray $copilotTools))
    }

    $copilotMeta = Get-Prop $Meta 'copilot'
    if ($null -ne (Get-Prop $copilotMeta 'userInvocable')) {
        $frontmatter.Add('user-invocable: ' + ((ConvertTo-BoolValue (Get-Prop $copilotMeta 'userInvocable') $true).ToString().ToLower()))
    }

    if ($Client -eq 'vscode') {
        $handoffs = Get-Prop $copilotMeta 'handoffs'
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

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $Body
}

function ConvertTo-ClaudeAgentDocument {
    param(
        [object]$Meta,
        [string]$Body
    )

    $frontmatter = New-Object System.Collections.Generic.List[string]
    $frontmatter.Add('name: ' + (Format-YamlScalar (Get-Prop $Meta 'name')))
    $frontmatter.Add('description: ' + (Format-YamlScalar (Get-Prop $Meta 'description')))

    $model = Resolve-ClaudeModel (Get-Prop (Get-Prop $Meta 'models') 'claude')
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

    $copilotMeta = Get-Prop $Meta 'copilot'
    if ((ConvertTo-StringArray (Get-Prop $copilotMeta 'agents')).Count -gt 0 -or $null -ne (Get-Prop $copilotMeta 'handoffs')) {
        Add-Warning "$(Get-Prop $Meta 'id'): Copilot orchestration fields were omitted from Claude rendering because there is no compatible native frontmatter equivalent."
    }

    return New-DocumentContent -FrontmatterLines $frontmatter.ToArray() -Body $Body
}

function ConvertTo-CopilotInstructionDocument {
    param(
        [object]$Meta,
        [string]$Body
    )

    $scope = Get-Prop (Get-Prop $Meta 'scope') 'copilot' '**'
    $frontmatter = @('applyTo: ' + (Format-YamlScalar $scope))
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
    foreach ($pathPattern in (ConvertTo-StringArray (Get-Prop (Get-Prop $Meta 'scope') 'claude'))) {
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

function Get-AgentDirectories {
    Get-ChildItem -LiteralPath (Join-Path $aiRoot 'agents') -Directory |
        Where-Object {
            (Test-Path -LiteralPath (Join-Path $_.FullName 'body.md')) -and
            (Test-Path -LiteralPath (Get-CanonicalMetaPath -Directory $_))
        } |
        Sort-Object Name
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
        claude = [pscustomobject]@{
            exposeCommands = (Test-Path -LiteralPath (Join-Path $Directory.FullName 'commands'))
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
            RepositoryRoot = Get-AgentRepositoryRoot -Meta $meta
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
            RepositoryRoot = Get-InstructionRepositoryRoot -Meta $meta
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

    function Install-ManagedLinkedSkillItem {
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
                $childSucceeded = Install-ManagedLinkedSkillItem -SourceItem $_ -DestinationPath $childPath
                $allChildItemsSucceeded = $allChildItemsSucceeded -and $childSucceeded
            }

            return $allChildItemsSucceeded
        }

        return (Write-ManagedSymlink -Path $DestinationPath -Target $SourceItem.FullName)
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
        $linkSucceeded = Install-ManagedLinkedSkillItem -SourceItem $_ -DestinationPath $targetPath
        $allSucceeded = $allSucceeded -and $linkSucceeded
    }

    return $allSucceeded
}

Invoke-PolicySync
