#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusteredFolderTree.ps1'
  $script:Protected = @(
    @{ principal = 'NT AUTHORITY\SYSTEM'; access_control_type = 'Allow'; rights = 'FullControl' },
    @{ principal = 'BUILTIN\Administrators'; access_control_type = 'Allow'; rights = 'FullControl' }
  )
  $script:Folders = @(
    @{
      path = 'North'
      inherit = $False
      access = @(
        $script:Protected[0]
        $script:Protected[1]
        @{ principal = 'TCN\North File Users'; access_control_type = 'Allow'; rights = 'Modify' }
      )
    },
    @{
      path = 'North\Projects'
      inherit = $True
      access = @(
        $script:Protected[0]
        $script:Protected[1]
        @{
          principal = 'TCN\North Projects File Users'
          access_control_type = 'Allow'
          rights = 'Modify'
        }
      )
    }
  )

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed = $True
      CheckMode = $CheckMode.IsPresent
      Failed = $False
      Result = $Null
    }
    $global:Ansible
  }
  Function Remove-AnsibleContext {
    Remove-Variable -Name Ansible -Scope Global -Force -ErrorAction SilentlyContinue
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
      [System.String]$Rights,
      [System.Boolean]$Inherited = $False,
      [System.String]$Type = 'Allow'
    )
    [PSCustomObject]@{
      IdentityReference = New-FakeIdentity -Value $global:FsFolderSid[$Principal]
      AccessControlType = [System.Security.AccessControl.AccessControlType]$Type
      FileSystemRights = [System.Security.AccessControl.FileSystemRights]$Rights
      InheritanceFlags = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
      PropagationFlags = [System.Security.AccessControl.PropagationFlags]::None
      IsInherited = $Inherited
    }
  }
  Function New-FakeAcl {
    Param (
      [System.Boolean]$Protected = $True,
      [System.Object[]]$Access = @()
    )
    $Acl = [PSCustomObject]@{
      AreAccessRulesProtected = $Protected
      Access = @($Access)
    }
    $Acl | Add-Member -MemberType ScriptMethod -Name SetAccessRuleProtection -Value {
      Param ($Protect, $PreserveInheritance)
      $this.AreAccessRulesProtected = [System.Boolean]$Protect
      If (-not $PreserveInheritance) {
        $this.Access = @($this.Access | Where-Object -FilterScript {
            -not [System.Boolean]$PSItem.IsInherited
          })
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
    Param ([System.String]$Path)
    $Rules = @($global:FsFolderAcls[$Path].Access | ForEach-Object -Process {
        $ExistingRule = $PSItem
        $Principal = @($global:FsFolderSid.Keys | Where-Object -FilterScript {
            $global:FsFolderSid[$PSItem] -eq $ExistingRule.IdentityReference.Value
          })[0]
        New-FakeRule -Principal $Principal -Rights (
          [System.String]$ExistingRule.FileSystemRights
        ) -Inherited (
          [System.Boolean]$ExistingRule.IsInherited
        ) -Type (
          [System.String]$ExistingRule.AccessControlType
        )
      })
    New-FakeAcl -Protected (
      [System.Boolean]$global:FsFolderAcls[$Path].AreAccessRulesProtected
    ) -Access $Rules
  }
  Function New-Object {
    Param (
      [System.String]$TypeName,
      [System.Object[]]$ArgumentList
    )
    $Arguments = @($ArgumentList)
    If ($Arguments.Count -eq 1 -and $Arguments[0] -is [System.Object[]]) {
      $Arguments = @($Arguments[0])
    }
    If ($TypeName -eq 'System.Security.Principal.NTAccount') {
      $Principal = [System.String]$Arguments[0]
      If (-not $global:FsFolderSid.ContainsKey($Principal)) {
        Throw 'unresolvable'
      }
      $Account = [PSCustomObject]@{ Principal = $Principal }
      $Account | Add-Member -MemberType ScriptMethod -Name Translate -Value {
        Param ($Type)
        [PSCustomObject]@{ Value = $global:FsFolderSid[$this.Principal] }
      }
      Return $Account
    }
    If ($TypeName -eq 'System.Security.AccessControl.FileSystemAccessRule') {
      Return New-FakeRule -Principal (
        [System.String]$Arguments[0]
      ) -Rights (
        [System.String]$Arguments[1]
      ) -Type (
        [System.String]$Arguments[4]
      )
    }
    Throw ('Unexpected New-Object type {0}.' -f $TypeName)
  }
  Function Test-Path {
    Param (
      [System.String]$LiteralPath,
      [System.String]$PathType
    )
    $global:FsFolderReads += $LiteralPath
    $global:FsFolderDirectories.ContainsKey($LiteralPath) -and
    [System.Boolean]$global:FsFolderDirectories[$LiteralPath]
  }
  Function New-Item {
    Param (
      [System.String]$ItemType,
      [System.String]$Path
    )
    $Parent = $Path.Substring(0, $Path.LastIndexOf('\'))
    If (-not $global:FsFolderDirectories.ContainsKey($Parent)) {
      Throw ('parent missing: {0}' -f $Parent)
    }
    $global:FsFolderWrites += [PSCustomObject]@{
      Command = 'NewItem'
      Path = $Path
    }
    If (-not $global:FsFolderFrozen) {
      $global:FsFolderDirectories[$Path] = $True
      $global:FsFolderAcls[$Path] = New-FakeAcl -Protected $False -Access @()
    }
  }
  Function Get-Acl {
    Param ([System.String]$LiteralPath)
    $global:FsFolderReads += $LiteralPath
    Copy-FakeAcl -Path $LiteralPath
  }
  Function Set-Acl {
    Param (
      [System.String]$LiteralPath,
      [System.Object]$AclObject
    )
    $global:FsFolderWrites += [PSCustomObject]@{
      Command = 'SetAcl'
      Path = $LiteralPath
    }
    If (-not $global:FsFolderFrozen) {
      $global:FsFolderAcls[$LiteralPath] = $AclObject
    }
  }
}

AfterAll {
  Remove-Variable -Name 'FsFolderSid', 'FsFolderDirectories', 'FsFolderAcls',
  'FsFolderWrites', 'FsFolderReads', 'FsFolderFrozen' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ClusteredFolderTree' {
  BeforeEach {
    $global:FsFolderSid = @{
      'NT AUTHORITY\SYSTEM' = 'S-1-5-18'
      'BUILTIN\Administrators' = 'S-1-5-32-544'
      'TCN\North File Users' = 'S-1-5-21-1000-1101'
      'TCN\North Projects File Users' = 'S-1-5-21-1000-1102'
      'Everyone' = 'S-1-1-0'
    }
    $global:FsFolderDirectories = @{
      'D:\shares\sites' = $True
      'D:\shares\sites\North' = $True
      'D:\shares\sites\North\Projects' = $True
      'D:\shares\sites\Undeclared' = $True
    }
    $global:FsFolderAcls = @{
      'D:\shares\sites\North' = New-FakeAcl -Protected $True -Access @(
        $(New-FakeRule -Principal 'NT AUTHORITY\SYSTEM' -Rights 'FullControl')
        $(New-FakeRule -Principal 'BUILTIN\Administrators' -Rights 'FullControl')
        $(New-FakeRule -Principal 'TCN\North File Users' -Rights 'Modify')
      )
      'D:\shares\sites\North\Projects' = New-FakeAcl -Protected $False -Access @(
        $(New-FakeRule -Principal 'NT AUTHORITY\SYSTEM' -Rights 'FullControl')
        $(New-FakeRule -Principal 'BUILTIN\Administrators' -Rights 'FullControl')
        $(New-FakeRule -Principal 'TCN\North Projects File Users' -Rights 'Modify')
        $(New-FakeRule -Principal 'TCN\North File Users' -Rights 'Modify' -Inherited $True)
      )
      'D:\shares\sites\Undeclared' = New-FakeAcl -Protected $True -Access @(
        $(New-FakeRule -Principal 'Everyone' -Rights 'FullControl')
      )
    }
    $global:FsFolderWrites = @()
    $global:FsFolderReads = @()
    $global:FsFolderFrozen = $False
  }
  AfterEach {
    Remove-AnsibleContext
  }

  It 'reports no change on an exact tree and on an immediate second run' {
    $First = & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $script:Folders |
      ConvertFrom-Json
    $Second = & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $script:Folders |
      ConvertFrom-Json

    $First.changed | Should -BeFalse
    $Second.changed | Should -BeFalse
    $global:FsFolderWrites | Should -HaveCount 0
  }

  It 'accepts ReadAndExecute NTFS rights for a read-only folder grant' {
    $ReadOnlyFolders = @($script:Folders | ForEach-Object -Process {
        $Folder = @{} + $PSItem
        $Folder.access = @($PSItem.access | ForEach-Object -Process { @{} + $PSItem })
        $Folder
      })
    $ReadOnlyFolders[0].access[2].rights = 'ReadAndExecute'
    $global:FsFolderAcls['D:\shares\sites\North'].Access[2] = New-FakeRule `
      -Principal 'TCN\North File Users' -Rights 'ReadAndExecute'

    $Result = & $script:ScriptPath -RootPath 'D:\shares\sites' `
      -Folders $ReadOnlyFolders | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $global:FsFolderWrites | Should -HaveCount 0
  }

  It 'creates parents before children and converges their exact explicit entries' {
    $global:FsFolderDirectories.Remove('D:\shares\sites\North')
    $global:FsFolderDirectories.Remove('D:\shares\sites\North\Projects')
    $global:FsFolderAcls.Remove('D:\shares\sites\North')
    $global:FsFolderAcls.Remove('D:\shares\sites\North\Projects')

    $Result = & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $script:Folders |
      ConvertFrom-Json

    $Result.changed | Should -BeTrue
    @($global:FsFolderWrites | Where-Object -FilterScript {
        $PSItem.Command -eq 'NewItem'
      }).Path | Should -Be @(
      'D:\shares\sites\North'
      'D:\shares\sites\North\Projects'
    )
    $Result.after.exact | Should -Not -Contain $False
  }

  It 'removes stale explicit entries and leaves an undeclared sibling untouched' {
    $global:FsFolderAcls['D:\shares\sites\North'] = New-FakeAcl -Protected $False -Access @(
      $(New-FakeRule -Principal 'Everyone' -Rights 'FullControl' -Type 'Deny')
    )
    $SiblingBefore = $global:FsFolderAcls['D:\shares\sites\Undeclared']

    & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $script:Folders | Out-Null

    $global:FsFolderAcls['D:\shares\sites\North'].Access | Should -HaveCount 3
    [System.Object]::ReferenceEquals(
      $global:FsFolderAcls['D:\shares\sites\Undeclared'],
      $SiblingBefore
    ) | Should -BeTrue
    $global:FsFolderWrites.Path | Should -Not -Contain 'D:\shares\sites\Undeclared'
    $global:FsFolderReads | Should -Not -Contain 'D:\shares\sites\Undeclared'
  }

  It 'breaks and restores inheritance exactly as declared' {
    $global:FsFolderAcls['D:\shares\sites\North'].AreAccessRulesProtected = $False
    & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $script:Folders | Out-Null
    $global:FsFolderAcls['D:\shares\sites\North'].AreAccessRulesProtected | Should -BeTrue

    $Restore = @($script:Folders | ForEach-Object -Process { @{} + $PSItem })
    $Restore[0].inherit = $True
    & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $Restore | Out-Null
    $global:FsFolderAcls['D:\shares\sites\North'].AreAccessRulesProtected | Should -BeFalse
  }

  It 'refuses a change that would drop SYSTEM' {
    $Unsafe = @($script:Folders | ForEach-Object -Process { @{} + $PSItem })
    $Unsafe[0].access = @($Unsafe[0].access | Where-Object -FilterScript {
        $PSItem.principal -ne 'NT AUTHORITY\SYSTEM'
      })

    {
      & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $Unsafe
    } | Should -Throw '*must retain one Allow FullControl entry for protected SID S-1-5-18*'

    $global:FsFolderWrites | Should -HaveCount 0
  }

  It 'refuses a change that would drop Administrators' {
    $Unsafe = @($script:Folders | ForEach-Object -Process { @{} + $PSItem })
    $Unsafe[0].access = @($Unsafe[0].access | Where-Object -FilterScript {
        $PSItem.principal -ne 'BUILTIN\Administrators'
      })

    {
      & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $Unsafe
    } | Should -Throw '*must retain one Allow FullControl entry for protected SID S-1-5-32-544*'

    $global:FsFolderWrites | Should -HaveCount 0
  }

  It 'refuses a child declared before its parent' {
    $Reversed = @($script:Folders[1], $script:Folders[0])

    {
      & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $Reversed
    } | Should -Throw '*must declare its parent North earlier*'

    $global:FsFolderWrites | Should -HaveCount 0
  }

  It 'predicts all drift in check mode without writing' {
    $global:FsFolderDirectories.Remove('D:\shares\sites\North\Projects')
    $global:FsFolderAcls.Remove('D:\shares\sites\North\Projects')
    $global:FsFolderAcls['D:\shares\sites\North'].AreAccessRulesProtected = $False
    $Context = New-AnsibleContext -CheckMode

    & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $script:Folders | Out-Null

    $Context.Changed | Should -BeTrue
    $Context.Result.check_mode | Should -BeTrue
    $Context.Result.actions | Should -Contain 'create_folder:North\Projects'
    $global:FsFolderWrites | Should -HaveCount 0
    $global:FsFolderDirectories.ContainsKey(
      'D:\shares\sites\North\Projects'
    ) | Should -BeFalse
  }

  It 'predicts the complete tree when the share root is absent in check mode' {
    $global:FsFolderDirectories.Remove('D:\shares\sites')
    $global:FsFolderDirectories.Remove('D:\shares\sites\North')
    $global:FsFolderDirectories.Remove('D:\shares\sites\North\Projects')
    $global:FsFolderAcls.Remove('D:\shares\sites\North')
    $global:FsFolderAcls.Remove('D:\shares\sites\North\Projects')
    $Context = New-AnsibleContext -CheckMode

    & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $script:Folders | Out-Null

    $Context.Changed | Should -BeTrue
    $Context.Result.actions | Should -Contain 'create_folder:North'
    $Context.Result.actions | Should -Contain 'create_folder:North\Projects'
    $global:FsFolderWrites | Should -HaveCount 0
  }

  It 'fails when the fresh readback does not match the declaration' {
    $global:FsFolderAcls['D:\shares\sites\North'].AreAccessRulesProtected = $False
    $global:FsFolderFrozen = $True

    {
      & $script:ScriptPath -RootPath 'D:\shares\sites' -Folders $script:Folders
    } | Should -Throw '*failed exact explicit-access readback*'
  }
}
