#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges one declared file-share access group in Active Directory.
    .DESCRIPTION
        Creates or updates one Global security group without changing membership or deleting
        any object, then independently reads the group and verifies every owned property.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER Description
        Exact group description.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER Path
        Distinguished name of the organizational unit that owns the group.
    .PARAMETER Principal
        Down-level group principal in DOMAIN\Group form.
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

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Description,

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^OU=[^,=]+(?:,OU=[^,=]+)*,(?:DC=[A-Za-z0-9-]+,)*DC=[A-Za-z0-9-]+$')]
  [System.String]
  $Path,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,13}[A-Za-z0-9])?\\(?:[A-Za-z0-9]|[A-Za-z0-9][A-Za-z0-9 ._-]{0,62}[A-Za-z0-9])$')]
  [System.String]
  $Principal
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
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as
    [System.Management.Automation.ActionPreference]
  )
}
$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse(
  $DebugLevel.Substring(0, 1)
)
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
        'Failed to execute command: {0}' -f
        [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line
      )
    }
    Write-Warning -Message:('[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      ))
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }
  Break
}
$StandaloneRun = $Null -eq (
  Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue'
)
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{
    Changed   = $True
    CheckMode = $WhatIfRequested
    Failed    = $False
    Result    = $Null
  }
}
$Ansible.Changed = $False
#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

$GroupName = [System.String]($Principal.Split('\') | Select-Object -Last 1)
$BeforeMatches = @(Get-ADGroup -LDAPFilter ('(sAMAccountName={0})' -f $GroupName) -Properties @(
    'Description', 'GroupCategory', 'GroupScope', 'sAMAccountName'
  ) -ErrorAction Stop)
If ($BeforeMatches.Count -gt 1) {
  Throw ('Group principal {0} resolved to more than one directory object.' -f $Principal)
}
$Before = $Null
$Actions = [System.Collections.Generic.List[System.String]]::new()
If ($BeforeMatches.Count -eq 0) {
  $Actions.Add('create_group')
} Else {
  $Before = $BeforeMatches[0]
  $BeforeParent = [System.String]$Before.DistinguishedName.Substring(
    $Before.DistinguishedName.IndexOf(',') + 1
  )
  If ([System.String]$Before.Name -cne $GroupName) {
    $Actions.Add('rename_group')
  }
  If ($BeforeParent -ine $Path) {
    $Actions.Add('move_group')
  }
  If ([System.String]$Before.sAMAccountName -cne $GroupName -or
    [System.String]$Before.Description -cne $Description -or
    [System.String]$Before.GroupScope -ne 'Global' -or
    [System.String]$Before.GroupCategory -ne 'Security') {
    $Actions.Add('set_group_properties')
  }
}

If ($Actions.Count -gt 0 -and -not $Ansible.CheckMode) {
  If ($Null -eq $Before) {
    New-ADGroup -Name $GroupName -SamAccountName $GroupName -Description $Description `
      -GroupCategory Security -GroupScope Global -Path $Path -ErrorAction Stop
  } Else {
    $Identity = $Before.ObjectGUID
    If ($Actions.Contains('rename_group')) {
      Rename-ADObject -Identity $Identity -NewName $GroupName -ErrorAction Stop
    }
    If ($Actions.Contains('move_group')) {
      Move-ADObject -Identity $Identity -TargetPath $Path -ErrorAction Stop
    }
    If ($Actions.Contains('set_group_properties')) {
      Set-ADGroup -Identity $Identity -Description $Description -SamAccountName $GroupName `
        -GroupCategory Security -GroupScope Global -ErrorAction Stop
    }
  }
}

$After = $Before
If (-not $Ansible.CheckMode) {
  $AfterMatches = @(Get-ADGroup -LDAPFilter ('(sAMAccountName={0})' -f $GroupName) -Properties @(
      'Description', 'GroupCategory', 'GroupScope', 'sAMAccountName'
    ) -ErrorAction Stop)
  If ($AfterMatches.Count -ne 1) {
    Throw ('Fresh readback for {0} returned {1} objects, expected one.' -f $Principal, $AfterMatches.Count)
  }
  $After = $AfterMatches[0]
  $AfterParent = [System.String]$After.DistinguishedName.Substring(
    $After.DistinguishedName.IndexOf(',') + 1
  )
  $Disagreements = [System.Collections.Generic.List[System.String]]::new()
  If ([System.String]$After.Name -cne $GroupName) {
    $Disagreements.Add(('name expected "{0}" but was "{1}"' -f $GroupName, $After.Name))
  }
  If ([System.String]$After.sAMAccountName -cne $GroupName) {
    $Disagreements.Add(('account name expected "{0}" but was "{1}"' -f $GroupName, $After.sAMAccountName))
  }
  If ($AfterParent -ine $Path) {
    $Disagreements.Add(('path expected "{0}" but was "{1}"' -f $Path, $AfterParent))
  }
  If ([System.String]$After.Description -cne $Description) {
    $Disagreements.Add(('description expected "{0}" but was "{1}"' -f $Description, $After.Description))
  }
  If ([System.String]$After.GroupScope -ne 'Global') {
    $Disagreements.Add(('scope expected Global but was {0}' -f $After.GroupScope))
  }
  If ([System.String]$After.GroupCategory -ne 'Security') {
    $Disagreements.Add(('category expected Security but was {0}' -f $After.GroupCategory))
  }
  If ($Disagreements.Count -gt 0) {
    Throw ('File-share access group {0} failed fresh readback: {1}.' -f
      $Principal, ($Disagreements -join '; '))
  }
}

$BeforeResult = $Null
If ($Null -ne $Before) {
  $BeforeResult = [PSCustomObject]@{
    name               = [System.String]$Before.Name
    sam_account_name   = [System.String]$Before.sAMAccountName
    description        = [System.String]$Before.Description
    distinguished_name = [System.String]$Before.DistinguishedName
    scope              = [System.String]$Before.GroupScope
    category           = [System.String]$Before.GroupCategory
  }
}
$AfterResult = $Null
If ($Null -ne $After) {
  $AfterResult = [PSCustomObject]@{
    name               = [System.String]$After.Name
    sam_account_name   = [System.String]$After.sAMAccountName
    description        = [System.String]$After.Description
    distinguished_name = [System.String]$After.DistinguishedName
    scope              = [System.String]$After.GroupScope
    category           = [System.String]$After.GroupCategory
  }
}
$Result = [PSCustomObject]@{
  changed        = $Actions.Count -gt 0
  check_mode     = [System.Boolean]$Ansible.CheckMode
  actions        = @($Actions)
  before         = $BeforeResult
  after          = $AfterResult
  readbacks      = $(If ($Ansible.CheckMode) { 0 } Else { 1 })
  postconditions = $(If ($Ansible.CheckMode) { 0 } Else { 1 })
  msg            = $(
    If ($Actions.Count -eq 0) {
      'File-share access group already matches.'
    } ElseIf ($Ansible.CheckMode) {
      'Check mode: file-share access group would be converged.'
    } Else {
      'File-share access group converged and verified.'
    }
  )
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
