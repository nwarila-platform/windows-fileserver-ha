#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusterSharedDisks.ps1'
  $script:Owners = @('tcnaw-hafs01a', 'tcnaw-hafs02a')
  $script:Declaration = @{ Function = 'Cluster Shared Volume (AZ A)'; VolumeId = 'vol-0abc123'; Owners = $script:Owners; FileServerHome = $True }

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null }
    $global:Ansible
  }
  Function Remove-AnsibleContext { Remove-Variable -Name Ansible -Scope Global -Force -ErrorAction SilentlyContinue }
  Function New-DiskResource {
    Param ([System.String]$Name = 'Cluster Disk 9', [System.String]$Guid = '11111111-1111-1111-1111-111111111111', [System.String]$State = 'Online')
    [PSCustomObject]@{ Name = $Name; ResourceType = 'Physical Disk'; State = $State; DiskIdGuid = $Guid }
  }
  Function Get-Disk { @($global:FsHaDiskLocal) }
  Function Get-ClusterNode {
    Param ([System.String]$Cluster)
    @('tcnaw-hafs01a', 'tcnaw-hafs02a', 'tcnaw-hafs01b', 'tcnaw-hafs02b') | ForEach-Object -Process { [PSCustomObject]@{ Name = $PSItem } }
  }
  Function Get-ClusterResource {
    Param ([System.String]$Cluster)
    @($global:FsHaDiskResources)
  }
  Function Get-ClusterParameter {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.String]$Name)
    [PSCustomObject]@{ Name = 'DiskIdGuid'; Value = $InputObject.DiskIdGuid }
  }
  Function Get-ClusterOwnerNode {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject)
    @($global:FsHaDiskOwners[$InputObject.Name] | ForEach-Object -Process { [PSCustomObject]@{ Name = $PSItem } })
  }
  Function Add-ClusterDisk {
    Param ([System.Object]$InputObject, [System.String]$Cluster)
    $global:FsHaDiskWrites += [PSCustomObject]@{ Command = 'Add'; InputObject = $InputObject; Cluster = $Cluster }
    $Resource = New-DiskResource -Guid $global:FsHaDiskAddedGuid -State $global:FsHaDiskAddedState
    If (-not $global:FsHaDiskFreezeAdd) {
      $global:FsHaDiskResources += $Resource
      $global:FsHaDiskOwners[$Resource.Name] = @('tcnaw-hafs01a', 'tcnaw-hafs02a', 'tcnaw-hafs01b', 'tcnaw-hafs02b')
    }
    $Resource
  }
  Function Set-ClusterOwnerNode {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.String[]]$Owners)
    $global:FsHaDiskWrites += [PSCustomObject]@{ Command = 'Owners'; Name = $InputObject.Name; Owners = $Owners }
    If (-not $global:FsHaDiskFreezeOwners) { $global:FsHaDiskOwners[$InputObject.Name] = @($Owners) }
  }
  Function Start-ClusterResource {
    Param ([System.Object]$InputObject, [System.Int32]$Wait)
    $global:FsHaDiskWrites += [PSCustomObject]@{ Command = 'Start'; Name = $InputObject.Name; Wait = $Wait }
    If (-not $global:FsHaDiskFreezeStart) { $InputObject.State = 'Online' }
  }
}

