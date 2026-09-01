#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusteredSmbShare.ps1'
  $script:Ntfs = @(
    @{ principal = 'NT AUTHORITY\SYSTEM'; access_control_type = 'Allow'; rights = 'FullControl'; inheritance_flags = 'ContainerInherit,ObjectInherit'; propagation_flags = 'None' },
    @{ principal = 'BUILTIN\Administrators'; access_control_type = 'Allow'; rights = 'FullControl'; inheritance_flags = 'ContainerInherit,ObjectInherit'; propagation_flags = 'None' },
    @{ principal = 'TCN\Domain Users'; access_control_type = 'Allow'; rights = 'Modify'; inheritance_flags = 'ContainerInherit,ObjectInherit'; propagation_flags = 'None' }
  )
  $script:ShareAccess = @(
    @{ principal = 'BUILTIN\Administrators'; access_control_type = 'Allow'; access_right = 'Full' },
    @{ principal = 'TCN\Domain Users'; access_control_type = 'Allow'; access_right = 'Change' }
  )
  $script:Common = @{
    ScopeName = 'TCNAW-HAFS01'; Name = 'data'; Path = 'D:\shares\data'; Description = 'Highly available file data'
    ContinuouslyAvailable = $True; FolderEnumerationMode = 'AccessBased'; CachingMode = 'None'; EncryptData = $True
    NtfsAccess = $script:Ntfs; ShareAccess = $script:ShareAccess
  }

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null }
    $global:Ansible
  }
  Function Remove-AnsibleContext { Remove-Variable -Name Ansible -Scope Global -Force -ErrorAction SilentlyContinue }
  Function New-FakeIdentity {
    Param ([System.String]$Value)
    $Identity = [PSCustomObject]@{ Value = $Value }
    $Identity | Add-Member -MemberType ScriptMethod -Name Translate -Value { Param ($Type) [PSCustomObject]@{ Value = $this.Value } }
    $Identity
  }
  Function New-FakeRule {
    Param ([System.String]$Principal, [System.String]$Rights, [System.Boolean]$Inherited = $False, [System.String]$Type = 'Allow')
    [PSCustomObject]@{
      IdentityReference = New-FakeIdentity -Value $global:FsHaShareSid[$Principal]
      AccessControlType = [System.Security.AccessControl.AccessControlType]$Type
      FileSystemRights = [System.Security.AccessControl.FileSystemRights]$Rights
      InheritanceFlags = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
      PropagationFlags = [System.Security.AccessControl.PropagationFlags]'None'
      IsInherited = $Inherited
    }
  }
  Function New-FakeAcl {
    Param ([System.Boolean]$Protected = $True, [System.Object[]]$Access = @())
    $Acl = [PSCustomObject]@{ AreAccessRulesProtected = $Protected; Access = @($Access) }
    $Acl | Add-Member -MemberType ScriptMethod -Name SetAccessRuleProtection -Value {
      Param ($Protect, $PreserveInheritance)
      $this.AreAccessRulesProtected = [System.Boolean]$Protect
      If (-not $PreserveInheritance) { $this.Access = @($this.Access | Where-Object -FilterScript { -not $PSItem.IsInherited }) }
    }
    $Acl | Add-Member -MemberType ScriptMethod -Name RemoveAccessRuleSpecific -Value { Param ($Rule) $this.Access = @($this.Access | Where-Object -FilterScript { $PSItem -ne $Rule }); $True }
    $Acl | Add-Member -MemberType ScriptMethod -Name AddAccessRule -Value { Param ($Rule) $this.Access += $Rule; $True }
    $Acl
  }
  Function Copy-FakeAcl {
    $Rules = @($global:FsHaShareAcl.Access | ForEach-Object -Process {
        $ExistingRule = $PSItem
        $Principal = @($global:FsHaShareSid.Keys | Where-Object -FilterScript { $global:FsHaShareSid[$PSItem] -eq $ExistingRule.IdentityReference.Value })[0]
        New-FakeRule -Principal $Principal -Rights ([System.String]$ExistingRule.FileSystemRights) -Inherited ([System.Boolean]$ExistingRule.IsInherited) -Type ([System.String]$ExistingRule.AccessControlType)
      })
    New-FakeAcl -Protected $global:FsHaShareAcl.AreAccessRulesProtected -Access $Rules
  }
  Function New-Object {
    Param ([System.String]$TypeName, [System.Object[]]$ArgumentList)
    $Arguments = @($ArgumentList)
    If ($Arguments.Count -eq 1 -and $Arguments[0] -is [System.Object[]]) { $Arguments = @($Arguments[0]) }
    If ($TypeName -eq 'System.Security.Principal.NTAccount') {
      $Principal = [System.String]$Arguments[0]
      If (-not $global:FsHaShareSid.ContainsKey($Principal)) { Throw 'unresolvable' }
      $Account = [PSCustomObject]@{ Principal = $Principal }
      $Account | Add-Member -MemberType ScriptMethod -Name Translate -Value { Param ($Type) [PSCustomObject]@{ Value = $global:FsHaShareSid[$this.Principal] } }
      Return $Account
    }
    If ($TypeName -eq 'System.Security.AccessControl.FileSystemAccessRule') {
      Return New-FakeRule -Principal ([System.String]$Arguments[0]) -Rights ([System.String]$Arguments[1]) -Type ([System.String]$Arguments[4])
    }
    Throw ('Unexpected New-Object type {0}.' -f $TypeName)
  }
  Function Test-Path { Param ([System.String]$LiteralPath, [System.String]$PathType) $global:FsHaSharePathExists }
  Function Get-Acl { Param ([System.String]$LiteralPath) Copy-FakeAcl }
  Function Set-Acl {
    Param ([System.String]$LiteralPath, [System.Object]$AclObject)
    $global:FsHaShareWrites += [PSCustomObject]@{ Command = 'SetAcl'; Path = $LiteralPath }
    If (-not $global:FsHaShareFrozen) { $global:FsHaShareAcl = $AclObject }
  }
  Function Get-SmbShare {
    Param ([System.String]$Name, [System.String]$ScopeName, [System.String]$ErrorAction)
    If ($global:FsHaShareAmbiguous) { Return @($global:FsHaShareObject, $global:FsHaShareObject) }
    If ($Null -ne $global:FsHaShareObject -and $global:FsHaShareObject.Name -eq $Name -and $global:FsHaShareObject.ScopeName -eq $ScopeName) { $global:FsHaShareObject }
  }
  Function Get-SmbShareAccess { Param ([System.String]$Name, [System.String]$ScopeName) @($global:FsHaShareCurrentAccess) }
  Function New-SmbShare {
    Param (
      [System.String]$Name, [System.String]$ScopeName, [System.String]$Path, [System.String]$Description,
      [System.Boolean]$ContinuouslyAvailable, [System.String]$FolderEnumerationMode, [System.String]$CachingMode,
      [System.Boolean]$EncryptData, [System.String[]]$FullAccess, [System.String[]]$ChangeAccess
    )
    $global:FsHaShareWrites += [PSCustomObject]@{ Command = 'NewShare'; Name = $Name; ScopeName = $ScopeName; Path = $Path; Description = $Description; ContinuouslyAvailable = $ContinuouslyAvailable; FolderEnumerationMode = $FolderEnumerationMode; CachingMode = $CachingMode; EncryptData = $EncryptData; FullAccess = $FullAccess; ChangeAccess = $ChangeAccess }
    If (-not $global:FsHaShareFrozen) {
      $global:FsHaShareObject = [PSCustomObject]@{ Name = $Name; ScopeName = $ScopeName; Path = $Path; Description = $Description; ContinuouslyAvailable = $ContinuouslyAvailable; FolderEnumerationMode = $FolderEnumerationMode; CachingMode = $CachingMode; EncryptData = $EncryptData }
      $global:FsHaShareCurrentAccess = @(
        [PSCustomObject]@{ AccountName = $FullAccess[0]; AccessControlType = 'Allow'; AccessRight = 'Full' },
        [PSCustomObject]@{ AccountName = $ChangeAccess[0]; AccessControlType = 'Allow'; AccessRight = 'Change' }
      )
    }
  }
  Function Set-SmbShare {
    Param ([System.String]$Name, [System.String]$ScopeName, [System.String]$Description, [System.Boolean]$ContinuouslyAvailable, [System.String]$FolderEnumerationMode, [System.String]$CachingMode, [System.Boolean]$EncryptData, [Switch]$Force)
    $global:FsHaShareWrites += [PSCustomObject]@{ Command = 'SetShare'; Description = $Description; ContinuouslyAvailable = $ContinuouslyAvailable; FolderEnumerationMode = $FolderEnumerationMode; CachingMode = $CachingMode; EncryptData = $EncryptData; Force = $Force.IsPresent }
    If (-not $global:FsHaShareFrozen) {
      $global:FsHaShareObject.Description = $Description; $global:FsHaShareObject.ContinuouslyAvailable = $ContinuouslyAvailable
      $global:FsHaShareObject.FolderEnumerationMode = $FolderEnumerationMode; $global:FsHaShareObject.CachingMode = $CachingMode; $global:FsHaShareObject.EncryptData = $EncryptData
    }
  }
  Function Revoke-SmbShareAccess {
    Param ([System.String]$Name, [System.String]$ScopeName, [System.String]$AccountName, [Switch]$Force)
    $global:FsHaShareWrites += [PSCustomObject]@{ Command = 'Revoke'; AccountName = $AccountName; Force = $Force.IsPresent }
    If (-not $global:FsHaShareFrozen) { $global:FsHaShareCurrentAccess = @($global:FsHaShareCurrentAccess | Where-Object -FilterScript { $PSItem.AccountName -ne $AccountName }) }
  }
  Function Unblock-SmbShareAccess {
    Param ([System.String]$Name, [System.String]$ScopeName, [System.String]$AccountName, [Switch]$Force)
    $global:FsHaShareWrites += [PSCustomObject]@{ Command = 'Unblock'; AccountName = $AccountName; Force = $Force.IsPresent }
    If (-not $global:FsHaShareFrozen) { $global:FsHaShareCurrentAccess = @($global:FsHaShareCurrentAccess | Where-Object -FilterScript { $PSItem.AccountName -ne $AccountName }) }
  }
  Function Grant-SmbShareAccess {
    Param ([System.String]$Name, [System.String]$ScopeName, [System.String]$AccountName, [System.String]$AccessRight, [Switch]$Force)
    $global:FsHaShareWrites += [PSCustomObject]@{ Command = 'Grant'; AccountName = $AccountName; AccessRight = $AccessRight; Force = $Force.IsPresent }
    If (-not $global:FsHaShareFrozen) { $global:FsHaShareCurrentAccess += [PSCustomObject]@{ AccountName = $AccountName; AccessControlType = 'Allow'; AccessRight = $AccessRight } }
  }
}

