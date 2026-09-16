#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-FileShareAccessGroup.ps1'
  $script:Common = @{
    Principal = 'TCN\TCN_GS-FileShare_Sites-North-Modify'
    Description = 'Membership grants modify access to the North folder of the sites share.'
    Path = 'OU=Domain Groups,DC=tcn,DC=example,DC=com'
  }

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
  Function New-FakeGroup {
    Param (
      [System.String]$Name = 'TCN_GS-FileShare_Sites-North-Modify',
      [System.String]$Description = 'Membership grants modify access to the North folder of the sites share.',
      [System.String]$Path = 'OU=Domain Groups,DC=tcn,DC=example,DC=com',
      [System.String]$Scope = 'Global',
      [System.String]$Category = 'Security'
    )
    [PSCustomObject]@{
      Name = $Name
      sAMAccountName = $Name
      Description = $Description
      DistinguishedName = 'CN={0},{1}' -f $Name, $Path
      GroupScope = $Scope
      GroupCategory = $Category
      ObjectGUID = [System.Guid]'00000000-0000-0000-0000-000000000101'
    }
  }
  Function Get-ADGroup {
    [CmdletBinding()]
    Param (
      [System.String]$LDAPFilter,
      [System.String[]]$Properties
    )
    [System.Void]($global:FsAccessGroupReads++)
    If ($global:FsAccessGroupWrongReadback -and $global:FsAccessGroupReads -gt 1) {
      Return New-FakeGroup -Description 'wrong'
    }
    If ($Null -ne $global:FsAccessGroup) {
      $global:FsAccessGroup
    }
  }
  Function New-ADGroup {
    [CmdletBinding()]
    Param (
      [System.String]$Name,
      [System.String]$SamAccountName,
      [System.String]$Description,
      [System.String]$GroupCategory,
      [System.String]$GroupScope,
      [System.String]$Path
    )
    $global:FsAccessGroupWrites += [PSCustomObject]@{
      Command = 'NewGroup'
      Name = $Name
      SamAccountName = $SamAccountName
      Description = $Description
      GroupCategory = $GroupCategory
      GroupScope = $GroupScope
      Path = $Path
    }
    If (-not $global:FsAccessGroupFrozen) {
      $global:FsAccessGroup = New-FakeGroup -Name $Name -Description $Description -Path $Path `
        -Scope $GroupScope -Category $GroupCategory
    }
  }
  Function Set-ADGroup {
    [CmdletBinding()]
    Param (
      [System.Object]$Identity,
      [System.String]$Description,
      [System.String]$SamAccountName,
      [System.String]$GroupCategory,
      [System.String]$GroupScope
    )
    $global:FsAccessGroupWrites += [PSCustomObject]@{
      Command = 'SetGroup'
      Description = $Description
      SamAccountName = $SamAccountName
      GroupCategory = $GroupCategory
      GroupScope = $GroupScope
    }
    If (-not $global:FsAccessGroupFrozen) {
      $global:FsAccessGroup.Description = $Description
      $global:FsAccessGroup.sAMAccountName = $SamAccountName
      $global:FsAccessGroup.GroupCategory = $GroupCategory
      $global:FsAccessGroup.GroupScope = $GroupScope
    }
  }
  Function Rename-ADObject {
    [CmdletBinding()]
    Param ([System.Object]$Identity, [System.String]$NewName)
    $global:FsAccessGroupWrites += [PSCustomObject]@{ Command = 'RenameGroup'; NewName = $NewName }
    If (-not $global:FsAccessGroupFrozen) {
      $Parent = $global:FsAccessGroup.DistinguishedName.Substring(
        $global:FsAccessGroup.DistinguishedName.IndexOf(',') + 1
      )
      $global:FsAccessGroup.Name = $NewName
      $global:FsAccessGroup.DistinguishedName = 'CN={0},{1}' -f $NewName, $Parent
    }
  }
  Function Move-ADObject {
    [CmdletBinding()]
    Param ([System.Object]$Identity, [System.String]$TargetPath)
    $global:FsAccessGroupWrites += [PSCustomObject]@{ Command = 'MoveGroup'; Path = $TargetPath }
    If (-not $global:FsAccessGroupFrozen) {
      $global:FsAccessGroup.DistinguishedName = 'CN={0},{1}' -f (
        $global:FsAccessGroup.Name, $TargetPath
      )
    }
  }
}

AfterAll {
  Remove-Variable -Name 'FsAccessGroup', 'FsAccessGroupReads', 'FsAccessGroupWrites',
  'FsAccessGroupFrozen', 'FsAccessGroupWrongReadback' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-FileShareAccessGroup' {
  BeforeEach {
    $global:FsAccessGroup = New-FakeGroup
    $global:FsAccessGroupReads = 0
    $global:FsAccessGroupWrites = @()
    $global:FsAccessGroupFrozen = $False
    $global:FsAccessGroupWrongReadback = $False
  }
  AfterEach {
    Remove-AnsibleContext
  }

  It 'reads an exact group independently and reports no change' {
    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $Result.readbacks | Should -Be 1
    $Result.postconditions | Should -Be 1
    $global:FsAccessGroupReads | Should -Be 2
    $global:FsAccessGroupWrites | Should -HaveCount 0
  }

  It 'creates an absent Global security group and freshly verifies it' {
    $global:FsAccessGroup = $Null

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $global:FsAccessGroupWrites | Should -HaveCount 1
    $global:FsAccessGroupWrites[0].Command | Should -Be 'NewGroup'
    $global:FsAccessGroupWrites[0].Name | Should -Be 'TCN_GS-FileShare_Sites-North-Modify'
    $global:FsAccessGroupWrites[0].GroupScope | Should -Be 'Global'
    $global:FsAccessGroupWrites[0].GroupCategory | Should -Be 'Security'
    $global:FsAccessGroupReads | Should -Be 2
  }

  It 'converges name path description scope and category without membership arguments' {
    $global:FsAccessGroup = New-FakeGroup -Name 'Old Name' -Description 'old' `
      -Path 'OU=Old,DC=tcn,DC=example,DC=com' -Scope 'DomainLocal' -Category 'Distribution'
    $global:FsAccessGroup.sAMAccountName = 'TCN_GS-FileShare_Sites-North-Modify'

    $Result = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $global:FsAccessGroupWrites.Command | Should -Be @('RenameGroup', 'MoveGroup', 'SetGroup')
    $global:FsAccessGroupWrites.PSObject.Properties.Name | Should -Not -Contain 'Members'
    $Result.after.description | Should -Be $script:Common.Description
    $Result.after.scope | Should -Be 'Global'
    $Result.after.category | Should -Be 'Security'
  }

  It 'reports an absent group in check mode with zero writes' {
    $global:FsAccessGroup = $Null
    $Context = New-AnsibleContext -CheckMode

    & $script:ScriptPath @script:Common | Out-Null

    $Context.Changed | Should -BeTrue
    $Context.Result.actions | Should -Contain 'create_group'
    $Context.Result.readbacks | Should -Be 0
    $global:FsAccessGroupReads | Should -Be 1
    $global:FsAccessGroupWrites | Should -HaveCount 0
  }

  It 'fails when the independent readback does not match' {
    $global:FsAccessGroup.Description = 'old'
    $global:FsAccessGroupWrongReadback = $True

    { & $script:ScriptPath @script:Common } |
      Should -Throw '*failed fresh readback*description expected*'
  }

  It 'reports zero change on the immediate second run' {
    $global:FsAccessGroup = $Null

    $First = & $script:ScriptPath @script:Common | ConvertFrom-Json
    $Second = & $script:ScriptPath @script:Common | ConvertFrom-Json

    $First.changed | Should -BeTrue
    $Second.changed | Should -BeFalse
    @($global:FsAccessGroupWrites | Where-Object -FilterScript {
        $PSItem.Command -eq 'NewGroup'
      }) | Should -HaveCount 1
  }
}