AfterAll {
  Remove-Variable -Name 'FsHaDiskLocal', 'FsHaDiskResources', 'FsHaDiskOwners', 'FsHaDiskWrites', 'FsHaDiskFreezeAdd', 'FsHaDiskFreezeOwners', 'FsHaDiskFreezeStart', 'FsHaDiskAddedGuid', 'FsHaDiskAddedState' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ClusterSharedDisks' {
  BeforeEach {
    $Local = [PSCustomObject]@{ Number = 9; Guid = '11111111-1111-1111-1111-111111111111'; UniqueId = 'AWS_vol0abc123' }
    $Resource = New-DiskResource
    $global:FsHaDiskLocal = @($Local)
    $global:FsHaDiskResources = @($Resource)
    $global:FsHaDiskOwners = @{ 'Cluster Disk 9' = @($script:Owners) }
    $global:FsHaDiskWrites = @()
    $global:FsHaDiskFreezeAdd = $False
    $global:FsHaDiskFreezeOwners = $False
    $global:FsHaDiskFreezeStart = $False
    $global:FsHaDiskAddedGuid = '11111111-1111-1111-1111-111111111111'
    $global:FsHaDiskAddedState = 'Online'
  }
  AfterEach { Remove-AnsibleContext }

  It 'returns exact standalone no-change state' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $Result.after.observed_unique_id | Should -Be 'AWS_vol0abc123'
    $global:FsHaDiskWrites | Should -HaveCount 0
  }

  It 'adopts only the exact local disk object and sets declared owners' {
    $global:FsHaDiskResources = @()
    $global:FsHaDiskOwners = @{}
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | ConvertFrom-Json
    $global:FsHaDiskWrites.Command | Should -Be @('Add', 'Owners')
    $Result.actions | Should -Be @('adopt_disk', 'set_possible_owners')
    $global:FsHaDiskWrites[0].InputObject | Should -Be $global:FsHaDiskLocal[0]
    $global:FsHaDiskWrites[0].Cluster | Should -Be 'TCNAW-FSCL01'
    $global:FsHaDiskWrites[1].Owners | Should -Be $script:Owners
  }

  It 'reports and performs a start when adoption returns an offline resource' {
    $global:FsHaDiskResources = @()
    $global:FsHaDiskOwners = @{}
    $global:FsHaDiskAddedState = 'Offline'

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | ConvertFrom-Json
    $global:FsHaDiskWrites.Command | Should -Be @('Add', 'Owners', 'Start')
    $Result.actions | Should -Be @('adopt_disk', 'set_possible_owners', 'start_disk')
  }

  It 'repairs owner-only drift without a second adoption' {
    $global:FsHaDiskOwners['Cluster Disk 9'] = @('tcnaw-hafs01a', 'tcnaw-hafs02a', 'tcnaw-hafs01b')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | Out-Null
    $global:FsHaDiskWrites.Command | Should -Be @('Owners')
  }

  It 'starts offline-only drift with the exact wait' {
    $global:FsHaDiskResources[0].State = 'Offline'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | Out-Null
    $global:FsHaDiskWrites | Should -HaveCount 1
    $global:FsHaDiskWrites[0].Command | Should -Be 'Start'
    $global:FsHaDiskWrites[0].Wait | Should -Be 300
  }

  It 'repairs combined owner and offline drift' {
    $global:FsHaDiskResources[0].State = 'Offline'
    $global:FsHaDiskOwners['Cluster Disk 9'] = @('tcnaw-hafs01a')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | Out-Null
    $global:FsHaDiskWrites.Command | Should -Be @('Owners', 'Start')
  }

  It 'fails adoption readback when the mapping does not appear' {
    $global:FsHaDiskResources = @()
    $global:FsHaDiskOwners = @{}
    $global:FsHaDiskFreezeAdd = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration } | Should -Throw '*failed identity*'
  }

  It 'fails when Add-ClusterDisk returns a resource mapped to the wrong DiskIdGuid' {
    $global:FsHaDiskResources = @()
    $global:FsHaDiskOwners = @{}
    $global:FsHaDiskAddedGuid = '22222222-2222-2222-2222-222222222222'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration } | Should -Throw '*failed identity*'
    @($global:FsHaDiskWrites | Where-Object -FilterScript { $PSItem.Command -eq 'Add' }) | Should -HaveCount 1
  }

  It 'fails owner readback when the correction does not land' {
    $global:FsHaDiskOwners['Cluster Disk 9'] = @('tcnaw-hafs01a')
    $global:FsHaDiskFreezeOwners = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration } | Should -Throw '*failed identity*'
  }

  It 'fails state readback when Start does not land' {
    $global:FsHaDiskResources[0].State = 'Offline'
    $global:FsHaDiskFreezeStart = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration } | Should -Throw '*failed identity*'
  }

  It 'predicts unadopted check mode with zero writes' {
    $global:FsHaDiskResources = @()
    $global:FsHaDiskOwners = @{}
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | Out-Null
    $Context.Changed | Should -BeTrue
    $Context.Result.actions | Should -Contain 'adopt_disk'
    $global:FsHaDiskWrites | Should -HaveCount 0
  }

  It 'predicts owner drift in check mode with zero writes' {
    $global:FsHaDiskOwners['Cluster Disk 9'] = @('tcnaw-hafs01a')
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | Out-Null
    $Context.Changed | Should -BeTrue
    $global:FsHaDiskWrites | Should -HaveCount 0
  }

  It 'rejects missing and duplicate local volume tokens before writes' {
    $global:FsHaDiskLocal = @([PSCustomObject]@{ Guid = 'x'; UniqueId = 'other' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration } | Should -Throw '*exactly one local*'
    $global:FsHaDiskLocal = @(
      [PSCustomObject]@{ Guid = '1'; UniqueId = 'vol0abc123' },
      [PSCustomObject]@{ Guid = '2'; UniqueId = 'vol0abc123' }
    )
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration } | Should -Throw '*exactly one local*'
    $global:FsHaDiskWrites | Should -HaveCount 0
  }

  It 'rejects an ambiguous cluster-resource token' {
    $global:FsHaDiskResources += New-DiskResource -Name 'Physical Disk Alpha'
    $global:FsHaDiskOwners['Physical Disk Alpha'] = @($script:Owners)
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration } | Should -Throw '*ambiguously maps*'
  }

  It 'rejects malformed volume IDs and bad owner declarations' {
    $Bad = @{} + $script:Declaration
    $Bad.VolumeId = 'disk-123'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $Bad } | Should -Throw '*Malformed*'
    $Bad = @{} + $script:Declaration
    $Bad.Owners = @('tcnaw-hafs01a', 'unknown')
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $Bad } | Should -Throw '*absent from the cluster*'
    $Bad.Owners = @('tcnaw-hafs01a')
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $Bad } | Should -Throw '*exactly two unique*'
    $Bad.Owners = @('tcnaw-hafs01a', 'tcnaw-hafs01a')
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $Bad } | Should -Throw '*exactly two unique*'
  }

  It 'selects by volume token despite reversed resource names' {
    $OtherDisk = [PSCustomObject]@{ Number = 8; Guid = '22222222-2222-2222-2222-222222222222'; UniqueId = 'AWS_vol0def456' }
    $OtherResource = New-DiskResource -Name 'Cluster Disk 1' -Guid $OtherDisk.Guid
    $global:FsHaDiskLocal = @($OtherDisk, $global:FsHaDiskLocal[0])
    $global:FsHaDiskResources = @($OtherResource, $global:FsHaDiskResources[0])
    $global:FsHaDiskOwners['Cluster Disk 1'] = @('tcnaw-hafs01b', 'tcnaw-hafs02b')
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | ConvertFrom-Json
    $Result.after.resource_name | Should -Be 'Cluster Disk 9'
  }

  It 'sets Ansible Changed false from its initially true value' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | Out-Null
    $Context.Changed | Should -BeFalse
  }
}
