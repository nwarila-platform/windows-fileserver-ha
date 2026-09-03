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

  $global:SetFileServerClusterFindComputerAccount = {
    Param ([System.String]$SamAccountName)
    $global:FsHaComputerAccountReads += $SamAccountName
    If (-not $global:FsHaComputerAccountPresent) { Return $Null }
    [PSCustomObject]@{
      path                 = 'LDAP://CN=TCNAW-FSCL01,OU=Cluster'
      user_account_control = $global:FsHaComputerAccountControl
    }
  }
  $global:SetFileServerClusterSetComputerAccountControl = {
    Param ([System.String]$Path, [System.Int32]$UserAccountControl)
    $global:FsHaComputerAccountWrites += [PSCustomObject]@{ Path = $Path; UserAccountControl = $UserAccountControl }
    $global:FsHaComputerAccountControl = $UserAccountControl
  }
  $global:SetFileServerClusterGetCurrentIdentityName = { 'TCN\svc-fscluster-mgr' }
  $global:SetFileServerClusterReadTranscriptTail = { 'terminating mutation proof' }
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
  Function New-Cluster {
    [CmdletBinding()]
    Param (
      [System.String]$Name, [System.String[]]$Node, [System.String[]]$StaticAddress,
      [Switch]$NoStorage, [Switch]$Force
    )
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
    If ($InnerCommand -notmatch "FromBase64String\('(?<Payload>[A-Za-z0-9+/=]+)'\)") { Throw 'Mutation payload was not encoded.' }
    $MutationXml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Matches.Payload))
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
  }
  Function Start-ScheduledTask {
    Param ([System.String]$TaskName)
    $global:FsHaTaskStarts += $TaskName
    If ($global:FsHaTaskResult -ne 0) { Return }
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
  Function Get-ScheduledTaskInfo {
    Param ([System.String]$TaskName)
    [PSCustomObject]@{ LastTaskResult = $global:FsHaTaskResult }
  }
  Function Unregister-ScheduledTask {
    Param ([System.String]$TaskName, [Switch]$Confirm)
    $global:FsHaTaskUnregistrations += $TaskName
  }
  Function Invoke-MutationInnerCommand {
    Param ([System.String]$Command)
    $PayloadMatches = [System.Text.RegularExpressions.Regex]::Matches($Command, "FromBase64String\('(?<Payload>[A-Za-z0-9+/=]+)'\)")
    If ($PayloadMatches.Count -ne 2) { Throw 'Encoded mutation command did not contain exactly two payloads.' }
    $TranscriptPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PayloadMatches[1].Groups['Payload'].Value))
    $ExecutableCommand = $Command.Replace('Exit $ExitCode', 'Write-Output -InputObject $ExitCode')
    Try {
      $Output = @(& ([System.Management.Automation.ScriptBlock]::Create($ExecutableCommand)))
      [PSCustomObject]@{
        exit_code  = [System.Int32]$Output[-1]
        transcript = [System.String](Get-Content -LiteralPath $TranscriptPath -Raw)
      }
    } Finally {
      Remove-Item -LiteralPath $TranscriptPath -Force -ErrorAction SilentlyContinue
    }
  }
}

