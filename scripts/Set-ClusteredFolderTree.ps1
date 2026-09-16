#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges the declared folders and explicit DACL entries beneath one clustered share root.
    .DESCRIPTION
        Reads only declared folders, computes exact explicit-entry and inheritance drift, applies
        changes in declaration order, and verifies each changed path with a fresh readback.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER Folders
        Ordered relative folder declarations with inherit and explicit access values.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER RootPath
        Existing drive-rooted clustered share directory.
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
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [AllowEmptyCollection()]
  [System.Collections.IDictionary[]] $Folders,
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String] $LogLevel = '002223',
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[A-Za-z]:\\[^*?\[\]]+$')]
  [System.String] $RootPath
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

If (-not (Test-Path -LiteralPath $RootPath -PathType Container) -and -not $Ansible.CheckMode) {
  Throw ('Clustered share root {0} does not exist as a directory.' -f $RootPath)
}

$ExpectedFolderKeys = @('access', 'inherit', 'path')
$ExpectedAccessKeys = @('access_control_type', 'principal', 'rights')
$SynchronizeRight = [System.Int32][System.Security.AccessControl.FileSystemRights]::Synchronize
$Inheritance = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
$Propagation = [System.Security.AccessControl.PropagationFlags]::None
$DeclaredPaths = [System.Collections.Generic.List[System.String]]::new()
$Plans = [System.Collections.Generic.List[System.Object]]::new()
$Actions = [System.Collections.Generic.List[System.String]]::new()

