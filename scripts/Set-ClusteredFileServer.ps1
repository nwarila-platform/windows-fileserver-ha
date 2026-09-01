#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges one clustered file-server role and its exact static-IP surface.
    .DESCRIPTION
        Resolves the home disk and client networks from observed identity,
        computes one exact role-resource transaction, and verifies readback.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER ClusterName
        Exact failover cluster name.
    .PARAMETER RoleName
        Exact clustered file-server role name.
    .PARAMETER HomeVolumeId
        EBS volume identity of the role's home disk.
    .PARAMETER Owners
        Exact ordered preferred owners.
    .PARAMETER StaticAddress
        Exact role static IPv4 addresses.
    .PARAMETER IgnoredNetworkAddress
        Exact network base addresses excluded during creation.
    .OUTPUTS
        System.String
#>
[CmdletBinding(
  ConfirmImpact = 'None',
  DefaultParameterSetName = 'default',
  HelpUri = '',
  PositionalBinding = $False,
  RemotingCapability = 'PowerShell',
  SupportsPaging = $False,
  SupportsShouldProcess = $True
)]
Param (
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String] $DebugLevel = '103',
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String] $LogLevel = '002223',
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $ClusterName,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $RoleName,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $HomeVolumeId,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $Owners,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $StaticAddress,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $IgnoredNetworkAddress
)

#region ------ [ Script ] -------------------------------------------------------------------- #
#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'
$WhatIfPreference = $false
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)
New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:([System.Management.Automation.ActionPreference]::Stop)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:([System.Management.Automation.ActionPreference]::Stop)
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}
$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse($DebugLevel.Substring(0, 1))
Switch ($DebugLevel.Substring(1, 1)) {
  '0' { Set-PSDebug -Off }
  '1' { Set-PSDebug -Trace:1 }
  '2' { Set-PSDebug -Trace:2 }
  '3' { Set-PSDebug -Trace:1 -Step }
  '4' { Set-PSDebug -Trace:2 -Step }
}
If ($DebugLevel.Substring(2, 1) -eq '0') { Set-StrictMode -Off } Else { Set-StrictMode -Version:([System.String]$DebugLevel.Substring(2, 1)) }
Trap {
  Try {
    If ($PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord') {
      Write-Debug -Message:('Failed to execute command: {0}' -f [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line)
    }
    Write-Warning -Message:('[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      ))
  } Catch { Write-Debug -Message:'Trap diagnostics unavailable for this error record.' }
  Break
}
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $False; Failed = $False; Result = $Null }
}
$Ansible.Changed = $False
#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

$ConvertToIpv4UInt32 = {
  Param ([System.String]$Address)
  $Parsed = [System.Net.IPAddress]::None
  If (-not [System.Net.IPAddress]::TryParse($Address, [ref]$Parsed) -or
    $Parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    Throw ('Not an IPv4 address: {0}.' -f $Address)
  }
  $Bytes = $Parsed.GetAddressBytes()
  [Array]::Reverse($Bytes)
  [System.BitConverter]::ToUInt32($Bytes, 0)
}

$GetResourceParameterValue = {
  Param ([System.Object]$Resource, [System.String]$Name)
  $Value = @(Get-ClusterParameter -InputObject $Resource -Name $Name)
  If ($Value.Count -ne 1) { Throw ('Resource {0} must expose one {1} parameter.' -f $Resource.Name, $Name) }
  $Value[0].Value
}

