#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Enforces the clustered data-directory DACL or publishes its clustered SMB share.
    .DESCRIPTION
        Separates complete NTFS policy enforcement from share publication while
        preserving one exact read, diff, mutation, and verification contract.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER Mode
        DirectoryAcl or Share mutation boundary.
    .PARAMETER ScopeName
        Exact clustered file-server scope.
    .PARAMETER Name
        Exact SMB share name.
    .PARAMETER Path
        Exact local directory path on the current role owner.
    .PARAMETER Description
        Exact SMB share description.
    .PARAMETER ContinuouslyAvailable
        Exact continuously-available setting.
    .PARAMETER FolderEnumerationMode
        Exact SMB folder enumeration mode.
    .PARAMETER CachingMode
        Exact SMB offline caching mode.
    .PARAMETER EncryptData
        Exact SMB encryption setting.
    .PARAMETER NtfsAccess
        Complete declared NTFS allow-access set.
    .PARAMETER ShareAccess
        Complete declared SMB allow-access set.
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
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [ValidateSet('DirectoryAcl', 'Share')] [System.String] $Mode,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $ScopeName,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $Name,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $Path,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $Description,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.Boolean] $ContinuouslyAvailable,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [ValidateSet('AccessBased', 'Unrestricted')] [System.String] $FolderEnumerationMode,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [ValidateSet('None', 'Manual', 'Documents', 'Programs', 'BranchCache')] [System.String] $CachingMode,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.Boolean] $EncryptData,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.Collections.IDictionary[]] $NtfsAccess,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.Collections.IDictionary[]] $ShareAccess
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

$ResolveAccountSid = {
  Param ([System.String]$Principal)
  Try {
    $Account = New-Object -TypeName 'System.Security.Principal.NTAccount' -ArgumentList $Principal
    [System.String]$Account.Translate([System.Security.Principal.SecurityIdentifier]).Value
  } Catch {
    Throw ('Principal {0} could not be resolved to a SID.' -f $Principal)
  }
}

