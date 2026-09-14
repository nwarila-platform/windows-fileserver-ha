#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-DomainControllerReverseZone.ps1'
  $script:Namespace = '.112.69.10.in-addr.arpa'
  $script:Servers = @('10.69.112.4', '10.69.112.5')
  $script:Comment = 'Managed reverse zone'

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

  Function Get-DnsClientNrptRule {
    $global:FsHaNrptReads++
    @(
      ForEach ($Rule In $global:FsHaNrptRules) {
        [PSCustomObject]@{
          Comment     = $Rule.Comment
          Name        = $Rule.Name
          NameServers = [System.String[]]@($Rule.NameServers)
          Namespace   = [System.String[]]@($Rule.Namespace)
        }
      }
    )
  }

  Function Add-DnsClientNrptRule {
    Param (
      [System.String]$Namespace,
      [System.String[]]$NameServers,
      [System.String]$Comment
    )
    $global:FsHaNrptOperations += 'add'
    If ($global:FsHaNrptAddFailure) { Throw 'injected add failure' }
    If (-not $global:FsHaNrptIgnoreAdd) {
      $global:FsHaNrptNextName++
      $global:FsHaNrptRules += @{
        Comment     = $Comment
        Name        = 'new-{0}' -f $global:FsHaNrptNextName
        NameServers = @($NameServers)
        Namespace   = @($Namespace)
      }
    }
  }

  Function Set-DnsClientNrptRule {
    Param (
      [System.String]$Name,
      [System.String]$Namespace,
      [System.String[]]$NameServers
    )
    $global:FsHaNrptOperations += 'set'
    If (-not $global:FsHaNrptIgnoreSet) {
      ForEach ($Rule In $global:FsHaNrptRules) {
        If ($Rule.Name -eq $Name) {
          $Rule.Namespace = @($Namespace)
          $Rule.NameServers = @($NameServers)
        }
      }
    }
  }

  Function Remove-DnsClientNrptRule {
    Param ([System.String]$Name, [Switch]$Force)
    $global:FsHaNrptOperations += 'remove:{0}' -f $Name
    $global:FsHaNrptRules = @($global:FsHaNrptRules | Where-Object { $PSItem.Name -ne $Name })
  }

  Function New-OwnedRule {
    Param (
      [System.String]$Name,
      [System.String[]]$NameServers = $script:Servers,
      [System.String]$Namespace = $script:Namespace
    )
    @{
      Comment     = $script:Comment
      Name        = $Name
      NameServers = @($NameServers)
      Namespace   = @($Namespace)
    }
  }
}

