#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Get-ClusteredFileServerOwner.ps1'

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Function Get-Cluster {
    $global:FsHaOwnerClusterReads++
    @($global:FsHaOwnerClusters)
  }

  Function Get-ClusterGroup {
    Param ([System.Object]$InputObject)
    $global:FsHaOwnerGroupReads++
    $global:FsHaOwnerClusterInputs += [System.String]$InputObject.Name
    @($global:FsHaOwnerGroups)
  }
}

AfterAll {
  Remove-AnsibleContext
  Remove-Variable -Name 'FsHaOwnerClusters', 'FsHaOwnerGroups', 'FsHaOwnerClusterReads', 'FsHaOwnerGroupReads', 'FsHaOwnerClusterInputs' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Get-ClusteredFileServerOwner' {
  BeforeEach {
    $global:FsHaOwnerClusters = @([PSCustomObject]@{ Name = 'TCNAW-FSCL01' })
    $global:FsHaOwnerGroups = @([PSCustomObject]@{
        Name = 'TCNAW-HAFS01'; OwnerNode = 'tcnaw-hafs01a'; State = 'Online'
      })
    $global:FsHaOwnerClusterReads = 0
    $global:FsHaOwnerGroupReads = 0
    $global:FsHaOwnerClusterInputs = @()
  }

  AfterEach { Remove-AnsibleContext }

  It 'returns the one Online declared role owner without reporting change' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' | ConvertFrom-Json

    $Result.owner_node | Should -Be 'tcnaw-hafs01a'
    $global:FsHaOwnerClusterReads | Should -Be 1
    $global:FsHaOwnerGroupReads | Should -Be 1
    $global:FsHaOwnerClusterInputs | Should -Be @('TCNAW-FSCL01')
  }

  It 'preserves the owner object on Ansible output and sets Changed false' {
    $Context = New-AnsibleContext

    $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01'

    $Output.owner_node | Should -Be 'tcnaw-hafs01a'
    $Context.Result.owner_node | Should -Be 'tcnaw-hafs01a'
    $Context.Changed | Should -BeFalse
  }

  It 'rejects zero local clusters before any group read' {
    $global:FsHaOwnerClusters = @()

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' } | Should -Throw '*Expected one local cluster; found 0*'
    $global:FsHaOwnerGroupReads | Should -Be 0
  }

  It 'rejects multiple local clusters before any group read' {
    $global:FsHaOwnerClusters = @(
      [PSCustomObject]@{ Name = 'TCNAW-FSCL01' },
      [PSCustomObject]@{ Name = 'OTHER' }
    )

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' } | Should -Throw '*found 2*'
    $global:FsHaOwnerGroupReads | Should -Be 0
  }

  It 'rejects a differently named local cluster before any group read' {
    $global:FsHaOwnerClusters = @([PSCustomObject]@{ Name = 'OTHER' })

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' } | Should -Throw '*belongs to cluster OTHER*'
    $global:FsHaOwnerGroupReads | Should -Be 0
  }

  It 'rejects a missing declared role' {
    $global:FsHaOwnerGroups = @([PSCustomObject]@{
        Name = 'OTHER'; OwnerNode = 'tcnaw-hafs01a'; State = 'Online'
      })

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' } | Should -Throw '*must exist exactly once and be Online*'
  }

  It 'rejects duplicate declared roles' {
    $global:FsHaOwnerGroups = @(
      [PSCustomObject]@{ Name = 'TCNAW-HAFS01'; OwnerNode = 'tcnaw-hafs01a'; State = 'Online' },
      [PSCustomObject]@{ Name = 'TCNAW-HAFS01'; OwnerNode = 'tcnaw-hafs02a'; State = 'Online' }
    )

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' } | Should -Throw '*must exist exactly once and be Online*'
  }

  It 'rejects an Offline declared role' {
    $global:FsHaOwnerGroups[0].State = 'Offline'

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' } | Should -Throw '*must exist exactly once and be Online*'
  }

  It 'matches cluster and role names case-insensitively like the inline program' {
    $Result = & $script:ScriptPath -ClusterName 'tcnaw-fscl01' -RoleName 'tcnaw-hafs01' | ConvertFrom-Json

    $Result.owner_node | Should -Be 'tcnaw-hafs01a'
  }

  It 'rejects an empty role name before reading cluster state' {
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName '' } | Should -Throw
    $global:FsHaOwnerClusterReads | Should -Be 0
  }
}
