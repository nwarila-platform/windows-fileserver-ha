#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges the SMB server configuration against a declared settings map
        with a deterministic Changed/NoChange verdict.

    .DESCRIPTION
        Fills the step Ansible cannot do effectively: no ansible.windows
        module owns Set-SmbServerConfiguration. Org scripts are a single
        straightforward process stage in the org script template's
        architecture: one [ Script ] region carrying [ Initialization ]
        (strict mode, transport detection, input normalization), [ Main ]
        (read -> compare -> mutate only the drift -> re-acquire and verify ->
        build ONE result object), and [ Output ] (the same object to $Ansible
        or as JSON).

        Shipped by the org three-file convention: developed under scripts/ with its
        sibling Set-SmbServerHardening.pester.ps1 spec, while the fileserver
        role carries files/Set-SmbServerHardening.ps1.stub, which the
        ansible-build resolves by dropping this file into the role.

    .PARAMETER DebugLevel
        Three-digit control string configuring independent debugging
        functions, one digit each. First digit: ErrorActionPreference
        (0 SilentlyContinue, 1 Stop, 2 Continue, 3 Inquire, 4 Ignore,
        5 Suspend). Second digit: Set-PSDebug (0 off, 1 trace 1, 2 trace 2,
        3 trace 1 + step, 4 trace 2 + step). Third digit: Set-StrictMode
        (0 off, 1-3 that version). Default '103': stop on error, no tracing,
        strict mode 3.0.

    .PARAMETER LogLevel
        Six-digit control string mapping the Verbose, Debug, Information,
        Warning, Error, and Fatal streams (in that order) to an
        ActionPreference value per digit (0 SilentlyContinue, 1 Stop,
        2 Continue, 3 Inquire, 4 Ignore, 5 Suspend). Default '002223'.

    .PARAMETER Setting
        Desired SMB server configuration as property-name -> desired-value
        pairs. Accepted loosely typed because the transport may deliver a
        Hashtable or a PSCustomObject; normalized before first use. Property
        names must be Get/Set-SmbServerConfiguration properties; an unknown
        name fails BEFORE any mutation.

    .EXAMPLE
        PS> ./Set-SmbServerHardening.ps1 -Setting @{ EnableSMB1Protocol = $False }

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
  SupportsShouldProcess = $False
)]
Param (
  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(
    DontShow = $False,
    Mandatory = $False,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(
    DontShow = $False,
    Mandatory = $True,
    ParameterSetName = 'default',
    ValueFromPipeline = $False,
    ValueFromPipelineByPropertyName = $False
  )]
  [AllowNull()]
  [System.Object]
  $Setting
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

# Initialize STATIC log level names, indexed by LogLevel digit position.
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)

# Initialize the custom stream preferences; the built-in ones already exist.
New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:(
  [System.Management.Automation.ActionPreference]::Stop
)

# Configure log levels based on the LogLevel parameter.
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}

# Configure the debug levels: first digit ErrorActionPreference, second digit
# Set-PSDebug, third digit Set-StrictMode.
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

