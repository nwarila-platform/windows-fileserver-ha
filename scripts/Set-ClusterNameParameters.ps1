#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges the two declared Cluster Name resource parameters.
    .DESCRIPTION
        Reads, diffs, mutates only drift, reacquires, and verifies the exact
        DNS registration parameters owned by the Cluster Name resource.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER ClusterName
        Name of the failover cluster.
    .PARAMETER ResourceName
        Exact Cluster Name resource name.
    .PARAMETER RegisterAllProvidersIP
        Desired RegisterAllProvidersIP integer.
    .PARAMETER HostRecordTTL
        Desired HostRecordTTL integer.
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
  [System.String]
  $DebugLevel = '103',

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [System.String]
  $ClusterName,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [System.String]
  $ResourceName,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [System.Int32]
  $RegisterAllProvidersIP,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [System.Int32]
  $HostRecordTTL
)

#region ------ [ Script ] -------------------------------------------------------------------- #
#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

$WhatIfPreference = $false
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)
New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)
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

$GetNameResourceState = {
  [CmdletBinding()]
  Param (
    [Parameter(Mandatory = $True)] [System.String] $Name,
    [Parameter(Mandatory = $True)] [System.Object] $Cluster
  )

  $Resources = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript { $PSItem.Name -ieq $Name })
  If ($Resources.Count -ne 1) {
    Throw ('Cluster {0} must expose exactly one resource named {1}; found {2}.' -f $Cluster.Name, $Name, $Resources.Count)
  }
  $Resource = $Resources[0]
  If ([System.String]$Resource.ResourceType -ne 'Network Name' -or [System.String]$Resource.OwnerGroup -ne 'Cluster Group') {
    Throw ('Resource {0} must be a Network Name owned by Cluster Group.' -f $Name)
  }

  $Register = @(Get-ClusterParameter -InputObject $Resource -Name 'RegisterAllProvidersIP')
  $Ttl = @(Get-ClusterParameter -InputObject $Resource -Name 'HostRecordTTL')
  If ($Register.Count -ne 1 -or $Ttl.Count -ne 1) {
    Throw ('Resource {0} must expose one RegisterAllProvidersIP and one HostRecordTTL parameter.' -f $Name)
  }
  $RegisterValue = 0
  $TtlValue = 0
  If (-not [System.Int32]::TryParse([System.String]$Register[0].Value, [ref]$RegisterValue) -or
    -not [System.Int32]::TryParse([System.String]$Ttl[0].Value, [ref]$TtlValue)) {
    Throw ('Resource {0} returned a non-integral cluster name parameter.' -f $Name)
  }

  [PSCustomObject]@{
    resource                  = $Resource
    register_all_providers_ip = $RegisterValue
    host_record_ttl           = $TtlValue
  }
}

# Cluster truth is local until the cluster name can resolve.
$Clusters = @(Get-Cluster)
If ($Clusters.Count -ne 1) { Throw ('Expected one local cluster; found {0}.' -f $Clusters.Count) }
$Cluster = $Clusters[0]
If ([System.String]$Cluster.Name -ine $ClusterName) {
  Throw ('The local node belongs to cluster {0}, not {1}.' -f $Cluster.Name, $ClusterName)
}

$Before = & $GetNameResourceState -Name $ResourceName -Cluster $Cluster
$Actions = [System.Collections.Generic.List[System.String]]::new()
If ($Before.register_all_providers_ip -ne $RegisterAllProvidersIP) {
  $Actions.Add('set_register_all_providers_ip')
}
If ($Before.host_record_ttl -ne $HostRecordTTL) {
  $Actions.Add('set_host_record_ttl')
}

If ($Actions.Count -eq 0) {
  $After = $Before
} ElseIf ($Ansible.CheckMode) {
  $After = $Before
} Else {
  If ($Actions.Contains('set_register_all_providers_ip')) {
    $Null = $Before.resource | Set-ClusterParameter -Name 'RegisterAllProvidersIP' -Value $RegisterAllProvidersIP
  }
  If ($Actions.Contains('set_host_record_ttl')) {
    $Null = $Before.resource | Set-ClusterParameter -Name 'HostRecordTTL' -Value $HostRecordTTL
  }
  $After = & $GetNameResourceState -Name $ResourceName -Cluster $Cluster
  If ($After.register_all_providers_ip -ne $RegisterAllProvidersIP -or
    $After.host_record_ttl -ne $HostRecordTTL) {
    Throw ('Cluster Name parameter readback failed for resource {0}.' -f $ResourceName)
  }
}

# Result payloads contain primitives only; live cmdlet objects remain internal.
$Result = [PSCustomObject]@{
  changed    = $Actions.Count -gt 0
  check_mode = [System.Boolean]$Ansible.CheckMode
  actions    = @($Actions)
  before     = [PSCustomObject]@{
    register_all_providers_ip = [System.Int32]$Before.register_all_providers_ip
    host_record_ttl           = [System.Int32]$Before.host_record_ttl
  }
  after      = [PSCustomObject]@{
    register_all_providers_ip = [System.Int32]$After.register_all_providers_ip
    host_record_ttl           = [System.Int32]$After.host_record_ttl
  }
  msg        = $(If ($Actions.Count -eq 0) { 'Cluster Name parameters already match.' } ElseIf ($Ansible.CheckMode) { 'Check mode: Cluster Name parameters would be converged.' } Else { 'Cluster Name parameters converged.' })
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) {
  $Result | ConvertTo-Json -Depth:4
}
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
