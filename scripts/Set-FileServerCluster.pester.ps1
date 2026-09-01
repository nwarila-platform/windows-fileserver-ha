#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-FileServerCluster.ps1'
  $script:Nodes = @('tcnaw-hafs01a', 'tcnaw-hafs02a', 'tcnaw-hafs01b', 'tcnaw-hafs02b')
  $script:Addresses = @('10.0.1.11', '10.0.33.11', '10.0.65.11', '10.0.97.11')

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null }
    $global:Ansible
  }
  Function Remove-AnsibleContext { Remove-Variable -Name 'Ansible' -Scope Global -Force -ErrorAction SilentlyContinue }

  Function Get-Cluster {
    Param ([System.String]$Name, [System.String]$ErrorAction)
    If ($PSBoundParameters.ContainsKey('Name')) {
      If (-not $global:FsHaClusterPresent) { Return @() }
      Return [PSCustomObject]@{ Name = $global:FsHaClusterName }
    }
    If ($global:FsHaLocalClusterName) { [PSCustomObject]@{ Name = $global:FsHaLocalClusterName } }
  }
  Function Get-ClusterNode {
    Param ([System.String]$Cluster)
    @($global:FsHaClusterNodes | ForEach-Object -Process {
        [PSCustomObject]@{ Name = $PSItem; State = $(If ($global:FsHaDownNode -eq $PSItem) { 'Down' } Else { 'Up' }) }
      })
  }
  Function Get-ClusterGroup {
    Param ([System.String]$Cluster)
    [PSCustomObject]@{ Name = 'Cluster Group'; GroupType = 'Cluster' }
  }
  Function Get-ClusterResource {
    Param ([System.String]$Cluster)
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
  }
  Function Add-ClusterNode {
    Param ([System.String]$Cluster, [System.String]$Name, [Switch]$NoStorage)
    $global:FsHaClusterWrites += [PSCustomObject]@{ Command = 'Add'; Cluster = $Cluster; Name = $Name; NoStorage = $NoStorage.IsPresent }
    If (-not $global:FsHaClusterFrozen) { $global:FsHaClusterNodes += $Name }
  }
  Function Get-ClusterAvailableDisk { $global:FsHaEligibleDiskReads++; [PSCustomObject]@{ Number = 9 } }
}

AfterAll {
  Remove-Variable -Name 'FsHaClusterPresent', 'FsHaClusterName', 'FsHaClusterNodes', 'FsHaClusterAddresses', 'FsHaClusterPhysicalDisks', 'FsHaClusterAutoAddDisk', 'FsHaLocalClusterName', 'FsHaDownNode', 'FsHaClusterWrites', 'FsHaClusterFrozen', 'FsHaEligibleDiskReads' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-FileServerCluster' {
  BeforeEach {
    $global:FsHaClusterPresent = $True
    $global:FsHaClusterName = 'TCNAW-FSCL01'
    $global:FsHaClusterNodes = @($script:Nodes)
    $global:FsHaClusterAddresses = @($script:Addresses)
    $global:FsHaClusterPhysicalDisks = @()
    $global:FsHaClusterAutoAddDisk = $False
    $global:FsHaLocalClusterName = ''
    $global:FsHaDownNode = ''
    $global:FsHaClusterWrites = @()
    $global:FsHaClusterFrozen = $False
    $global:FsHaEligibleDiskReads = 0
  }
  AfterEach { Remove-AnsibleContext }

  It 'returns standalone exact no-change state with no calls' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'creates an absent cluster with exact arguments and no storage' {
    $global:FsHaClusterPresent = $False
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses | ConvertFrom-Json
    $Result.changed | Should -BeTrue
    $global:FsHaClusterWrites | Should -HaveCount 1
    $global:FsHaClusterWrites[0].Command | Should -Be 'New'
    $global:FsHaClusterWrites[0].Node | Should -Be $script:Nodes
    $global:FsHaClusterWrites[0].StaticAddress | Should -Be $script:Addresses
    $global:FsHaClusterWrites[0].NoStorage | Should -BeTrue
    $global:FsHaClusterWrites[0].Force | Should -BeTrue
    $Result.after.physical_disks | Should -HaveCount 0
    $global:FsHaEligibleDiskReads | Should -Be 0
  }

  It 'fails formation readback when New-Cluster auto-adds storage' {
    $global:FsHaClusterPresent = $False
    $global:FsHaClusterAutoAddDisk = $True

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses } |
      Should -Throw '*auto-added Physical Disk*'
  }

  It 'does not confuse later declared storage with formation-time auto-add' {
    $global:FsHaClusterPhysicalDisks = @(
      [PSCustomObject]@{
        Name = 'Cluster Disk 9'; ResourceType = 'Physical Disk'; OwnerGroup = 'Available Storage'
      }
    )

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'repairs one missing node with only Add-ClusterNode' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses | Out-Null
    $global:FsHaClusterWrites | Should -HaveCount 1
    $global:FsHaClusterWrites[0].Command | Should -Be 'Add'
    $global:FsHaClusterWrites[0].Name | Should -Be 'tcnaw-hafs02b'
    $global:FsHaClusterWrites[0].NoStorage | Should -BeTrue
  }

  It 'fails a creation readback that did not land' {
    $global:FsHaClusterPresent = $False
    $global:FsHaClusterFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses } | Should -Throw '*not reacquired*'
  }

  It 'fails an add-node readback that did not land' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])
    $global:FsHaClusterFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses } | Should -Throw '*failed exact*'
  }

  It 'predicts absent-cluster check mode with zero writes' {
    $global:FsHaClusterPresent = $False
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses | Out-Null
    $Context.Changed | Should -BeTrue
    $Context.Result.actions | Should -Be @('create_cluster')
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'predicts missing-node check mode with zero writes' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses | Out-Null
    $Context.Changed | Should -BeTrue
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'rejects a differently named local cluster before writes' {
    $global:FsHaClusterPresent = $False
    $global:FsHaLocalClusterName = 'OTHER'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses } | Should -Throw '*differently named*'
  }

  It 'rejects duplicate desired nodes and addresses' {
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node @('a', 'a') -StaticAddress $script:Addresses } | Should -Throw '*Node must contain*'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress @('10.0.1.11', '10.0.1.11') } | Should -Throw '*StaticAddress must contain*'
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'rejects an unexpected existing node' {
    $global:FsHaClusterNodes += 'intruder'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses } | Should -Throw '*unexpected nodes*'
  }

  It 'rejects a wrong existing core address set' {
    $global:FsHaClusterAddresses[3] = '10.0.99.11'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses } | Should -Throw '*address identity*'
  }

  It 'fails when a declared node remains Down' {
    $global:FsHaClusterNodes = @($script:Nodes[0..2])
    $global:FsHaDownNode = 'tcnaw-hafs02b'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses } | Should -Throw '*failed exact*'
  }

  It 'fails an existing Down node without writes' {
    $global:FsHaDownNode = 'tcnaw-hafs02b'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses } | Should -Throw '*failed exact*'
    $global:FsHaClusterWrites | Should -HaveCount 0
  }

  It 'sets Ansible Changed false from an initially true context' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Node $script:Nodes -StaticAddress $script:Addresses | Out-Null
    $Context.Changed | Should -BeFalse
  }
}