AfterAll {
  $env:TEMP = $script:OriginalTemp
  Remove-Variable -Name 'SetFileServerClusterFindComputerAccount', 'SetFileServerClusterSetComputerAccountControl', 'SetFileServerClusterGetCurrentIdentityName', 'SetFileServerClusterReadTranscriptTail', 'SetFileServerClusterGetClusterCoreState', 'SetFileServerClusterGetLocalMembershipStatus', 'FsHaObjectBearingError', 'FsHaLocalMembershipStatus', 'FsHaClusterCoreStateReads', 'FsHaComputerAccountPresent', 'FsHaComputerAccountControl', 'FsHaComputerAccountReads', 'FsHaComputerAccountWrites', 'FsHaClusterPresent', 'FsHaClusterName', 'FsHaClusterObject', 'FsHaClusterReads', 'FsHaClusterNodes', 'FsHaClusterAddresses', 'FsHaClusterPhysicalDisks', 'FsHaClusterAutoAddDisk', 'FsHaDownNode', 'FsHaClusterWrites', 'FsHaClusterFrozen', 'FsHaMutationWritesError', 'FsHaEligibleDiskReads', 'FsHaInnerCommand', 'FsHaScheduledMutation', 'FsHaTaskRegistrations', 'FsHaTaskStarts', 'FsHaTaskResult', 'FsHaTaskUnregistrations' -Scope Global -ErrorAction SilentlyContinue
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
    $global:FsHaComputerAccountPresent = $True
    $global:FsHaComputerAccountControl = 4096
    $global:FsHaComputerAccountReads = @()
    $global:FsHaComputerAccountWrites = @()
    $global:FsHaInnerCommand = ''
    $global:FsHaScheduledMutation = $Null
    $global:FsHaTaskRegistrations = @()
    $global:FsHaTaskStarts = @()
    $global:FsHaTaskResult = 0
    $global:FsHaTaskUnregistrations = @()
  }
  AfterEach { Remove-AnsibleContext }

  It 'returns standalone exact no-change state with no calls' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:FsHaClusterWrites | Should -HaveCount 0
    $global:FsHaComputerAccountReads | Should -HaveCount 0
    @($global:FsHaClusterReads | Where-Object NameBound) | Should -HaveCount 0
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
    $global:FsHaComputerAccountReads | Should -Be @('TCNAW-FSCL01$')
    $global:FsHaComputerAccountWrites.UserAccountControl | Should -Be @(4098)
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
    $global:FsHaComputerAccountReads | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'rejects a stopped member proven by Automatic service start' {
    Set-LocalMembershipStatus -Status 'stopped-member' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Automatic'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*ClusSvc is stopped*CLUSDB present = False*StartType = Automatic*Starting ClusSvc or evicting the node is an operator decision*'
    $global:FsHaClusterReads | Should -HaveCount 0
    $global:FsHaComputerAccountReads | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'selects creation for a stopped node with no CLUSDB and non-Automatic start' {
    $global:FsHaClusterPresent = $False
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'
    $Context = New-AnsibleContext -CheckMode

    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null

    $Context.Result.actions | Should -Be @('create_cluster')
    $global:FsHaClusterReads | Should -HaveCount 0
    $global:FsHaComputerAccountReads | Should -HaveCount 0
    $global:FsHaTaskRegistrations | Should -HaveCount 0
  }

  It 'rejects an absent ClusSvc as a deployment lifecycle violation' {
    $global:SetFileServerClusterGetLocalMembershipStatus = {
      Throw 'ClusSvc is absent after failover clustering should have been installed; the deployment lifecycle was violated.'
    }

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password } |
      Should -Throw '*ClusSvc is absent*lifecycle was violated*'
    $global:FsHaClusterReads | Should -HaveCount 0
    $global:FsHaComputerAccountReads | Should -HaveCount 0
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
    $global:FsHaComputerAccountReads | Should -HaveCount 0
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
    $global:FsHaComputerAccountReads | Should -HaveCount 0
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
    $global:FsHaComputerAccountReads | Should -HaveCount 0
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

  It 'leaves an already disabled prestaged CNO unchanged on the create path' {
    $global:FsHaClusterPresent = $False
    $global:FsHaComputerAccountControl = 4098
    Set-LocalMembershipStatus -Status 'fresh' -ServiceStatus 'Stopped' -ClusDbPresent $False -StartType 'Manual'

    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses -Password $script:Password | Out-Null

    $global:FsHaComputerAccountReads | Should -Be @('TCNAW-FSCL01$')
    $global:FsHaComputerAccountWrites | Should -HaveCount 0
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
