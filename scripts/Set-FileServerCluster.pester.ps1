#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-FileServerCluster.ps1'
  $script:Nodes = @('tcnaw-hafs01a', 'tcnaw-hafs02a', 'tcnaw-hafs01b', 'tcnaw-hafs02b')
  $script:Addresses = @('10.0.1.11', '10.0.33.11', '10.0.65.11', '10.0.97.11')
  $script:Password = 'pester-cluster-password'
  $script:OriginalTemp = $env:TEMP
  If ([System.String]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP = [System.IO.Path]::GetTempPath() }

  $global:SetFileServerClusterGetCurrentIdentityName = { 'TCN\svc-fscluster-mgr' }
  $global:SetFileServerClusterReadTranscriptTail = { 'terminating mutation proof' }
  $global:SetFileServerClusterFindPrestageComputerObject = {
    Param (
      [System.String]$Name,
      [System.String]$IdentityName,
      [System.String]$Password,
      [System.DirectoryServices.AuthenticationTypes]$AuthenticationType
    )
    $global:FsHaDirectoryCalls += $Name
    $global:FsHaDirectoryFactoryArguments += [PSCustomObject]@{
      IdentityName       = $IdentityName
      Password           = $Password
      AuthenticationType = $AuthenticationType
    }
    $global:FsHaFormationOperations += ('DirectoryRead:{0}' -f $Name)
    If ($global:FsHaDirectoryLookupFailure -eq $Name) {
      Throw 'injected directory lookup failure'
    }
    New-StubDirectoryEntry -Name $Name
  }
  $script:GetLocalMembershipStatus = { $global:FsHaLocalMembershipStatus }

  Function Set-LocalMembershipStatus {
    Param (
      [ValidateSet('member-running', 'fresh', 'stopped-member')] [System.String]$Status,
      [ValidateSet('Running', 'Stopped')] [System.String]$ServiceStatus,
      [System.Boolean]$ClusDbPresent,
      [ValidateSet('Automatic', 'Manual', 'Disabled')] [System.String]$StartType
    )
    $global:FsHaLocalMembershipStatus = [PSCustomObject]@{
      status         = $Status
      service_status = $ServiceStatus
      clusdb_present = $ClusDbPresent
      start_type     = $StartType
    }
  }

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null }
    $global:Ansible
  }
  Function Remove-AnsibleContext { Remove-Variable -Name 'Ansible' -Scope Global -Force -ErrorAction SilentlyContinue }
  Function Assert-ResultPrimitiveLeaves {
    Param ([AllowNull()] [System.Object]$Value, [System.String]$Path = '$')
    If ($Null -eq $Value -or $Value -is [System.String] -or $Value -is [System.Int32] -or $Value -is [System.Boolean]) { Return }
    If ($Value -is [PSCustomObject]) {
      ForEach ($Property In $Value.PSObject.Properties) {
        Assert-ResultPrimitiveLeaves -Value $Property.Value -Path ('{0}.{1}' -f $Path, $Property.Name)
      }
      Return
    }
    If ($Value -is [System.Array]) {
      For ($Index = 0; $Index -lt $Value.Count; $Index++) {
        Assert-ResultPrimitiveLeaves -Value $Value[$Index] -Path ('{0}[{1}]' -f $Path, $Index)
      }
      Return
    }
    Throw ('Result leaf {0} has forbidden type {1}.' -f $Path, $Value.GetType().FullName)
  }

  Function New-StubDirectoryEntry {
    Param ([System.String]$Name)
    $Property = [PSCustomObject]@{ Value = [System.Int32]$global:FsHaDirectoryUserAccountControl[$Name] }
    $Entry = [PSCustomObject]@{
      Name = $Name
      Properties = @{ userAccountControl = $Property }
    }
    $Entry | Add-Member -MemberType ScriptMethod -Name 'RefreshCache' -Value {
      Param ([System.String[]]$PropertyName)
      $global:FsHaDirectoryReadbacks += $this.Name
      $this.Properties['userAccountControl'].Value = [System.Int32]$global:FsHaDirectoryUserAccountControl[$this.Name]
    }
    $Entry | Add-Member -MemberType ScriptMethod -Name 'CommitChanges' -Value {
      $global:FsHaDirectoryCommits += $this.Name
      $global:FsHaFormationOperations += ('DirectoryWrite:{0}' -f $this.Name)
      If ($global:FsHaDirectoryCommitFailure -eq $this.Name) {
        Throw 'injected directory commit failure'
      }
      If ($global:FsHaDirectoryReadbackMismatch -ne $this.Name) {
        $global:FsHaDirectoryUserAccountControl[$this.Name] = [System.Int32]$this.Properties['userAccountControl'].Value
      }
    }
    $Entry
  }

  Function Get-Cluster {
    Param ([System.String]$Name, [System.String]$ErrorAction)
    $global:FsHaClusterReads += [PSCustomObject]@{ NameBound = $PSBoundParameters.ContainsKey('Name'); Name = $Name }
    If (-not $global:FsHaClusterPresent) { Return @() }
    If ($Null -ne $global:FsHaClusterObject) { Return $global:FsHaClusterObject }
    [PSCustomObject]@{ Name = $global:FsHaClusterName }
  }
  Function Get-ClusterNode {
    Param ([System.Object]$InputObject)
    @($global:FsHaClusterNodes | ForEach-Object -Process {
        [PSCustomObject]@{ Name = $PSItem; State = $(If ($global:FsHaDownNode -eq $PSItem) { 'Down' } Else { 'Up' }) }
      })
  }
  Function Get-ClusterGroup {
    Param ([System.Object]$InputObject)
    [PSCustomObject]@{ Name = 'Cluster Group'; GroupType = 'Cluster' }
  }
  Function Get-ClusterResource {
    Param ([System.Object]$InputObject)
    ForEach ($Address In $global:FsHaClusterAddresses) {
      [PSCustomObject]@{ Name = "IP Address $Address"; ResourceType = 'IP Address'; OwnerGroup = 'Cluster Group'; Address = $Address }
    }
    @($global:FsHaClusterPhysicalDisks)
  }
  Function Get-ClusterParameter {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.String]$Name)
    [PSCustomObject]@{ Name = 'Address'; Value = $InputObject.Address }
  }
  Function Get-WmiObject {
    [CmdletBinding()]
    Param ([System.String]$Class, [System.String]$ComputerName, [System.String]$Filter)
    $global:FsHaFormationProbeCalls += [PSCustomObject]@{
      Class        = $Class
      ComputerName = $ComputerName
      Filter       = $Filter
      ErrorAction  = [System.String]$PSBoundParameters.ErrorAction
    }
    $global:FsHaFormationOperations += ('Probe:{0}' -f $ComputerName)
    $CallCount = @($global:FsHaFormationProbeCalls | Where-Object -FilterScript { $PSItem.ComputerName -eq $ComputerName }).Count
    If ($global:FsHaFormationProbeFailures.ContainsKey($ComputerName) -and
      $CallCount -le [System.Int32]$global:FsHaFormationProbeFailures[$ComputerName]) {
      Throw ('Readiness probe failed for {0}.' -f $ComputerName)
    }
    $States = @($global:FsHaFormationServiceStates[$ComputerName])
    $StateIndex = [System.Int32][Math]::Min($CallCount - 1, $States.Count - 1)
    [PSCustomObject]@{ Name = 'ClusSvc'; State = [System.String]$States[$StateIndex] }
  }
  Function New-Cluster {
    [CmdletBinding()]
    Param (
      [System.String]$Name, [System.String[]]$Node, [System.String[]]$StaticAddress,
      [Switch]$NoStorage, [Switch]$Force
    )
    $global:FsHaFormationOperations += 'New'
    $global:FsHaClusterWrites += [PSCustomObject]@{ Command = 'New'; Name = $Name; Node = $Node; StaticAddress = $StaticAddress; NoStorage = $NoStorage.IsPresent; Force = $Force.IsPresent }
    If (-not $global:FsHaClusterFrozen) {
      $global:FsHaClusterPresent = $True
      $global:FsHaClusterName = $Name
      $global:FsHaClusterNodes = @($Node)
      $global:FsHaClusterAddresses = @($StaticAddress)
      If ($global:FsHaClusterAutoAddDisk) {
        $global:FsHaClusterPhysicalDisks = @(
          [PSCustomObject]@{
            Name = 'Cluster Disk 9'; ResourceType = 'Physical Disk'; OwnerGroup = 'Available Storage'
          }
        )
      }
    }
    If ($global:FsHaMutationWritesError) {
      Write-Error -Message 'simulated non-terminating New-Cluster DNS registration error'
    }
  }
  Function Add-ClusterNode {
    [CmdletBinding()]
    Param ([System.Object]$InputObject, [System.String]$Name, [Switch]$NoStorage)
    $global:FsHaClusterWrites += [PSCustomObject]@{ Command = 'Add'; Cluster = $InputObject.Name; Name = $Name; NoStorage = $NoStorage.IsPresent }
    If (-not $global:FsHaClusterFrozen) { $global:FsHaClusterNodes += $Name }
    If ($global:FsHaMutationWritesError) {
      Write-Error -Message 'simulated non-terminating Add-ClusterNode membership error'
    }
  }
  Function Get-ClusterAvailableDisk { $global:FsHaEligibleDiskReads++; [PSCustomObject]@{ Number = 9 } }
  Function New-ScheduledTaskAction {
    Param ([System.String]$Execute, [System.String]$Argument)
    $EncodedCommand = @($Argument -split ' ')[-1]
    $InnerCommand = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($EncodedCommand))
    $ParserTokens = $Null
    $ParserErrors = $Null
    $Null = [System.Management.Automation.Language.Parser]::ParseInput($InnerCommand, [ref]$ParserTokens, [ref]$ParserErrors)
    If ($ParserErrors.Count -gt 0) { Throw 'Encoded mutation command did not parse.' }
    $PayloadMatches = [System.Text.RegularExpressions.Regex]::Matches($InnerCommand, "FromBase64String\('(?<Payload>[A-Za-z0-9+/=]+)'\)")
    If ($PayloadMatches.Count -ne 2) { Throw 'Mutation command did not contain exactly two encoded payloads.' }
    $MutationXml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PayloadMatches[0].Groups['Payload'].Value))
    $global:FsHaTranscriptPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PayloadMatches[1].Groups['Payload'].Value))
    $global:FsHaInnerCommand = $InnerCommand
    $global:FsHaScheduledMutation = [System.Management.Automation.PSSerializer]::Deserialize($MutationXml)
    [PSCustomObject]@{ Execute = $Execute; Argument = $Argument }
  }
  Function Register-ScheduledTask {
    Param (
      [System.String]$TaskName, [System.Object]$Action, [System.String]$User,
      [System.String]$Password, [System.String]$RunLevel, [Switch]$Force
    )
    $global:FsHaTaskRegistrations += [PSCustomObject]@{
      TaskName        = $TaskName
      User            = $User
      PasswordMatches = $Password -ceq $script:Password
      RunLevel        = $RunLevel
      Force           = $Force.IsPresent
    }
    $global:FsHaTaskExists = $True
    $global:FsHaTaskState = 'Ready'
    [PSCustomObject]@{ TaskName = $TaskName; State = $global:FsHaTaskState }
  }
  Function Get-ScheduledTask {
    Param ([System.String]$TaskName)
    $global:FsHaTaskReads++
    If ($global:FsHaTaskExists -and $global:FsHaTaskRegistrationVisible) {
      [PSCustomObject]@{ TaskName = $TaskName; State = $global:FsHaTaskState }
    }
  }
  Function Start-ScheduledTask {
    Param ([System.String]$TaskName)
    $global:FsHaTaskStarts += $TaskName
    $global:FsHaTaskState = 'Running'
    If ($global:FsHaTranscriptSeedOnStart -and -not [System.String]::IsNullOrWhiteSpace($global:FsHaTranscriptPath)) {
      [System.IO.File]::WriteAllText($global:FsHaTranscriptPath, 'cleanup transcript proof')
    }
  }
  Function Complete-ScheduledMutation {
    Param ([System.UInt32]$Result)
    If ($global:FsHaTaskCompleted) { Return }
    If (-not [System.String]::IsNullOrWhiteSpace($global:FsHaTranscriptPath)) {
      [System.IO.File]::WriteAllText($global:FsHaTranscriptPath, 'scheduled mutation proof')
    }
    If ($Result -eq 0) {
      If ($global:FsHaScheduledMutation.create_cluster) {
        New-Cluster -Name $global:FsHaScheduledMutation.cluster_name -Node $global:FsHaScheduledMutation.nodes -StaticAddress $global:FsHaScheduledMutation.static_addresses -NoStorage -Force
      } Else {
        $Clusters = @(Get-Cluster)
        If ($Clusters.Count -ne 1) { Throw 'Scheduled mutation could not acquire one local cluster.' }
        $Cluster = $Clusters[0]
        If ([System.String]$Cluster.Name -ine [System.String]$global:FsHaScheduledMutation.cluster_name) { Throw 'Scheduled mutation acquired the wrong local cluster.' }
        ForEach ($MissingNode In $global:FsHaScheduledMutation.missing_nodes) {
          Add-ClusterNode -InputObject $Cluster -Name $MissingNode -NoStorage
        }
      }
    }
    $global:FsHaTaskResult = $Result
    $global:FsHaTaskLastRunTime = $global:FsHaTaskLastRunTime.AddSeconds(1)
    $global:FsHaTaskState = 'Ready'
    $global:FsHaTaskCompleted = $True
  }
  Function Get-ScheduledTaskInfo {
    Param ([System.String]$TaskName)
    $global:FsHaTaskInfoReads++
    If ($global:FsHaTaskInfoSequence.Count -ge $global:FsHaTaskInfoReads) {
      $Info = $global:FsHaTaskInfoSequence[$global:FsHaTaskInfoReads - 1]
      If ($Null -ne $Info -and [System.DateTime]$Info.LastRunTime -gt $global:FsHaTaskLastRunTime -and
        [System.UInt32]$Info.LastTaskResult -notin [System.UInt32[]]@(267009, 267011, 267045)) {
        Complete-ScheduledMutation -Result ([System.UInt32]$Info.LastTaskResult)
      }
      Return $Info
    }
    If ($global:FsHaTaskStarts.Count -eq 0) {
      Return [PSCustomObject]@{ LastTaskResult = [System.UInt32]267011; LastRunTime = $global:FsHaTaskLastRunTime }
    }
    Complete-ScheduledMutation -Result ([System.UInt32]$global:FsHaTaskResult)
    [PSCustomObject]@{ LastTaskResult = [System.UInt32]$global:FsHaTaskResult; LastRunTime = $global:FsHaTaskLastRunTime }
  }
  Function Stop-ScheduledTask {
    Param ([System.String]$TaskName)
    $global:FsHaTaskStops += $TaskName
    If ($global:FsHaTaskStopFails) { Throw 'injected stop failure' }
    If ($global:FsHaTaskStopLeavesRunning) { Return }
    $global:FsHaTaskState = 'Ready'
  }
  Function Unregister-ScheduledTask {
    Param ([System.String]$TaskName, [Switch]$Confirm)
    $global:FsHaTaskUnregistrations += $TaskName
    If ($global:FsHaTaskUnregisterFails) { Throw 'injected unregister failure' }
    $global:FsHaTaskExists = $False
  }
  Function Remove-Item {
    [CmdletBinding()]
    Param (
      [System.String]$LiteralPath,
      [System.String]$Path,
      [Switch]$Force,
      [Switch]$Recurse
    )
    $SelectedPath = If ($PSBoundParameters.ContainsKey('LiteralPath')) { $LiteralPath } Else { $Path }
    If ($global:FsHaTranscriptRemoveFails -and $SelectedPath -eq $global:FsHaTranscriptPath) {
      $global:FsHaTranscriptRemoveAttempts++
      Write-Error -Message 'injected transcript removal failure'
      Return
    }
    If ($global:FsHaTranscriptRemoveLeavesFile -and $SelectedPath -eq $global:FsHaTranscriptPath) {
      $global:FsHaTranscriptRemoveAttempts++
      Return
    }
    Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
  }
  Function Start-Sleep {
    [CmdletBinding()]
    Param ([System.Double]$Seconds, [System.Int32]$Milliseconds)
    If ($global:FsHaSkipSleep) { Return }
    Microsoft.PowerShell.Utility\Start-Sleep @PSBoundParameters
  }
  Function Invoke-MutationInnerCommand {
    Param (
      [System.String]$Command,
      [System.Int32]$PreScreenDeadlineSeconds = 300,
      [System.Int32]$PreScreenIntervalSeconds = 0
    )
    $PayloadMatches = [System.Text.RegularExpressions.Regex]::Matches($Command, "FromBase64String\('(?<Payload>[A-Za-z0-9+/=]+)'\)")
    If ($PayloadMatches.Count -ne 2) { Throw 'Encoded mutation command did not contain exactly two payloads.' }
    $TranscriptPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PayloadMatches[1].Groups['Payload'].Value))
    $ExecutableCommand = $Command.
      Replace('$PreScreenDeadlineSeconds = 300', ('$PreScreenDeadlineSeconds = {0}' -f $PreScreenDeadlineSeconds)).
      Replace('$PreScreenIntervalSeconds = 15', ('$PreScreenIntervalSeconds = {0}' -f $PreScreenIntervalSeconds)).
      Replace('Exit $ExitCode', 'Write-Output -InputObject $ExitCode')
    Try {
      $Output = @(& ([System.Management.Automation.ScriptBlock]::Create($ExecutableCommand)))
      If ($Output.Count -eq 0) { Throw 'Cluster mutation inner command returned no terminal exit code.' }
      [PSCustomObject]@{
        exit_code  = [System.Int32]$Output[-1]
        transcript = [System.String](Get-Content -LiteralPath $TranscriptPath -Raw)
      }
    } Finally {
      Remove-Item -LiteralPath $TranscriptPath -Force -ErrorAction SilentlyContinue
    }
  }

  Function New-FormationInnerCommand {
    $global:FsHaClusterPresent = $False
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null
    $Command = $global:FsHaInnerCommand
    $global:FsHaClusterPresent = $False
    $global:FsHaClusterWrites = @()
    $global:FsHaFormationProbeCalls = @()
    $global:FsHaFormationOperations = @()
    $Command
  }
}

