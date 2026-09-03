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
          Name         = $(If ($Index -eq 0) { 'Cluster Name' } Else { 'Cluster Name' })
          ResourceType = $global:FsHaNameResourceType
          OwnerGroup   = $global:FsHaNameOwnerGroup
        }
      }
    }
    $Items
  }

  Function Get-ClusterParameter {
    Param (
      [Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject,
      [System.String]$Name
    )
    If ($global:FsHaNameMissingParameter -eq $Name) { Return @() }
    [PSCustomObject]@{ Name = $Name; Value = $global:FsHaNameValues[$Name] }
  }

  Function Set-ClusterParameter {
    Param (
      [Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject,
      [System.String]$Name,
      [System.Object]$Value
    )
    $global:FsHaNameWrites += [PSCustomObject]@{ Name = $Name; Value = $Value }
    If (-not $global:FsHaNameFrozen) { $global:FsHaNameValues[$Name] = $Value }
  }
}

AfterAll {
  Remove-Variable -Name 'FsHaNameClusterName', 'FsHaNameClusterReads', 'FsHaNameClusterInputs', 'FsHaNameReads', 'FsHaNameResourceCount', 'FsHaNameResourceObject', 'FsHaNameResourceType', 'FsHaNameOwnerGroup', 'FsHaNameValues', 'FsHaNameWrites', 'FsHaNameFrozen', 'FsHaNameMissingParameter' -Scope 'Global' -ErrorAction 'SilentlyContinue'
}

Describe 'Set-ClusterNameParameters' {
  BeforeEach {
    $global:FsHaNameClusterName = 'TCNAW-FSCL01'
    $global:FsHaNameClusterReads = 0
    $global:FsHaNameClusterInputs = @()
    $global:FsHaNameReads = 0
    $global:FsHaNameResourceCount = 1
    $global:FsHaNameResourceObject = $Null
    $global:FsHaNameResourceType = 'Network Name'
    $global:FsHaNameOwnerGroup = 'Cluster Group'
    $global:FsHaNameValues = @{ RegisterAllProvidersIP = 0; HostRecordTTL = 300 }
    $global:FsHaNameWrites = @()
    $global:FsHaNameFrozen = $False
    $global:FsHaNameMissingParameter = ''
  }

  AfterEach { Remove-AnsibleContext }

  It 'returns standalone no-change state with zero writes' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $Result.actions | Should -HaveCount 0
    $global:FsHaNameWrites | Should -HaveCount 0
    $global:FsHaNameClusterReads | Should -Be 1
    $global:FsHaNameClusterInputs | Should -Be @('TCNAW-FSCL01')
  }

  It 'exports only serialization-safe primitive result leaves' {
    $RawResource = [System.IO.MemoryStream]::new()
    Try {
      $RawResource | Add-Member -NotePropertyName Name -NotePropertyValue 'Cluster Name'
      $RawResource | Add-Member -NotePropertyName ResourceType -NotePropertyValue 'Network Name'
      $RawResource | Add-Member -NotePropertyName OwnerGroup -NotePropertyValue 'Cluster Group'
      $global:FsHaNameResourceObject = $RawResource
      $Context = New-AnsibleContext

      $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300

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
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*belongs to cluster OTHER*'
    $global:FsHaNameReads | Should -Be 0
    $global:FsHaNameWrites | Should -HaveCount 0
  }

  It 'corrects RegisterAllProvidersIP only' {
    $global:FsHaNameValues.RegisterAllProvidersIP = 1
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | ConvertFrom-Json
    $Result.changed | Should -BeTrue
    $global:FsHaNameWrites | Should -HaveCount 1
    $global:FsHaNameWrites[0].Name | Should -Be 'RegisterAllProvidersIP'
    $global:FsHaNameWrites[0].Value | Should -Be 0
  }

  It 'corrects HostRecordTTL only from a partial state' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | Out-Null
    $global:FsHaNameWrites | Should -HaveCount 1
    $global:FsHaNameWrites[0].Name | Should -Be 'HostRecordTTL'
  }

  It 'corrects both parameters with two exact calls' {
    $global:FsHaNameValues.RegisterAllProvidersIP = 1
    $global:FsHaNameValues.HostRecordTTL = 1200
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | Out-Null
    $global:FsHaNameWrites.Name | Should -Be @('RegisterAllProvidersIP', 'HostRecordTTL')
  }

  It 'fails when RegisterAllProvidersIP does not survive readback' {
    $global:FsHaNameValues.RegisterAllProvidersIP = 1
    $global:FsHaNameFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*readback failed*'
  }

  It 'fails when HostRecordTTL does not survive readback' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    $global:FsHaNameFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*readback failed*'
  }

  It 'predicts check-mode drift without writes through the Ansible transport' {
    $global:FsHaNameValues.HostRecordTTL = 1200
    $Context = New-AnsibleContext -CheckMode
    $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300
    $Output | Should -BeNullOrEmpty
    $Context.Changed | Should -BeTrue
    $Context.Result.check_mode | Should -BeTrue
    $global:FsHaNameWrites | Should -HaveCount 0
  }

  It 'sets Ansible Changed false from an initially true context' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 | Out-Null
    $Context.Changed | Should -BeFalse
  }

  It 'rejects a missing Network Name resource before writes' {
    $global:FsHaNameResourceCount = 0
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*exactly one*'
    $global:FsHaNameWrites | Should -HaveCount 0
  }

  It 'rejects ambiguous Network Name resources before writes' {
    $global:FsHaNameResourceCount = 2
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*exactly one*'
  }

  It 'rejects a wrong resource type or owner group' {
    $global:FsHaNameResourceType = 'IP Address'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*Network Name*'
    $global:FsHaNameResourceType = 'Network Name'
    $global:FsHaNameOwnerGroup = 'Other Group'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*Cluster Group*'
  }

  It 'rejects a missing parameter before writes' {
    $global:FsHaNameMissingParameter = 'HostRecordTTL'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -ResourceName 'Cluster Name' -RegisterAllProvidersIP 0 -HostRecordTTL 300 } | Should -Throw '*must expose one*'
    $global:FsHaNameWrites | Should -HaveCount 0
  }
}