$GetHomeDiskResource = {
  Param ([System.String]$Cluster, [System.String]$VolumeId)
  $Token = $VolumeId.ToLowerInvariant().Replace('-', '')
  $LocalDisks = @(Get-Disk)
  $LocalMatches = @($LocalDisks | Where-Object -FilterScript {
      (([System.String]$PSItem.UniqueId).ToLowerInvariant() -replace '[^0-9a-z]', '').Contains($Token)
    })
  If ($LocalMatches.Count -ne 1) { Throw ('Home volume {0} must match exactly one local disk.' -f $VolumeId) }
  $DiskResourceMatches = @()
  ForEach ($Resource In @(Get-ClusterResource -Cluster $Cluster | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' })) {
    $Guid = ([System.String](& $GetResourceParameterValue -Resource $Resource -Name 'DiskIdGuid')).Trim('{}')
    $Mapped = @($LocalDisks | Where-Object -FilterScript { ([System.String]$PSItem.Guid).Trim('{}') -ieq $Guid })
    If ($Mapped.Count -eq 1 -and (([System.String]$Mapped[0].UniqueId).ToLowerInvariant() -replace '[^0-9a-z]', '').Contains($Token)) {
      $DiskResourceMatches += $Resource
    }
  }
  If ($DiskResourceMatches.Count -ne 1) { Throw ('Home volume {0} must map to exactly one Physical Disk resource.' -f $VolumeId) }
  $Resource = $DiskResourceMatches[0]
  $PossibleOwners = @(Get-ClusterOwnerNode -InputObject $Resource | ForEach-Object -Process { ([System.String]$PSItem.Name).ToLowerInvariant() } | Sort-Object)
  $DesiredOwners = @($Owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Sort-Object)
  If ([System.String]$Resource.State -ne 'Online' -or @(Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $PossibleOwners).Count -gt 0) {
    Throw ('Home disk {0} must already be Online and owner-scoped to the declared owners.' -f $Resource.Name)
  }
  $Resource
}

$GetRoleState = {
  Param ([System.String]$Cluster, [System.String]$Name)
  $Groups = @(Get-ClusterGroup -Cluster $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq $Name })
  If ($Groups.Count -gt 1) { Throw ('File-server role {0} is ambiguous.' -f $Name) }
  If ($Groups.Count -eq 0) { Return $Null }
  $Group = $Groups[0]
  $Resources = @(Get-ClusterResource -Cluster $Cluster | Where-Object -FilterScript { [System.String]$PSItem.OwnerGroup -ieq $Name })
  $NameResources = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Network Name' })
  If ($NameResources.Count -ne 1) { Throw ('Role {0} must expose exactly one Network Name resource.' -f $Name) }
  $IpResources = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'IP Address' })
  $Ips = @(
    ForEach ($Resource In $IpResources) {
      [PSCustomObject]@{
        resource    = $Resource
        name        = [System.String]$Resource.Name
        state       = [System.String]$Resource.State
        address     = [System.String](& $GetResourceParameterValue -Resource $Resource -Name 'Address')
        network     = [System.String](& $GetResourceParameterValue -Resource $Resource -Name 'Network')
        subnet_mask = [System.String](& $GetResourceParameterValue -Resource $Resource -Name 'SubnetMask')
        enable_dhcp = [System.Int32](& $GetResourceParameterValue -Resource $Resource -Name 'EnableDhcp')
      }
    }
  )
  $DependencyRead = @(Get-ClusterResourceDependency -Resource $NameResources[0])
  $Dependency = ''
  If ($DependencyRead.Count -eq 1) {
    If ($DependencyRead[0].PSObject.Properties.Name -contains 'DependencyExpression') {
      $Dependency = [System.String]$DependencyRead[0].DependencyExpression
    } Else {
      $Dependency = [System.String]$DependencyRead[0]
    }
  }
  [PSCustomObject]@{
    group            = $Group
    name             = [System.String]$Group.Name
    state            = [System.String]$Group.State
    owner_node       = [System.String]$Group.OwnerNode
    preferred_owners = @(Get-ClusterOwnerNode -Group $Group | ForEach-Object -Process { [System.String]$PSItem.Name })
    resources        = $Resources
    name_resource    = $NameResources[0]
    ip_resources     = $Ips
    physical_disks   = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' })
    dependency       = $Dependency
  }
}

