#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Forms the declared failover cluster or completes an interrupted node join.
    .DESCRIPTION
        Reads and validates cluster identity, creates an absent cluster or adds
        declared missing nodes, then reacquires and proves exact state.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER ClusterName
        Exact failover cluster name.
    .PARAMETER Node
        Exact ordered cluster node names.
    .PARAMETER StaticAddress
        Exact ordered cluster-core static IPv4 addresses.
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
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $Node,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $StaticAddress
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

$ConvertToNormalizedNameSet = {
  Param ([System.String[]]$Value, [System.String]$Label)
  $Normalized = @($Value | ForEach-Object -Process { ([System.String]$PSItem).Trim().ToLowerInvariant() })
  If ($Normalized.Count -eq 0 -or @($Normalized | Where-Object -FilterScript { [System.String]::IsNullOrWhiteSpace($PSItem) }).Count -gt 0 -or
    @($Normalized | Select-Object -Unique).Count -ne $Normalized.Count) {
    Throw ('{0} must contain non-empty unique values.' -f $Label)
  }
  $Normalized
}

$GetClusterCoreState = {
  Param ([System.String]$Name)
  $Clusters = @(Get-Cluster -Name $Name -ErrorAction SilentlyContinue)
  If ($Clusters.Count -eq 0) { Return $Null }
  If ($Clusters.Count -ne 1) { Throw ('Cluster identity {0} is ambiguous.' -f $Name) }
  $Cluster = $Clusters[0]
  $Nodes = @(Get-ClusterNode -Cluster $Name)
  $CoreGroups = @(Get-ClusterGroup -Cluster $Name | Where-Object -FilterScript { [System.String]$PSItem.GroupType -eq 'Cluster' })
  If ($CoreGroups.Count -ne 1) { Throw ('Cluster {0} must expose exactly one core group.' -f $Name) }
  $CoreGroupName = [System.String]$CoreGroups[0].Name
  $Resources = @(Get-ClusterResource -Cluster $Name)
  $IpResources = @($Resources | Where-Object -FilterScript {
      [System.String]$PSItem.ResourceType -eq 'IP Address' -and [System.String]$PSItem.OwnerGroup -eq $CoreGroupName
    })
  $Addresses = @(
    ForEach ($Resource In $IpResources) {
      $Parameter = @(Get-ClusterParameter -InputObject $Resource -Name 'Address')
      If ($Parameter.Count -ne 1 -or [System.String]::IsNullOrWhiteSpace([System.String]$Parameter[0].Value)) {
        Throw ('Core IP resource {0} has no single Address parameter.' -f $Resource.Name)
      }
      ([System.String]$Parameter[0].Value).Trim()
    }
  )
  [PSCustomObject]@{
    cluster        = $Cluster
    name           = [System.String]$Cluster.Name
    nodes          = @($Nodes | ForEach-Object -Process { [PSCustomObject]@{ name = [System.String]$PSItem.Name; state = [System.String]$PSItem.State } })
    addresses      = $Addresses
    physical_disks = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' })
  }
}

$DesiredNodes = @(& $ConvertToNormalizedNameSet -Value $Node -Label 'Node')
$DesiredAddresses = @(& $ConvertToNormalizedNameSet -Value $StaticAddress -Label 'StaticAddress')
ForEach ($Address In $StaticAddress) {
  $Parsed = [System.Net.IPAddress]::None
  If (-not [System.Net.IPAddress]::TryParse($Address, [ref]$Parsed) -or
    $Parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    Throw ('StaticAddress contains a non-IPv4 value: {0}.' -f $Address)
  }
}

$Before = & $GetClusterCoreState -Name $ClusterName
$Actions = [System.Collections.Generic.List[System.String]]::new()
If ($Null -eq $Before) {
  $LocalClusters = @(Get-Cluster -ErrorAction SilentlyContinue)
  If ($LocalClusters.Count -gt 0 -and @($LocalClusters | Where-Object -FilterScript { [System.String]$PSItem.Name -ine $ClusterName }).Count -gt 0) {
    Throw ('The local node already belongs to a differently named cluster: {0}.' -f (($LocalClusters.Name | Sort-Object) -join ', '))
  }
  $Actions.Add('create_cluster')
} Else {
  $CurrentNodes = @($Before.nodes | ForEach-Object -Process { $PSItem.name.ToLowerInvariant() })
  $UnexpectedNodes = @($CurrentNodes | Where-Object -FilterScript { $PSItem -notin $DesiredNodes })
  If ($UnexpectedNodes.Count -gt 0) {
    Throw ('Cluster {0} contains unexpected nodes: {1}.' -f $ClusterName, ($UnexpectedNodes -join ', '))
  }
  $CurrentAddresses = @($Before.addresses | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  If (@(Compare-Object -ReferenceObject $DesiredAddresses -DifferenceObject $CurrentAddresses).Count -gt 0) {
    Throw ('Cluster {0} core address identity differs from the declaration.' -f $ClusterName)
  }
  For ($Index = 0; $Index -lt $DesiredNodes.Count; $Index++) {
    If ($DesiredNodes[$Index] -notin $CurrentNodes) { $Actions.Add(('add_node:{0}' -f $Node[$Index])) }
  }
}

If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
  $After = $Before
} Else {
  If ($Actions.Contains('create_cluster')) {
    $Null = New-Cluster -Name $ClusterName -Node $Node -StaticAddress $StaticAddress -NoStorage -Force
  } Else {
    ForEach ($Action In $Actions) {
      If ($Action.StartsWith('add_node:', [System.StringComparison]::Ordinal)) {
        $MissingNode = $Action.Substring(9)
        $Null = Add-ClusterNode -Cluster $ClusterName -Name $MissingNode -NoStorage
      }
    }
  }
  $After = & $GetClusterCoreState -Name $ClusterName
}

If (-not $Ansible.CheckMode -or $Actions.Count -eq 0) {
  If ($Null -eq $After -or $After.name -ine $ClusterName) {
    Throw ('Cluster {0} was not reacquired after mutation.' -f $ClusterName)
  }
  $AfterNodes = @($After.nodes | ForEach-Object -Process { $PSItem.name.ToLowerInvariant() })
  $AfterAddresses = @($After.addresses | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  If (@(Compare-Object -ReferenceObject $DesiredNodes -DifferenceObject $AfterNodes).Count -gt 0 -or
    @($After.nodes | Where-Object -FilterScript { $PSItem.state -ne 'Up' }).Count -gt 0 -or
    @(Compare-Object -ReferenceObject $DesiredAddresses -DifferenceObject $AfterAddresses).Count -gt 0) {
    Throw ('Cluster {0} failed exact node/state/address readback.' -f $ClusterName)
  }
  If ($Actions.Contains('create_cluster') -and $After.physical_disks.Count -ne 0) {
    Throw ('Cluster {0} auto-added Physical Disk resources despite the -NoStorage formation contract.' -f $ClusterName)
  }
}

$Result = [PSCustomObject]@{
  changed    = $Actions.Count -gt 0
  check_mode = [System.Boolean]$Ansible.CheckMode
  actions    = @($Actions)
  before     = $Before
  after      = $After
  msg        = $(If ($Actions.Count -eq 0) { 'File server cluster already matches.' } ElseIf ($Ansible.CheckMode) { 'Check mode: file server cluster would be converged.' } Else { 'File server cluster converged.' })
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
