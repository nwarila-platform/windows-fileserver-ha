#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-ClusterDirectoryRights.ps1 (org pair convention: every
    script ships with a sibling <Name>.pester.ps1; the pester-matrix workflow
    runs one leg per pair).

    Runs anywhere, Linux CI included. Get-ADUser, Get-ADComputer, Get-Acl,
    Set-Acl and New-Object are stubbed as functions in this file, and the
    script -- invoked as a child scope -- resolves the stubs instead of the
    real cmdlets. Only SecurityIdentifier and the rule constructor are Windows
    gated; the ActiveDirectoryRights and PropagationFlags ENUMS resolve on any
    platform, so the stub ACEs carry genuine enum values and the script's real
    predicate runs unmodified.

    What is deliberately NOT asserted: canonical ACE ordering. The script no
    longer computes it -- AddAccessRule does -- and testing the framework's own
    guarantee against a stub would prove nothing. That the script delegates it
    is the point; an earlier revision computed ordering in SDDL text and was
    wrong in three separate ways.

    Stub state lives in $global: variables because inside a function called
    from a child SCRIPT, $script: resolves to the child script's own scope. The
    Set-Acl stub stores what it is handed, so the script's re-acquire-and-verify
    pass runs against the value it just wrote.

    Both transports are asserted. The $Ansible stub's Changed defaults to $True
    exactly like win_powershell, so the no-drift test proves the script SETS
    Changed=$False rather than inheriting a default.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusterDirectoryRights.ps1'

  $script:AccountSid = 'S-1-5-21-1-2-3-1001'
  $script:ClusterSid = 'S-1-5-21-1-2-3-1002'
  $script:FileServerSid = 'S-1-5-21-1-2-3-1003'
  $script:ClusterDn = 'CN=TCNAW-FSCL01,OU=HA,DC=example,DC=test'
  $script:FileServerDn = 'CN=TCNAW-HAFS01,OU=HA,DC=example,DC=test'

  $script:FULL = [System.DirectoryServices.ActiveDirectoryRights]::GenericAll
  $script:READ = [System.DirectoryServices.ActiveDirectoryRights]::ReadProperty

  # A stand-in ACE carrying REAL enum values, so the script's predicate is exercised as written.
  Function New-StubAce {
    Param (
      [System.String]$Sid,
      [System.Object]$Rights = $script:FULL,
      [System.String]$Type = 'Allow',
      [System.Object]$Propagation = ([System.Security.AccessControl.PropagationFlags]::None),
      [System.Object]$Inheritance = ([System.DirectoryServices.ActiveDirectorySecurityInheritance]::None)
    )
    # A real ACE reports an NTAccount that must be Translate()d to a SID; the stub answers the
    # same way so the script's translation path is exercised rather than bypassed.
    $Identity = [PSCustomObject]@{ Value = "TCN\\stub-$Sid" }
    $Identity | Add-Member -MemberType ScriptMethod -Name 'Translate' -Value {
      Param ($Type)
      [PSCustomObject]@{ Value = $this.Sid }
    }
    $Identity | Add-Member -MemberType NoteProperty -Name 'Sid' -Value $Sid
    [PSCustomObject]@{
      AccessControlType     = $Type
      IdentityReference     = $Identity
      ActiveDirectoryRights = $Rights
      PropagationFlags      = $Propagation
      # Carried so a regression from a this-object-only rule to an inheritable one is visible.
      InheritanceType       = $Inheritance
    }
  }

  Function New-StubAcl {
    Param ([System.Object[]]$Access = @())
    $Acl = [PSCustomObject]@{ Access = [System.Collections.ArrayList]@($Access) }
    $Acl | Add-Member -MemberType ScriptMethod -Name 'AddAccessRule' -Value {
      Param ([System.Object]$Rule)
      $null = $this.Access.Add($Rule)
    }
    $Acl
  }

  Function Get-ADUser {
    Param ($Identity)
    If ($global:StubFailInitialRead) { Throw 'The initial directory read failed.' }
    [PSCustomObject]@{ SID = $global:StubAccountSid }
  }

  Function Get-ADComputer {
    Param ($Identity)
    if ($Identity -eq 'TCNAW-HAFS01') {
      [PSCustomObject]@{ SID = $global:StubFileServerSid; DistinguishedName = $global:StubFileServerDn }
    } else {
      [PSCustomObject]@{ SID = $global:StubClusterSid; DistinguishedName = $global:StubClusterDn }
    }
  }

  # Returns a COPY, as the real cmdlet does: the script mutates the object it is handed, and a
  # shared reference would let an unwritten change appear on re-read and defeat the write check.
  Function Get-Acl {
    Param ($Path)
    New-StubAcl -Access @($global:StubAcl[$Path].Access)
  }

  Function Set-Acl {
    Param ($Path, $AclObject)
    $global:StubSetAclCalls += 1
    $global:StubAcl[$Path] = New-StubAcl -Access @($AclObject.Access)
  }

  # SecurityIdentifier and the rule constructor are Windows only; the script's use of them is a
  # delegation, so the stub records the request and hands back an ACE-shaped object.
  Function New-Object {
    Param (
      [Parameter(Position = 0)][System.String]$TypeName,
      [Parameter(Position = 1)][System.Object[]]$ArgumentList
    )
    switch -Wildcard ($TypeName) {
      '*SecurityIdentifier' { [PSCustomObject]@{ Value = [System.String]$ArgumentList[0] } }
      '*ActiveDirectoryAccessRule' {
        New-StubAce -Sid $ArgumentList[0].Value -Rights $ArgumentList[1] -Type $ArgumentList[2] `
          -Inheritance $ArgumentList[3]
      }
      default { Microsoft.PowerShell.Utility\New-Object @PSBoundParameters }
    }
  }

  Function Reset-Stubs {
    Param ([System.Collections.IDictionary]$Acl)
    $global:StubAccountSid = $script:AccountSid
    $global:StubClusterSid = $script:ClusterSid
    $global:StubFileServerSid = $script:FileServerSid
    $global:StubClusterDn = $script:ClusterDn
    $global:StubFileServerDn = $script:FileServerDn
    $global:StubAcl = @{}
    foreach ($k in $Acl.Keys) { $global:StubAcl[$k] = $Acl[$k] }
    $global:StubSetAclCalls = 0
    $global:StubFailInitialRead = $False
  }

  Function New-AnsibleContext {
    Param ([System.Boolean]$CheckMode = $False)
    $global:Ansible = [PSCustomObject]@{
      Changed = $True; CheckMode = $CheckMode; Failed = $False; Result = $Null
    }
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Function Invoke-Script {
    & $script:ScriptPath -AccountName 'svc-fscluster-mgr' -ClusterName 'TCNAW-FSCL01' `
      -FileServerName 'TCNAW-HAFS01'
  }

  $script:ClusterPath = "AD:\$script:ClusterDn"
  $script:FileServerPath = "AD:\$script:FileServerDn"
}

Describe 'Set-ClusterDirectoryRights' {

  AfterEach { Remove-AnsibleContext }

  Context 'standalone JSON transport' {

    It 'applies both grants on a directory that carries neither' {
      Reset-Stubs -Acl @{ $script:ClusterPath = (New-StubAcl); $script:FileServerPath = (New-StubAcl) }
      $r = Invoke-Script | ConvertFrom-Json

      $r.changed | Should -BeTrue
      $r.applied.Count | Should -Be 2
      $global:StubSetAclCalls | Should -Be 2
    }

    It 'performs zero writes and reports NoChange when both grants are already held' {
      Reset-Stubs -Acl @{
        $script:ClusterPath    = (New-StubAcl -Access @((New-StubAce -Sid $script:AccountSid)))
        $script:FileServerPath = (New-StubAcl -Access @((New-StubAce -Sid $script:ClusterSid)))
      }
      $r = Invoke-Script | ConvertFrom-Json

      $r.changed | Should -BeFalse
      $global:StubSetAclCalls | Should -Be 0
    }

    It 'applies only the missing grant when one is already held' {
      Reset-Stubs -Acl @{
        $script:ClusterPath    = (New-StubAcl -Access @((New-StubAce -Sid $script:AccountSid)))
        $script:FileServerPath = (New-StubAcl)
      }
      $r = Invoke-Script | ConvertFrom-Json

      $r.applied.Count | Should -Be 1
      $r.applied[0].grant | Should -Be 'cluster_name_object_controls_file_server_access_point'
      $global:StubSetAclCalls | Should -Be 1
    }

    It 'does not accept an INHERIT-ONLY ace as the grant' {
      # An inherit-only ACE governs child objects and never the object carrying it, so treating
      # it as the grant would leave the cluster without the right it needs.
      Reset-Stubs -Acl @{
        $script:ClusterPath = (New-StubAcl -Access @(
            (New-StubAce -Sid $script:AccountSid `
                -Propagation ([System.Security.AccessControl.PropagationFlags]::InheritOnly))))
        $script:FileServerPath = (New-StubAcl -Access @((New-StubAce -Sid $script:ClusterSid)))
      }
      $r = Invoke-Script | ConvertFrom-Json

      $r.changed | Should -BeTrue
      $r.applied[0].grant | Should -Be 'service_account_controls_cluster_name_object'
    }

    It 'does not accept a DENY ace, nor a lesser right, as the grant' {
      Reset-Stubs -Acl @{
        $script:ClusterPath = (New-StubAcl -Access @(
            (New-StubAce -Sid $script:AccountSid -Type 'Deny'),
            (New-StubAce -Sid $script:AccountSid -Rights $script:READ)))
        $script:FileServerPath = (New-StubAcl -Access @((New-StubAce -Sid $script:ClusterSid)))
      }
      $r = Invoke-Script | ConvertFrom-Json

      $r.changed | Should -BeTrue
      $global:StubSetAclCalls | Should -Be 1
    }

    It 'does not mistake another principal holding the right for our grant' {
      Reset-Stubs -Acl @{
        $script:ClusterPath = (New-StubAcl -Access @((New-StubAce -Sid 'S-1-5-18')))
        $script:FileServerPath = (New-StubAcl -Access @((New-StubAce -Sid $script:ClusterSid)))
      }
      $r = Invoke-Script | ConvertFrom-Json

      $r.changed | Should -BeTrue
    }

    It 'creates a rule that applies to THIS object only, never an inheritable one' {
      # An inheritable grant would silently extend the cluster's rights to every child object.
      Reset-Stubs -Acl @{ $script:ClusterPath = (New-StubAcl); $script:FileServerPath = (New-StubAcl) }
      $Null = Invoke-Script

      foreach ($path in @($script:ClusterPath, $script:FileServerPath)) {
        $added = $global:StubAcl[$path].Access | Select-Object -Last 1
        $added.InheritanceType |
          Should -Be ([System.DirectoryServices.ActiveDirectorySecurityInheritance]::None)
      }
    }

    It 'refuses to report convergence when the write does not land' {
      Reset-Stubs -Acl @{ $script:ClusterPath = (New-StubAcl); $script:FileServerPath = (New-StubAcl) }
      # A directory that silently discards the write is the failure this guard exists for.
      Function Set-Acl { Param ($Path, $AclObject) $global:StubSetAclCalls += 1 }

      { Invoke-Script } | Should -Throw
    }
  }

  Context '$Ansible transport' {

    It 'sets Changed true and records both grants' {
      Reset-Stubs -Acl @{ $script:ClusterPath = (New-StubAcl); $script:FileServerPath = (New-StubAcl) }
      New-AnsibleContext
      Invoke-Script

      $global:Ansible.Changed | Should -BeTrue
      $global:Ansible.Result.applied.Count | Should -Be 2
      $global:Ansible.Result.msg | Should -Be 'Cluster directory rights granted: 2.'
    }

    It 'SETS Changed false on a converged directory rather than inheriting the default' {
      Reset-Stubs -Acl @{
        $script:ClusterPath    = (New-StubAcl -Access @((New-StubAce -Sid $script:AccountSid)))
        $script:FileServerPath = (New-StubAcl -Access @((New-StubAce -Sid $script:ClusterSid)))
      }
      New-AnsibleContext
      $global:Ansible.Changed | Should -BeTrue   # the default the transport hands us
      Invoke-Script

      $global:Ansible.Changed | Should -BeFalse
      $global:Ansible.Result.msg | Should -Be 'Cluster directory rights already converged; no change.'
    }

    It 'settles Changed false before an initial directory read can fail' {
      Reset-Stubs -Acl @{}
      New-AnsibleContext
      $global:StubFailInitialRead = $True

      { Invoke-Script } | Should -Throw '*initial directory read failed*'
      $global:Ansible.Changed | Should -BeFalse
      $global:StubSetAclCalls | Should -Be 0
    }

    It 'reports the pending grants but writes nothing in check mode' {
      Reset-Stubs -Acl @{ $script:ClusterPath = (New-StubAcl); $script:FileServerPath = (New-StubAcl) }
      New-AnsibleContext -CheckMode $True
      Invoke-Script

      $global:Ansible.Changed | Should -BeTrue
      $global:Ansible.Result.applied.Count | Should -Be 2
      $global:StubSetAclCalls | Should -Be 0
      $global:Ansible.Result.msg | Should -Be 'Cluster directory rights would be granted: 2.'
    }
  }
}
