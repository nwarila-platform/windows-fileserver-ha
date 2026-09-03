#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Adopts one declared EBS disk by volume identity and constrains its owners.
    .DESCRIPTION
        Maps one declared volume through local UniqueId and cluster DiskIdGuid,
        then adopts, owner-scopes, conditionally starts, reacquires, and verifies it.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER ClusterName
        Exact failover cluster name.
    .PARAMETER Disk
        Exact Function, VolumeId, Owners, and FileServerHome declaration.
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
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.Collections.IDictionary] $Disk
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

# Result payloads contain primitives only; live cmdlet objects remain internal.
$ConvertToSafeDiskState = {
  Param ([System.Object]$State)
  If ($Null -eq $State) { Return $Null }
  [PSCustomObject]@{
    function           = [System.String]$State.function
    volume_id          = [System.String]$State.volume_id
    expected_serial    = [System.String]$State.expected_serial
    resource_name      = $(If ($Null -eq $State.resource) { $Null } Else { [System.String]$State.resource.Name })
    disk_id_guid       = $(If ($Null -eq $State.disk_id_guid) { $Null } Else { [System.String]$State.disk_id_guid })
    observed_unique_id = [System.String]$State.observed_unique_id
    state              = $(If ($Null -eq $State.resource) { $Null } Else { [System.String]$State.resource.State })
    possible_owners    = @($State.possible_owners | ForEach-Object -Process { [System.String]$PSItem })
  }
}

$GetDeclaredDiskState = {
  Param (
    [System.Object]$Cluster,
    [System.String]$Function,
    [System.String]$VolumeId,
    [System.String[]]$Owners
  )
  $Token = $VolumeId.ToLowerInvariant().Replace('-', '')
  $LocalDisks = @(Get-Disk)
  $LocalMatches = @($LocalDisks | Where-Object -FilterScript {
      (([System.String]$PSItem.UniqueId).ToLowerInvariant() -replace '[^0-9a-z]', '').Contains($Token)
    })
  If ($LocalMatches.Count -ne 1) {
    $SafeIdentities = @($LocalDisks | ForEach-Object -Process { [System.String]$PSItem.UniqueId }) -join ', '
    Throw ('Volume {0} must match exactly one local UniqueId; found {1}. Observed identities: {2}.' -f $VolumeId, $LocalMatches.Count, $SafeIdentities)
  }
  $LocalDisk = $LocalMatches[0]
  $Resources = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' })
  $ResourceMatches = @()
  $MatchDetails = @{}
  ForEach ($Resource In $Resources) {
    $Parameters = @(Get-ClusterParameter -InputObject $Resource -Name 'DiskIdGuid')
    If ($Parameters.Count -ne 1 -or [System.String]::IsNullOrWhiteSpace([System.String]$Parameters[0].Value)) {
      Throw ('Physical Disk resource {0} has no single DiskIdGuid.' -f $Resource.Name)
    }
    $DiskIdGuid = ([System.String]$Parameters[0].Value).Trim('{}')
    $Mapped = @($LocalDisks | Where-Object -FilterScript { ([System.String]$PSItem.Guid).Trim('{}') -ieq $DiskIdGuid })
    If ($Mapped.Count -eq 1) {
      $ObservedToken = (([System.String]$Mapped[0].UniqueId).ToLowerInvariant() -replace '[^0-9a-z]', '')
      If ($ObservedToken.Contains($Token)) {
        $ResourceMatches += $Resource
        $MatchDetails[[System.String]$Resource.Name] = [PSCustomObject]@{ DiskIdGuid = $DiskIdGuid; UniqueId = [System.String]$Mapped[0].UniqueId }
      }
    }
  }
  If ($ResourceMatches.Count -gt 1) {
    Throw ('Volume {0} ambiguously maps to {1} Physical Disk resources.' -f $VolumeId, $ResourceMatches.Count)
  }
  $Resource = $(If ($ResourceMatches.Count -eq 1) { $ResourceMatches[0] } Else { $Null })
  $PossibleOwners = @()
  $DiskId = $Null
  $UniqueId = [System.String]$LocalDisk.UniqueId
  If ($Null -ne $Resource) {
    $Detail = $MatchDetails[[System.String]$Resource.Name]
    $DiskId = $Detail.DiskIdGuid
    $UniqueId = $Detail.UniqueId
    $OwnerNodeState = Get-ClusterOwnerNode -InputObject $Resource
    $PossibleOwners = @($OwnerNodeState.OwnerNodes | ForEach-Object -Process { [System.String]$PSItem.Name })
  }
  [PSCustomObject]@{
    function           = $Function
    volume_id          = $VolumeId
    expected_serial    = $Token
    local_disk         = $LocalDisk
    resource           = $Resource
    disk_id_guid       = $DiskId
    observed_unique_id = $UniqueId
    possible_owners    = $PossibleOwners
    desired_owners     = $Owners
  }
}

