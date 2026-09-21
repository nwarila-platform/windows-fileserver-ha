#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusterFileShareWitness.ps1'
  $script:Common = @{
    CachingMode = 'None'
    ClusterPrincipal = 'TCN\TCNAW-FSCL01$'
    Description = 'Failover cluster file share witness'
    EncryptData = $True
    Name = 'witness$'
    Path = 'C:\ClusterWitness'
  }

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null
    }
    $global:Ansible
  }
  Function Remove-AnsibleContext {
    Remove-Variable -Name Ansible -Scope Global -Force -ErrorAction SilentlyContinue
  }
  Function Assert-ResultPrimitiveLeaves {
    Param ([AllowNull()] [System.Object]$Value, [System.String]$Path = '$')
    If ($Null -eq $Value -or $Value -is [System.String] -or $Value -is [System.Int32] -or $Value -is [System.Boolean]) { Return }
    If ($Value -is [PSCustomObject]) {
      ForEach ($Property In $Value.PSObject.Properties) {
        Assert-ResultPrimitiveLeaves -Value $Property.Value -Path ('{0}.{1}' -f $Path, $Property.Name)
      }
      Return
    }
    If ($Value -is [System.Array]) {
      For ($Index = 0; $Index -lt $Value.Count; $Index++) {
        Assert-ResultPrimitiveLeaves -Value $Value[$Index] -Path ('{0}[{1}]' -f $Path, $Index)
      }
      Return
    }
    Throw ('Result leaf {0} has forbidden type {1}.' -f $Path, $Value.GetType().FullName)
  }
  Function New-FakeIdentity {
    Param ([System.String]$Value)
    $Identity = [PSCustomObject]@{ Value = $Value }
    $Identity | Add-Member -MemberType ScriptMethod -Name Translate -Value {
      Param ($Type)
      [PSCustomObject]@{ Value = $this.Value }
    }
    $Identity
  }
  Function New-FakeRule {
    Param (
      [System.String]$Principal,
      [System.String]$Rights = 'FullControl',
      [System.Boolean]$Inherited = $False,
      [System.String]$Type = 'Allow'
    )
    [PSCustomObject]@{
      IdentityReference = New-FakeIdentity -Value $global:FsWitnessSid[$Principal]
      AccessControlType = [System.Security.AccessControl.AccessControlType]$Type
      FileSystemRights = [System.Security.AccessControl.FileSystemRights]$Rights
      InheritanceFlags = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
      PropagationFlags = [System.Security.AccessControl.PropagationFlags]::None
      IsInherited = $Inherited
    }
  }
  Function New-FakeAcl {
    Param ([System.Boolean]$Protected = $True, [System.Object[]]$Access = @())
    $Acl = [PSCustomObject]@{ AreAccessRulesProtected = $Protected; Access = @($Access) }
    $Acl | Add-Member -MemberType ScriptMethod -Name SetAccessRuleProtection -Value {
      Param ($Protect, $PreserveInheritance)
      $this.AreAccessRulesProtected = [System.Boolean]$Protect
      If (-not $PreserveInheritance) {
        $this.Access = @($this.Access | Where-Object -FilterScript { -not $PSItem.IsInherited })
      }
    }
    $Acl | Add-Member -MemberType ScriptMethod -Name RemoveAccessRuleSpecific -Value {
      Param ($Rule)
      $this.Access = @($this.Access | Where-Object -FilterScript { $PSItem -ne $Rule })
      $True
    }
    $Acl | Add-Member -MemberType ScriptMethod -Name AddAccessRule -Value {
      Param ($Rule)
      $this.Access += $Rule
      $True
    }
    $Acl
  }
  Function Copy-FakeAcl {
    $Rules = @($global:FsWitnessAcl.Access | ForEach-Object -Process {
        $ExistingRule = $PSItem
        $Principal = @($global:FsWitnessSid.Keys | Where-Object -FilterScript {
            $global:FsWitnessSid[$PSItem] -eq $ExistingRule.IdentityReference.Value
          })[0]
        New-FakeRule -Principal $Principal -Rights ([System.String]$ExistingRule.FileSystemRights) -Inherited ([System.Boolean]$ExistingRule.IsInherited) -Type ([System.String]$ExistingRule.AccessControlType)
      })
    New-FakeAcl -Protected $global:FsWitnessAcl.AreAccessRulesProtected -Access $Rules
  }
  Function New-Object {
    Param ([System.String]$TypeName, [System.Object[]]$ArgumentList)
    $Arguments = @($ArgumentList)
    If ($Arguments.Count -eq 1 -and $Arguments[0] -is [System.Object[]]) {
      $Arguments = @($Arguments[0])
    }
    If ($TypeName -eq 'System.Security.Principal.NTAccount') {
      $Principal = [System.String]$Arguments[0]
      If (-not $global:FsWitnessSid.ContainsKey($Principal)) { Throw 'unresolvable' }
      $Account = [PSCustomObject]@{ Principal = $Principal }
      $Account | Add-Member -MemberType ScriptMethod -Name Translate -Value {
        Param ($Type)
        [PSCustomObject]@{ Value = $global:FsWitnessSid[$this.Principal] }
      }
      Return $Account
    }
    If ($TypeName -eq 'System.Security.AccessControl.FileSystemAccessRule') {
      Return New-FakeRule -Principal ([System.String]$Arguments[0]) -Rights ([System.String]$Arguments[1]) -Type ([System.String]$Arguments[4])
    }
    Throw ('Unexpected New-Object type {0}.' -f $TypeName)
  }
  Function Test-Path {
    Param ([System.String]$LiteralPath, [System.String]$PathType)
    If ($PathType -eq 'Container') { Return $global:FsWitnessDirectoryExists }
    $global:FsWitnessPathExists
  }
  Function New-Item {
    Param ([System.String]$ItemType, [System.String]$Path, [Switch]$Force)
    $global:FsWitnessWrites += [PSCustomObject]@{
      Command = 'NewItem'; ItemType = $ItemType; Path = $Path; Force = $Force.IsPresent
    }
    If (-not $global:FsWitnessFrozen) {
      $global:FsWitnessDirectoryExists = $True
      $global:FsWitnessPathExists = $True
    }
  }
  Function Get-Acl { Param ([System.String]$LiteralPath) Copy-FakeAcl }
  Function Set-Acl {
    Param ([System.String]$LiteralPath, [System.Object]$AclObject)
    $global:FsWitnessWrites += [PSCustomObject]@{ Command = 'SetAcl'; Path = $LiteralPath }
    If (-not $global:FsWitnessFrozen) { $global:FsWitnessAcl = $AclObject }
  }
  Function Get-SmbShare {
    [CmdletBinding()]
    Param ([System.String]$Name)
    If ($global:FsWitnessLookupFails) { Write-Error -Message 'injected share lookup failure'; Return }
    If ($global:FsWitnessAmbiguous) { Return @($global:FsWitnessShare, $global:FsWitnessShare) }
    If ($Null -ne $global:FsWitnessShare) { $global:FsWitnessShare }
  }
  Function Get-SmbShareAccess {
    Param ([System.String]$Name)
    @($global:FsWitnessShareAccess)
  }
  Function New-SmbShare {
    Param (
      [System.String]$Name, [System.String]$Path, [System.String]$Description,
      [System.Boolean]$ContinuouslyAvailable, [System.String]$FolderEnumerationMode,
      [System.String]$CachingMode, [System.Boolean]$EncryptData, [System.String[]]$FullAccess
    )
    $global:FsWitnessWrites += [PSCustomObject]@{
      Command = 'NewShare'; Name = $Name; Path = $Path; Description = $Description
      ContinuouslyAvailable = $ContinuouslyAvailable; FolderEnumerationMode = $FolderEnumerationMode
      CachingMode = $CachingMode; EncryptData = $EncryptData; FullAccess = @($FullAccess)
    }
    If (-not $global:FsWitnessFrozen) {
      $global:FsWitnessShare = [PSCustomObject]@{
        Name = $Name; Path = $Path; Description = $Description
        ContinuouslyAvailable = $ContinuouslyAvailable; FolderEnumerationMode = $FolderEnumerationMode
        CachingMode = $CachingMode; EncryptData = $EncryptData
      }
      $global:FsWitnessShareAccess = @(
        [PSCustomObject]@{ AccountName = $FullAccess[0]; AccessControlType = 'Allow'; AccessRight = 'Full' }
      )
    }
  }
  Function Set-SmbShare {
    Param (
      [System.String]$Name, [System.String]$Description,
      [System.Boolean]$ContinuouslyAvailable, [System.String]$FolderEnumerationMode,
      [System.String]$CachingMode, [System.Boolean]$EncryptData, [Switch]$Force
    )
    $global:FsWitnessWrites += [PSCustomObject]@{
      Command = 'SetShare'; Description = $Description; ContinuouslyAvailable = $ContinuouslyAvailable
      FolderEnumerationMode = $FolderEnumerationMode; CachingMode = $CachingMode
      EncryptData = $EncryptData; Force = $Force.IsPresent
    }
    If (-not $global:FsWitnessFrozen) {
      $global:FsWitnessShare.Description = $Description
      $global:FsWitnessShare.ContinuouslyAvailable = $ContinuouslyAvailable
      $global:FsWitnessShare.FolderEnumerationMode = $FolderEnumerationMode
      $global:FsWitnessShare.CachingMode = $CachingMode
      $global:FsWitnessShare.EncryptData = $EncryptData
    }
  }
  Function Revoke-SmbShareAccess {
    Param ([System.String]$Name, [System.String]$AccountName, [Switch]$Force)
    $global:FsWitnessWrites += [PSCustomObject]@{
      Command = 'Revoke'; AccountName = $AccountName; Force = $Force.IsPresent
    }
    If (-not $global:FsWitnessFrozen) {
      $global:FsWitnessShareAccess = @($global:FsWitnessShareAccess | Where-Object -FilterScript {
          $PSItem.AccountName -ne $AccountName
        })
    }
  }
  Function Unblock-SmbShareAccess {
    Param ([System.String]$Name, [System.String]$AccountName, [Switch]$Force)
    $global:FsWitnessWrites += [PSCustomObject]@{
      Command = 'Unblock'; AccountName = $AccountName; Force = $Force.IsPresent
    }
    If (-not $global:FsWitnessFrozen) {
      $global:FsWitnessShareAccess = @($global:FsWitnessShareAccess | Where-Object -FilterScript {
          $PSItem.AccountName -ne $AccountName
        })
    }
  }
  Function Grant-SmbShareAccess {
    Param ([System.String]$Name, [System.String]$AccountName, [System.String]$AccessRight, [Switch]$Force)
    $global:FsWitnessWrites += [PSCustomObject]@{
      Command = 'Grant'; AccountName = $AccountName; AccessRight = $AccessRight; Force = $Force.IsPresent
    }
    If (-not $global:FsWitnessFrozen) {
      $global:FsWitnessShareAccess += [PSCustomObject]@{
        AccountName = $AccountName; AccessControlType = 'Allow'; AccessRight = $AccessRight
      }
    }
  }
}

