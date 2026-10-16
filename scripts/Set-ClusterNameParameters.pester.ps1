#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusterNameParameters.ps1'

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
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

  Function Reset-FsHaNameFixture {
    Remove-AnsibleContext
    $global:FsHaNameClusterName = 'TCNAW-FSCL01'
    $global:FsHaNameClusterReads = 0
    $global:FsHaNameClusterInputs = @()
    $global:FsHaNameReads = 0
    $global:FsHaNameResourceCount = 1
    $global:FsHaNameResourceName = 'Cluster Name'
    $global:FsHaNameResourceObject = $Null
    $global:FsHaNameResourceType = 'Network Name'
    $global:FsHaNameOwnerGroup = 'Cluster Group'
    $global:FsHaNameResourceState = 'Online'
    $global:FsHaNameGroupCount = 1
    $global:FsHaNameGroupState = 'Online'
    $global:FsHaNameGroupReads = 0
    $global:FsHaNameGroupOfflineReadAt = 0
    $global:FsHaNameValues = @{ RegisterAllProvidersIP = 0; HostRecordTTL = 300 }
    $global:FsHaNameWrites = @()
    $global:FsHaNameSetCalls = 0
    $global:FsHaNameSetThrowAtCall = 0
    $global:FsHaNameSetNoChangeAtCall = 0
    $global:FsHaNameFrozen = $False
    $global:FsHaNameMissingParameter = ''
    $global:FsHaNameParameterReads = 0
    $global:FsHaNameSpoofTtlReadAt = 0
    $global:FsHaNameSpoofTtlValue = 0
    $global:FsHaNameStops = 0
    $global:FsHaNameStarts = 0
    $global:FsHaNameStopThrowAtCall = 0
    $global:FsHaNameStartThrowAtCall = 0
    $global:FsHaNameStartLeavesGroupState = $False
    $global:FsHaNameRollbackStops = 0
    $global:FsHaNameRollbackStarts = 0
    $global:FsHaNameRollbackStartPending = $False
  }

  Function Get-Cluster {
    $global:FsHaNameClusterReads++
    [PSCustomObject]@{ Name = $global:FsHaNameClusterName }
  }

  Function Get-ClusterResource {
    Param ([System.Object]$InputObject)
    $global:FsHaNameReads++
    $global:FsHaNameClusterInputs += [System.String]$InputObject.Name
    If ($global:FsHaNameResourceCount -eq 0) { Return @() }
    $Items = @()
    For ($Index = 0; $Index -lt $global:FsHaNameResourceCount; $Index++) {
      If ($Index -eq 0 -and $Null -ne $global:FsHaNameResourceObject) {
        $Items += $global:FsHaNameResourceObject
      } Else {
        $Items += [PSCustomObject]@{
          Name         = $global:FsHaNameResourceName
          ResourceType = $global:FsHaNameResourceType
          OwnerGroup   = $global:FsHaNameOwnerGroup
          State        = $global:FsHaNameResourceState
        }
      }
    }
    $Items
  }

  Function Get-ClusterGroup {
    Param ([System.String]$Name)
    If ($global:FsHaNameGroupCount -eq 0) { Return @() }
    $global:FsHaNameGroupReads++
    If ($global:FsHaNameGroupReads -eq $global:FsHaNameGroupOfflineReadAt) {
      $global:FsHaNameGroupState = 'Offline'
    }
    [PSCustomObject]@{ Name = $Name; State = $global:FsHaNameGroupState }
  }

  Function Get-ClusterParameter {
    Param (
      [Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject,
      [System.String]$Name
    )
    If ($global:FsHaNameMissingParameter -eq $Name) { Return @() }
    $global:FsHaNameParameterReads++
    $Value = $global:FsHaNameValues[$Name]
    If ($Name -eq 'HostRecordTTL' -and $global:FsHaNameParameterReads -eq $global:FsHaNameSpoofTtlReadAt) {
      $Value = $global:FsHaNameSpoofTtlValue
    }
    [PSCustomObject]@{ Name = $Name; Value = $Value }
  }

  Function Set-ClusterParameter {
    Param (
      [Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject,
      [System.String]$Name,
      [System.Object]$Value
    )
    $global:FsHaNameSetCalls++
    $global:FsHaNameWrites += [PSCustomObject]@{ Name = $Name; Value = $Value }
    If (-not $global:FsHaNameFrozen -and $global:FsHaNameSetCalls -ne $global:FsHaNameSetNoChangeAtCall) {
      $global:FsHaNameValues[$Name] = $Value
    }
    If ($global:FsHaNameSetCalls -eq $global:FsHaNameSetThrowAtCall) {
      Throw 'injected parameter write failure.'
    }
    [PSCustomObject]@{ sentinel = 'set' }
  }

  Function Stop-ClusterResource {
    Param ([System.Object]$InputObject, [System.Int32]$Wait)
    $global:FsHaNameStops++
    If ($global:FsHaNameStops -eq $global:FsHaNameStopThrowAtCall) {
      Throw 'injected stop failure.'
    }
    $global:FsHaNameResourceState = 'Offline'
    $global:FsHaNameGroupState = 'Offline'
    If ($global:FsHaNameValues.HostRecordTTL -eq 1200) {
      $global:FsHaNameRollbackStops++
      $global:FsHaNameRollbackStartPending = $True
    }
    [PSCustomObject]@{ sentinel = 'stop' }
  }

  Function Start-ClusterGroup {
    Param ([System.String]$Name, [System.Int32]$Wait)
    $global:FsHaNameStarts++
    If ($global:FsHaNameStarts -eq $global:FsHaNameStartThrowAtCall) {
      Throw 'injected start failure.'
    }
    If ($global:FsHaNameRollbackStartPending) {
      $global:FsHaNameRollbackStarts++
      $global:FsHaNameRollbackStartPending = $False
    }
    $global:FsHaNameResourceState = 'Online'
    If (-not $global:FsHaNameStartLeavesGroupState) {
      $global:FsHaNameGroupState = 'Online'
    }
    [PSCustomObject]@{ sentinel = 'start' }
  }
}

AfterAll {
  Remove-Variable -Name 'FsHaNameClusterName', 'FsHaNameClusterReads', 'FsHaNameClusterInputs',
    'FsHaNameReads', 'FsHaNameResourceCount', 'FsHaNameResourceName', 'FsHaNameResourceObject',
    'FsHaNameResourceType', 'FsHaNameOwnerGroup', 'FsHaNameResourceState', 'FsHaNameGroupCount',
    'FsHaNameGroupState', 'FsHaNameGroupReads', 'FsHaNameGroupOfflineReadAt', 'FsHaNameValues',
    'FsHaNameWrites', 'FsHaNameSetCalls',
    'FsHaNameSetThrowAtCall', 'FsHaNameSetNoChangeAtCall', 'FsHaNameFrozen',
    'FsHaNameMissingParameter', 'FsHaNameParameterReads', 'FsHaNameSpoofTtlReadAt',
    'FsHaNameSpoofTtlValue', 'FsHaNameStops', 'FsHaNameStarts', 'FsHaNameStopThrowAtCall',
    'FsHaNameStartThrowAtCall', 'FsHaNameStartLeavesGroupState', 'FsHaNameRollbackStops',
    'FsHaNameRollbackStarts', 'FsHaNameRollbackStartPending' -Scope 'Global' `
    -ErrorAction 'SilentlyContinue'
}

Describe 'Set-ClusterNameParameters' {
  BeforeEach { Reset-FsHaNameFixture }

  AfterEach { Remove-AnsibleContext }

  It 'returns standalone no-change state with zero writes' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $Result.actions | Should -HaveCount 0
    $global:FsHaNameWrites | Should -HaveCount 0
    $global:FsHaNameClusterReads | Should -Be 1
    $global:FsHaNameClusterInputs | Should -Be @('TCNAW-FSCL01')
  }

  It 'honors standalone WhatIf for drift without parameter writes' {
    $global:FsHaNameValues.HostRecordTTL = 1200

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 -WhatIf | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.check_mode | Should -BeTrue
    $global:FsHaNameWrites | Should -HaveCount 0
    $global:FsHaNameValues.HostRecordTTL | Should -Be 1200
  }

  It 'exports only serialization-safe primitive result leaves' {
    $RawResource = [System.IO.MemoryStream]::new()
    Try {
      $RawResource | Add-Member -NotePropertyName Name -NotePropertyValue 'Cluster Name'
      $RawResource | Add-Member -NotePropertyName ResourceType -NotePropertyValue 'Network Name'
      $RawResource | Add-Member -NotePropertyName OwnerGroup -NotePropertyValue 'Cluster Group'
      $RawResource | Add-Member -NotePropertyName State -NotePropertyValue 'Online'
      $global:FsHaNameResourceObject = $RawResource
      $Context = New-AnsibleContext

      $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300

      $Output | Should -BeNullOrEmpty
      { $Context.Result | ConvertTo-Json -Depth 6 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $Context.Result } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $RawResource } | Should -Throw '*System.IO.MemoryStream*'
      $Context.Result.before.host_record_ttl | Should -Be 300
    } Finally {
      $RawResource.Dispose()
    }
  }

  It 'rejects a differently named local cluster before resource reads or writes' {
    $global:FsHaNameClusterName = 'OTHER'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*belongs to cluster OTHER*'
    $global:FsHaNameReads | Should -Be 0
    $global:FsHaNameWrites | Should -HaveCount 0
  }

  It 'corrects RegisterAllProvidersIP only' {
    $global:FsHaNameValues.RegisterAllProvidersIP = 1
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | ConvertFrom-Json
    $Result.changed | Should -BeTrue
    $global:FsHaNameWrites | Should -HaveCount 1
    $global:FsHaNameWrites[0].Name | Should -Be 'RegisterAllProvidersIP'
    $global:FsHaNameWrites[0].Value | Should -Be 0
  }

  It 'corrects HostRecordTTL only from a partial state' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | Out-Null
    $global:FsHaNameWrites | Should -HaveCount 1
    $global:FsHaNameWrites[0].Name | Should -Be 'HostRecordTTL'
  }

  It 'corrects both parameters with two exact calls' {
    $global:FsHaNameValues.RegisterAllProvidersIP = 1
    $global:FsHaNameValues.HostRecordTTL = 1200
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | Out-Null
    $global:FsHaNameWrites.Name | Should -Be @('RegisterAllProvidersIP', 'HostRecordTTL')
  }

  It 'fails when RegisterAllProvidersIP does not survive readback' {
    $global:FsHaNameValues.RegisterAllProvidersIP = 1
    $global:FsHaNameFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*readback failed*'
  }

  It 'fails when HostRecordTTL does not survive readback' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    $global:FsHaNameFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*readback failed*'
  }

  It 'predicts check-mode drift without writes through the Ansible transport' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    $Context = New-AnsibleContext -CheckMode
    $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300
    $Output | Should -BeNullOrEmpty
    $Context.Changed | Should -BeTrue
    $Context.Result.check_mode | Should -BeTrue
    $global:FsHaNameWrites | Should -HaveCount 0
  }

  It 'sets Ansible Changed false from an initially true context' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | Out-Null
    $Context.Changed | Should -BeFalse
  }

  It 'rejects a missing Network Name resource before writes' {
    $global:FsHaNameResourceCount = 0
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*exactly one*'
    $global:FsHaNameWrites | Should -HaveCount 0
  }

  It 'rejects ambiguous Network Name resources before writes' {
    $global:FsHaNameResourceCount = 2
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*exactly one*'
  }

  It 'rejects a wrong resource type or owner group' {
    $global:FsHaNameResourceType = 'IP Address'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*Network Name*'
    $global:FsHaNameResourceType = 'Network Name'
    $global:FsHaNameOwnerGroup = 'Other Group'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*Cluster Group*'
  }

  It 'rejects a missing parameter before writes' {
    $global:FsHaNameMissingParameter = 'HostRecordTTL'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*must expose one*'
    $global:FsHaNameWrites | Should -HaveCount 0
  }

  It 'N1 converges a Network Name resource owned by its declared role group' {
    $global:FsHaNameResourceName = 'TCNAW-HAFS01'
    $global:FsHaNameOwnerGroup = 'TCNAW-HAFS01'
    $global:FsHaNameValues.HostRecordTTL = 1200

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'TCNAW-HAFS01' -OwnerGroup 'TCNAW-HAFS01' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.actions | Should -Be @('set_host_record_ttl', 'restart_network_name_resource')
    $global:FsHaNameValues.HostRecordTTL | Should -Be 300
  }

  It 'N2 rejects a Network Name resource owned by another group without mutations' {
    $global:FsHaNameResourceName = 'TCNAW-HAFS01'
    $global:FsHaNameOwnerGroup = 'Other Group'
    $global:FsHaNameValues.HostRecordTTL = 1200

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'TCNAW-HAFS01' -OwnerGroup 'TCNAW-HAFS01' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*owned by TCNAW-HAFS01*'

    $global:FsHaNameWrites | Should -HaveCount 0
    $global:FsHaNameStops | Should -Be 0
    $global:FsHaNameStarts | Should -Be 0
  }

  It 'N3 applies exactly once after writes and never for no drift or check mode' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    $Context = New-AnsibleContext

    $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300

    $Output | Should -BeNullOrEmpty
    $Context.Result.actions | Should -Be @('set_host_record_ttl', 'restart_network_name_resource')
    $global:FsHaNameStops | Should -Be 1
    $global:FsHaNameStarts | Should -Be 1

    Remove-AnsibleContext
    $NoDriftOutput = @(& $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300)
    $NoDriftOutput | Should -HaveCount 1
    ($NoDriftOutput[0] | ConvertFrom-Json).actions | Should -HaveCount 0
    $global:FsHaNameStops | Should -Be 1
    $global:FsHaNameStarts | Should -Be 1

    Reset-FsHaNameFixture
    $global:FsHaNameValues.HostRecordTTL = 1200
    $CheckOutput = @(& $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 -WhatIf)
    $CheckOutput | Should -HaveCount 1
    ($CheckOutput[0] | ConvertFrom-Json).actions | Should -Be @('set_host_record_ttl', 'restart_network_name_resource')
    $global:FsHaNameWrites | Should -HaveCount 0
    $global:FsHaNameStops | Should -Be 0
    $global:FsHaNameStarts | Should -Be 0
  }

  It 'N4 recovers write and apply failures and reports rollback failures exactly' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    $global:FsHaNameStartThrowAtCall = 1
    $Context = New-AnsibleContext
    $Captured = [System.Collections.Generic.List[System.Object]]::new()
    $Failure = $Null
    Try {
      & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 |
        ForEach-Object -Process { $Captured.Add($PSItem) }
    } Catch { $Failure = $PSItem }
    $Captured | Should -HaveCount 0
    $Failure.Exception.Message | Should -Be 'Network Name convergence failed for resource Cluster Name during apply: injected start failure.; rollback: succeeded; availability recovery: succeeded'
    $global:FsHaNameValues.HostRecordTTL | Should -Be 1200
    $global:FsHaNameResourceState | Should -Be 'Online'
    $global:FsHaNameGroupState | Should -Be 'Online'
    $WritesBeforeRetry = $global:FsHaNameWrites.Count
    $StartsBeforeRetry = $global:FsHaNameStarts
    $global:FsHaNameStartThrowAtCall = 0
    $RetryOutput = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300
    $RetryOutput | Should -BeNullOrEmpty
    $global:FsHaNameWrites.Count | Should -BeGreaterThan $WritesBeforeRetry
    $global:FsHaNameStarts | Should -BeGreaterThan $StartsBeforeRetry
    $global:FsHaNameValues.HostRecordTTL | Should -Be 300

    Reset-FsHaNameFixture
    $global:FsHaNameValues.RegisterAllProvidersIP = 1
    $global:FsHaNameSetThrowAtCall = 1
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } |
      Should -Throw -ExpectedMessage 'Network Name convergence failed for resource Cluster Name during write RegisterAllProvidersIP: injected parameter write failure.; rollback: succeeded; availability recovery: succeeded'
    $global:FsHaNameValues.RegisterAllProvidersIP | Should -Be 1

    Reset-FsHaNameFixture
    $global:FsHaNameValues.HostRecordTTL = 1200
    $global:FsHaNameStartThrowAtCall = 1
    $global:FsHaNameSetNoChangeAtCall = 2
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } |
      Should -Throw -ExpectedMessage '*during apply: injected start failure.; rollback: failed: Network Name parameter rollback readback failed*; availability recovery: succeeded'
    $global:FsHaNameValues.HostRecordTTL | Should -Be 300

    Reset-FsHaNameFixture
    $global:FsHaNameValues.HostRecordTTL = 1200
    $global:FsHaNameStartThrowAtCall = 1
    $global:FsHaNameSetThrowAtCall = 2
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } |
      Should -Throw -ExpectedMessage '*during apply: injected start failure.; rollback: failed: injected parameter write failure.; availability recovery: succeeded'
    $global:FsHaNameValues.HostRecordTTL | Should -Be 1200

    Reset-FsHaNameFixture
    $global:FsHaNameValues.HostRecordTTL = 1200
    $global:FsHaNameSpoofTtlReadAt = 4
    $global:FsHaNameSpoofTtlValue = 1200
    $Captured = [System.Collections.Generic.List[System.Object]]::new()
    $Failure = $Null
    Try {
      & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 |
        ForEach-Object -Process { $Captured.Add($PSItem) }
    } Catch { $Failure = $PSItem }
    $Captured | Should -HaveCount 0
    $Failure.Exception.Message | Should -Be 'Network Name convergence failed for resource Cluster Name during readback: Network Name parameter readback failed for resource Cluster Name.; rollback: succeeded; availability recovery: succeeded'
    $global:FsHaNameValues.HostRecordTTL | Should -Be 1200
    $global:FsHaNameStops | Should -Be 2
    $global:FsHaNameStarts | Should -Be 2
  }

  It 'N5 recovers original values and reports a group that remains non-Online' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    $global:FsHaNameGroupOfflineReadAt = 2
    $global:FsHaNameStartLeavesGroupState = $True
    $Context = New-AnsibleContext
    $Captured = [System.Collections.Generic.List[System.Object]]::new()
    $Failure = $Null

    Try {
      & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -OwnerGroup 'Cluster Group' -RegisterAllProvidersIP 0 -HostRecordTTL 300 |
        ForEach-Object -Process { $Captured.Add($PSItem) }
    } Catch { $Failure = $PSItem }

    $Captured | Should -HaveCount 0
    $Failure.Exception.Message | Should -Be 'Network Name convergence failed for resource Cluster Name during readback: Network Name parameter readback failed for resource Cluster Name.; rollback: failed: Network Name rollback state readback failed for resource Cluster Name.; availability recovery: failed: Network Name availability recovery readback failed for resource Cluster Name.'
    $global:FsHaNameValues.HostRecordTTL | Should -Be 1200
    $global:FsHaNameResourceState | Should -Be 'Online'
    $global:FsHaNameGroupState | Should -Be 'Offline'
    $global:FsHaNameRollbackStops | Should -Be 1
    $global:FsHaNameRollbackStarts | Should -Be 1
  }
}
