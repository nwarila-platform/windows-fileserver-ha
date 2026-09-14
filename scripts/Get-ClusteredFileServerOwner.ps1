#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Reads the Online owner of one declared clustered file-server role.
    .DESCRIPTION
        Requires exactly one local cluster with the declared name and exactly one Online cluster
        group with the declared role name, then returns its owner node without mutation.
    .PARAMETER ClusterName
        Declared failover-cluster name.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER RoleName
        Declared clustered file-server role name.
    .OUTPUTS
        System.Object
#>
[CmdletBinding(
  ConfirmImpact = 'None',
  DefaultParameterSetName = 'default',
  HelpUri = '',
  PositionalBinding = $False,
  RemotingCapability = 'PowerShell',
  SupportsPaging = $False,
  SupportsShouldProcess = $False
)]
[OutputType([System.Object])]
Param (
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $ClusterName,

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $RoleName
)

#region ------ [ Script ] -------------------------------------------------------------------- #
#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

$WhatIfPreference = $False
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

# Cluster truth is local until the cluster name can resolve.
$Clusters = @(Get-Cluster)
If ($Clusters.Count -ne 1) { Throw "Expected one local cluster; found $($Clusters.Count)." }
$Cluster = $Clusters[0]
If ([System.String]$Cluster.Name -ine $ClusterName) {
  Throw "The local node belongs to cluster $($Cluster.Name), not $ClusterName."
}
$Groups = @(Get-ClusterGroup -InputObject:$Cluster | Where-Object -FilterScript {
    [System.String]$PSItem.Name -eq $RoleName
  })
If ($Groups.Count -ne 1 -or [System.String]$Groups[0].State -ne 'Online') {
  Throw "Clustered file-server role $RoleName must exist exactly once and be Online."
}
$Result = [PSCustomObject]@{ owner_node = [System.String]$Groups[0].OwnerNode }
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $False
$Ansible.Result = $Result
If ($StandaloneRun) {
  $Result | ConvertTo-Json -Depth:2
} Else {
  Write-Output -InputObject:$Result
}
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
