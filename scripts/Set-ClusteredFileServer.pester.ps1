#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusteredFileServer.ps1'
  $script:Owners = @('tcnaw-hafs01a', 'tcnaw-hafs02a')
  $script:Addresses = @('10.0.1.12', '10.0.33.12')
  $script:Ignored = @('10.0.64.0', '10.0.96.0')

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null }
    $global:Ansible
  }
  Function Remove-AnsibleContext { Remove-Variable -Name Ansible -Scope Global -Force -ErrorAction SilentlyContinue }
  Function New-Resource {
    Param ([System.String]$Name, [System.String]$Type, [System.String]$Group, [System.String]$State = 'Online', [System.Collections.IDictionary]$Parameters = @{})
    [PSCustomObject]@{ Name = $Name; ResourceType = $Type; OwnerGroup = $Group; State = $State; Parameters = $Parameters }
  }
  Function Get-Disk { @($global:FsHaRoleLocalDisks) }
  Function Get-ClusterResource { Param ([System.String]$Cluster) @($global:FsHaRoleResources) }
  Function Get-ClusterParameter {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.String]$Name)
    If (-not $InputObject.Parameters.Contains($Name)) { Return @() }
    [PSCustomObject]@{ Name = $Name; Value = $InputObject.Parameters[$Name] }
  }
  Function Get-ClusterOwnerNode {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.Object]$Group)
    If ($PSBoundParameters.ContainsKey('Group')) {
      @($global:FsHaRoleOwners | ForEach-Object -Process { [PSCustomObject]@{ Name = $PSItem } })
    } Else {
      @($global:FsHaHomeOwners | ForEach-Object -Process { [PSCustomObject]@{ Name = $PSItem } })
    }
  }
  Function Get-ClusterGroup {
    Param ([System.String]$Cluster)
    If (-not $global:FsHaRolePresent) { Return @() }
    For ($Index = 0; $Index -lt $global:FsHaRoleGroupCount; $Index++) { $global:FsHaRoleGroup }
  }
  Function Get-ClusterNetwork { Param ([System.String]$Cluster) @($global:FsHaRoleNetworks) }
  Function Get-ClusterResourceDependency {
    Param ([System.Object]$Resource)
    [PSCustomObject]@{ DependencyExpression = $global:FsHaRoleDependency }
  }
  Function Add-ClusterFileServerRole {
    Param (
      [System.String]$Cluster, [System.String]$Name, [System.String]$Storage,
      [System.String[]]$StaticAddress, [System.String[]]$IgnoreNetwork, [System.Int32]$Wait
    )
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'Create'; Cluster = $Cluster; Name = $Name; Storage = $Storage; StaticAddress = $StaticAddress; IgnoreNetwork = $IgnoreNetwork; Wait = $Wait }
    If ($global:FsHaRoleFrozen) { Return }
    $global:FsHaRolePresent = $True
    $global:FsHaRoleGroup.State = 'Online'
    $global:FsHaRoleGroup.OwnerNode = $script:Owners[0]
    # Add-ClusterFileServerRole has no preferred-owner parameter; creation therefore cannot
    # fabricate the declared two-node preference that Set-ClusterOwnerNode owns.
    $global:FsHaRoleOwners = @(
      'tcnaw-hafs01a', 'tcnaw-hafs02a', 'tcnaw-hafs01b', 'tcnaw-hafs02b'
    )
    $HomeResource = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })[0]
    $HomeResource.OwnerGroup = $Name
    $global:FsHaRoleResources += New-Resource -Name 'File Server Name' -Type 'Network Name' -Group $Name
    $global:FsHaRoleResources += New-Resource -Name 'IP Address 10.0.1.12' -Type 'IP Address' -Group $Name -Parameters @{ Address = '10.0.1.12'; Network = 'Cluster Network 1'; SubnetMask = '255.255.255.0'; EnableDhcp = 0 }
    $global:FsHaRoleResources += New-Resource -Name 'IP Address 10.0.33.12' -Type 'IP Address' -Group $Name -State 'Offline' -Parameters @{ Address = '10.0.33.12'; Network = 'Cluster Network 2'; SubnetMask = '255.255.255.0'; EnableDhcp = 0 }
    $global:FsHaRoleDependency = '[IP Address 10.0.1.12] or [IP Address 10.0.33.12]'
  }
  Function Move-ClusterResource {
    Param ([System.Object]$InputObject, [System.String]$Group)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'Move'; Name = $InputObject.Name; Group = $Group }
    If (-not $global:FsHaRoleFrozen) { $InputObject.OwnerGroup = $Group }
  }
  Function Set-ClusterOwnerNode {
    Param ([System.Object]$Group, [System.String[]]$Owners)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'Owners'; Group = $Group; Owners = $Owners }
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleOwners = @($Owners) }
  }
  Function Stop-ClusterGroup {
    Param ([System.String]$Name, [System.Int32]$Wait)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'StopGroup'; Name = $Name; Wait = $Wait }
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleGroup.State = 'Offline' }
  }
  Function Add-ClusterResource {
    Param ([System.String]$Name, [System.String]$ResourceType, [System.String]$Group)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'AddIp'; Name = $Name; ResourceType = $ResourceType; Group = $Group }
    $Resource = New-Resource -Name $Name -Type $ResourceType -Group $Group -State 'Offline'
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleResources += $Resource }
    $Resource
  }
  Function Set-ClusterParameter {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.Collections.IDictionary]$Multiple)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'SetIp'; Name = $InputObject.Name; Multiple = $Multiple }
    If (-not $global:FsHaRoleFrozen) { ForEach ($Key In $Multiple.Keys) { $InputObject.Parameters[$Key] = $Multiple[$Key] } }
  }
  Function Stop-ClusterResource {
    Param ([System.Object]$InputObject, [System.Int32]$Wait)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'StopIp'; Name = $InputObject.Name; Wait = $Wait }
    If (-not $global:FsHaRoleFrozen) { $InputObject.State = 'Offline' }
  }
  Function Remove-ClusterResource {
    Param ([System.Object]$InputObject, [Switch]$Force)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'RemoveIp'; Name = $InputObject.Name; Force = $Force.IsPresent }
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem -ne $InputObject }) }
  }
  Function Set-ClusterResourceDependency {
    Param ([System.Object]$Resource, [System.String]$Dependency)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'Dependency'; Name = $Resource.Name; Dependency = $Dependency }
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleDependency = $Dependency }
  }
  Function Start-ClusterGroup {
    Param ([System.String]$Name, [System.Int32]$Wait)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'StartGroup'; Name = $Name; Wait = $Wait }
    If (-not $global:FsHaRoleFrozen) {
      $global:FsHaRoleGroup.State = 'Online'
      $Ips = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'IP Address' -and $PSItem.OwnerGroup -eq $Name } | Sort-Object -Property Name)
      For ($Index = 0; $Index -lt $Ips.Count; $Index++) { $Ips[$Index].State = $(If ($Index -eq 0) { 'Online' } Else { 'Offline' }) }
    }
  }
}