AfterAll {
  Remove-AnsibleContext
  Remove-Variable -Name 'FsHaNrptRules', 'FsHaNrptReads', 'FsHaNrptOperations', 'FsHaNrptAddFailure', 'FsHaNrptIgnoreAdd', 'FsHaNrptIgnoreSet', 'FsHaNrptNextName' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Set-DomainControllerReverseZone' {
  BeforeEach {
    $global:FsHaNrptRules = @()
    $global:FsHaNrptReads = 0
    $global:FsHaNrptOperations = @()
    $global:FsHaNrptAddFailure = $False
    $global:FsHaNrptIgnoreAdd = $False
    $global:FsHaNrptIgnoreSet = $False
    $global:FsHaNrptNextName = 0
  }

  AfterEach { Remove-AnsibleContext }

  It 'reports exact state unchanged with zero mutations and a fresh readback' {
    $global:FsHaNrptRules = @((New-OwnedRule -Name 'owned-1'))

    $Result = & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $Result.action | Should -Be 'none'
    $global:FsHaNrptOperations | Should -HaveCount 0
    $global:FsHaNrptReads | Should -Be 2
  }

  It 'rejects a foreign same-namespace rule with zero mutations' {
    $global:FsHaNrptRules = @(
      @{ Comment = 'Foreign owner'; Name = 'foreign-1'; NameServers = @('192.0.2.1'); Namespace = @($script:Namespace) }
    )

    { & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment } | Should -Throw '*foreign NRPT rule*'

    $global:FsHaNrptOperations | Should -HaveCount 0
    $global:FsHaNrptRules | Should -HaveCount 1
  }

  It 'performs no removals when a multiple-rule replacement add fails' {
    $global:FsHaNrptRules = @(
      (New-OwnedRule -Name 'owned-1'),
      (New-OwnedRule -Name 'owned-2' -NameServers @('10.69.112.9'))
    )
    $global:FsHaNrptAddFailure = $True

    { & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment } | Should -Throw '*injected add failure*'

    $global:FsHaNrptOperations | Should -Be @('add')
    $global:FsHaNrptRules | Should -HaveCount 2
  }

  It 'repairs multiple owned rules by adding before removing and verifies one exact rule' {
    $global:FsHaNrptRules = @(
      (New-OwnedRule -Name 'owned-1'),
      (New-OwnedRule -Name 'owned-2' -NameServers @('10.69.112.9'))
    )

    $Result = & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.action | Should -Be 'replace'
    $global:FsHaNrptOperations | Should -Be @('add', 'remove:owned-1', 'remove:owned-2')
    $global:FsHaNrptRules | Should -HaveCount 1
    @($global:FsHaNrptRules[0].NameServers) | Should -Be $script:Servers
  }

  It 'rejects an ignored add through fresh readback' {
    $global:FsHaNrptIgnoreAdd = $True

    { & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment } | Should -Throw '*did not survive exact readback*'

    $global:FsHaNrptOperations | Should -Be @('add')
    $global:FsHaNrptReads | Should -Be 2
  }

  It 'rejects an ignored set through fresh readback' {
    $global:FsHaNrptRules = @((New-OwnedRule -Name 'owned-1' -NameServers @('10.69.112.9')))
    $global:FsHaNrptIgnoreSet = $True

    { & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment } | Should -Throw '*did not survive exact readback*'

    $global:FsHaNrptOperations | Should -Be @('set')
    $global:FsHaNrptReads | Should -Be 2
  }

  It 'adds a missing rule and verifies exact state' {
    $Result = & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.action | Should -Be 'add'
    $global:FsHaNrptOperations | Should -Be @('add')
    $global:FsHaNrptRules | Should -HaveCount 1
  }

  It 'sets a drifted single rule and verifies exact state' {
    $global:FsHaNrptRules = @((New-OwnedRule -Name 'owned-1' -NameServers @('10.69.112.9')))

    $Result = & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.action | Should -Be 'set'
    $global:FsHaNrptOperations | Should -Be @('set')
    @($global:FsHaNrptRules[0].NameServers) | Should -Be $script:Servers
  }

  It 'reports check-mode drift with zero mutations' {
    $Context = New-AnsibleContext -CheckMode

    $Output = & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment -WhatIf

    $Output | Should -BeNullOrEmpty
    $Context.Changed | Should -BeTrue
    $Context.Result.check_mode | Should -BeTrue
    $global:FsHaNrptOperations | Should -HaveCount 0
  }

  It 'sets Ansible Changed false from an initially true exact-state context' {
    $global:FsHaNrptRules = @((New-OwnedRule -Name 'owned-1'))
    $Context = New-AnsibleContext

    $Output = & $script:ScriptPath -Namespace $script:Namespace -NameServers $script:Servers -Comment $script:Comment

    $Output | Should -BeNullOrEmpty
    $Context.Changed | Should -BeFalse
    $Context.Result.changed | Should -BeFalse
  }

  It 'rejects an empty namespace before any state read or mutation' {
    { & $script:ScriptPath -Namespace '' -NameServers $script:Servers -Comment $script:Comment } | Should -Throw
    $global:FsHaNrptReads | Should -Be 0
    $global:FsHaNrptOperations | Should -HaveCount 0
  }
}