AfterAll {
  Remove-Variable -Name 'FsHaShareSid', 'FsHaShareAcl', 'FsHaSharePathExists', 'FsHaShareObject', 'FsHaShareCurrentAccess', 'FsHaShareAmbiguous', 'FsHaShareWrites', 'FsHaShareFrozen' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ClusteredSmbShare' {
  BeforeEach {
    $global:FsHaShareSid = @{
      'NT AUTHORITY\SYSTEM' = 'S-1-5-18'; 'BUILTIN\Administrators' = 'S-1-5-32-544';
      'TCN\Domain Users' = 'S-1-5-21-1000-513'; 'Everyone' = 'S-1-1-0'
    }
    $Rules = @(
      $(New-FakeRule -Principal 'NT AUTHORITY\SYSTEM' -Rights 'FullControl')
      $(New-FakeRule -Principal 'BUILTIN\Administrators' -Rights 'FullControl')
      $(New-FakeRule -Principal 'TCN\Domain Users' -Rights 'Modify')
    )
    $global:FsHaShareAcl = New-FakeAcl -Protected $True -Access $Rules
    $global:FsHaSharePathExists = $True
    $global:FsHaShareObject = [PSCustomObject]@{ Name = 'data'; ScopeName = 'TCNAW-HAFS01'; Path = 'D:\shares\data'; Description = 'Highly available file data'; ContinuouslyAvailable = $True; FolderEnumerationMode = 'AccessBased'; CachingMode = 'None'; EncryptData = $True }
    $global:FsHaShareCurrentAccess = @(
      [PSCustomObject]@{ AccountName = 'BUILTIN\Administrators'; AccessControlType = 'Allow'; AccessRight = 'Full' },
      [PSCustomObject]@{ AccountName = 'TCN\Domain Users'; AccessControlType = 'Allow'; AccessRight = 'Change' }
    )
    $global:FsHaShareAmbiguous = $False
    $global:FsHaShareWrites = @()
    $global:FsHaShareFrozen = $False
  }
  AfterEach { Remove-AnsibleContext }

  It 'returns standalone exact DACL no-change state' {
    $Result = & $script:ScriptPath @script:Common -Mode DirectoryAcl | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:FsHaShareWrites | Should -HaveCount 0
  }

  It 'replaces a wholesale stale DACL with the exact protected set' {
    $global:FsHaShareAcl = New-FakeAcl -Protected $False -Access @(
      $(New-FakeRule -Principal 'Everyone' -Rights 'FullControl' -Type 'Deny')
      $(New-FakeRule -Principal 'Everyone' -Rights 'FullControl' -Inherited $True)
    )
    $Result = & $script:ScriptPath @script:Common -Mode DirectoryAcl | ConvertFrom-Json
    $Result.changed | Should -BeTrue
    $global:FsHaShareWrites.Command | Should -Be @('SetAcl')
    $global:FsHaShareAcl.AreAccessRulesProtected | Should -BeTrue
    $global:FsHaShareAcl.Access | Should -HaveCount 3
  }

  It 'fails DACL readback when Set-Acl does not land' {
    $global:FsHaShareAcl = New-FakeAcl -Protected $False -Access @()
    $global:FsHaShareFrozen = $True
    { & $script:ScriptPath @script:Common -Mode DirectoryAcl } | Should -Throw '*failed exact readback*'
  }

  It 'predicts DirectoryAcl check mode with no filesystem writes' {
    $global:FsHaShareAcl = New-FakeAcl -Protected $False -Access @()
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath @script:Common -Mode DirectoryAcl | Out-Null
    $Context.Changed | Should -BeTrue
    $global:FsHaShareWrites | Should -HaveCount 0
  }

  It 'rejects a missing path and unresolvable or duplicate principal' {
    $global:FsHaSharePathExists = $False
    { & $script:ScriptPath @script:Common -Mode DirectoryAcl } | Should -Throw '*does not exist*'
    $global:FsHaSharePathExists = $True
    $Bad = @($script:Ntfs | ForEach-Object -Process { @{} + $PSItem })
    $Bad[0].principal = 'Unknown'
    $BadArguments = @{} + $script:Common
    $BadArguments.NtfsAccess = $Bad
    { & $script:ScriptPath @BadArguments -Mode DirectoryAcl } | Should -Throw '*could not be resolved*'
    $Bad[0].principal = 'TCN\Domain Users'
    $BadArguments.NtfsAccess = $Bad
    { & $script:ScriptPath @BadArguments -Mode DirectoryAcl } | Should -Throw '*duplicate principals*'
  }

  It 'returns exact share no-change state through the Ansible transport' {
    $Context = New-AnsibleContext
    $Output = & $script:ScriptPath @script:Common -Mode Share
    $Output | Should -BeNullOrEmpty
    $Context.Changed | Should -BeFalse
    $global:FsHaShareWrites | Should -HaveCount 0
  }

  It 'creates an absent share with every exact argument' {
    $global:FsHaShareObject = $Null
    $global:FsHaShareCurrentAccess = @()
    & $script:ScriptPath @script:Common -Mode Share | Out-Null
    $New = @($global:FsHaShareWrites | Where-Object -FilterScript { $PSItem.Command -eq 'NewShare' })[0]
    $New.ScopeName | Should -Be 'TCNAW-HAFS01'
    $New.Path | Should -Be 'D:\shares\data'
    $New.ContinuouslyAvailable | Should -BeTrue
    $New.FolderEnumerationMode | Should -Be 'AccessBased'
    $New.CachingMode | Should -Be 'None'
    $New.EncryptData | Should -BeTrue
    $New.FullAccess | Should -Be @('BUILTIN\Administrators')
    $New.ChangeAccess | Should -Be @('TCN\Domain Users')
  }

  It 'corrects all property drift in one Set-SmbShare call' {
    $global:FsHaShareObject.Description = 'old'; $global:FsHaShareObject.ContinuouslyAvailable = $False
    $global:FsHaShareObject.FolderEnumerationMode = 'Unrestricted'; $global:FsHaShareObject.CachingMode = 'Manual'; $global:FsHaShareObject.EncryptData = $False
    & $script:ScriptPath @script:Common -Mode Share | Out-Null
    $Set = @($global:FsHaShareWrites | Where-Object -FilterScript { $PSItem.Command -eq 'SetShare' })
    $Set | Should -HaveCount 1
    $Set[0].Force | Should -BeTrue
  }

  It 'removes stale allow deny and wrong rights then grants exact access' {
    $global:FsHaShareCurrentAccess = @(
      [PSCustomObject]@{ AccountName = 'Everyone'; AccessControlType = 'Allow'; AccessRight = 'Full' },
      [PSCustomObject]@{ AccountName = 'BUILTIN\Administrators'; AccessControlType = 'Deny'; AccessRight = 'Full' },
      [PSCustomObject]@{ AccountName = 'TCN\Domain Users'; AccessControlType = 'Allow'; AccessRight = 'Read' }
    )
    & $script:ScriptPath @script:Common -Mode Share | Out-Null
    $global:FsHaShareWrites.Command | Should -Contain 'Revoke'
    $global:FsHaShareWrites.Command | Should -Contain 'Unblock'
    @($global:FsHaShareWrites | Where-Object -FilterScript { $PSItem.Command -eq 'Grant' }) | Should -HaveCount 2
  }

  It 'fails share readback when mutations do not land' {
    $global:FsHaShareObject.Description = 'old'
    $global:FsHaShareFrozen = $True
    { & $script:ScriptPath @script:Common -Mode Share } | Should -Throw '*failed exact readback*'
  }

  It 'predicts Share check mode with zero SMB writes' {
    $global:FsHaShareObject = $Null
    $global:FsHaShareCurrentAccess = @()
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath @script:Common -Mode Share | Out-Null
    $Context.Changed | Should -BeTrue
    $global:FsHaShareWrites | Should -HaveCount 0
  }

  It 'blocks publication when the DACL drifts' {
    $global:FsHaShareAcl.AreAccessRulesProtected = $False
    { & $script:ScriptPath @script:Common -Mode Share } | Should -Throw '*must be exact*'
    $global:FsHaShareWrites | Should -HaveCount 0
  }

  It 'rejects an existing exact-scope path mismatch' {
    $global:FsHaShareObject.Path = 'D:\other'
    { & $script:ScriptPath @script:Common -Mode Share } | Should -Throw '*different path*'
  }

  It 'leaves a same-name share in another scope untouched' {
    $global:FsHaShareObject.ScopeName = 'OTHER'
    $global:FsHaShareCurrentAccess = @()
    & $script:ScriptPath @script:Common -Mode Share | Out-Null
    @($global:FsHaShareWrites | Where-Object -FilterScript { $PSItem.Command -eq 'NewShare' }) | Should -HaveCount 1
  }

  It 'rejects an ambiguous exact share' {
    $global:FsHaShareAmbiguous = $True
    { & $script:ScriptPath @script:Common -Mode Share } | Should -Throw '*ambiguous*'
  }

  It 'publishes partial state where directory and DACL exist but the share does not' {
    $global:FsHaShareObject = $Null
    $global:FsHaShareCurrentAccess = @()
    $Result = & $script:ScriptPath @script:Common -Mode Share | ConvertFrom-Json
    $Result.changed | Should -BeTrue
    $global:FsHaShareObject.Name | Should -Be 'data'
  }
}