$ConvertToDesiredNtfsAccess = {
  Param ([System.Collections.IDictionary[]]$Declaration)
  $ExpectedKeys = @('access_control_type', 'inheritance_flags', 'principal', 'propagation_flags', 'rights')
  $Resolved = @()
  ForEach ($Entry In $Declaration) {
    $Keys = @($Entry.Keys | ForEach-Object -Process { [System.String]$PSItem } | Sort-Object)
    If (@(Compare-Object -ReferenceObject $ExpectedKeys -DifferenceObject $Keys).Count -gt 0 -or
      [System.String]$Entry.access_control_type -ne 'Allow' -or [System.String]$Entry.rights -notin @('FullControl', 'Modify') -or
      [System.String]$Entry.inheritance_flags -ne 'ContainerInherit,ObjectInherit' -or [System.String]$Entry.propagation_flags -ne 'None') {
      Throw 'NtfsAccess contains an unsupported key or access value.'
    }
    $Sid = & $ResolveAccountSid -Principal ([System.String]$Entry.principal)
    $Resolved += [PSCustomObject]@{
      principal         = [System.String]$Entry.principal
      sid               = $Sid
      access_type       = 'Allow'
      rights            = [System.String]$Entry.rights
      rights_value      = [System.Int32]([System.Security.AccessControl.FileSystemRights]$Entry.rights)
      inheritance       = 'ContainerInherit,ObjectInherit'
      inheritance_value = [System.Int32]([System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit')
      propagation       = 'None'
      propagation_value = [System.Int32]([System.Security.AccessControl.PropagationFlags]'None')
      canonical         = '{0}|Allow|{1}|ContainerInherit,ObjectInherit|None' -f $Sid, [System.String]$Entry.rights
    }
  }
  If (@($Resolved.sid | Select-Object -Unique).Count -ne $Resolved.Count) { Throw 'NtfsAccess contains duplicate principals.' }
  $Resolved
}

$ConvertToDesiredShareAccess = {
  Param ([System.Collections.IDictionary[]]$Declaration)
  $ExpectedKeys = @('access_control_type', 'access_right', 'principal')
  $Resolved = @()
  ForEach ($Entry In $Declaration) {
    $Keys = @($Entry.Keys | ForEach-Object -Process { [System.String]$PSItem } | Sort-Object)
    If (@(Compare-Object -ReferenceObject $ExpectedKeys -DifferenceObject $Keys).Count -gt 0 -or
      [System.String]$Entry.access_control_type -ne 'Allow' -or [System.String]$Entry.access_right -notin @('Full', 'Change', 'Read')) {
      Throw 'ShareAccess contains an unsupported key or access value.'
    }
    $Sid = & $ResolveAccountSid -Principal ([System.String]$Entry.principal)
    $Resolved += [PSCustomObject]@{
      principal    = [System.String]$Entry.principal
      sid          = $Sid
      access_type  = 'Allow'
      access_right = [System.String]$Entry.access_right
      canonical    = '{0}|Allow|{1}' -f $Sid, [System.String]$Entry.access_right
    }
  }
  If (@($Resolved.sid | Select-Object -Unique).Count -ne $Resolved.Count) { Throw 'ShareAccess contains duplicate principals.' }
  $Resolved
}

$GetIdentitySid = {
  Param ([System.Object]$Identity)
  If ($Identity.PSObject.Properties.Name -contains 'Value' -and [System.String]$Identity.Value -match '^S-') { Return [System.String]$Identity.Value }
  $Identity.Translate([System.Security.Principal.SecurityIdentifier]).Value
}

$GetNtfsState = {
  Param ([System.String]$LiteralPath, [System.Object[]]$Desired)
  If (-not (Test-Path -LiteralPath $LiteralPath -PathType Container)) { Throw ('Path {0} does not exist as a directory.' -f $LiteralPath) }
  $Acl = Get-Acl -LiteralPath $LiteralPath
  $InheritedCount = 0
  $Current = @()
  ForEach ($Rule In @($Acl.Access)) {
    If ([System.Boolean]$Rule.IsInherited) {
      $InheritedCount++
    } Else {
      $Sid = & $GetIdentitySid -Identity $Rule.IdentityReference
      $RightsValue = [System.Int32]$Rule.FileSystemRights
      $DesiredMatch = @($Desired | Where-Object -FilterScript {
          $PSItem.sid -eq $Sid -and $PSItem.access_type -eq [System.String]$Rule.AccessControlType -and
          $PSItem.rights_value -eq $RightsValue -and $PSItem.inheritance_value -eq [System.Int32]$Rule.InheritanceFlags -and
          $PSItem.propagation_value -eq [System.Int32]$Rule.PropagationFlags
        })
      If ($DesiredMatch.Count -eq 1) {
        $Current += $DesiredMatch[0].canonical
      } Else {
        $Current += '{0}|{1}|{2}|{3}|{4}' -f $Sid, $Rule.AccessControlType, $Rule.FileSystemRights, $Rule.InheritanceFlags, $Rule.PropagationFlags
      }
    }
  }
  $DesiredCanonical = @($Desired.canonical | Sort-Object)
  $CurrentCanonical = @($Current | Sort-Object)
  $Exact = [System.Boolean]$Acl.AreAccessRulesProtected -and $InheritedCount -eq 0 -and
  @(Compare-Object -ReferenceObject $DesiredCanonical -DifferenceObject $CurrentCanonical).Count -eq 0
  [PSCustomObject]@{
    acl             = $Acl
    protected       = [System.Boolean]$Acl.AreAccessRulesProtected
    inherited_count = $InheritedCount
    desired         = $DesiredCanonical
    current         = $CurrentCanonical
    exact           = $Exact
  }
}

$GetShareState = {
  Param ([System.String]$ShareName, [System.String]$ShareScope, [System.Object[]]$DesiredAccess)
  $Shares = @(Get-SmbShare -Name $ShareName -ScopeName $ShareScope -ErrorAction SilentlyContinue)
  If ($Shares.Count -gt 1) { Throw ('Share {0} in scope {1} is ambiguous.' -f $ShareName, $ShareScope) }
  If ($Shares.Count -eq 0) { Return [PSCustomObject]@{ share = $Null; access = @(); canonical_access = @() } }
  $Access = @(Get-SmbShareAccess -Name $ShareName -ScopeName $ShareScope)
  $Canonical = @(
    ForEach ($Entry In $Access) {
      $Sid = & $ResolveAccountSid -Principal ([System.String]$Entry.AccountName)
      '{0}|{1}|{2}' -f $Sid, [System.String]$Entry.AccessControlType, [System.String]$Entry.AccessRight
    }
  ) | Sort-Object
  [PSCustomObject]@{ share = $Shares[0]; access = $Access; canonical_access = @($Canonical); desired_access = @($DesiredAccess.canonical | Sort-Object) }
}

$DesiredNtfs = @(& $ConvertToDesiredNtfsAccess -Declaration $NtfsAccess)
$DesiredShare = @(& $ConvertToDesiredShareAccess -Declaration $ShareAccess)
$BeforeNtfs = & $GetNtfsState -LiteralPath $Path -Desired $DesiredNtfs
$Actions = [System.Collections.Generic.List[System.String]]::new()

If ($Mode -eq 'DirectoryAcl') {
  If (-not $BeforeNtfs.exact) { $Actions.Add('enforce_directory_acl') }
  If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
    $AfterNtfs = $BeforeNtfs
  } Else {
    $Acl = $BeforeNtfs.acl
    $Acl.SetAccessRuleProtection($True, $False)
    ForEach ($Rule In @($Acl.Access | Where-Object -FilterScript { -not [System.Boolean]$PSItem.IsInherited })) {
      $Null = $Acl.RemoveAccessRuleSpecific($Rule)
    }
    ForEach ($Entry In $DesiredNtfs) {
      $Rule = New-Object -TypeName 'System.Security.AccessControl.FileSystemAccessRule' -ArgumentList @(
        $Entry.principal,
        [System.Security.AccessControl.FileSystemRights]$Entry.rights,
        [System.Security.AccessControl.InheritanceFlags]$Entry.inheritance,
        [System.Security.AccessControl.PropagationFlags]$Entry.propagation,
        [System.Security.AccessControl.AccessControlType]$Entry.access_type
      )
      $Null = $Acl.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $Acl
    $AfterNtfs = & $GetNtfsState -LiteralPath $Path -Desired $DesiredNtfs
    If (-not $AfterNtfs.exact) { Throw ('Directory DACL on {0} failed exact readback.' -f $Path) }
  }
  $Before = $BeforeNtfs
  $After = $AfterNtfs
} Else {
  If (-not $BeforeNtfs.exact) { Throw ('Directory DACL on {0} must be exact before share publication.' -f $Path) }
  $BeforeShare = & $GetShareState -ShareName $Name -ShareScope $ScopeName -DesiredAccess $DesiredShare
  If ($Null -ne $BeforeShare.share -and [System.String]$BeforeShare.share.Path -ine $Path) {
    Throw ('Share {0} in scope {1} exists at a different path.' -f $Name, $ScopeName)
  }
  If ($Null -eq $BeforeShare.share) {
    $Actions.Add('create_share')
  } ElseIf ([System.String]$BeforeShare.share.Description -cne $Description -or
    [System.Boolean]$BeforeShare.share.ContinuouslyAvailable -ne $ContinuouslyAvailable -or
    [System.String]$BeforeShare.share.FolderEnumerationMode -ne $FolderEnumerationMode -or
    [System.String]$BeforeShare.share.CachingMode -ne $CachingMode -or
    [System.Boolean]$BeforeShare.share.EncryptData -ne $EncryptData) {
    $Actions.Add('set_share_properties')
  }
  $DesiredAccessCanonical = @($DesiredShare.canonical | Sort-Object)
  If (@(Compare-Object -ReferenceObject $DesiredAccessCanonical -DifferenceObject $BeforeShare.canonical_access).Count -gt 0) {
    $Actions.Add('set_share_access')
  }
  If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
    $AfterShare = $BeforeShare
    $AfterNtfs = $BeforeNtfs
  } Else {
    If ($Actions.Contains('create_share')) {
      $FullAccess = @($DesiredShare | Where-Object -FilterScript { $PSItem.access_right -eq 'Full' } | ForEach-Object -Process { $PSItem.principal })
      $ChangeAccess = @($DesiredShare | Where-Object -FilterScript { $PSItem.access_right -eq 'Change' } | ForEach-Object -Process { $PSItem.principal })
      $Null = New-SmbShare -Name $Name -ScopeName $ScopeName -Path $Path -Description $Description -ContinuouslyAvailable $ContinuouslyAvailable -FolderEnumerationMode $FolderEnumerationMode -CachingMode $CachingMode -EncryptData $EncryptData -FullAccess $FullAccess -ChangeAccess $ChangeAccess
    } ElseIf ($Actions.Contains('set_share_properties')) {
      $Null = Set-SmbShare -Name $Name -ScopeName $ScopeName -Description $Description -ContinuouslyAvailable $ContinuouslyAvailable -FolderEnumerationMode $FolderEnumerationMode -CachingMode $CachingMode -EncryptData $EncryptData -Force
    }
    $Current = & $GetShareState -ShareName $Name -ShareScope $ScopeName -DesiredAccess $DesiredShare
    ForEach ($Entry In @($Current.access)) {
      $Sid = & $ResolveAccountSid -Principal ([System.String]$Entry.AccountName)
      $Exact = @($DesiredShare | Where-Object -FilterScript { $PSItem.sid -eq $Sid -and $PSItem.access_right -eq [System.String]$Entry.AccessRight -and [System.String]$Entry.AccessControlType -eq 'Allow' })
      If ($Exact.Count -eq 0) {
        If ([System.String]$Entry.AccessControlType -eq 'Deny') {
          $Null = Unblock-SmbShareAccess -Name $Name -ScopeName $ScopeName -AccountName ([System.String]$Entry.AccountName) -Force
        } Else {
          $Null = Revoke-SmbShareAccess -Name $Name -ScopeName $ScopeName -AccountName ([System.String]$Entry.AccountName) -Force
        }
      }
    }
    $Current = & $GetShareState -ShareName $Name -ShareScope $ScopeName -DesiredAccess $DesiredShare
    ForEach ($Entry In $DesiredShare) {
      If ($Entry.canonical -notin $Current.canonical_access) {
        $Null = Grant-SmbShareAccess -Name $Name -ScopeName $ScopeName -AccountName $Entry.principal -AccessRight $Entry.access_right -Force
      }
    }
    $AfterShare = & $GetShareState -ShareName $Name -ShareScope $ScopeName -DesiredAccess $DesiredShare
    $AfterNtfs = & $GetNtfsState -LiteralPath $Path -Desired $DesiredNtfs
    $Share = $AfterShare.share
    If ($Null -eq $Share -or [System.String]$Share.Name -ine $Name -or [System.String]$Share.ScopeName -ine $ScopeName -or
      [System.String]$Share.Path -ine $Path -or [System.String]$Share.Description -cne $Description -or
      [System.Boolean]$Share.ContinuouslyAvailable -ne $ContinuouslyAvailable -or
      [System.String]$Share.FolderEnumerationMode -ne $FolderEnumerationMode -or [System.String]$Share.CachingMode -ne $CachingMode -or
      [System.Boolean]$Share.EncryptData -ne $EncryptData -or -not $AfterNtfs.exact -or
      @(Compare-Object -ReferenceObject $DesiredAccessCanonical -DifferenceObject $AfterShare.canonical_access).Count -gt 0) {
      Throw ('Clustered SMB share {0} failed exact readback.' -f $Name)
    }
  }
  $Before = [PSCustomObject]@{ ntfs = $BeforeNtfs; share = $BeforeShare }
  $After = [PSCustomObject]@{ ntfs = $AfterNtfs; share = $AfterShare }
}

$Result = [PSCustomObject]@{
  changed    = $Actions.Count -gt 0
  check_mode = [System.Boolean]$Ansible.CheckMode
  actions    = @($Actions)
  before     = $Before
  after      = $After
  msg        = $(If ($Actions.Count -eq 0) { '{0} already matches.' -f $Mode } ElseIf ($Ansible.CheckMode) { 'Check mode: {0} would be converged.' -f $Mode } Else { '{0} converged.' -f $Mode })
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) { $Result | ConvertTo-Json -Depth:8 }
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
