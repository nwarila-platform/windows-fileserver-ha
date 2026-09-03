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
  Function New-DiskResource {
    Param (
      [System.String]$Name = 'Cluster Disk 9', [System.String]$Guid = '11111111-1111-1111-1111-111111111111',
      [System.String]$State = 'Online', [System.String]$Group = 'Available Storage'
    )
    [PSCustomObject]@{ Name = $Name; ResourceType = 'Physical Disk'; OwnerGroup = $Group; State = $State; DiskIdGuid = $Guid }
  }
  Function Get-Cluster {
    $global:FsHaDiskClusterReads++
    [PSCustomObject]@{ Name = $global:FsHaDiskClusterName }
  }
  Function Get-Disk { @($global:FsHaDiskLocal) }
  Function Get-ClusterNode {
    Param ([System.Object]$InputObject)
    $global:FsHaDiskClusterInputs += [System.String]$InputObject.Name
    @('tcnaw-hafs01a', 'tcnaw-hafs02a', 'tcnaw-hafs01b', 'tcnaw-hafs02b') | ForEach-Object -Process { [PSCustomObject]@{ Name = $PSItem } }
  }
  Function Get-ClusterResource {
    Param ([System.Object]$InputObject)
    $global:FsHaDiskClusterInputs += [System.String]$InputObject.Name
    @($global:FsHaDiskResources)
  }
  Function Get-ClusterParameter {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.String]$Name)
    [PSCustomObject]@{ Name = 'DiskIdGuid'; Value = $InputObject.DiskIdGuid }
  }
  Function Get-ClusterOwnerNode {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject)
    [PSCustomObject]@{
      OwnerNodes = @($global:FsHaDiskOwners[$InputObject.Name] | ForEach-Object -Process { [PSCustomObject]@{ Name = $PSItem } })
    }
  }
  Function Get-ClusterGroup {
    Param ([System.Object]$InputObject)
    $global:FsHaDiskClusterInputs += [System.String]$InputObject.Name
    [PSCustomObject]@{ Name = 'Available Storage'; OwnerNode = $global:FsHaDiskAvailableOwner }
  }
  Function Add-ClusterDisk {
    Param ([System.Object]$InputObject)
    $global:FsHaDiskWrites += [PSCustomObject]@{ Command = 'Add'; InputObject = $InputObject }
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
  Remove-Variable -Name 'FsHaDiskClusterName', 'FsHaDiskClusterReads', 'FsHaDiskClusterInputs', 'FsHaDiskAvailableOwner', 'FsHaDiskLocal', 'FsHaDiskResources', 'FsHaDiskOwners', 'FsHaDiskWrites', 'FsHaDiskFreezeAdd', 'FsHaDiskFreezeOwners', 'FsHaDiskFreezeStart', 'FsHaDiskAddedGuid', 'FsHaDiskAddedState' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ClusterSharedDisks' {
  BeforeEach {
    $global:FsHaDiskClusterName = 'TCNAW-FSCL01'
    $global:FsHaDiskClusterReads = 0
    $global:FsHaDiskClusterInputs = @()
    $global:FsHaDiskAvailableOwner = 'tcnaw-hafs01a'
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
    $global:FsHaDiskClusterReads | Should -Be 1
    $global:FsHaDiskClusterInputs | Should -Be @('TCNAW-FSCL01', 'TCNAW-FSCL01')
  }

  It 'exports only serialization-safe primitive result leaves' {
    $RawResource = [System.IO.MemoryStream]::new()
    Try {
      $RawResource | Add-Member -NotePropertyName Name -NotePropertyValue 'Cluster Disk 9'
      $RawResource | Add-Member -NotePropertyName ResourceType -NotePropertyValue 'Physical Disk'
      $RawResource | Add-Member -NotePropertyName OwnerGroup -NotePropertyValue 'Available Storage'
      $RawResource | Add-Member -NotePropertyName State -NotePropertyValue 'Online'
      $RawResource | Add-Member -NotePropertyName DiskIdGuid -NotePropertyValue '11111111-1111-1111-1111-111111111111'
      $global:FsHaDiskResources = @($RawResource)
      $Context = New-AnsibleContext

      $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration

      $Output | Should -BeNullOrEmpty
      { $Context.Result | ConvertTo-Json -Depth 6 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $Context.Result } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $RawResource } | Should -Throw '*System.IO.MemoryStream*'
      $Context.Result.after.resource_name | Should -Be 'Cluster Disk 9'
    } Finally {
      $RawResource.Dispose()
    }
  }

  It 'rejects a differently named local cluster before disk reads or writes' {
    $global:FsHaDiskClusterName = 'OTHER'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration } | Should -Throw '*belongs to cluster OTHER*'
    $global:FsHaDiskWrites | Should -HaveCount 0
    $global:FsHaDiskClusterInputs | Should -HaveCount 0
  }

  It 'adopts only the exact local disk object and sets declared owners' {
    $global:FsHaDiskResources = @()
    $global:FsHaDiskOwners = @{}
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | ConvertFrom-Json
    $global:FsHaDiskWrites.Command | Should -Be @('Add', 'Owners')
    $Result.actions | Should -Be @('adopt_disk', 'set_possible_owners')
    $global:FsHaDiskWrites[0].InputObject | Should -Be $global:FsHaDiskLocal[0]
    $global:FsHaDiskWrites[0].PSObject.Properties.Name | Should -Not -Contain 'Cluster'
    $global:FsHaDiskWrites[1].Owners | Should -Be $script:Owners
  }

  It 'reports and performs a start when adoption returns an offline resource' {
    $global:FsHaDiskResources = @()
    $global:FsHaDiskOwners = @{}
    $global:FsHaDiskAddedState = 'Offline'

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | ConvertFrom-Json
    $global:FsHaDiskWrites.Command | Should -Be @('Add', 'Owners', 'Start')
    $Result.actions | Should -Be @('adopt_disk', 'set_possible_owners', 'start_disk')
    $Result.online_deferred | Should -BeFalse
  }

  It 'adopts but defers an offline disk when the Available Storage owner is outside its declared pair' {
    $global:FsHaDiskResources = @()
    $global:FsHaDiskOwners = @{}
    $global:FsHaDiskAddedState = 'Offline'
    $global:FsHaDiskAvailableOwner = 'tcnaw-hafs01b'

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Disk $script:Declaration | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.actions | Should -Be @('adopt_disk', 'set_possible_owners', 'defer_online')
    $Result.online_deferred | Should -BeTrue
    $Result.after.state | Should -Be 'Offline'
    $global:FsHaDiskWrites.Command | Should -Be @('Add', 'Owners')
    $global:FsHaDiskWrites.Command | Should -Not -Contain 'Start'
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