If ($HomeVolumeId -notmatch '^vol-[0-9a-fA-F]+$') { Throw ('Malformed HomeVolumeId: {0}.' -f $HomeVolumeId) }
$OwnerNames = @($Owners | ForEach-Object -Process { ([System.String]$PSItem).Trim() })
If ($OwnerNames.Count -ne 2 -or @($OwnerNames | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Select-Object -Unique).Count -ne 2) {
  Throw 'Owners must contain exactly two unique node names.'
}
$DesiredAddresses = @($StaticAddress | ForEach-Object -Process { ([System.String]$PSItem).Trim() })
$IgnoredAddresses = @($IgnoredNetworkAddress | ForEach-Object -Process { ([System.String]$PSItem).Trim() })
If ($DesiredAddresses.Count -ne 2 -or @($DesiredAddresses | Select-Object -Unique).Count -ne 2 -or
  $IgnoredAddresses.Count -ne 2 -or @($IgnoredAddresses | Select-Object -Unique).Count -ne 2) {
  Throw 'StaticAddress and IgnoredNetworkAddress must each contain two unique IPv4 values.'
}
ForEach ($Address In ($DesiredAddresses + $IgnoredAddresses)) { $Null = & $ConvertToIpv4UInt32 -Address $Address }

$HomeDisk = & $GetHomeDiskResource -Cluster $ClusterName -VolumeId $HomeVolumeId
$Networks = @(Get-ClusterNetwork -Cluster $ClusterName)
$StaticNetworks = @{}
ForEach ($Address In $DesiredAddresses) {
  $AddressInteger = & $ConvertToIpv4UInt32 -Address $Address
  $NetworkMatches = @($Networks | Where-Object -FilterScript {
      $MaskInteger = & $ConvertToIpv4UInt32 -Address ([System.String]$PSItem.AddressMask)
      $NetworkInteger = & $ConvertToIpv4UInt32 -Address ([System.String]$PSItem.Address)
      ($AddressInteger -band $MaskInteger) -eq ($NetworkInteger -band $MaskInteger)
    })
  If ($NetworkMatches.Count -ne 1) { Throw ('Static address {0} must map to exactly one cluster network.' -f $Address) }
  $StaticNetworks[$Address] = $NetworkMatches[0]
}
$IgnoredNetworks = @()
ForEach ($Address In $IgnoredAddresses) {
  $NetworkMatches = @($Networks | Where-Object -FilterScript { [System.String]$PSItem.Address -eq $Address })
  If ($NetworkMatches.Count -ne 1) { Throw ('Ignored network address {0} must map to exactly one cluster network.' -f $Address) }
  $IgnoredNetworks += $NetworkMatches[0]
}
$StaticNetworkNames = @($StaticNetworks.Values | ForEach-Object -Process { [System.String]$PSItem.Name } | Sort-Object -Unique)
$IgnoredNetworkNames = @($IgnoredNetworks | ForEach-Object -Process { [System.String]$PSItem.Name } | Sort-Object -Unique)
If (@(Compare-Object -ReferenceObject $StaticNetworkNames -DifferenceObject $IgnoredNetworkNames -IncludeEqual -ExcludeDifferent).Count -gt 0) {
  Throw 'Static and ignored network declarations overlap.'
}
$EligibleNetworkNames = @($Networks | Where-Object -FilterScript { [System.Int32]$PSItem.Role -in @(2, 3) } | ForEach-Object -Process { [System.String]$PSItem.Name } | Sort-Object -Unique)
$DeclaredNetworkNames = @(($StaticNetworkNames + $IgnoredNetworkNames) | Sort-Object -Unique)
If (@(Compare-Object -ReferenceObject $EligibleNetworkNames -DifferenceObject $DeclaredNetworkNames).Count -gt 0) {
  Throw 'Static and ignored declarations must cover every client-eligible cluster network exactly.'
}

$Before = & $GetRoleState -Cluster $ClusterName -Name $RoleName
$Current = $Before
$Actions = [System.Collections.Generic.List[System.String]]::new()
$IpTransaction = $False
$DesiredDependency = ''
If ($Null -eq $Before) {
  $Actions.Add('create_role')

  If (-not $Ansible.CheckMode) {
    $Null = Add-ClusterFileServerRole -Cluster $ClusterName -Name $RoleName -Storage $HomeDisk.Name -StaticAddress $DesiredAddresses -IgnoreNetwork $IgnoredNetworkNames -Wait 600
    $Current = & $GetRoleState -Cluster $ClusterName -Name $RoleName
  }
}

