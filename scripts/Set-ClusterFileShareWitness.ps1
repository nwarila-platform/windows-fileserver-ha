#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges the dedicated SMB file-share witness on a domain member.
    .DESCRIPTION
        Creates the witness directory when absent, enforces its protected DACL, publishes the
        standalone SMB share, and grants the declared cluster name object Full access. Reads and
        verifies the complete owned state before reporting whether anything changed.
    .PARAMETER CachingMode
        Exact SMB offline caching mode.
    .PARAMETER ClusterPrincipal
        Down-level logon name of the cluster name object, including its trailing dollar sign.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER Description
        Exact SMB share description.
    .PARAMETER EncryptData
        Exact SMB encryption setting.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER Name
        Exact SMB share name.
    .PARAMETER Path
        Exact local witness directory path.
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
  [ValidateSet('None', 'Manual', 'Documents', 'Programs', 'BranchCache')]
  [System.String]
  $CachingMode = 'None',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[^\\]+\\[^\\]+\$$')]
  [System.String]
  $ClusterPrincipal,

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $Description,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [System.Boolean]
  $EncryptData,

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[^\\/:*?"<>|]+\$?$')]
  [System.String]
  $Name,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[A-Za-z]:\\[^*?\[\]]+$')]
  [System.String]
  $Path
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

$DesiredNtfsAccess = @()
ForEach ($Principal In @('NT AUTHORITY\SYSTEM', 'BUILTIN\Administrators', $ClusterPrincipal)) {
  Try {
    $Account = New-Object -TypeName 'System.Security.Principal.NTAccount' -ArgumentList $Principal
    $Sid = [System.String]$Account.Translate([System.Security.Principal.SecurityIdentifier]).Value
  } Catch {
    Throw ('Principal {0} could not be resolved to a SID.' -f $Principal)
  }
  $DesiredNtfsAccess += [PSCustomObject]@{ principal = $Principal; sid = $Sid }
}
If (@($DesiredNtfsAccess.sid | Select-Object -Unique).Count -ne $DesiredNtfsAccess.Count) {
  Throw 'The witness DACL principals must resolve to three distinct SIDs.'
}
$FullControlValue = [System.Int32][System.Security.AccessControl.FileSystemRights]::FullControl
$InheritanceValue = [System.Int32][System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
$PropagationValue = [System.Int32][System.Security.AccessControl.PropagationFlags]::None
$DesiredNtfsCanonical = @($DesiredNtfsAccess | ForEach-Object -Process {
    '{0}|Allow|{1}|{2}|{3}' -f $PSItem.sid, $FullControlValue, $InheritanceValue, $PropagationValue
  } | Sort-Object)
$ClusterSid = [System.String]$DesiredNtfsAccess[2].sid
$DesiredShareCanonical = '{0}|Allow|Full' -f $ClusterSid

$BeforeContainerExists = Test-Path -LiteralPath $Path -PathType Container
If (-not $BeforeContainerExists) {
  If (Test-Path -LiteralPath $Path) {
    Throw ('Witness path {0} exists but is not a directory.' -f $Path)
  }
  $BeforeDirectory = [PSCustomObject]@{
    acl = $Null; current = @(); exists = $False; exact = $False; inherited_count = 0; protected = $False
  }
} Else {
  $BeforeAcl = Get-Acl -LiteralPath $Path
  $BeforeInheritedCount = 0
  $BeforeCurrent = @()
  ForEach ($Rule In @($BeforeAcl.Access)) {
    If ([System.Boolean]$Rule.IsInherited) {
      $BeforeInheritedCount++
    } Else {
      If ($Rule.IdentityReference.PSObject.Properties.Name -contains 'Value' -and
        [System.String]$Rule.IdentityReference.Value -match '^S-') {
        $Sid = [System.String]$Rule.IdentityReference.Value
      } Else {
        $Sid = [System.String]$Rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
      }
      $BeforeCurrent += '{0}|{1}|{2}|{3}|{4}' -f @(
        $Sid
        [System.String]$Rule.AccessControlType
        [System.Int32]$Rule.FileSystemRights
        [System.Int32]$Rule.InheritanceFlags
        [System.Int32]$Rule.PropagationFlags
      )
    }
  }
  $BeforeCurrent = @($BeforeCurrent | Sort-Object)
  $BeforeExact = [System.Boolean]$BeforeAcl.AreAccessRulesProtected -and $BeforeInheritedCount -eq 0 -and
  @(Compare-Object -ReferenceObject $DesiredNtfsCanonical -DifferenceObject $BeforeCurrent).Count -eq 0
  $BeforeDirectory = [PSCustomObject]@{
    acl = $BeforeAcl; current = $BeforeCurrent; exists = $True; exact = $BeforeExact
    inherited_count = $BeforeInheritedCount; protected = [System.Boolean]$BeforeAcl.AreAccessRulesProtected
  }
}

$BeforeShares = @(Get-SmbShare -ErrorAction Stop | Where-Object -FilterScript {
    [System.String]$PSItem.Name -ieq $Name
  })
If ($BeforeShares.Count -gt 1) { Throw ('Witness share {0} is ambiguous.' -f $Name) }
If ($BeforeShares.Count -eq 0) {
  $BeforeShare = [PSCustomObject]@{
    access = @(); access_exact = $False; exists = $False; exact = $False; properties_exact = $False; share = $Null
  }
} Else {
  $BeforeShareObject = $BeforeShares[0]
  If ([System.String]$BeforeShareObject.Path -ine $Path) {
    Throw ('Witness share {0} already targets {1}, not {2}; refusing to repoint it.' -f $Name, $BeforeShareObject.Path, $Path)
  }
  $BeforeAccess = @(Get-SmbShareAccess -Name $Name)
  $BeforeCanonicalAccess = @($BeforeAccess | ForEach-Object -Process {
      $AccessEntry = $PSItem
      Try {
        $Account = New-Object -TypeName 'System.Security.Principal.NTAccount' -ArgumentList ([System.String]$AccessEntry.AccountName)
        $Sid = [System.String]$Account.Translate([System.Security.Principal.SecurityIdentifier]).Value
      } Catch {
        $Sid = 'UNRESOLVED:{0}' -f ([System.String]$AccessEntry.AccountName).ToUpperInvariant()
      }
      '{0}|{1}|{2}' -f $Sid, [System.String]$AccessEntry.AccessControlType, [System.String]$AccessEntry.AccessRight
    } | Sort-Object)
  $BeforeAccessExact = $BeforeCanonicalAccess.Count -eq 1 -and $BeforeCanonicalAccess[0] -eq $DesiredShareCanonical
  $BeforePropertiesExact = [System.String]$BeforeShareObject.Description -ceq $Description -and
  -not [System.Boolean]$BeforeShareObject.ContinuouslyAvailable -and
  [System.String]$BeforeShareObject.FolderEnumerationMode -eq 'AccessBased' -and
  [System.String]$BeforeShareObject.CachingMode -eq $CachingMode -and
  [System.Boolean]$BeforeShareObject.EncryptData -eq $EncryptData
  $BeforeShare = [PSCustomObject]@{
    access = $BeforeAccess; access_canonical = $BeforeCanonicalAccess; access_exact = $BeforeAccessExact
    exists = $True; exact = $BeforePropertiesExact -and $BeforeAccessExact
    properties_exact = $BeforePropertiesExact; share = $BeforeShareObject
  }
}

$Actions = [System.Collections.Generic.List[System.String]]::new()
If (-not $BeforeDirectory.exists) { $Actions.Add('create_directory') }
If (-not $BeforeDirectory.exact) { $Actions.Add('enforce_directory_acl') }
If (-not $BeforeShare.exists) {
  $Actions.Add('create_share')
} Else {
  If (-not $BeforeShare.properties_exact) { $Actions.Add('set_share_properties') }
  If (-not $BeforeShare.access_exact) { $Actions.Add('set_share_access') }
}

If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
  $AfterDirectory = $BeforeDirectory
  $AfterShare = $BeforeShare
} Else {
  If ($Actions.Contains('create_directory')) {
    $Null = New-Item -ItemType Directory -Path $Path -Force
  }
  If ($Actions.Contains('enforce_directory_acl')) {
    $Acl = Get-Acl -LiteralPath $Path
    $Acl.SetAccessRuleProtection($True, $False)
    ForEach ($Rule In @($Acl.Access | Where-Object -FilterScript { -not [System.Boolean]$PSItem.IsInherited })) {
      $Null = $Acl.RemoveAccessRuleSpecific($Rule)
    }
    ForEach ($Entry In $DesiredNtfsAccess) {
      $Rule = New-Object -TypeName 'System.Security.AccessControl.FileSystemAccessRule' -ArgumentList @(
        $Entry.principal
        [System.Security.AccessControl.FileSystemRights]::FullControl
        [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
        [System.Security.AccessControl.PropagationFlags]::None
        [System.Security.AccessControl.AccessControlType]::Allow
      )
      $Null = $Acl.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $Acl
  }
  If ($Actions.Contains('create_share')) {
    $Null = New-SmbShare -Name $Name -Path $Path -Description $Description -ContinuouslyAvailable $False -FolderEnumerationMode 'AccessBased' -CachingMode $CachingMode -EncryptData $EncryptData -FullAccess @($ClusterPrincipal)
  } Else {
    If ($Actions.Contains('set_share_properties')) {
      $Null = Set-SmbShare -Name $Name -Description $Description -ContinuouslyAvailable $False -FolderEnumerationMode 'AccessBased' -CachingMode $CachingMode -EncryptData $EncryptData -Force
    }
    If ($Actions.Contains('set_share_access')) {
      $DesiredAccessHeld = $False
      ForEach ($AccessEntry In @($BeforeShare.access)) {
        Try {
          $Account = New-Object -TypeName 'System.Security.Principal.NTAccount' -ArgumentList ([System.String]$AccessEntry.AccountName)
          $Sid = [System.String]$Account.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } Catch {
          $Sid = 'UNRESOLVED:{0}' -f ([System.String]$AccessEntry.AccountName).ToUpperInvariant()
        }
        $ExactAccess = -not $DesiredAccessHeld -and
        $Sid -eq $ClusterSid -and
        [System.String]$AccessEntry.AccessControlType -eq 'Allow' -and
        [System.String]$AccessEntry.AccessRight -eq 'Full'
        If ($ExactAccess) {
          $DesiredAccessHeld = $True
        } ElseIf ([System.String]$AccessEntry.AccessControlType -eq 'Deny') {
          $Null = Unblock-SmbShareAccess -Name $Name -AccountName ([System.String]$AccessEntry.AccountName) -Force
        } Else {
          $Null = Revoke-SmbShareAccess -Name $Name -AccountName ([System.String]$AccessEntry.AccountName) -Force
        }
      }
      If (-not $DesiredAccessHeld) {
        $Null = Grant-SmbShareAccess -Name $Name -AccountName $ClusterPrincipal -AccessRight 'Full' -Force
      }
    }
  }
  $AfterAcl = Get-Acl -LiteralPath $Path
  $AfterInheritedCount = 0
  $AfterCurrent = @()
  ForEach ($Rule In @($AfterAcl.Access)) {
    If ([System.Boolean]$Rule.IsInherited) {
      $AfterInheritedCount++
    } Else {
      If ($Rule.IdentityReference.PSObject.Properties.Name -contains 'Value' -and
        [System.String]$Rule.IdentityReference.Value -match '^S-') {
        $Sid = [System.String]$Rule.IdentityReference.Value
      } Else {
        $Sid = [System.String]$Rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
      }
      $AfterCurrent += '{0}|{1}|{2}|{3}|{4}' -f @(
        $Sid
        [System.String]$Rule.AccessControlType
        [System.Int32]$Rule.FileSystemRights
        [System.Int32]$Rule.InheritanceFlags
        [System.Int32]$Rule.PropagationFlags
      )
    }
  }
  $AfterCurrent = @($AfterCurrent | Sort-Object)
  $AfterExact = [System.Boolean]$AfterAcl.AreAccessRulesProtected -and $AfterInheritedCount -eq 0 -and
  @(Compare-Object -ReferenceObject $DesiredNtfsCanonical -DifferenceObject $AfterCurrent).Count -eq 0
  $AfterDirectory = [PSCustomObject]@{
    acl = $AfterAcl; current = $AfterCurrent; exists = $True; exact = $AfterExact
    inherited_count = $AfterInheritedCount; protected = [System.Boolean]$AfterAcl.AreAccessRulesProtected
  }

  $AfterShares = @(Get-SmbShare -ErrorAction Stop | Where-Object -FilterScript {
      [System.String]$PSItem.Name -ieq $Name
    })
  If ($AfterShares.Count -gt 1) { Throw ('Witness share {0} is ambiguous.' -f $Name) }
  If ($AfterShares.Count -eq 0) {
    $AfterShare = [PSCustomObject]@{
      access = @(); access_exact = $False; exists = $False; exact = $False; properties_exact = $False; share = $Null
    }
  } Else {
    $AfterShareObject = $AfterShares[0]
    If ([System.String]$AfterShareObject.Path -ine $Path) {
      Throw ('Witness share {0} already targets {1}, not {2}; refusing to repoint it.' -f $Name, $AfterShareObject.Path, $Path)
    }
    $AfterAccess = @(Get-SmbShareAccess -Name $Name)
    $AfterCanonicalAccess = @($AfterAccess | ForEach-Object -Process {
        $AccessEntry = $PSItem
        Try {
          $Account = New-Object -TypeName 'System.Security.Principal.NTAccount' -ArgumentList ([System.String]$AccessEntry.AccountName)
          $Sid = [System.String]$Account.Translate([System.Security.Principal.SecurityIdentifier]).Value
        } Catch {
          $Sid = 'UNRESOLVED:{0}' -f ([System.String]$AccessEntry.AccountName).ToUpperInvariant()
        }
        '{0}|{1}|{2}' -f $Sid, [System.String]$AccessEntry.AccessControlType, [System.String]$AccessEntry.AccessRight
      } | Sort-Object)
    $AfterAccessExact = $AfterCanonicalAccess.Count -eq 1 -and $AfterCanonicalAccess[0] -eq $DesiredShareCanonical
    $AfterPropertiesExact = [System.String]$AfterShareObject.Description -ceq $Description -and
    -not [System.Boolean]$AfterShareObject.ContinuouslyAvailable -and
    [System.String]$AfterShareObject.FolderEnumerationMode -eq 'AccessBased' -and
    [System.String]$AfterShareObject.CachingMode -eq $CachingMode -and
    [System.Boolean]$AfterShareObject.EncryptData -eq $EncryptData
    $AfterShare = [PSCustomObject]@{
      access = $AfterAccess; access_canonical = $AfterCanonicalAccess; access_exact = $AfterAccessExact
      exists = $True; exact = $AfterPropertiesExact -and $AfterAccessExact
      properties_exact = $AfterPropertiesExact; share = $AfterShareObject
    }
  }
  If (-not $AfterDirectory.exact -or -not $AfterShare.exact) {
    Throw ('Witness share readback failed for {0} at {1}.' -f $Name, $Path)
  }
}

$BeforeSafe = [PSCustomObject]@{
  directory_exists       = [System.Boolean]$BeforeDirectory.exists
  dacl_protected         = [System.Boolean]$BeforeDirectory.protected
  inherited_ace_count    = [System.Int32]$BeforeDirectory.inherited_count
  dacl_exact             = [System.Boolean]$BeforeDirectory.exact
  share_exists           = [System.Boolean]$BeforeShare.exists
  share_path             = $(If ($BeforeShare.exists) { [System.String]$BeforeShare.share.Path } Else { '' })
  share_properties_exact = [System.Boolean]$BeforeShare.properties_exact
  share_access_exact     = [System.Boolean]$BeforeShare.access_exact
  exact                  = [System.Boolean]($BeforeDirectory.exact -and $BeforeShare.exact)
}
$AfterSafe = [PSCustomObject]@{
  directory_exists       = [System.Boolean]$AfterDirectory.exists
  dacl_protected         = [System.Boolean]$AfterDirectory.protected
  inherited_ace_count    = [System.Int32]$AfterDirectory.inherited_count
  dacl_exact             = [System.Boolean]$AfterDirectory.exact
  share_exists           = [System.Boolean]$AfterShare.exists
  share_path             = $(If ($AfterShare.exists) { [System.String]$AfterShare.share.Path } Else { '' })
  share_properties_exact = [System.Boolean]$AfterShare.properties_exact
  share_access_exact     = [System.Boolean]$AfterShare.access_exact
  exact                  = [System.Boolean]($AfterDirectory.exact -and $AfterShare.exact)
}

$Result = [PSCustomObject]@{
  changed    = $Actions.Count -gt 0
  check_mode = [System.Boolean]$Ansible.CheckMode
  actions    = @($Actions)
  before     = $BeforeSafe
  after      = $AfterSafe
  msg        = $(If ($Actions.Count -eq 0) { 'File-share witness already matches.' } ElseIf ($Ansible.CheckMode) { 'Check mode: file-share witness would be converged.' } Else { 'File-share witness converged.' })
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