AfterAll {
  Remove-Variable -Name 'FsWitnessSid', 'FsWitnessAcl', 'FsWitnessDirectoryExists',
  'FsWitnessPathExists', 'FsWitnessShare', 'FsWitnessShareAccess', 'FsWitnessLookupFails',
  'FsWitnessAmbiguous', 'FsWitnessWrites', 'FsWitnessFrozen' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ClusterFileShareWitness' {
  BeforeEach {
    $global:FsWitnessSid = @{
      'NT AUTHORITY\SYSTEM' = 'S-1-5-18'
      'BUILTIN\Administrators' = 'S-1-5-32-544'
      'TCN\TCNAW-FSCL01$' = 'S-1-5-21-1000-1101'
      'Everyone' = 'S-1-1-0'
    }
    $global:FsWitnessAcl = New-FakeAcl -Protected $True -Access @(
      $(New-FakeRule -Principal 'NT AUTHORITY\SYSTEM')
      $(New-FakeRule -Principal 'BUILTIN\Administrators')
      $(New-FakeRule -Principal 'TCN\TCNAW-FSCL01$')
    )
    $global:FsWitnessDirectoryExists = $True
    $global:FsWitnessPathExists = $True
    $global:FsWitnessShare = [PSCustomObject]@{
      Name = 'witness$'; Path = 'C:\ClusterWitness'
      Description = 'Failover cluster file share witness'; ContinuouslyAvailable = $False
      FolderEnumerationMode = 'AccessBased'; CachingMode = 'None'; EncryptData = $True
    }
    $global:FsWitnessShareAccess = @(
      [PSCustomObject]@{
        AccountName = 'TCN\TCNAW-FSCL01$'; AccessControlType = 'Allow'; AccessRight = 'Full'
      }
    )
    $global:FsWitnessLookupFails = $False
    $global:FsWitnessAmbiguous = $False
    $global:FsWitnessWrites = @()
    $global:FsWitnessFrozen = $False
  }
  AfterEach { Remove-AnsibleContext }

  It 'returns exact standalone state without writes' {
    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $Result.after.exact | Should -BeTrue
    $global:FsWitnessWrites | Should -HaveCount 0
  }

  It 'creates the directory, exact DACL, and standalone share in order' {
    $global:FsWitnessDirectoryExists = $False
    $global:FsWitnessPathExists = $False
    $global:FsWitnessShare = $Null
    $global:FsWitnessShareAccess = @()
    $global:FsWitnessAcl = New-FakeAcl -Protected $False -Access @(
      $(New-FakeRule -Principal 'Everyone' -Inherited $True)
    )

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.actions | Should -Be @('create_directory', 'enforce_directory_acl', 'create_share')
    $global:FsWitnessWrites.Command | Should -Be @('NewItem', 'SetAcl', 'NewShare')
    $global:FsWitnessAcl.AreAccessRulesProtected | Should -BeTrue
    $global:FsWitnessAcl.Access | Should -HaveCount 3
    $global:FsWitnessWrites[2].ContinuouslyAvailable | Should -BeFalse
    $global:FsWitnessWrites[2].FolderEnumerationMode | Should -Be 'AccessBased'
    $global:FsWitnessWrites[2].FullAccess | Should -Be @('TCN\TCNAW-FSCL01$')
    $Result.after.exact | Should -BeTrue
  }

  It 'replaces inherited and stale DACL entries with the exact principal set' {
    $global:FsWitnessAcl = New-FakeAcl -Protected $False -Access @(
      $(New-FakeRule -Principal 'Everyone' -Type 'Deny')
      $(New-FakeRule -Principal 'Everyone' -Inherited $True)
    )

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $global:FsWitnessWrites.Command | Should -Be @('SetAcl')
    $global:FsWitnessAcl.AreAccessRulesProtected | Should -BeTrue
    $global:FsWitnessAcl.Access.IdentityReference.Value | Sort-Object | Should -Be @(
      'S-1-5-18', 'S-1-5-21-1000-1101', 'S-1-5-32-544'
    )
  }

  It 'repairs share property drift' {
    $global:FsWitnessShare.Description = 'stale'
    $global:FsWitnessShare.ContinuouslyAvailable = $True
    $global:FsWitnessShare.FolderEnumerationMode = 'Unrestricted'
    $global:FsWitnessShare.CachingMode = 'Manual'
    $global:FsWitnessShare.EncryptData = $False

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.actions | Should -Be @('set_share_properties')
    $global:FsWitnessWrites.Command | Should -Be @('SetShare')
    $global:FsWitnessWrites[0].ContinuouslyAvailable | Should -BeFalse
    $global:FsWitnessWrites[0].FolderEnumerationMode | Should -Be 'AccessBased'
    $Result.after.exact | Should -BeTrue
  }

  It 'replaces every stale allow and deny share ACE with CNO Full access' {
    $global:FsWitnessShareAccess = @(
      [PSCustomObject]@{ AccountName = 'Everyone'; AccessControlType = 'Allow'; AccessRight = 'Full' }
      [PSCustomObject]@{ AccountName = 'BUILTIN\Administrators'; AccessControlType = 'Deny'; AccessRight = 'Full' }
    )

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.actions | Should -Be @('set_share_access')
    $global:FsWitnessWrites.Command | Should -Be @('Revoke', 'Unblock', 'Grant')
    $global:FsWitnessShareAccess | Should -HaveCount 1
    $global:FsWitnessShareAccess[0].AccountName | Should -Be 'TCN\TCNAW-FSCL01$'
    $global:FsWitnessShareAccess[0].AccessRight | Should -Be 'Full'
    $Result.after.share_access_exact | Should -BeTrue
  }

  It 'removes an orphaned share principal that no longer resolves' {
    $global:FsWitnessShareAccess = @(
      [PSCustomObject]@{
        AccountName = 'TCN\S-1-5-21-1000-9999'; AccessControlType = 'Allow'; AccessRight = 'Full'
      }
    )

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.actions | Should -Be @('set_share_access')
    $global:FsWitnessWrites.Command | Should -Be @('Revoke', 'Grant')
    $global:FsWitnessShareAccess | Should -HaveCount 1
    $global:FsWitnessShareAccess[0].AccountName | Should -Be 'TCN\TCNAW-FSCL01$'
    $Result.after.share_access_exact | Should -BeTrue
  }

  It 'predicts all drift in check mode without writes' {
    $global:FsWitnessDirectoryExists = $False
    $global:FsWitnessPathExists = $False
    $global:FsWitnessShare = $Null
    $global:FsWitnessShareAccess = @()
    $Context = New-AnsibleContext -CheckMode

    & $script:ScriptPath @script:Common | Out-Null

    $Context.Changed | Should -BeTrue
    $Context.Result.actions | Should -Be @('create_directory', 'enforce_directory_acl', 'create_share')
    $Context.Result.check_mode | Should -BeTrue
    $global:FsWitnessWrites | Should -HaveCount 0
  }

  It 'returns through the Ansible transport without pipeline output' {
    $Context = New-AnsibleContext

    $Output = & $script:ScriptPath @script:Common

    $Output | Should -BeNullOrEmpty
    $Context.Changed | Should -BeFalse
    $Context.Result.after.exact | Should -BeTrue
  }

  It 'rejects an existing share at a different path before writes' {
    $global:FsWitnessShare.Path = 'D:\Other'

    { & $script:ScriptPath @script:Common } | Should -Throw '*refusing to repoint it*'

    $global:FsWitnessWrites | Should -HaveCount 0
  }

  It 'rejects a non-directory witness path before writes' {
    $global:FsWitnessDirectoryExists = $False
    $global:FsWitnessPathExists = $True

    { & $script:ScriptPath @script:Common } | Should -Throw '*exists but is not a directory*'

    $global:FsWitnessWrites | Should -HaveCount 0
  }

  It 'rejects ambiguous shares and propagates lookup failures before writes' {
    $global:FsWitnessAmbiguous = $True
    { & $script:ScriptPath @script:Common } | Should -Throw '*is ambiguous*'
    $global:FsWitnessAmbiguous = $False
    $global:FsWitnessLookupFails = $True
    { & $script:ScriptPath @script:Common } | Should -Throw '*injected share lookup failure*'
    $global:FsWitnessWrites | Should -HaveCount 0
  }

  It 'rejects an unresolvable CNO before state reads or writes' {
    $global:FsWitnessSid.Remove('TCN\TCNAW-FSCL01$')

    { & $script:ScriptPath @script:Common } | Should -Throw '*could not be resolved*'

    $global:FsWitnessWrites | Should -HaveCount 0
  }

  It 'fails when a write does not survive readback' {
    $global:FsWitnessShare.Description = 'stale'
    $global:FsWitnessFrozen = $True

    { & $script:ScriptPath @script:Common } | Should -Throw '*readback failed*'
  }

  It 'preserves exact CNO access while removing a stale ACE' {
    $global:FsWitnessShareAccess = @(
      [PSCustomObject]@{
        AccountName = 'TCN\TCNAW-FSCL01$'; AccessControlType = 'Allow'; AccessRight = 'Full'
      }
      [PSCustomObject]@{ AccountName = 'Everyone'; AccessControlType = 'Allow'; AccessRight = 'Full' }
    )

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.actions | Should -Be @('set_share_access')
    $global:FsWitnessWrites.Command | Should -Be @('Revoke')
    $global:FsWitnessWrites[0].AccountName | Should -Be 'Everyone'
    $global:FsWitnessShareAccess | Should -HaveCount 1
    $global:FsWitnessShareAccess[0].AccountName | Should -Be 'TCN\TCNAW-FSCL01$'
    $Result.after.share_access_exact | Should -BeTrue
  }

  It 'exports only serialization-safe primitive result leaves' {
    $Context = New-AnsibleContext

    & $script:ScriptPath @script:Common | Out-Null

    { Assert-ResultPrimitiveLeaves -Value $Context.Result } | Should -Not -Throw
  }

  It 'rejects malformed CNO, share name, and local path parameters' {
    $Bad = @{} + $script:Common
    $Bad.ClusterPrincipal = 'TCN\TCNAW-FSCL01'
    { & $script:ScriptPath @Bad } | Should -Throw
    $Bad = @{} + $script:Common
    $Bad.Name = 'bad/name'
    { & $script:ScriptPath @Bad } | Should -Throw
    $Bad = @{} + $script:Common
    $Bad.Path = '\\server\share'
    { & $script:ScriptPath @Bad } | Should -Throw
  }
}