If ($Null -ne $Current) {
  $RolePhysicalNames = @($Current.physical_disks | ForEach-Object -Process { [System.String]$PSItem.Name })
  If ($RolePhysicalNames.Count -gt 0 -and ($RolePhysicalNames.Count -ne 1 -or $RolePhysicalNames[0] -ine [System.String]$HomeDisk.Name)) {
    Throw ('Role {0} contains a wrong or extra Physical Disk resource.' -f $RoleName)
  }
  If ($RolePhysicalNames.Count -eq 0) {
    If ([System.String]$HomeDisk.OwnerGroup -ne 'Available Storage') { Throw 'The home disk belongs to a foreign cluster group.' }
    $Actions.Add('move_home_disk')
  }
  $CurrentOwners = @($Current.preferred_owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  $DesiredOwners = @($OwnerNames | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  If ($CurrentOwners.Count -ne $DesiredOwners.Count -or (Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $CurrentOwners -SyncWindow 0)) {
    $Actions.Add('set_preferred_owners')
  }
  $DesiredIpObjects = @()
  ForEach ($Address In $DesiredAddresses) {
    $IpMatches = @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -eq $Address })
    If ($IpMatches.Count -gt 1) { Throw ('Role {0} has duplicate IP resources for {1}.' -f $RoleName, $Address) }
    $Network = $StaticNetworks[$Address]
    If ($IpMatches.Count -eq 0) {
      $Actions.Add(('add_ip:{0}' -f $Address))
      $IpTransaction = $True
      $DesiredIpObjects += [PSCustomObject]@{ address = $Address; name = "IP Address $Address"; network = [System.String]$Network.Name; subnet_mask = [System.String]$Network.AddressMask }
    } Else {
      $Ip = $IpMatches[0]
      $DesiredIpObjects += $Ip
      If ($Ip.network -ne [System.String]$Network.Name -or $Ip.subnet_mask -ne [System.String]$Network.AddressMask -or $Ip.enable_dhcp -ne 0) {
        $Actions.Add(('correct_ip:{0}' -f $Address))
        $IpTransaction = $True
      }
    }
  }
  ForEach ($Extra In @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -notin $DesiredAddresses })) {
    $Actions.Add(('remove_ip:{0}' -f $Extra.name))
    $IpTransaction = $True
  }
  $DesiredDependency = (($DesiredIpObjects | Sort-Object -Property address | ForEach-Object -Process { '[{0}]' -f $PSItem.name }) -join ' or ')
  If ($IpTransaction -or $Current.dependency -ne $DesiredDependency) {
    $Actions.Add('set_dependency')
    $IpTransaction = $True
  }
  If ($Current.state -ne 'Online' -and -not $IpTransaction) { $Actions.Add('start_group') }
}