# Universal trap used to help with debugging efforts. The original template's
# Wait-Debugger/Exit are interactive-host machinery; under the Ansible
# transport the trap logs and rethrows (Break) so the task fails honestly.
Trap {
  # Diagnostics are wrapped so a partially-populated error record can never
  # replace the original failure with a StrictMode property error.
  Try {
    # Write debug statement if the invoking line is available.
    If ($PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord') {
      Write-Debug -Message:(
        'Failed to execute command: {0}' -f [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line
      )
    }

    # Write the error text. The original template uses Write-Host red here;
    # PSAvoidUsingWriteHost is ratified, so the warning stream carries it.
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

# Under win_powershell the transport provides $Ansible; standalone (a dev
# shell or a Pester spec) it does not, so the script creates a faithful stub.
# Either way the rest of the script has exactly ONE code path: the outcome is
# always written to $Ansible, and Output serializes the stub as JSON when the
# script created it. Changed defaults to $True like the real transport and is
# set explicitly on every path.
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $False
    Failed    = $False
    Result    = $Null
  }
}

# The transport may deliver the dictionary as a Hashtable or a PSCustomObject
# depending on the invocation path; normalize to one non-empty table.
$Desired = @{}
If ($Setting -is [System.Collections.IDictionary]) {
  ForEach ($Key In $Setting.Keys) {
    $Desired[[System.String]$Key] = $Setting[$Key]
  }
} ElseIf ($Setting -is [System.Management.Automation.PSCustomObject]) {
  ForEach ($Property In $Setting.PSObject.Properties) {
    $Desired[$Property.Name] = $Property.Value
  }
} Else {
  Throw ('Setting must be a dictionary of SMB property names to desired values; received type {0}.' -f $(If ($Null -eq $Setting) { 'null' } Else { $Setting.GetType().FullName }))
}
If ($Desired.Count -eq 0) {
  Throw 'Setting is empty: a baseline that declares nothing cannot converge anything.'
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

# Compare stringified, trimmed values with PowerShell's default
# case-insensitive -ne, so $True, 'True', and 'true' compare equal: YAML
# booleans cross the transport as strings often enough that a raw comparison
# would report perpetual drift and re-mutate a converged host every run.
# Unknown names throw BEFORE any mutation, so a typo cannot half-apply a
# baseline; sorted order keeps the drift payload diffable across runs.
$SmbConfiguration = Get-SmbServerConfiguration
$Drift = @(
  ForEach ($Name In ($Desired.Keys | Sort-Object)) {
    $LiveProperty = $SmbConfiguration.PSObject.Properties[$Name]
    If ($Null -eq $LiveProperty) {
      Throw ('SMB server configuration exposes no property named {0}. Declared names must be Get/Set-SmbServerConfiguration properties; failing before any mutation.' -f $Name)
    }
    If ("$($LiveProperty.Value)".Trim() -ne "$($Desired[$Name])".Trim()) {
      [PSCustomObject]@{
        current = $LiveProperty.Value
        desired = $Desired[$Name]
        name    = $Name
      }
    }
  }
)

If ($Drift.Count -eq 0) {
  $Result = [PSCustomObject]@{
    changed    = $False
    check_mode = $Ansible.CheckMode
    drift      = @()
    msg        = 'SMB server configuration already matches the declared baseline.'
  }
} Else {
  $DriftSummary = ($Drift | ForEach-Object -Process { '{0}: ''{1}'' -> ''{2}''' -f $PSItem.name, $PSItem.current, $PSItem.desired }) -join '; '

  If ($Ansible.CheckMode) {
    $Result = [PSCustomObject]@{
      changed    = $True
      check_mode = $True
      drift      = $Drift
      msg        = ('Check mode: would converge {0}.' -f $DriftSummary)
    }
  } Else {
    # Mutate ONLY the drifted properties: passing the full declared map would
    # rewrite converged values and bury the audit trail in noise.
    $ApplySplat = @{}
    ForEach ($Item In $Drift) {
      $ApplySplat[$Item.name] = $Desired[$Item.name]
    }
    Set-SmbServerConfiguration @ApplySplat -Force -Confirm:$False

    # Re-acquire and verify: 'changed' is only ever reported from a fresh read
    # proving the mutation landed, never from the Set returning without error.
    $SmbConfiguration = Get-SmbServerConfiguration
    $ResidualNames = @(
      ForEach ($Item In $Drift) {
        If ("$($SmbConfiguration.PSObject.Properties[$Item.name].Value)".Trim() -ne "$($Desired[$Item.name])".Trim()) {
          $Item.name
        }
      }
    )
    If ($ResidualNames.Count -gt 0) {
      Throw ('Set-SmbServerConfiguration returned without error, but these properties still differ from the declared baseline: {0}. Refusing to report convergence.' -f ($ResidualNames -join ', '))
    }

    $Result = [PSCustomObject]@{
      changed    = $True
      check_mode = $False
      drift      = $Drift
      msg        = ('Converged {0}.' -f $DriftSummary)
    }
  }
}

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