AfterAll {
  $env:TEMP = $script:OriginalTemp
  Remove-Variable -Name 'SetFileServerClusterGetCurrentIdentityName', 'SetFileServerClusterReadTranscriptTail', 'SetFileServerClusterFindPrestageComputerObject', 'SetFileServerClusterGetClusterCoreState', 'SetFileServerClusterGetLocalMembershipStatus', 'FsHaObjectBearingError', 'FsHaLocalMembershipStatus', 'FsHaClusterCoreStateReads', 'FsHaClusterPresent', 'FsHaClusterName', 'FsHaClusterObject', 'FsHaClusterReads', 'FsHaClusterNodes', 'FsHaClusterAddresses', 'FsHaClusterPhysicalDisks', 'FsHaClusterAutoAddDisk', 'FsHaDownNode', 'FsHaClusterWrites', 'FsHaClusterFrozen', 'FsHaMutationWritesError', 'FsHaEligibleDiskReads', 'FsHaInnerCommand', 'FsHaScheduledMutation', 'FsHaTranscriptPath', 'FsHaTranscriptSeedOnStart', 'FsHaTranscriptRemoveFails', 'FsHaTranscriptRemoveLeavesFile', 'FsHaTranscriptRemoveAttempts', 'FsHaTaskRegistrations', 'FsHaTaskStarts', 'FsHaTaskReads', 'FsHaTaskResult', 'FsHaTaskUnregistrations', 'FsHaTaskExists', 'FsHaTaskState', 'FsHaTaskRegistrationVisible', 'FsHaTaskLastRunTime', 'FsHaTaskCompleted', 'FsHaTaskInfoReads', 'FsHaTaskInfoSequence', 'FsHaTaskStops', 'FsHaTaskStopFails', 'FsHaTaskStopLeavesRunning', 'FsHaTaskUnregisterFails', 'FsHaSkipSleep', 'FsHaFormationProbeCalls', 'FsHaFormationProbeFailures', 'FsHaFormationServiceStates', 'FsHaFormationOperations', 'FsHaDirectoryCalls', 'FsHaDirectoryFactoryArguments', 'FsHaDirectoryReadbacks', 'FsHaDirectoryCommits', 'FsHaDirectoryUserAccountControl', 'FsHaDirectoryLookupFailure', 'FsHaDirectoryCommitFailure', 'FsHaDirectoryReadbackMismatch' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-FileServerCluster' {
  BeforeEach {
    Remove-Variable -Name 'SetFileServerClusterGetClusterCoreState' -Scope Global -ErrorAction SilentlyContinue
    $global:SetFileServerClusterGetLocalMembershipStatus = $script:GetLocalMembershipStatus
    Set-LocalMembershipStatus -Status 'member-running' -ServiceStatus 'Running' -ClusDbPresent $True -StartType 'Automatic'
    $global:FsHaClusterCoreStateReads = 0
    $global:FsHaClusterPresent = $True
    $global:FsHaClusterName = 'TCNAW-FSCL01'
    $global:FsHaClusterObject = $Null
    $global:FsHaClusterReads = @()
    $global:FsHaClusterNodes = @($script:Nodes)
    $global:FsHaClusterAddresses = @($script:Addresses)
    $global:FsHaClusterPhysicalDisks = @()
    $global:FsHaClusterAutoAddDisk = $False
    $global:FsHaDownNode = ''
    $global:FsHaClusterWrites = @()
    $global:FsHaClusterFrozen = $False
    $global:FsHaMutationWritesError = $False
    $global:FsHaEligibleDiskReads = 0
    $global:FsHaInnerCommand = ''
    $global:FsHaScheduledMutation = $Null
    $global:FsHaTranscriptPath = ''
    $global:FsHaTranscriptSeedOnStart = $False
    $global:FsHaTranscriptRemoveFails = $False
    $global:FsHaTranscriptRemoveLeavesFile = $False
    $global:FsHaTranscriptRemoveAttempts = 0
    $global:FsHaTaskRegistrations = @()
    $global:FsHaTaskStarts = @()
    $global:FsHaTaskReads = 0
    $global:FsHaTaskResult = 0
    $global:FsHaTaskUnregistrations = @()
    $global:FsHaTaskExists = $False
    $global:FsHaTaskState = 'Ready'
    $global:FsHaTaskRegistrationVisible = $True
    $global:FsHaTaskLastRunTime = [System.DateTime]'2000-01-01T00:00:00Z'
    $global:FsHaTaskCompleted = $False
    $global:FsHaTaskInfoReads = 0
    $global:FsHaTaskInfoSequence = @()
    $global:FsHaTaskStops = @()
    $global:FsHaTaskStopFails = $False
    $global:FsHaTaskStopLeavesRunning = $False
    $global:FsHaTaskUnregisterFails = $False
    $global:FsHaSkipSleep = $False
    $global:FsHaFormationProbeCalls = @()
    $global:FsHaFormationProbeFailures = @{}
    $global:FsHaFormationServiceStates = @{}
    ForEach ($ClusterNodeName In $script:Nodes) {
      $global:FsHaFormationServiceStates[$ClusterNodeName] = @('Stopped')
    }
    $global:FsHaFormationOperations = @()
    $global:FsHaDirectoryCalls = @()
    $global:FsHaDirectoryFactoryArguments = @()
    $global:FsHaDirectoryReadbacks = @()
    $global:FsHaDirectoryCommits = @()
    $global:FsHaDirectoryUserAccountControl = @{
      'TCNAW-FSCL01' = [System.Int32]4098
    }
    $global:FsHaDirectoryLookupFailure = ''
    $global:FsHaDirectoryCommitFailure = ''
    $global:FsHaDirectoryReadbackMismatch = ''
  }
  AfterEach {
    Remove-AnsibleContext
    If (-not [System.String]::IsNullOrWhiteSpace($global:FsHaTranscriptPath) -and
      (Test-Path -LiteralPath $global:FsHaTranscriptPath)) {
      Microsoft.PowerShell.Management\Remove-Item -LiteralPath $global:FsHaTranscriptPath -Force -ErrorAction SilentlyContinue
    }
  }

  It 'returns standalone exact no-change state with no calls' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:FsHaClusterWrites | Should -HaveCount 0
    @($global:FsHaClusterReads | Where-Object NameBound) | Should -HaveCount 0
  }

  It 'honors standalone WhatIf for drift without cluster writes' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password -WhatIf | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.check_mode | Should -BeTrue
    $global:FsHaClusterWrites | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
    $global:FsHaClusterNodes | Should -Be $script:Nodes[0..2]
  }

  It 'exports only serialization-safe primitive result leaves' {
    $RawCluster = [System.IO.MemoryStream]::new()
    $RawDisk = [System.IO.MemoryStream]::new()
    Try {
      $RawCluster | Add-Member -NotePropertyName Name -NotePropertyValue 'TCNAW-FSCL01'
      $RawDisk | Add-Member -NotePropertyName Name -NotePropertyValue 'Cluster Disk 9'
      $RawDisk | Add-Member -NotePropertyName ResourceType -NotePropertyValue 'Physical Disk'
      $RawDisk | Add-Member -NotePropertyName OwnerGroup -NotePropertyValue 'Available Storage'
      $global:FsHaClusterObject = $RawCluster
      $global:FsHaClusterPhysicalDisks = @($RawDisk)
      $Context = New-AnsibleContext

      $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password

      $Output | Should -BeNullOrEmpty
      { $Context.Result | ConvertTo-Json -Depth 6 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $Context.Result } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $RawCluster } | Should -Throw '*System.IO.MemoryStream*'
      $Context.Result.before.physical_disk_names | Should -Be @('Cluster Disk 9')
    } Finally {
      $RawDisk.Dispose()
      $RawCluster.Dispose()
    }
  }

  It 'rethrows an object-bearing main error as a serialization-safe string' {
    $LiveTarget = [System.IO.MemoryStream]::new()
    Try {
      $InnerException = [System.InvalidOperationException]::new('inner formation message')
      $OuterException = [System.Exception]::new('outer formation message', $InnerException)
      $global:FsHaObjectBearingError = [System.Management.Automation.ErrorRecord]::new(
        $OuterException,
        'ObjectBearingFormationFailure',
        [System.Management.Automation.ErrorCategory]::InvalidOperation,
        $LiveTarget
      )
      $global:SetFileServerClusterGetLocalMembershipStatus = { Throw $global:FsHaObjectBearingError }
      $RethrownError = $Null

      Try {
        & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password
      } Catch {
        $RethrownError = $PSItem
      }

      $RethrownError.Exception.Message | Should -BeOfType ([System.String])
      $RethrownError.Exception.Message | Should -Match 'outer formation message'
      $RethrownError.Exception.Message | Should -Match 'inner formation message'
      $RethrownError.TargetObject | Should -BeOfType ([System.String])
      $RethrownError.Exception.InnerException | Should -BeNullOrEmpty
      $SafeFailure = [PSCustomObject]@{
        message         = $RethrownError.Exception.Message
        target_object   = $RethrownError.TargetObject
        inner_exception = $RethrownError.Exception.InnerException
        error_details   = $RethrownError.ErrorDetails
      }
      { Assert-ResultPrimitiveLeaves -Value $SafeFailure } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $LiveTarget } | Should -Throw '*System.IO.MemoryStream*'
    } Finally {
      $LiveTarget.Dispose()
    }
  }

  It 'creates an absent cluster with exact arguments and no storage' {
    $global:FsHaClusterPresent = $False
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | ConvertFrom-Json
    $Result.changed | Should -BeTrue
    $global:FsHaClusterWrites | Should -HaveCount 1
    $global:FsHaClusterWrites[0].Command | Should -Be 'New'
    $global:FsHaClusterWrites[0].Node | Should -Be $script:Nodes
    $global:FsHaClusterWrites[0].StaticAddress | Should -Be $script:Addresses
    $global:FsHaClusterWrites[0].NoStorage | Should -BeTrue
    $global:FsHaClusterWrites[0].Force | Should -BeTrue
    $Result.after.physical_disk_names | Should -HaveCount 0
    $global:FsHaEligibleDiskReads | Should -Be 0
    $global:FsHaTaskRegistrations | Should -HaveCount 1
    $global:FsHaTaskRegistrations[0].User | Should -Be 'TCN\svc-fscluster-mgr'
    $global:FsHaTaskRegistrations[0].PasswordMatches | Should -BeTrue
    $global:FsHaTaskRegistrations[0].RunLevel | Should -Be 'Highest'
    $global:FsHaTaskRegistrations[0].Force | Should -BeTrue
    $global:FsHaTaskUnregistrations | Should -HaveCount 1
    $global:FsHaInnerCommand | Should -Not -Match ([System.Text.RegularExpressions.Regex]::Escape($script:Password))
    ($Result | ConvertTo-Json -Depth 9) | Should -Not -Match ([System.Text.RegularExpressions.Regex]::Escape($script:Password))
    $global:FsHaMutationWritesError = $True
    $InnerResult = Invoke-MutationInnerCommand -Command $global:FsHaInnerCommand
    $InnerResult.exit_code | Should -Be 0
    $InnerResult.transcript | Should -Not -Match 'simulated non-terminating New-Cluster DNS registration error'
    $global:FsHaClusterPresent = $False
    $global:FsHaClusterFrozen = $True
    $InnerResult = Invoke-MutationInnerCommand -Command $global:FsHaInnerCommand
    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match 'simulated non-terminating New-Cluster DNS registration error'
    $InnerResult.transcript | Should -Not -Match 'New-Cluster -Name \$Mutation\.cluster_name'
  }

  It 'disables an enabled prestaged CNO before New-Cluster and reports the change' {
    $global:FsHaClusterPresent = $False
    $global:FsHaDirectoryUserAccountControl['TCNAW-FSCL01'] = [System.Int32]4096
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.actions | Should -Contain 'disable_prestaged_computer:TCNAW-FSCL01'
    $Result.actions | Should -Contain 'create_cluster'
    ([System.Int32]$global:FsHaDirectoryUserAccountControl['TCNAW-FSCL01'] -band 2) | Should -Be 2
    $global:FsHaDirectoryCommits | Should -Be @('TCNAW-FSCL01')
    [System.Array]::IndexOf($global:FsHaFormationOperations, 'DirectoryWrite:TCNAW-FSCL01') |
      Should -BeLessThan ([System.Array]::IndexOf($global:FsHaFormationOperations, 'New'))
  }

  It 'performs zero directory calls when Get-Cluster returns the existing cluster' {
    Set-LocalMembershipStatus -Status 'member-running' -ServiceStatus 'Running' -ClusDbPresent $True -StartType 'Automatic'

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $global:FsHaClusterReads | Should -HaveCount 1
    $global:FsHaDirectoryCalls | Should -HaveCount 0
    $global:FsHaDirectoryCommits | Should -HaveCount 0
  }

  It 'names the prestaged object when its disable fails' {
    $global:FsHaClusterPresent = $False
    $global:FsHaDirectoryUserAccountControl['TCNAW-FSCL01'] = [System.Int32]4096
    $global:FsHaDirectoryCommitFailure = 'TCNAW-FSCL01'
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*Prestage computer object TCNAW-FSCL01 disable failed:*injected directory commit failure*'
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'fails when userAccountControl readback lacks the disable bit' {
    $global:FsHaClusterPresent = $False
    $global:FsHaDirectoryUserAccountControl['TCNAW-FSCL01'] = [System.Int32]4096
    $global:FsHaDirectoryReadbackMismatch = 'TCNAW-FSCL01'
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*Prestage computer object TCNAW-FSCL01 disable failed:*userAccountControl readback 4096 does not contain the ACCOUNTDISABLE bit*'
    $global:FsHaDirectoryReadbacks | Should -Be @('TCNAW-FSCL01', 'TCNAW-FSCL01')
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'predicts enabled-CNO disablement in check mode without directory or cluster writes' {
    $global:FsHaClusterPresent = $False
    $global:FsHaDirectoryUserAccountControl['TCNAW-FSCL01'] = [System.Int32]4096
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $Context = New-AnsibleContext -CheckMode

    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null

    $Context.Changed | Should -BeTrue
    $Context.Result.actions | Should -Be @('disable_prestaged_computer:TCNAW-FSCL01', 'create_cluster')
    $global:FsHaDirectoryCommits | Should -HaveCount 0
    $global:FsHaClusterWrites | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'binds the prestage directory factory with explicit credentials in check mode without writes' {
    $global:FsHaClusterPresent = $False
    $global:FsHaDirectoryUserAccountControl['TCNAW-FSCL01'] = [System.Int32]4096
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $Context = New-AnsibleContext -CheckMode
    $ExpectedAuthenticationType = [System.DirectoryServices.AuthenticationTypes]::Secure -bor
    [System.DirectoryServices.AuthenticationTypes]::Sealing -bor
    [System.DirectoryServices.AuthenticationTypes]::Signing

    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null

    $global:FsHaDirectoryFactoryArguments | Should -HaveCount 1
    $FactoryArguments = $global:FsHaDirectoryFactoryArguments[0]
    $FactoryArguments.IdentityName | Should -Be 'TCN\svc-fscluster-mgr'
    ($FactoryArguments.Password -ceq $script:Password) | Should -BeTrue
    [System.Int32]$FactoryArguments.AuthenticationType | Should -Be ([System.Int32]$ExpectedAuthenticationType)
    $Context.Result.actions | Should -Be @('disable_prestaged_computer:TCNAW-FSCL01', 'create_cluster')
    $global:FsHaDirectoryCommits | Should -HaveCount 0
    $global:FsHaClusterWrites | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'probes every prospective node over WMI for stopped ClusSvc before formation' {
    $InnerCommand = New-FormationInnerCommand

    $InnerResult = Invoke-MutationInnerCommand -Command $InnerCommand

    $InnerResult.exit_code | Should -Be 0
    $InnerCommand | Should -Match '\$PreScreenDeadlineSeconds = 300'
    $InnerCommand | Should -Match '\$PreScreenIntervalSeconds = 15'
    $global:FsHaFormationProbeCalls | Should -HaveCount $script:Nodes.Count
    @($global:FsHaFormationProbeCalls | ForEach-Object -Process { $PSItem.ComputerName }) | Should -Be $script:Nodes
    @($global:FsHaFormationProbeCalls | ForEach-Object -Process { $PSItem.Class }) | Select-Object -Unique | Should -Be 'Win32_Service'
    @($global:FsHaFormationProbeCalls | ForEach-Object -Process { $PSItem.Filter }) | Select-Object -Unique | Should -Be "Name='ClusSvc'"
    @($global:FsHaFormationProbeCalls | ForEach-Object -Process { $PSItem.ErrorAction }) | Select-Object -Unique | Should -Be 'Stop'
    $global:FsHaFormationOperations | Should -Be @(
      @($script:Nodes | ForEach-Object -Process { 'Probe:{0}' -f $PSItem }) + 'New'
    )
  }

  It 'retries a prospective node that becomes ready and then forms the cluster' {
    $ColdNode = $script:Nodes[1]
    $InnerCommand = New-FormationInnerCommand
    $global:FsHaFormationProbeFailures[$ColdNode] = 1

    $InnerResult = Invoke-MutationInnerCommand -Command $InnerCommand -PreScreenDeadlineSeconds 10 -PreScreenIntervalSeconds 0

    $InnerResult.exit_code | Should -Be 0
    $global:FsHaFormationProbeCalls | Should -HaveCount 8
    @($global:FsHaFormationProbeCalls | ForEach-Object -Process { $PSItem.ComputerName }) | Should -Be @($script:Nodes + $script:Nodes)
    $global:FsHaClusterWrites | Should -HaveCount 1
    @($global:FsHaClusterWrites | ForEach-Object -Process { $PSItem.Command }) | Should -Be @('New')
    $global:FsHaFormationOperations | Should -HaveCount 9
    $global:FsHaFormationOperations[-1] | Should -Be 'New'
  }

  It 'blocks formation and names a prospective node that never becomes ready' {
    $ColdNode = $script:Nodes[2]
    $InnerCommand = New-FormationInnerCommand
    $global:FsHaFormationServiceStates[$ColdNode] = @('Running')

    $InnerResult = Invoke-MutationInnerCommand -Command $InnerCommand -PreScreenDeadlineSeconds 0 -PreScreenIntervalSeconds 0

    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match ([System.Text.RegularExpressions.Regex]::Escape($ColdNode))
    $InnerResult.transcript | Should -Match 'last error: ClusSvc state is Running; expected Stopped'
    @($global:FsHaClusterWrites | Where-Object -FilterScript { $Null -ne $PSItem -and $PSItem.Command -eq 'New' }) | Should -HaveCount 0
    $global:FsHaFormationOperations | Should -Not -Contain 'New'
  }

  It 'converges a running member acquired by bare local cluster lookup' {
    Set-LocalMembershipStatus -Status 'member-running' -ServiceStatus 'Running' -ClusDbPresent $True -StartType 'Automatic'

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $global:FsHaClusterReads | Should -HaveCount 1
    $global:FsHaClusterReads[0].NameBound | Should -BeFalse
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'rejects a stopped member proven by CLUSDB' {
    Set-LocalMembershipStatus -Status 'stopped-member' -ServiceStatus 'Stopped' -ClusDbPresent $True -StartType 'Manual'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*ClusSvc is stopped*CLUSDB present = True*StartType = Manual*Starting ClusSvc or evicting the node is an operator decision*'
    $global:FsHaClusterReads | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'rejects a stopped member proven by Automatic service start' {
    Set-LocalMembershipStatus -Status 'stopped-member' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Automatic'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*ClusSvc is stopped*CLUSDB present = False*StartType = Automatic*Starting ClusSvc or evicting the node is an operator decision*'
    $global:FsHaClusterReads | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'selects creation for a stopped node with no CLUSDB and non-Automatic start' {
    $global:FsHaClusterPresent = $False
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $Context = New-AnsibleContext -CheckMode

    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null

    $Context.Result.actions | Should -Be @('create_cluster')
    $global:FsHaClusterReads | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'rejects an absent ClusSvc as a deployment lifecycle violation' {
    $global:SetFileServerClusterGetLocalMembershipStatus = {
      Throw 'ClusSvc is absent after failover clustering should have been installed; the deployment lifecycle was violated.'
    }

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*ClusSvc is absent*lifecycle was violated*'
    $global:FsHaClusterReads | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'fails formation readback when New-Cluster auto-adds storage' {
    $global:FsHaClusterPresent = $False
    $global:FsHaClusterAutoAddDisk = $True
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*auto-added Physical Disk*'
  }

  It 'does not confuse later declared storage with formation-time auto-add' {
    $global:FsHaClusterPhysicalDisks = @(
      [PSCustomObject]@{
        Name = 'Cluster Disk 9'; ResourceType = 'Physical Disk'; OwnerGroup = 'Available Storage'
      }
    )

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'repairs one missing node with only Add-ClusterNode' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null
    $global:FsHaClusterWrites | Should -HaveCount 1
    $global:FsHaClusterWrites[0].Command | Should -Be 'Add'
    $global:FsHaClusterWrites[0].Name | Should -Be 'tcnaw-hafs02b'
    $global:FsHaClusterWrites[0].NoStorage | Should -BeTrue
    $global:FsHaInnerCommand | Should -Match '\$Clusters = @\(Get-Cluster\)'
    $global:FsHaInnerCommand | Should -Not -Match 'Get-Cluster -Name'
    $global:FsHaInnerCommand | Should -Match 'Add-ClusterNode -InputObject \$Cluster'
    $global:FsHaInnerCommand | Should -Not -Match 'Add-ClusterNode -Cluster'
  }

  It 'fails cluster reacquisition after the bounded deadline' {
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $global:SetFileServerClusterGetClusterCoreState = {
      $global:FsHaClusterCoreStateReads++
      $Null
    }

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password -ReacquireTimeoutSeconds 1 } |
      Should -Throw '*not reacquired after mutation. Waited 1 seconds.*'
    $global:FsHaClusterCoreStateReads | Should -BeGreaterThan 1
  }

  It 'accepts a cluster that appears during the reacquisition window' {
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $global:SetFileServerClusterGetClusterCoreState = {
      $global:FsHaClusterCoreStateReads++
      If ($global:FsHaClusterCoreStateReads -le 1) { Return $Null }
      [PSCustomObject]@{
        cluster        = [PSCustomObject]@{ Name = 'TCNAW-FSCL01' }
        name           = 'TCNAW-FSCL01'
        nodes          = @($global:FsHaClusterNodes | ForEach-Object -Process { [PSCustomObject]@{ name = $PSItem; state = 'Up' } })
        addresses      = @($global:FsHaClusterAddresses)
        physical_disks = @()
      }
    }

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password -ReacquireTimeoutSeconds 10 | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $global:FsHaClusterCoreStateReads | Should -Be 2
  }

  It 'fails an add-node readback that did not land' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])
    $global:FsHaClusterFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } | Should -Throw '*failed exact*'
    $global:FsHaMutationWritesError = $True
    $InnerResult = Invoke-MutationInnerCommand -Command $global:FsHaInnerCommand
    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match ('left nodes missing: {0}' -f $script:Nodes[3])
    $InnerResult.transcript | Should -Match 'simulated non-terminating Add-ClusterNode membership error'
    $InnerResult.transcript | Should -Not -Match 'Add-ClusterNode -InputObject \$Cluster'
  }

  It 'predicts absent-cluster check mode with zero writes' {
    $global:FsHaClusterPresent = $False
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null
    $Context.Changed | Should -BeTrue
    $Context.Result.actions | Should -Be @('create_cluster')
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'predicts missing-node check mode with zero writes' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null
    $Context.Changed | Should -BeTrue
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'rejects a present but differently named local cluster without creating' {
    $global:FsHaClusterName = 'OTHER'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } | Should -Throw '*differently named*'
    $global:FsHaClusterWrites | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'rejects duplicate desired nodes and addresses' {
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node @('a', 'a') -StaticAddress $script:Addresses -Password $script:Password } | Should -Throw '*Node must contain*'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress @('10.0.1.11', '10.0.1.11') -Password $script:Password } | Should -Throw '*StaticAddress must contain*'
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'rejects an unexpected existing node' {
    $global:FsHaClusterNodes += 'intruder'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } | Should -Throw '*unexpected nodes*'
  }

  It 'rejects a wrong existing core address set' {
    $global:FsHaClusterAddresses[3] = '10.0.99.11'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } | Should -Throw '*address identity*'
  }

  It 'fails when a declared node remains Down' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])
    $global:FsHaDownNode = 'tcnaw-hafs02b'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } | Should -Throw '*failed exact*'
  }

  It 'fails an existing Down node without writes' {
    $global:FsHaDownNode = 'tcnaw-hafs02b'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } | Should -Throw '*failed exact*'
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'sets Ansible Changed false from an initially true context' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null
    $Context.Changed | Should -BeFalse
  }

  It 'requires exactly one scheduled task registration readback before start' {
    $global:FsHaClusterPresent = $False
    $global:FsHaTaskRegistrationVisible = $False
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    $Caught = $Null
    Try {
      & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password
    } Catch {
      $Caught = $PSItem
    }

    $Caught.Exception.Message | Should -Match '^Scheduled task registration readback must return exactly one task; found 0\.'
    $Caught.Exception.Message | Should -Match 'Cleanup failures: task-readback .*cleanup readback must return exactly one task; found 0\.'
    $global:FsHaTaskStarts | Should -HaveCount 0
    $global:FsHaTaskReads | Should -Be 2
    $global:FsHaTaskUnregistrations | Should -HaveCount 0
  }

  It 'waits through stale runtime data and every documented pending result' {
    $global:FsHaClusterPresent = $False
    $global:FsHaSkipSleep = $True
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $Old = [System.DateTime]'2000-01-01T00:00:00Z'
    $New = [System.DateTime]'2000-01-01T00:00:01Z'
    $global:FsHaTaskInfoSequence = @(
      [PSCustomObject]@{ LastRunTime = $Old; LastTaskResult = [System.UInt32]267011 },
      [PSCustomObject]@{ LastRunTime = $Old; LastTaskResult = [System.UInt32]0 },
      [PSCustomObject]@{ LastRunTime = $New; LastTaskResult = [System.UInt32]267011 },
      [PSCustomObject]@{ LastRunTime = $New; LastTaskResult = [System.UInt32]267045 },
      [PSCustomObject]@{ LastRunTime = $New; LastTaskResult = [System.UInt32]267009 },
      [PSCustomObject]@{ LastRunTime = $New; LastTaskResult = [System.UInt32]0 }
    )

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Not -Throw

    $global:FsHaTaskInfoReads | Should -Be 6
    $global:FsHaTaskUnregistrations | Should -HaveCount 1
  }

  It 'suppresses unregister after a scheduled task stop failure' {
    $global:FsHaClusterPresent = $False
    $global:FsHaTranscriptSeedOnStart = $True
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $global:FsHaTaskInfoSequence = @(
      [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:00Z'; LastTaskResult = [System.UInt32]267011 },
      $Null
    )
    $global:FsHaTaskStopFails = $True
    $Caught = $Null

    Try {
      & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password
    } Catch {
      $Caught = $PSItem
    }

    $Caught.Exception.Message | Should -Match '^Scheduled task runtime-info poll must return one object with LastRunTime and LastTaskResult\.'
    $Caught.Exception.Message | Should -Match 'Cleanup failures: stop-if-running .*injected stop failure'
    $global:FsHaTaskStops | Should -HaveCount 1
    $global:FsHaTaskReads | Should -Be 2
    $global:FsHaTaskUnregistrations | Should -HaveCount 0
    Test-Path -LiteralPath $global:FsHaTranscriptPath | Should -BeFalse
  }

  It 'suppresses unregister when a stopped task still reads Running' {
    $global:FsHaClusterPresent = $False
    $global:FsHaTranscriptSeedOnStart = $True
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $global:FsHaTaskInfoSequence = @(
      [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:00Z'; LastTaskResult = [System.UInt32]267011 },
      $Null
    )
    $global:FsHaTaskStopLeavesRunning = $True
    $Caught = $Null

    Try {
      & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password
    } Catch {
      $Caught = $PSItem
    }

    $Caught.Exception.Message | Should -Match '^Scheduled task runtime-info poll must return one object with LastRunTime and LastTaskResult\.'
    $Caught.Exception.Message | Should -Match 'Cleanup failures: post-stop-state .*scheduled task is still Running\.'
    $global:FsHaTaskStops | Should -HaveCount 1
    $global:FsHaTaskReads | Should -Be 3
    $global:FsHaTaskUnregistrations | Should -HaveCount 0
    Test-Path -LiteralPath $global:FsHaTranscriptPath | Should -BeFalse
  }

  It 'permits unregister after a successful stop and aggregates its failure independently' {
    $global:FsHaClusterPresent = $False
    $global:FsHaTranscriptSeedOnStart = $True
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $global:FsHaTaskInfoSequence = @(
      [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:00Z'; LastTaskResult = [System.UInt32]267011 },
      $Null
    )
    $global:FsHaTaskUnregisterFails = $True
    $Caught = $Null

    Try {
      & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password
    } Catch {
      $Caught = $PSItem
    }

    $Caught.Exception.Message | Should -Match '^Scheduled task runtime-info poll must return one object with LastRunTime and LastTaskResult\.'
    $Caught.Exception.Message | Should -Match 'Cleanup failures: unregister .*injected unregister failure'
    $global:FsHaTaskStops | Should -HaveCount 1
    $global:FsHaTaskReads | Should -Be 3
    $global:FsHaTaskUnregistrations | Should -HaveCount 1
    Test-Path -LiteralPath $global:FsHaTranscriptPath | Should -BeFalse
  }

  It 'reports transcript removal failure after successful mutation and readback' {
    $global:FsHaClusterPresent = $False
    $global:FsHaTranscriptRemoveFails = $True
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*cleanup failed*transcript*injected transcript removal failure*'

    $global:FsHaTranscriptRemoveAttempts | Should -Be 1
    Test-Path -LiteralPath $global:FsHaTranscriptPath | Should -BeTrue
    $global:FsHaTaskUnregistrations | Should -HaveCount 1
  }

  It 'reports a transcript that still exists after successful removal' {
    $global:FsHaClusterPresent = $False
    $global:FsHaTranscriptRemoveLeavesFile = $True
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*transcript*still exists after removal*'

    $global:FsHaTranscriptRemoveAttempts | Should -Be 1
    Test-Path -LiteralPath $global:FsHaTranscriptPath | Should -BeTrue
    $global:FsHaTaskUnregistrations | Should -HaveCount 1
  }

  It 'surfaces a failed batch mutation transcript and unregisters the task' {
    $global:FsHaClusterPresent = $False
    $global:FsHaTaskResult = 1
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*scheduled task result 1*terminating mutation proof*'
    $global:FsHaTaskUnregistrations | Should -HaveCount 1
  }
}
