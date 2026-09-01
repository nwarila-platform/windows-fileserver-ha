#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges the directory rights a Windows failover cluster needs, with a
        deterministic Changed/NoChange verdict.

    .DESCRIPTION
        Fills the step Ansible cannot do effectively: microsoft.ad exposes
        nTSecurityDescriptor only as a whole-value attribute, so a module-only
        approach would have to rewrite every existing and inherited ACE to add
        one. This script adds the two ACEs the cluster needs and leaves the
        rest of each descriptor untouched.

        Two rights, one purpose -- letting the cluster form and then publish
        itself:
          * the service account gets Full Control of the prestaged cluster name
            object, so forming the cluster needs no right to create computer
            objects anywhere;
          * the cluster name object gets Full Control of the prestaged file
            server access point, so it can take that object over when the
            clustered role comes online.

        Both objects are prestaged, which is why neither principal is granted
        the right to CREATE computer objects anywhere. The vendor documents
        that alternative -- granting the cluster Create Computer objects on the
        OU -- and it is deliberately not used: prestaging names we already
        know costs nothing and leaves the cluster able to take over exactly two
        named objects and nothing else.

        Works through the directory's own ACL objects rather than SDDL text:
        AddAccessRule canonicalises ACE order on insert and the rule exposes
        structured rights and inheritance, so neither ordering nor the several
        legal spellings of full control has to be reimplemented here.

        Shipped by the org three-file convention: developed under scripts/ with
        its sibling Set-ClusterDirectoryRights.pester.ps1 spec, while the
        fileserver_ad_config role carries
        files/Set-ClusterDirectoryRights.ps1.stub, which the ansible-build
        resolves by dropping this file into the role.

    .PARAMETER DebugLevel
        Three-digit control string configuring independent debugging
        functions, one digit each. First digit: ErrorActionPreference
        (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire, 4 Ignore,
        5 Suspend). Second digit: Set-PSDebug (0 off, 1 trace 1, 2 trace 2,
        3 trace 1 + step, 4 trace 2 + step). Third digit: Set-StrictMode
        (0 off, 1-3 that version). Default '103'.

    .PARAMETER LogLevel
        Six-digit control string mapping the Verbose, Debug, Information,
        Warning, Error, and Fatal streams (in that order) to an
        ActionPreference value per digit. Default '002223'.

    .PARAMETER AccountName
        sAMAccountName of the account that forms the cluster. It receives Full
        Control of the cluster name object.

    .PARAMETER ClusterName
        Name of the prestaged cluster name object.

    .PARAMETER FileServerName
        Name of the prestaged file server access point object. The cluster name
        object receives Full Control of it.

    .EXAMPLE
        PS> ./Set-ClusterDirectoryRights.ps1 -AccountName 'svc-fscluster-mgr' `
              -ClusterName 'TCNAW-FSCL01' -FileServerName 'TCNAW-HAFS01'

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
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default')]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default')]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default')]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $AccountName,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default')]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $ClusterName,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default')]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $FileServerName
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# The module runs this script in check mode because it declares SupportsShouldProcess, and injects
# -WhatIf when it does. This script decides check mode from $Ansible.CheckMode, so -WhatIf is
# neutralised here; left on, it would suppress the New-Variable setup below.
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
If ($DebugLevel.Substring(2, 1) -eq '0') {
  Set-StrictMode -Off
} Else {
  Set-StrictMode -Version:([System.String]$DebugLevel.Substring(2, 1))
}

Trap {
  Try {
    If ($PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord') {
      Write-Debug -Message:(
        'Failed to execute command: {0}' -f [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line
      )
    }
    Write-Warning -Message:(
      '[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      )
    )
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }
  Break
}

# Under win_powershell the transport provides $Ansible; standalone (a dev shell or a Pester
# spec) it does not, so the script creates a faithful stub. Changed defaults to $True like the
# real transport and is set explicitly on every path.
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

Write-Debug -Message:'Exiting Stage: Initialization'
#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# The directory's own ACL objects are the primitive here, not SDDL text. They canonicalise ACE
# order on insert, expand generic rights, and expose inheritance flags -- three things a text
# parser has to reimplement and gets wrong on conditional ACEs, which may quote parentheses.
# The directory reports an ACE's principal as an account name, not a SID, so the comparison has
# to translate before it can mean anything. An identity that no longer resolves is not our grant.
Function Resolve-AceSid {
  Param ([System.Object]$Identity)

  If ($Identity -is [System.Security.Principal.SecurityIdentifier]) {
    Return [System.String]$Identity.Value
  }
  Try {
    [System.String]$Identity.Translate([System.Security.Principal.SecurityIdentifier]).Value
  } Catch {
    $Null
  }
}

Function Test-Grant {
  Param (
    [System.Object]$Acl,
    [System.String]$Sid
  )

  [System.Boolean](
    $Acl.Access | Where-Object {
      $_.AccessControlType -eq 'Allow' -and
      (Resolve-AceSid -Identity:$_.IdentityReference) -eq $Sid -and
      $_.ActiveDirectoryRights.HasFlag([System.DirectoryServices.ActiveDirectoryRights]::GenericAll) -and
      # An inherit-only ACE governs children, never the object carrying it, so it is not this grant.
      -not $_.PropagationFlags.HasFlag([System.Security.AccessControl.PropagationFlags]::InheritOnly)
    }
  )
}

$AccountSid = [System.String](Get-ADUser -Identity:$AccountName).SID
$Cluster = Get-ADComputer -Identity:$ClusterName
$ClusterSid = [System.String]$Cluster.SID
$FileServer = Get-ADComputer -Identity:$FileServerName

# Each grant names the principal it empowers and the single object it applies to.
$Grants = @(
  [PSCustomObject]@{
    name = 'service_account_controls_cluster_name_object'
    path = ('AD:\{0}' -f $Cluster.DistinguishedName)
    sid  = $AccountSid
  }
  [PSCustomObject]@{
    name = 'cluster_name_object_controls_file_server_access_point'
    path = ('AD:\{0}' -f $FileServer.DistinguishedName)
    sid  = $ClusterSid
  }
)

$Applied = [System.Collections.Generic.List[System.Object]]::new()

ForEach ($Grant In $Grants) {
  $Acl = Get-Acl -Path:$Grant.path
  If (Test-Grant -Acl:$Acl -Sid:$Grant.sid) {
    Continue
  }

  $Applied.Add([PSCustomObject]@{
      grant = $Grant.name
      path  = $Grant.path
    })

  If ($Ansible.CheckMode) {
    Continue
  }

  # AddAccessRule places the ACE in canonical order: explicit before inherited, deny before
  # allow, regular before object-specific. 'None' inheritance keeps the grant on this object.
  $Rule = New-Object System.DirectoryServices.ActiveDirectoryAccessRule(
    (New-Object System.Security.Principal.SecurityIdentifier($Grant.sid)),
    [System.DirectoryServices.ActiveDirectoryRights]::GenericAll,
    [System.Security.AccessControl.AccessControlType]::Allow,
    [System.DirectoryServices.ActiveDirectorySecurityInheritance]::None
  )
  $Acl.AddAccessRule($Rule)
  Set-Acl -Path:$Grant.path -AclObject:$Acl

  # Success is verified against the directory, never against the absence of an exception.
  If (-not (Test-Grant -Acl:(Get-Acl -Path:$Grant.path) -Sid:$Grant.sid)) {
    Throw ('The {0} grant did not land on {1}.' -f $Grant.name, $Grant.path)
  }
}

$Result = [PSCustomObject]@{
  changed    = $Applied.Count -gt 0
  applied    = $Applied.ToArray()
  check_mode = $Ansible.CheckMode
  msg        = $(
    If ($Applied.Count -eq 0) { 'Cluster directory rights already converged; no change.' }
    ElseIf ($Ansible.CheckMode) { 'Cluster directory rights would be granted: {0}.' -f $Applied.Count }
    Else { 'Cluster directory rights granted: {0}.' -f $Applied.Count }
  )
}

Write-Debug -Message:'Exiting Stage: Main'
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'

$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) {
  $Ansible.Result | ConvertTo-Json -Depth:4
}

Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
