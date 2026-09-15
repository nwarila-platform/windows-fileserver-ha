#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges a failover cluster on Node and File Share Majority quorum.
    .DESCRIPTION
        Resolves exactly one local cluster, compares its quorum resource and SharePath to the
        declared witness UNC, applies Set-ClusterQuorum when drift exists, and verifies readback.
    .PARAMETER ClusterName
        Exact local failover cluster name.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER WitnessPath
        Exact UNC path of the dedicated file-share witness.
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
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?$')]
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
  [ValidatePattern('^\\\\[^\\]+\\[^\\]+$')]
  [System.String]
  $WitnessPath
)

#region ------ [ Script ] -------------------------------------------------------------------- #
#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

$WhatIfRequested = [System.Boolean]$WhatIfPreference
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
  $Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $WhatIfRequested; Failed = $False; Result = $Null }
}
$Ansible.Changed = $False
#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

$Clusters = @(Get-Cluster -ErrorAction Stop | Where-Object -FilterScript {
    [System.String]$PSItem.Name -ieq $ClusterName
  })
If ($Clusters.Count -ne 1) {
  Throw ('Expected exactly one local cluster named {0}; found {1}.' -f $ClusterName, $Clusters.Count)
}
$Cluster = $Clusters[0]

$BeforeQuorum = Get-ClusterQuorum -InputObject $Cluster
$BeforeResource = $BeforeQuorum.QuorumResource
$BeforeResourceType = ''
$BeforeResourceState = ''
$BeforeSharePath = ''
If ($Null -ne $BeforeResource) {
  $BeforeResourceType = [System.String]$BeforeResource.ResourceType
  $BeforeResourceState = [System.String]$BeforeResource.State
  If ($BeforeResourceType -eq 'File Share Witness') {
    $BeforeSharePathParameters = @(Get-ClusterParameter -InputObject $BeforeResource -Name 'SharePath')
    If ($BeforeSharePathParameters.Count -ne 1) {
      Throw ('Expected exactly one SharePath parameter on the quorum resource; found {0}.' -f $BeforeSharePathParameters.Count)
    }
    $BeforeSharePath = [System.String]$BeforeSharePathParameters[0].Value
  }
}
$BeforeQuorumType = [System.String]$BeforeQuorum.QuorumType
$BeforeExact = (
  $BeforeQuorumType -eq 'NodeAndFileShareMajority' -and
  $BeforeResourceType -eq 'File Share Witness' -and
  $BeforeResourceState -eq 'Online' -and
  $BeforeSharePath -ieq $WitnessPath
)
$Before = [PSCustomObject]@{
  exact          = [System.Boolean]$BeforeExact
  quorum_type    = $BeforeQuorumType
  resource_state = $BeforeResourceState
  resource_type  = $BeforeResourceType
  share_path     = $BeforeSharePath
}

$Actions = [System.Collections.Generic.List[System.String]]::new()
If (-not $Before.exact) { $Actions.Add('set_file_share_witness') }

If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
  $After = $Before
} Else {
  $Null = Set-ClusterQuorum -InputObject $Cluster -FileShareWitness $WitnessPath
  $AfterQuorum = Get-ClusterQuorum -InputObject $Cluster
  $AfterResource = $AfterQuorum.QuorumResource
  $AfterResourceType = ''
  $AfterResourceState = ''
  $AfterSharePath = ''
  If ($Null -ne $AfterResource) {
    $AfterResourceType = [System.String]$AfterResource.ResourceType
    $AfterResourceState = [System.String]$AfterResource.State
    If ($AfterResourceType -eq 'File Share Witness') {
      $AfterSharePathParameters = @(Get-ClusterParameter -InputObject $AfterResource -Name 'SharePath')
      If ($AfterSharePathParameters.Count -ne 1) {
        Throw ('Expected exactly one SharePath parameter on the quorum resource; found {0}.' -f $AfterSharePathParameters.Count)
      }
      $AfterSharePath = [System.String]$AfterSharePathParameters[0].Value
    }
  }
  $AfterQuorumType = [System.String]$AfterQuorum.QuorumType
  $AfterExact = (
    $AfterQuorumType -eq 'NodeAndFileShareMajority' -and
    $AfterResourceType -eq 'File Share Witness' -and
    $AfterResourceState -eq 'Online' -and
    $AfterSharePath -ieq $WitnessPath
  )
  $After = [PSCustomObject]@{
    exact          = [System.Boolean]$AfterExact
    quorum_type    = $AfterQuorumType
    resource_state = $AfterResourceState
    resource_type  = $AfterResourceType
    share_path     = $AfterSharePath
  }
  If (-not $After.exact) {
    Throw ('Quorum readback failed for {0} with witness {1}.' -f $ClusterName, $WitnessPath)
  }
}

$Result = [PSCustomObject]@{
  changed      = $Actions.Count -gt 0
  check_mode   = [System.Boolean]$Ansible.CheckMode
  actions      = @($Actions)
  cluster_name = [System.String]$Cluster.Name
  witness_path = $WitnessPath
  before       = $Before
  after        = $After
  msg          = $(If ($Actions.Count -eq 0) { 'Cluster quorum already matches.' } ElseIf ($Ansible.CheckMode) { 'Check mode: cluster quorum would be converged.' } Else { 'Cluster quorum converged.' })
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) {
  $Result | ConvertTo-Json -Depth:5
}
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
