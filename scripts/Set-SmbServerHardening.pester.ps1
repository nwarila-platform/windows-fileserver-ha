#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT
<#
    Pester spec for Set-SmbServerHardening.ps1 (org pair convention: every
    script ships with a sibling <Name>.pester.ps1; the pester-matrix workflow
    runs one leg per pair).

    Runs anywhere, Linux CI included: Get/Set-SmbServerConfiguration are
    stubbed as functions in this file, and the script -- invoked as a child
    scope -- resolves the stubs instead of the real cmdlets. Stub state lives
    in $global: variables because inside a function called from a child SCRIPT,
    $script: resolves to the child script's own scope, not this file's. The
    Set stub actually applies what it is handed to the in-memory state, so the
    script's re-acquire-and-verify pass is exercised for real.

    Both transports are asserted: the standalone JSON emission and the
    $Ansible path via the inline context below (pairs are self-contained; no
    imports). Its Changed defaults to $True exactly like win_powershell -- so
    the no-drift test proves the script SETS Changed=$False rather than
    inheriting a default.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-SmbServerHardening.ps1'

  # Inline $Ansible stand-in (org contract: pairs are self-contained, no
  # imports). Faithful to win_powershell: Changed defaults to $True, and only
  # the ratified surface (Changed, CheckMode, Failed, Result) is modeled.
  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{
      Changed   = $True
      CheckMode = $CheckMode.IsPresent
      Failed    = $False
      Result    = $Null
    }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  # In-memory stand-in for the host's SMB server configuration. 'Frozen'
  # simulates a Set call that returns success without landing -- the case the
  # verify pass exists for.
  Function Get-SmbServerConfiguration {
    [CmdletBinding()]
    Param ()

    $global:FsHaSmbReads++
    Return [PSCustomObject]$global:FsHaSmbCurrent
  }

  Function Set-SmbServerConfiguration {
    [CmdletBinding(SupportsShouldProcess = $True)]
    Param (
      [Parameter()] [System.Boolean]$EnableSMB1Protocol,
      [Parameter()] [System.Boolean]$RequireSecuritySignature,
      [Parameter()] [System.Boolean]$EncryptData,
      [Parameter()] [System.Boolean]$RejectUnencryptedAccess,
      [Parameter()] [System.Boolean]$AuditSmb1Access,
      [Parameter()] [System.Management.Automation.SwitchParameter]$Force
    )

    $Applied = @{}
    ForEach ($Name In $PSBoundParameters.Keys) {
      If ($Name -notin @('Force', 'Confirm', 'WhatIf')) {
        $Applied[$Name] = $PSBoundParameters[$Name]
      }
    }
    $global:FsHaSmbWrites += , $Applied
    If (-not $global:FsHaSmbFrozen) {
      ForEach ($Name In $Applied.Keys) {
        $global:FsHaSmbCurrent[$Name] = $Applied[$Name]
      }
    }
  }
}

AfterAll {
  Remove-Variable -Name 'FsHaSmbCurrent', 'FsHaSmbReads', 'FsHaSmbWrites', 'FsHaSmbFrozen' -Scope 'Global' -ErrorAction 'SilentlyContinue'
}

Describe 'Set-SmbServerHardening' {

  BeforeEach {
    $global:FsHaSmbCurrent = @{
      EnableSMB1Protocol       = $True
      RequireSecuritySignature = $False
      EncryptData              = $False
      RejectUnencryptedAccess  = $False
      AuditSmb1Access          = $False
    }
    $global:FsHaSmbReads = 0
    $global:FsHaSmbWrites = @()
    $global:FsHaSmbFrozen = $False
  }

  AfterEach {
    Remove-AnsibleContext
  }

  Context 'standalone JSON transport' {

    It 'reports NoChange and performs zero writes on a converged host' {
      $global:FsHaSmbCurrent.EnableSMB1Protocol = $False

      $Result = & $script:ScriptPath -Setting @{ EnableSMB1Protocol = $False } | ConvertFrom-Json

      $Result.changed | Should -BeFalse
      $Result.drift | Should -HaveCount 0
      $global:FsHaSmbWrites | Should -HaveCount 0
    }

    It 'mutates only the drifted properties and reports each drift record' {
      $Desired = @{
        EnableSMB1Protocol       = $False   # drifted
        RequireSecuritySignature = $True    # drifted
        AuditSmb1Access          = $False   # already converged
      }

      $Result = & $script:ScriptPath -Setting $Desired | ConvertFrom-Json

      $Result.changed | Should -BeTrue
      $Result.drift.name | Should -Be @('EnableSMB1Protocol', 'RequireSecuritySignature')
      $global:FsHaSmbWrites | Should -HaveCount 1
      $global:FsHaSmbWrites[0].Keys | Sort-Object |
        Should -Be @('EnableSMB1Protocol', 'RequireSecuritySignature')
      # One read to diff, one to verify: 'changed' must come from a fresh read.
      $global:FsHaSmbReads | Should -Be 2
    }

    It 'compares by meaning, not representation, when YAML delivers booleans as strings' {
      $global:FsHaSmbCurrent.RequireSecuritySignature = $True

      $Result = & $script:ScriptPath -Setting @{ RequireSecuritySignature = 'True' } |
        ConvertFrom-Json

      $Result.changed | Should -BeFalse
      $global:FsHaSmbWrites | Should -HaveCount 0
    }

    It 'fails before any mutation when a declared property does not exist' {
      { & $script:ScriptPath -Setting @{ NoSuchSetting = $True; EnableSMB1Protocol = $False } } |
        Should -Throw '*no property named NoSuchSetting*'

      $global:FsHaSmbWrites | Should -HaveCount 0
    }

    It 'refuses to report convergence when the mutation does not land' {
      $global:FsHaSmbFrozen = $True

      { & $script:ScriptPath -Setting @{ EnableSMB1Protocol = $False } } |
        Should -Throw '*Refusing to report convergence*'
    }

    It 'rejects an empty baseline' {
      { & $script:ScriptPath -Setting @{} } | Should -Throw '*empty*'
    }
  }

  Context '$Ansible transport' {

    It 'sets Changed=$False explicitly on a converged host (transport defaults to $True)' {
      $global:FsHaSmbCurrent.EnableSMB1Protocol = $False
      $Context = New-AnsibleContext

      $Emitted = & $script:ScriptPath -Setting @{ EnableSMB1Protocol = $False }

      $Context.Changed | Should -BeFalse
      $Context.Result.msg | Should -Match 'already matches'
      # Everything goes through $Ansible.Result; nothing may leak to output.
      $Emitted | Should -BeNullOrEmpty
    }

    It 'reports Changed with the drift set after converging' {
      $Context = New-AnsibleContext

      & $script:ScriptPath -Setting @{ EncryptData = $True } | Out-Null

      $Context.Changed | Should -BeTrue
      $Context.Result.drift | Should -HaveCount 1
      $Context.Result.drift[0].name | Should -Be 'EncryptData'
      $global:FsHaSmbCurrent.EncryptData | Should -BeTrue
    }

    It 'honors CheckMode: reports would-change and performs zero writes' {
      $Context = New-AnsibleContext -CheckMode

      & $script:ScriptPath -Setting @{ EncryptData = $True } | Out-Null

      $Context.Changed | Should -BeTrue
      $Context.Result.check_mode | Should -BeTrue
      $global:FsHaSmbWrites | Should -HaveCount 0
      $global:FsHaSmbCurrent.EncryptData | Should -BeFalse
    }
  }
}
