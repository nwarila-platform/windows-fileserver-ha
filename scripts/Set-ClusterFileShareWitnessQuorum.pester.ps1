#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusterFileShareWitnessQuorum.ps1'
  $script:Common = @{
    ClusterName = 'TCNAW-FSCL01'
    WitnessPath = '\\tcnaw-witnes01c\witness$'
  }

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null
    }
    $global:Ansible
  }
  Function Remove-AnsibleContext {
    Remove-Variable -Name Ansible -Scope Global -Force -ErrorAction SilentlyContinue
  }
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
  Function New-FakeResource {
    [PSCustomObject]@{
      Name = 'File Share Witness'
      ResourceType = $global:FsQuorumResourceType
      State = $global:FsQuorumResourceState
    }
  }
  Function Get-Cluster {
    [CmdletBinding()]
    Param ()
    @($global:FsQuorumClusters)
  }
  Function Get-ClusterQuorum {
    Param ([System.Object]$InputObject)
    If ($Null -eq $global:FsQuorumResourceType) {
      Return [PSCustomObject]@{
        Cluster = $InputObject; QuorumResource = $Null; QuorumType = $global:FsQuorumType
      }
    }
    [PSCustomObject]@{
      Cluster = $InputObject; QuorumResource = New-FakeResource; QuorumType = $global:FsQuorumType
    }
  }
  Function Get-ClusterParameter {
    Param ([System.Object]$InputObject, [System.String]$Name)
    If ($global:FsQuorumSharePathCount -eq 0) { Return }
    For ($Index = 0; $Index -lt $global:FsQuorumSharePathCount; $Index++) {
      [PSCustomObject]@{ Name = 'SharePath'; Value = $global:FsQuorumSharePath }
    }
  }
  Function Set-ClusterQuorum {
    Param ([System.Object]$InputObject, [System.String]$FileShareWitness)
    $global:FsQuorumWrites += [PSCustomObject]@{
      Cluster = [System.String]$InputObject.Name; FileShareWitness = $FileShareWitness
    }
    If (-not $global:FsQuorumFrozen) {
      $global:FsQuorumType = 'Majority'
      $global:FsQuorumResourceType = 'File Share Witness'
      $global:FsQuorumResourceState = 'Online'
      $global:FsQuorumSharePath = $FileShareWitness
      $global:FsQuorumSharePathCount = 1
    }
  }
}