AfterAll {
  Remove-Variable -Name 'FsHaRoleLocalDisks', 'FsHaRoleResources', 'FsHaHomeOwners', 'FsHaRolePresent', 'FsHaRoleGroupCount', 'FsHaRoleGroup', 'FsHaRoleOwners', 'FsHaRoleNetworks', 'FsHaRoleDependency', 'FsHaRoleWrites', 'FsHaRoleFrozen' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ClusteredFileServer' {
  BeforeEach {
    $Guid = '11111111-1111-1111-1111-111111111111'
    $global:FsHaRoleLocalDisks = @([PSCustomObject]@{ Guid = $Guid; UniqueId = 'AWS_vol0abc123' })
    $HomeResource = New-Resource -Name 'Cluster Disk 9' -Type 'Physical Disk' -Group 'TCNAW-HAFS01' -Parameters @{ DiskIdGuid = $Guid }
    $Name = New-Resource -Name 'File Server Name' -Type 'Network Name' -Group 'TCNAW-HAFS01'
    $Ip1 = New-Resource -Name 'IP Address 10.0.1.12' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.1.12'; Network = 'Cluster Network 1'; SubnetMask = '255.255.255.0'; EnableDhcp = 0 }
    $Ip2 = New-Resource -Name 'IP Address 10.0.33.12' -Type 'IP Address' -Group 'TCNAW-HAFS01' -State 'Offline' -Parameters @{ Address = '10.0.33.12'; Network = 'Cluster Network 2'; SubnetMask = '255.255.255.0'; EnableDhcp = 0 }
    $global:FsHaRoleResources = @($HomeResource, $Name, $Ip1, $Ip2)
    $global:FsHaHomeOwners = @($script:Owners)
    $global:FsHaRolePresent = $True
    $global:FsHaRoleGroupCount = 1
    $global:FsHaRoleGroup = [PSCustomObject]@{ Name = 'TCNAW-HAFS01'; State = 'Online'; OwnerNode = 'tcnaw-hafs01a' }
    $global:FsHaRoleOwners = @($script:Owners)
    $global:FsHaRoleNetworks = @(
      [PSCustomObject]@{ Name = 'Cluster Network 1'; Address = '10.0.1.0'; AddressMask = '255.255.255.0'; Role = 3 },
      [PSCustomObject]@{ Name = 'Cluster Network 2'; Address = '10.0.33.0'; AddressMask = '255.255.255.0'; Role = 3 },
      [PSCustomObject]@{ Name = 'Cluster Network 3'; Address = '10.0.64.0'; AddressMask = '255.255.255.0'; Role = 3 },
      [PSCustomObject]@{ Name = 'Cluster Network 4'; Address = '10.0.96.0'; AddressMask = '255.255.255.0'; Role = 3 }
    )
    $global:FsHaRoleDependency = '[IP Address 10.0.1.12] or [IP Address 10.0.33.12]'
    $global:FsHaRoleWrites = @()
    $global:FsHaRoleFrozen = $False
  }
  AfterEach { Remove-AnsibleContext }

  It 'returns exact online standalone no-change state' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'creates an absent role then converges the residual preferred-owner contract' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources[0])
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('Create', 'Owners')
    $global:FsHaRoleWrites[0].Command | Should -Be 'Create'
    $global:FsHaRoleWrites[0].StaticAddress | Should -Be $script:Addresses
    $global:FsHaRoleWrites[0].IgnoreNetwork | Should -Be @('Cluster Network 3', 'Cluster Network 4')
    $global:FsHaRoleWrites[0].Storage | Should -Be 'Cluster Disk 9'
    $global:FsHaRoleWrites[0].Wait | Should -Be 600
    $global:FsHaRoleWrites[1].Group | Should -Be 'TCNAW-HAFS01'
    $global:FsHaRoleWrites[1].Owners | Should -Be $script:Owners

    $global:FsHaRoleWrites = @()
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'corrects preferred-owner drift without bouncing the group' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('Owners')
  }

  It 'moves the exact home disk from Available Storage' {
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('Move')
  }

  It 'removes an arbitrary extra IP in one stop-start transaction' {
    $global:FsHaRoleResources += New-Resource -Name 'Observed AZ A Artifact' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.1.0'; Network = 'Cluster Network 1'; SubnetMask = '255.255.255.0'; EnableDhcp = 0 }
    $global:FsHaRoleResources += New-Resource -Name 'Observed AZ A Artifact 2' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.33.0'; Network = 'Cluster Network 2'; SubnetMask = '255.255.255.0'; EnableDhcp = 0 }
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('StopGroup', 'StopIp', 'RemoveIp', 'StopIp', 'RemoveIp', 'Dependency', 'StartGroup')
    @($global:FsHaRoleWrites | Where-Object -FilterScript { $PSItem.Command -eq 'StopGroup' }) | Should -HaveCount 1
    @($global:FsHaRoleWrites | Where-Object -FilterScript { $PSItem.Command -eq 'StartGroup' }) | Should -HaveCount 1
  }

  It 'repairs a missing desired IP without recreating the role' {
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.Name -ne 'IP Address 10.0.33.12' })
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $global:FsHaRoleWrites.Command | Should -Contain 'AddIp'
    $global:FsHaRoleWrites.Command | Should -Not -Contain 'Create'
    $Set = @($global:FsHaRoleWrites | Where-Object -FilterScript { $PSItem.Command -eq 'SetIp' })[0]
    $Set.Multiple.Keys | Sort-Object | Should -Be @('Address', 'EnableDhcp', 'Network', 'SubnetMask')
  }

  It 'repairs wrong DHCP network and mask in one transaction' {
    $global:FsHaRoleResources[2].Parameters.EnableDhcp = 1
    $global:FsHaRoleResources[2].Parameters.Network = 'Wrong'
    $global:FsHaRoleResources[2].Parameters.SubnetMask = '255.0.0.0'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('StopGroup', 'SetIp', 'Dependency', 'StartGroup')
  }

  It 'repairs only the exact OR dependency with one stop-start' {
    $global:FsHaRoleDependency = '[IP Address 10.0.1.12] and [IP Address 10.0.33.12]'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('StopGroup', 'Dependency', 'StartGroup')
    $global:FsHaRoleWrites[1].Dependency | Should -Be '[IP Address 10.0.1.12] or [IP Address 10.0.33.12]'
  }

  It 'rejects an invalid no-change IP state without writes' {
    $global:FsHaRoleResources[3].State = 'Online'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*static-IP membership*'
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'fails readback after create or repair does not land' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources[0])
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*group-state readback*'
  }

  It 'fails readback after a static-IP repair does not land' {
    $global:FsHaRoleResources[2].Parameters.EnableDhcp = 1
    $global:FsHaRoleFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*static-IP*'
  }

  It 'predicts absent and partial role check mode with zero writes' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources[0])
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $Context.Changed | Should -BeTrue
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'predicts a partial existing role in check mode without cluster writes' {
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.Name -ne 'IP Address 10.0.33.12' })
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $Context.Result.actions | Should -Contain 'add_ip:10.0.33.12'
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'rejects missing or ambiguous home disk identity' {
    $global:FsHaRoleLocalDisks = @()
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*exactly one local*'
    $global:FsHaRoleLocalDisks = @([PSCustomObject]@{ Guid = 'a'; UniqueId = 'vol0abc123' }, [PSCustomObject]@{ Guid = 'b'; UniqueId = 'vol0abc123' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*exactly one local*'
  }

  It 'rejects an ambiguous home Physical Disk resource identity' {
    $global:FsHaRoleResources += New-Resource -Name 'Duplicate Home Identity' -Type 'Physical Disk' -Group 'Available Storage' -Parameters @{ DiskIdGuid = '11111111-1111-1111-1111-111111111111' }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*exactly one Physical Disk*'
  }

  It 'rejects a wrong or extra disk in the role' {
    $global:FsHaRoleResources += New-Resource -Name 'Foreign Disk' -Type 'Physical Disk' -Group 'TCNAW-HAFS01' -Parameters @{ DiskIdGuid = '22222222-2222-2222-2222-222222222222' }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*wrong or extra*'
  }

  It 'rejects missing or extra client-eligible network coverage' {
    $global:FsHaRoleNetworks = @($global:FsHaRoleNetworks | Where-Object -FilterScript { $PSItem.Address -ne '10.0.96.0' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*Ignored network address*'
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Cluster Network 4'; Address = '10.0.96.0'; AddressMask = '255.255.255.0'; Role = 3 }
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Unexpected'; Address = '172.16.0.0'; AddressMask = '255.255.0.0'; Role = 3 }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*cover every*'
  }

  It 'rejects missing or ambiguous static and ignored network identity' {
    $global:FsHaRoleNetworks = @($global:FsHaRoleNetworks | Where-Object -FilterScript { $PSItem.Address -ne '10.0.1.0' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*Static address*'
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Cluster Network 1'; Address = '10.0.1.0'; AddressMask = '255.255.255.0'; Role = 3 }
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Overlapping Static'; Address = '10.0.0.0'; AddressMask = '255.255.0.0'; Role = 3 }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*Static address*'
    $global:FsHaRoleNetworks = @($global:FsHaRoleNetworks | Where-Object -FilterScript { $PSItem.Name -ne 'Overlapping Static' })
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Duplicate Ignored'; Address = '10.0.64.0'; AddressMask = '255.255.255.0'; Role = 3 }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*Ignored network address*'
  }

  It 'rejects duplicate IP and missing or multiple Network Name resources' {
    $global:FsHaRoleResources += New-Resource -Name 'Duplicate' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.1.12'; Network = 'Cluster Network 1'; SubnetMask = '255.255.255.0'; EnableDhcp = 0 }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*duplicate IP*'
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -ne 'Network Name' -and $PSItem.Name -ne 'Duplicate' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*exactly one Network Name*'
    $global:FsHaRoleResources += New-Resource -Name 'File Server Name' -Type 'Network Name' -Group 'TCNAW-HAFS01'
    $global:FsHaRoleResources += New-Resource -Name 'Second File Server Name' -Type 'Network Name' -Group 'TCNAW-HAFS01'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored } | Should -Throw '*exactly one Network Name*'
  }

  It 'sets Ansible Changed false from its initially true context' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored | Out-Null
    $Context.Changed | Should -BeFalse
  }
}