$ExpectedKeys = @('FileServerHome', 'Function', 'Owners', 'VolumeId')
$ActualKeys = @($Disk.Keys | ForEach-Object -Process { [System.String]$PSItem } | Sort-Object)
If (@(Compare-Object -ReferenceObject $ExpectedKeys -DifferenceObject $ActualKeys).Count -gt 0) {
  Throw 'Disk must contain exactly Function, VolumeId, Owners, and FileServerHome.'
}
$VolumeId = ([System.String]$Disk.VolumeId).Trim().ToLowerInvariant()
If ($VolumeId -notmatch '^vol-[0-9a-f]+$') { Throw ('Malformed EBS volume ID: {0}.' -f $VolumeId) }
$Owners = @($Disk.Owners | ForEach-Object -Process { ([System.String]$PSItem).Trim() })
If ($Owners.Count -ne 2 -or @($Owners | Where-Object -FilterScript { [System.String]::IsNullOrWhiteSpace($PSItem) }).Count -gt 0 -or
  @($Owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Select-Object -Unique).Count -ne 2) {
  Throw 'Disk.Owners must contain exactly two unique node names.'
}
# Cluster truth is local until the cluster name can resolve.
$Clusters = @(Get-Cluster)
If ($Clusters.Count -ne 1) { Throw ('Expected one local cluster; found {0}.' -f $Clusters.Count) }
$Cluster = $Clusters[0]
If ([System.String]$Cluster.Name -ine $ClusterName) {
  Throw ('The local node belongs to cluster {0}, not {1}.' -f $Cluster.Name, $ClusterName)
}
$ClusterNodes = @(Get-ClusterNode -InputObject $Cluster | ForEach-Object -Process { ([System.String]$PSItem.Name).ToLowerInvariant() })
If (@($Owners | Where-Object -FilterScript { $PSItem.ToLowerInvariant() -notin $ClusterNodes }).Count -gt 0) {
  Throw 'Disk.Owners contains a node absent from the cluster.'
}

$Before = & $GetDeclaredDiskState -Cluster $Cluster -Function ([System.String]$Disk.Function) -VolumeId $VolumeId -Owners $Owners
$Actions = [System.Collections.Generic.List[System.String]]::new()
$OnlineDeferred = $False
If ($Null -eq $Before.resource) {
  $Actions.Add('adopt_disk')
  $Actions.Add('set_possible_owners')
} Else {
  $CurrentOwners = @($Before.possible_owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Sort-Object)
  $DesiredOwners = @($Owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Sort-Object)
  If (@(Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $CurrentOwners).Count -gt 0) { $Actions.Add('set_possible_owners') }
  If ([System.String]$Before.resource.State -ne 'Online') {
    $OwningGroups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq [System.String]$Before.resource.OwnerGroup })
    If ($OwningGroups.Count -ne 1) { Throw ('Physical Disk resource {0} must belong to exactly one cluster group.' -f $Before.resource.Name) }
    If ([System.String]$OwningGroups[0].OwnerNode -iin $Owners) {
      $Actions.Add('start_disk')
    } Else {
      $Actions.Add('defer_online')
      $OnlineDeferred = $True
    }
  }
}

If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
  $After = $Before
} Else {
  $Resource = $Before.resource
  If ($Actions.Contains('adopt_disk')) {
    $Added = @(Add-ClusterDisk -InputObject $Before.local_disk)
    If ($Added.Count -ne 1) { Throw ('Add-ClusterDisk for {0} did not return exactly one resource.' -f $VolumeId) }
    $Resource = $Added[0]
  }
  If ($Actions.Contains('set_possible_owners')) {
    $Null = $Resource | Set-ClusterOwnerNode -Owners $Owners
  }
  If ([System.String]$Resource.State -ne 'Online') {
    # Available Storage has one owner; a disk whose pair excludes that owner is placeable only
    # after the role region finalizes the storage layout.
    If ($Actions.Contains('start_disk')) {
      $Null = Start-ClusterResource -InputObject $Resource -Wait 300
    } ElseIf ($Actions.Contains('defer_online')) {
      $OnlineDeferred = $True
    } Else {
      $OwningGroups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq [System.String]$Resource.OwnerGroup })
      If ($OwningGroups.Count -ne 1) { Throw ('Physical Disk resource {0} must belong to exactly one cluster group.' -f $Resource.Name) }
      If ([System.String]$OwningGroups[0].OwnerNode -iin $Owners) {
        $Actions.Add('start_disk')
        $Null = Start-ClusterResource -InputObject $Resource -Wait 300
      } Else {
        $Actions.Add('defer_online')
        $OnlineDeferred = $True
      }
    }
  }
  $After = & $GetDeclaredDiskState -Cluster $Cluster -Function ([System.String]$Disk.Function) -VolumeId $VolumeId -Owners $Owners
  $AfterOwners = @($After.possible_owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Sort-Object)
  $DesiredOwners = @($Owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Sort-Object)
  $ObservedToken = ($After.observed_unique_id.ToLowerInvariant() -replace '[^0-9a-z]', '')
  If ($Null -eq $After.resource -or [System.String]::IsNullOrWhiteSpace([System.String]$After.disk_id_guid) -or
    -not $ObservedToken.Contains($Before.expected_serial) -or (-not $OnlineDeferred -and [System.String]$After.resource.State -ne 'Online') -or
    @(Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $AfterOwners).Count -gt 0) {
    Throw ('Shared disk {0} failed identity, state, or possible-owner readback.' -f $Disk.Function)
  }
}

$Changed = @($Actions | Where-Object -FilterScript { $PSItem -ne 'defer_online' }).Count -gt 0
$Result = [PSCustomObject]@{
  changed         = $Changed
  check_mode      = [System.Boolean]$Ansible.CheckMode
  actions         = @($Actions)
  online_deferred = $OnlineDeferred
  before          = & $ConvertToSafeDiskState -State $Before
  after           = & $ConvertToSafeDiskState -State $After
  msg             = $(If ($OnlineDeferred -and $Changed) { 'Shared disk converged; online placement deferred.' } ElseIf ($OnlineDeferred) { 'Shared disk online placement deferred.' } ElseIf ($Actions.Count -eq 0) { 'Shared disk already matches.' } ElseIf ($Ansible.CheckMode) { 'Check mode: shared disk would be converged.' } Else { 'Shared disk converged.' })
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) { $Result | ConvertTo-Json -Depth:5 }
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
