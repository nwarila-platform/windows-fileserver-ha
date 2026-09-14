#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges the declared domain-controller reverse-zone NRPT rule.
    .DESCRIPTION
        Treats Comment as the exact ownership marker, refuses a foreign rule for the same
        namespace before mutation, establishes a replacement before removing stale owned
        rules, and verifies exact namespace and name-server state from a fresh readback.
    .PARAMETER Comment
        Exact ownership marker for the managed rule.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER NameServers
        Ordered name-server addresses for the reverse zone.
    .PARAMETER Namespace
        Reverse-zone namespace to pin.
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
[OutputType([System.String])]
Param (
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Comment,

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
  [System.String[]]
  $NameServers,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Namespace
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
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $WhatIfRequested
    Failed    = $False
    Result    = $Null
  }
}
$DesiredServers = $NameServers -join ','
$Ansible.Changed = $False
#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

$Rules = @(Get-DnsClientNrptRule)
$Existing = @($Rules | Where-Object -FilterScript { [System.String]$PSItem.Comment -ceq $Comment })
$Foreign = @($Rules | Where-Object -FilterScript {
    @($PSItem.Namespace) -contains $Namespace -and [System.String]$PSItem.Comment -cne $Comment
  })
If ($Foreign.Count -gt 0) {
  Throw "A foreign NRPT rule already names $Namespace; refusing to shadow it."
}

$Changed = $False
$Action = 'none'
If ($Existing.Count -eq 0) {
  $Changed = $True
  $Action = 'add'
} ElseIf ($Existing.Count -gt 1) {
  $Changed = $True
  $Action = 'replace'
} Else {
  $CurrentNamespace = $Existing[0].Namespace -join ','
  $CurrentServers = $Existing[0].NameServers -join ','
  If ($CurrentNamespace -ne $Namespace -or $CurrentServers -ne $DesiredServers) {
    $Changed = $True
    $Action = 'set'
  }
}

If ($Changed -and -not $Ansible.CheckMode) {
  If ($Action -eq 'add') {
    $Null = Add-DnsClientNrptRule -Namespace:$Namespace -NameServers:$NameServers -Comment:$Comment
  } ElseIf ($Action -eq 'replace') {
    $Null = Add-DnsClientNrptRule -Namespace:$Namespace -NameServers:$NameServers -Comment:$Comment
    ForEach ($Rule In $Existing) {
      $Null = Remove-DnsClientNrptRule -Name:$Rule.Name -Force
    }
  } ElseIf ($Action -eq 'set') {
    $Null = Set-DnsClientNrptRule -Name:$Existing[0].Name -Namespace:$Namespace -NameServers:$NameServers
  }
}

If (-not $Ansible.CheckMode) {
  $Final = @(Get-DnsClientNrptRule | Where-Object -FilterScript {
      [System.String]$PSItem.Comment -ceq $Comment
    })
  $FinalNamespace = If ($Final.Count -eq 1) { $Final[0].Namespace -join ',' } Else { '' }
  $FinalServers = If ($Final.Count -eq 1) { $Final[0].NameServers -join ',' } Else { '' }
  If ($Final.Count -ne 1 -or $FinalNamespace -ne $Namespace -or
    $FinalServers -ne $DesiredServers) {
    Throw "The NRPT rule for $Namespace did not survive exact readback."
  }
}

$Result = [PSCustomObject]@{
  action       = [System.String]$Action
  changed      = [System.Boolean]$Changed
  check_mode   = [System.Boolean]$Ansible.CheckMode
  msg          = $(If ($Changed) {
      If ($Ansible.CheckMode) { 'The domain-controller reverse-zone rule would be converged.' }
      Else { 'The domain-controller reverse-zone rule was converged and verified.' }
    } Else { 'The domain-controller reverse-zone rule is unchanged and verified.' })
  name_servers = [System.String[]]$NameServers
  namespace    = [System.String]$Namespace
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