AfterAll {
  Remove-Variable -Name 'FsQuorumClusters', 'FsQuorumType', 'FsQuorumResourceType',
  'FsQuorumResourceState', 'FsQuorumSharePath', 'FsQuorumSharePathCount',
  'FsQuorumWrites', 'FsQuorumFrozen' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ClusterFileShareWitnessQuorum' {
  BeforeEach {
    $global:FsQuorumClusters = @([PSCustomObject]@{ Name = 'TCNAW-FSCL01' })
    $global:FsQuorumType = 'Majority'
    $global:FsQuorumResourceType = 'File Share Witness'
    $global:FsQuorumResourceState = 'Online'
    $global:FsQuorumSharePath = '\\tcnaw-witnes01c\witness$'
    $global:FsQuorumSharePathCount = 1
    $global:FsQuorumWrites = @()
    $global:FsQuorumFrozen = $False
  }
  AfterEach { Remove-AnsibleContext }

  It 'reports the live-observed Majority file-share witness unchanged' {
    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $Result.before.exact | Should -BeTrue
    $Result.after.quorum_type | Should -Be 'Majority'
    $Result.after.resource_type | Should -Be 'File Share Witness'
    $Result.after.resource_state | Should -Be 'Online'
    $Result.after.share_path | Should -Be '\\tcnaw-witnes01c\witness$'
    $global:FsQuorumWrites | Should -HaveCount 0
  }

  It 'converges Majority with no quorum resource to the declared file-share witness' {
    $global:FsQuorumResourceType = $Null
    $global:FsQuorumResourceState = $Null
    $global:FsQuorumSharePath = $Null
    $global:FsQuorumSharePathCount = 0

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.actions | Should -Be @('set_file_share_witness')
    $global:FsQuorumWrites | Should -HaveCount 1
    $global:FsQuorumWrites[0].Cluster | Should -Be 'TCNAW-FSCL01'
    $global:FsQuorumWrites[0].FileShareWitness | Should -Be '\\tcnaw-witnes01c\witness$'
    $Result.after.quorum_type | Should -Be 'Majority'
    $Result.after.resource_type | Should -Be 'File Share Witness'
    $Result.after.resource_state | Should -Be 'Online'
  }

  It 'repairs a wrong witness path' {
    $global:FsQuorumSharePath = '\\old-host\old$'

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $global:FsQuorumWrites | Should -HaveCount 1
    $Result.after.share_path | Should -Be '\\tcnaw-witnes01c\witness$'
  }

  It 'reapplies quorum when the declared witness resource is offline' {
    $global:FsQuorumResourceState = 'Offline'

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $global:FsQuorumWrites | Should -HaveCount 1
    $Result.after.resource_state | Should -Be 'Online'
  }

  It 'replaces another quorum resource type with the declared file-share witness' {
    $global:FsQuorumResourceType = 'Physical Disk'
    $global:FsQuorumSharePath = $Null
    $global:FsQuorumSharePathCount = 0

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.before.exact | Should -BeFalse
    $Result.before.resource_type | Should -Be 'Physical Disk'
    $Result.actions | Should -Be @('set_file_share_witness')
    $global:FsQuorumWrites | Should -HaveCount 1
    $Result.after.exact | Should -BeTrue
    $Result.after.resource_type | Should -Be 'File Share Witness'
  }

  It 'compares the declared witness path case-insensitively' {
    $global:FsQuorumSharePath = '\\TCNAW-WITNES01C\WITNESS$'

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $Result.before.exact | Should -BeTrue
    $global:FsQuorumWrites | Should -HaveCount 0
  }

  It 'predicts drift in check mode without writes' {
    $global:FsQuorumResourceState = 'Offline'
    $Context = New-AnsibleContext -CheckMode

    & $script:ScriptPath @script:Common | Out-Null

    $Context.Changed | Should -BeTrue
    $Context.Result.actions | Should -Be @('set_file_share_witness')
    $Context.Result.check_mode | Should -BeTrue
    $Context.Result.after.resource_state | Should -Be 'Offline'
    $global:FsQuorumWrites | Should -HaveCount 0
  }

  It 'returns through the Ansible transport without pipeline output' {
    $Context = New-AnsibleContext

    $Output = & $script:ScriptPath @script:Common

    $Output | Should -BeNullOrEmpty
    $Context.Changed | Should -BeFalse
    $Context.Result.after.exact | Should -BeTrue
  }

  It 'requires exactly one matching local cluster' {
    $global:FsQuorumClusters = @([PSCustomObject]@{ Name = 'OTHER' })
    { & $script:ScriptPath @script:Common } | Should -Throw '*found 0*'
    $global:FsQuorumClusters = @(
      [PSCustomObject]@{ Name = 'TCNAW-FSCL01' }
      [PSCustomObject]@{ Name = 'tcnaw-fscl01' }
    )
    { & $script:ScriptPath @script:Common } | Should -Throw '*found 2*'
    $global:FsQuorumWrites | Should -HaveCount 0
  }

  It 'requires exactly one SharePath parameter' {
    $global:FsQuorumSharePathCount = 0
    { & $script:ScriptPath @script:Common } | Should -Throw '*found 0*'
    $global:FsQuorumSharePathCount = 2
    { & $script:ScriptPath @script:Common } | Should -Throw '*found 2*'
    $global:FsQuorumWrites | Should -HaveCount 0
  }

  It 'fails with observed values when the resource is not Online after convergence' {
    $global:FsQuorumResourceState = 'Offline'
    $global:FsQuorumFrozen = $True

    { & $script:ScriptPath @script:Common } | Should -Throw '*Quorum readback failed*observed QuorumType=Majority, ResourceType=File Share Witness, State=Offline, SharePath=\\tcnaw-witnes01c\witness$*'
  }

  It 'exports only serialization-safe primitive result leaves' {
    $Context = New-AnsibleContext

    & $script:ScriptPath @script:Common | Out-Null

    { Assert-ResultPrimitiveLeaves -Value $Context.Result } | Should -Not -Throw
  }

  It 'rejects malformed cluster and witness path parameters' {
    $Bad = @{} + $script:Common
    $Bad.ClusterName = '-bad'
    { & $script:ScriptPath @Bad } | Should -Throw
    $Bad = @{} + $script:Common
    $Bad.WitnessPath = 'C:\ClusterWitness'
    { & $script:ScriptPath @Bad } | Should -Throw
    $Bad.WitnessPath = '\\host\share\nested'
    { & $script:ScriptPath @Bad } | Should -Throw
  }
}