If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
  $After = $Before
} Else {
  If ($Actions.Contains('move_home_disk')) { $Null = Move-ClusterResource -InputObject $HomeDisk -Group $RoleName }
  If ($Actions.Contains('set_preferred_owners')) { $Null = Set-ClusterOwnerNode -Group $RoleName -Owners $OwnerNames }
  If ($IpTransaction) {
    If ($Current.state -ne 'Offline') { $Null = Stop-ClusterGroup -Name $RoleName -Wait 600 }
    ForEach ($Action In @($Actions)) {
      If ($Action.StartsWith('add_ip:', [System.StringComparison]::Ordinal)) {
        $Address = $Action.Substring(7)
        $Network = $StaticNetworks[$Address]
        $Added = @(Add-ClusterResource -Name "IP Address $Address" -ResourceType 'IP Address' -Group $RoleName)
        If ($Added.Count -ne 1) { Throw ('Adding role IP {0} did not return one resource.' -f $Address) }
        $Parameters = @{ Address = $Address; Network = [System.String]$Network.Name; SubnetMask = [System.String]$Network.AddressMask; EnableDhcp = 0 }
        $Null = $Added[0] | Set-ClusterParameter -Multiple $Parameters
      } ElseIf ($Action.StartsWith('correct_ip:', [System.StringComparison]::Ordinal)) {
        $Address = $Action.Substring(11)
        $Ip = @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -eq $Address })[0]
        $Network = $StaticNetworks[$Address]
        $Parameters = @{ Address = $Address; Network = [System.String]$Network.Name; SubnetMask = [System.String]$Network.AddressMask; EnableDhcp = 0 }
        $Null = $Ip.resource | Set-ClusterParameter -Multiple $Parameters
      } ElseIf ($Action.StartsWith('remove_ip:', [System.StringComparison]::Ordinal)) {
        $ResourceName = $Action.Substring(10)
        $Extra = @($Current.ip_resources | Where-Object -FilterScript { $PSItem.name -eq $ResourceName })[0]
        If ($Extra.state -ne 'Offline') { $Null = Stop-ClusterResource -InputObject $Extra.resource -Wait 300 }
        $Null = Remove-ClusterResource -InputObject $Extra.resource -Force
      }
    }
    $Current = & $GetRoleState -Cluster $ClusterName -Name $RoleName
    $DesiredDependency = (($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -in $DesiredAddresses } | Sort-Object -Property address | ForEach-Object -Process { '[{0}]' -f $PSItem.name }) -join ' or ')
    $Null = Set-ClusterResourceDependency -Resource $Current.name_resource -Dependency $DesiredDependency
    $Null = Start-ClusterGroup -Name $RoleName -Wait 600
  } ElseIf ($Actions.Contains('start_group')) {
    $Null = Start-ClusterGroup -Name $RoleName -Wait 600
  }
  $After = & $GetRoleState -Cluster $ClusterName -Name $RoleName
}

If (-not $Ansible.CheckMode -or $Actions.Count -eq 0) {
  If ($Null -eq $After -or $After.state -ne 'Online' -or $After.owner_node.ToLowerInvariant() -notin @($OwnerNames | ForEach-Object -Process { $PSItem.ToLowerInvariant() })) {
    Throw ('Role {0} failed group-state readback.' -f $RoleName)
  }
  $AfterOwners = @($After.preferred_owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  $DesiredOwners = @($OwnerNames | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  If ($AfterOwners.Count -ne 2 -or (Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $AfterOwners -SyncWindow 0)) { Throw 'Role preferred-owner readback failed.' }
  If ($After.physical_disks.Count -ne 1 -or [System.String]$After.physical_disks[0].Name -ine [System.String]$HomeDisk.Name -or [System.String]$After.physical_disks[0].State -ne 'Online') {
    Throw 'Role home-disk readback failed.'
  }
  If ($After.ip_resources.Count -ne 2 -or @($After.ip_resources | Where-Object -FilterScript { $PSItem.address -notin $DesiredAddresses }).Count -gt 0 -or
    @($After.ip_resources | Where-Object -FilterScript { $PSItem.enable_dhcp -ne 0 }).Count -gt 0 -or
    @($After.ip_resources | Where-Object -FilterScript { $PSItem.state -eq 'Online' }).Count -ne 1) {
    Throw 'Role static-IP membership/state readback failed.'
  }
  ForEach ($Ip In $After.ip_resources) {
    $Network = $StaticNetworks[$Ip.address]
    If ($Ip.network -ne [System.String]$Network.Name -or $Ip.subnet_mask -ne [System.String]$Network.AddressMask) { Throw 'Role static-IP network readback failed.' }
  }
  $ExactDependency = (($After.ip_resources | Sort-Object -Property address | ForEach-Object -Process { '[{0}]' -f $PSItem.name }) -join ' or ')
  If ($After.dependency -ne $ExactDependency) { Throw 'Role Network Name dependency readback failed.' }
}

$Result = [PSCustomObject]@{
  changed    = $Actions.Count -gt 0
  check_mode = [System.Boolean]$Ansible.CheckMode
  actions    = @($Actions)
  before     = $Before
  after      = $After
  msg        = $(If ($Actions.Count -eq 0) { 'Clustered file-server role already matches.' } ElseIf ($Ansible.CheckMode) { 'Check mode: clustered file-server role would be converged.' } Else { 'Clustered file-server role converged.' })
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) { $Result | ConvertTo-Json -Depth:7 }
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