ForEach ($Folder In $Folders) {
  $FolderKeys = @($Folder.Keys | ForEach-Object -Process {
      [System.String]$PSItem
    } | Sort-Object)
  If (@(Compare-Object -ReferenceObject $ExpectedFolderKeys -DifferenceObject $FolderKeys).Count -gt 0) {
    Throw 'Folders contains an entry with unsupported or missing keys.'
  }

  $RelativePath = [System.String]$Folder.path
  If ([System.String]::IsNullOrWhiteSpace($RelativePath) -or
    $RelativePath -notmatch '^[^\\]+(?:\\[^\\]+)*$' -or
    $RelativePath -match '[:/*?"<>|]' -or
    $RelativePath -match '(^|\\)\.\.?($|\\)') {
    Throw ('Folder path {0} is not a normalized relative path.' -f $RelativePath)
  }
  If ($DeclaredPaths -contains $RelativePath) {
    Throw ('Folder path {0} is declared more than once.' -f $RelativePath)
  }

  $LastSeparator = $RelativePath.LastIndexOf('\')
  If ($LastSeparator -ge 0) {
    $ParentPath = $RelativePath.Substring(0, $LastSeparator)
    If ($DeclaredPaths -notcontains $ParentPath) {
      Throw ('Folder path {0} must declare its parent {1} earlier.' -f $RelativePath, $ParentPath)
    }
  }
  $DeclaredPaths.Add($RelativePath)

  $Desired = [System.Collections.Generic.List[System.Object]]::new()
  ForEach ($Entry In @($Folder.access)) {
    $AccessKeys = @($Entry.Keys | ForEach-Object -Process {
        [System.String]$PSItem
      } | Sort-Object)
    If (@(Compare-Object -ReferenceObject $ExpectedAccessKeys -DifferenceObject $AccessKeys).Count -gt 0 -or
      [System.String]$Entry.access_control_type -ne 'Allow' -or
      [System.String]$Entry.rights -notin @('FullControl', 'Modify', 'ReadAndExecute')) {
      Throw ('Folder {0} contains an unsupported access entry.' -f $RelativePath)
    }
    Try {
      $Account = New-Object -TypeName 'System.Security.Principal.NTAccount' -ArgumentList (
        [System.String]$Entry.principal
      )
      $Sid = [System.String]$Account.Translate(
        [System.Security.Principal.SecurityIdentifier]
      ).Value
    } Catch {
      Throw ('Principal {0} could not be resolved to a SID.' -f [System.String]$Entry.principal)
    }
    $RightsValue = [System.Int32](
      [System.Int32]([System.Security.AccessControl.FileSystemRights]$Entry.rights) -bor
      $SynchronizeRight
    )
    $Desired.Add([PSCustomObject]@{
        principal    = [System.String]$Entry.principal
        sid          = $Sid
        rights       = [System.String]$Entry.rights
        rights_value = $RightsValue
        canonical    = '{0}|Allow|{1}|{2}|{3}' -f @(
          $Sid
          $RightsValue
          [System.Int32]$Inheritance
          [System.Int32]$Propagation
        )
      })
  }

  If (@($Desired.sid | Select-Object -Unique).Count -ne $Desired.Count) {
    Throw ('Folder {0} contains duplicate principals.' -f $RelativePath)
  }
  ForEach ($ProtectedSid In @('S-1-5-18', 'S-1-5-32-544')) {
    $ProtectedMatches = @($Desired | Where-Object -FilterScript {
        $PSItem.sid -eq $ProtectedSid -and $PSItem.rights -eq 'FullControl'
      })
    If ($ProtectedMatches.Count -ne 1) {
      Throw (
        'Folder {0} must retain one Allow FullControl entry for protected SID {1}.' -f
        $RelativePath, $ProtectedSid
      )
    }
  }

  $FullPath = '{0}\{1}' -f $RootPath.TrimEnd('\'), $RelativePath
  $Exists = Test-Path -LiteralPath $FullPath -PathType Container
  If (-not $Exists -and (Test-Path -LiteralPath $FullPath)) {
    Throw ('Folder path {0} exists but is not a directory.' -f $FullPath)
  }
  $ExpectedProtected = -not [System.Boolean]$Folder.inherit
  $Current = @()
  $InheritedCount = 0
  $CurrentProtected = $False
  If ($Exists) {
    $Acl = Get-Acl -LiteralPath $FullPath
    $CurrentProtected = [System.Boolean]$Acl.AreAccessRulesProtected
    ForEach ($Rule In @($Acl.Access)) {
      If ([System.Boolean]$Rule.IsInherited) {
        $InheritedCount++
      } Else {
        If ($Rule.IdentityReference.PSObject.Properties.Name -contains 'Value' -and
          [System.String]$Rule.IdentityReference.Value -match '^S-') {
          $Sid = [System.String]$Rule.IdentityReference.Value
        } Else {
          $Sid = [System.String]$Rule.IdentityReference.Translate(
            [System.Security.Principal.SecurityIdentifier]
          ).Value
        }
        $RightsValue = [System.Int32](
          [System.Int32]$Rule.FileSystemRights -bor $SynchronizeRight
        )
        $Current += '{0}|{1}|{2}|{3}|{4}' -f @(
          $Sid
          [System.String]$Rule.AccessControlType
          $RightsValue
          [System.Int32]$Rule.InheritanceFlags
          [System.Int32]$Rule.PropagationFlags
        )
      }
    }
  }
  $DesiredCanonical = @($Desired.canonical | Sort-Object)
  $CurrentCanonical = @($Current | Sort-Object)
  $Exact = $Exists -and $CurrentProtected -eq $ExpectedProtected -and
  @(Compare-Object -ReferenceObject $DesiredCanonical -DifferenceObject $CurrentCanonical).Count -eq 0
  If (-not $Exists) {
    $Actions.Add(('create_folder:{0}' -f $RelativePath))
  }
  If (-not $Exact) {
    $Actions.Add(('set_explicit_access:{0}' -f $RelativePath))
  }
  $Plans.Add([PSCustomObject]@{
      relative_path      = $RelativePath
      full_path          = $FullPath
      inherit            = [System.Boolean]$Folder.inherit
      expected_protected = $ExpectedProtected
      desired            = @($Desired)
      desired_canonical  = $DesiredCanonical
      before             = [PSCustomObject]@{
        exists          = $Exists
        protected       = $CurrentProtected
        inherited_count = $InheritedCount
        explicit_access = $CurrentCanonical
        exact           = $Exact
      }
    })
}

If ($Actions.Count -gt 0 -and -not $Ansible.CheckMode) {
  ForEach ($Plan In $Plans) {
    If (-not [System.Boolean]$Plan.before.exists) {
      $Null = New-Item -ItemType Directory -Path $Plan.full_path
    }
    If (-not [System.Boolean]$Plan.before.exact) {
      $Acl = Get-Acl -LiteralPath $Plan.full_path
      $Acl.SetAccessRuleProtection($Plan.expected_protected, $False)
      ForEach ($Rule In @($Acl.Access | Where-Object -FilterScript {
            -not [System.Boolean]$PSItem.IsInherited
          })) {
        $Null = $Acl.RemoveAccessRuleSpecific($Rule)
      }
      ForEach ($Entry In $Plan.desired) {
        $Rule = New-Object -TypeName 'System.Security.AccessControl.FileSystemAccessRule' -ArgumentList @(
          $Entry.principal
          [System.Security.AccessControl.FileSystemRights]$Entry.rights
          $Inheritance
          $Propagation
          [System.Security.AccessControl.AccessControlType]::Allow
        )
        $Null = $Acl.AddAccessRule($Rule)
      }
      Set-Acl -LiteralPath $Plan.full_path -AclObject $Acl
    }
  }
}

$After = [System.Collections.Generic.List[System.Object]]::new()
ForEach ($Plan In $Plans) {
  If ($Ansible.CheckMode -or $Actions.Count -eq 0) {
    $After.Add($Plan.before)
    Continue
  }
  If (-not (Test-Path -LiteralPath $Plan.full_path -PathType Container)) {
    Throw ('Folder {0} was absent after convergence.' -f $Plan.full_path)
  }
  $Acl = Get-Acl -LiteralPath $Plan.full_path
  $Current = @()
  $InheritedCount = 0
  ForEach ($Rule In @($Acl.Access)) {
    If ([System.Boolean]$Rule.IsInherited) {
      $InheritedCount++
    } Else {
      If ($Rule.IdentityReference.PSObject.Properties.Name -contains 'Value' -and
        [System.String]$Rule.IdentityReference.Value -match '^S-') {
        $Sid = [System.String]$Rule.IdentityReference.Value
      } Else {
        $Sid = [System.String]$Rule.IdentityReference.Translate(
          [System.Security.Principal.SecurityIdentifier]
        ).Value
      }
      $RightsValue = [System.Int32](
        [System.Int32]$Rule.FileSystemRights -bor $SynchronizeRight
      )
      $Current += '{0}|{1}|{2}|{3}|{4}' -f @(
        $Sid
        [System.String]$Rule.AccessControlType
        $RightsValue
        [System.Int32]$Rule.InheritanceFlags
        [System.Int32]$Rule.PropagationFlags
      )
    }
  }
  $CurrentCanonical = @($Current | Sort-Object)
  $Exact = [System.Boolean]$Acl.AreAccessRulesProtected -eq $Plan.expected_protected -and
  @(Compare-Object -ReferenceObject $Plan.desired_canonical -DifferenceObject $CurrentCanonical).Count -eq 0
  $State = [PSCustomObject]@{
    exists          = $True
    protected       = [System.Boolean]$Acl.AreAccessRulesProtected
    inherited_count = $InheritedCount
    explicit_access = $CurrentCanonical
    exact           = $Exact
  }
  $After.Add($State)
  If (-not $Exact) {
    Throw ('Folder {0} failed exact explicit-access readback.' -f $Plan.full_path)
  }
}

$BeforeResult = @()
$AfterResult = @()
For ($Index = 0; $Index -lt $Plans.Count; $Index++) {
  $BeforeResult += [PSCustomObject]@{
    path            = [System.String]$Plans[$Index].relative_path
    exists          = [System.Boolean]$Plans[$Index].before.exists
    protected       = [System.Boolean]$Plans[$Index].before.protected
    inherited_count = [System.Int32]$Plans[$Index].before.inherited_count
    explicit_access = @($Plans[$Index].before.explicit_access)
    exact           = [System.Boolean]$Plans[$Index].before.exact
  }
  $AfterResult += [PSCustomObject]@{
    path            = [System.String]$Plans[$Index].relative_path
    exists          = [System.Boolean]$After[$Index].exists
    protected       = [System.Boolean]$After[$Index].protected
    inherited_count = [System.Int32]$After[$Index].inherited_count
    explicit_access = @($After[$Index].explicit_access)
    exact           = [System.Boolean]$After[$Index].exact
  }
}

$Result = [PSCustomObject]@{
  changed    = $Actions.Count -gt 0
  check_mode = [System.Boolean]$Ansible.CheckMode
  actions    = @($Actions)
  before     = $BeforeResult
  after      = $AfterResult
  msg        = $(
    If ($Actions.Count -eq 0) {
      'Declared folder tree already matches.'
    } ElseIf ($Ansible.CheckMode) {
      'Check mode: declared folder tree would be converged.'
    } Else {
      'Declared folder tree converged.'
    }
  )
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) {
  $Result | ConvertTo-Json -Depth:8
}
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
