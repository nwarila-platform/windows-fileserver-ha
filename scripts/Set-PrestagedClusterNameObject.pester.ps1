#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Set-PrestagedClusterNameObject.ps1'
  $script:Password = 'pester-cluster-password'
  $script:Controllers = @(
    'tcnhq-dc01.tcn.trinitytechnicalservices.com',
    'tcnhq-dc02.tcn.trinitytechnicalservices.com'
  )
  $script:DefaultNamingContext = 'DC=tcn,DC=trinitytechnicalservices,DC=com'
  $script:RootDsePath = 'LDAP://tcnhq-dc01.tcn.trinitytechnicalservices.com/RootDSE'
  $script:SearchRootPath = 'LDAP://tcnhq-dc01.tcn.trinitytechnicalservices.com/DC=tcn,DC=trinitytechnicalservices,DC=com'
  $script:TargetPath = 'LDAP://tcnhq-dc01.tcn.trinitytechnicalservices.com/CN=TCNAW-FSCL01,OU=HA,DC=tcn,DC=trinitytechnicalservices,DC=com'
  $script:SecondTargetPath = 'LDAP://tcnhq-dc01.tcn.trinitytechnicalservices.com/CN=TCNAW-FSCL01,OU=Other,DC=tcn,DC=trinitytechnicalservices,DC=com'
  $script:SecondControllerPath = 'LDAP://tcnhq-dc02.tcn.trinitytechnicalservices.com/CN=TCNAW-FSCL01,OU=HA,DC=tcn,DC=trinitytechnicalservices,DC=com'
  $global:FsReleaseDefaultNamingContext = $script:DefaultNamingContext
  $global:FsReleaseRootDsePath = $script:RootDsePath
  $global:FsReleaseSearchRootPath = $script:SearchRootPath
  $global:FsReleaseTargetPath = $script:TargetPath
  $script:ExpectedAuthenticationType = [System.DirectoryServices.AuthenticationTypes]::Secure -bor
  [System.DirectoryServices.AuthenticationTypes]::Sealing -bor
  [System.DirectoryServices.AuthenticationTypes]::Signing -bor
  [System.DirectoryServices.AuthenticationTypes]::ServerBind

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null }
    $global:Ansible
  }

  Function Remove-AnsibleContext {
    Remove-Variable -Name 'Ansible' -Scope Global -Force -ErrorAction SilentlyContinue
  }

  Function New-StubDirectoryEntry {
    Param ([System.String]$Path)
    If ($Path -eq $global:FsReleaseRootDsePath) {
      Return [PSCustomObject]@{
        Path       = $Path
        Properties = @{ defaultNamingContext = @($global:FsReleaseDefaultNamingContext) }
      }
    }
    If ($Path -eq $global:FsReleaseSearchRootPath) {
      Return [PSCustomObject]@{ Path = $Path; Properties = @{} }
    }

    If (-not $global:FsReleaseObjectOpenCounts.ContainsKey($Path)) {
      $global:FsReleaseObjectOpenCounts[$Path] = 0
    }
    $global:FsReleaseObjectOpenCounts[$Path]++
    $IsPoll = $Path -ne $global:FsReleaseTargetPath -or $global:FsReleaseObjectOpenCounts[$Path] -gt 1
    If ($IsPoll) {
      If (-not $global:FsReleasePollOpenCounts.ContainsKey($Path)) {
        $global:FsReleasePollOpenCounts[$Path] = 0
      }
      $PollIndex = [System.Int32]$global:FsReleasePollOpenCounts[$Path]
      $global:FsReleasePollOpenCounts[$Path]++
      If (-not $global:FsReleasePollSequences.ContainsKey($Path)) {
        $Value = [System.Int32]$global:FsReleaseDirectoryUserAccountControl[$Path]
      } Else {
        $Sequence = @($global:FsReleasePollSequences[$Path])
        $Value = [System.Int32]$Sequence[[System.Math]::Min($PollIndex, $Sequence.Count - 1)]
      }
    } Else {
      $Value = [System.Int32]$global:FsReleaseDirectoryUserAccountControl[$Path]
    }

    $Entry = [PSCustomObject]@{
      IsPoll    = [System.Boolean]$IsPoll
      Path      = $Path
      Properties = @{ userAccountControl = [PSCustomObject]@{ Value = $Value } }
    }
    $Entry | Add-Member -MemberType ScriptMethod -Name 'RefreshCache' -Value {
      Param ([System.String[]]$PropertyName)
      $global:FsReleaseReadbacks += $this.Path
      If (-not $this.IsPoll) {
        $this.Properties['userAccountControl'].Value = [System.Int32]$global:FsReleaseDirectoryUserAccountControl[$this.Path]
      }
    }
    $Entry | Add-Member -MemberType ScriptMethod -Name 'CommitChanges' -Value {
      $global:FsReleaseCommits += $this.Path
      $global:FsReleaseOperations += ('Commit:{0}' -f $this.Path)
      If ($global:FsReleaseCommitFailurePath -eq $this.Path) {
        Throw 'injected directory commit failure'
      }
      If ($global:FsReleaseReadbackMismatchPath -ne $this.Path) {
        $global:FsReleaseDirectoryUserAccountControl[$this.Path] = [System.Int32]$this.Properties['userAccountControl'].Value
      }
    }
    $Entry
  }

  $global:SetPrestagedClusterNameObjectGetCurrentIdentityName = { 'TCN\svc-fscluster-mgr' }
  $global:SetPrestagedClusterNameObjectOpenDirectoryEntry = {
    Param (
      [System.String]$Path,
      [System.String]$IdentityName,
      [System.String]$Password,
      [System.DirectoryServices.AuthenticationTypes]$AuthenticationType
    )
    $global:FsReleaseOpenCalls += [PSCustomObject]@{
      Path               = $Path
      IdentityName       = $IdentityName
      Password           = $Password
      AuthenticationType = $AuthenticationType
    }
    $global:FsReleaseOperations += ('Open:{0}' -f $Path)
    New-StubDirectoryEntry -Path $Path
  }
  $global:SetPrestagedClusterNameObjectSearchComputerObjects = {
    Param (
      [System.Object]$SearchRoot,
      [System.String]$EscapedName
    )
    $global:FsReleaseSearchCalls += [PSCustomObject]@{
      SearchRoot  = $SearchRoot
      EscapedName = $EscapedName
    }
    @($global:FsReleaseMatches | ForEach-Object -Process { [PSCustomObject]@{ Path = [System.String]$PSItem.Path } })
  }
  $global:SetPrestagedClusterNameObjectGetUtcNow = { $global:FsReleaseUtcNow }
  $global:SetPrestagedClusterNameObjectWaitForReplication = {
    $global:FsReleaseWaitCalls++
    $global:FsReleaseUtcNow = $global:FsReleaseUtcNow.AddSeconds($global:FsReleaseWaitAdvanceSeconds)
  }

  Function Invoke-Release {
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Password $script:Password -DomainControllers $script:Controllers
  }

  Function Assert-DirectoryOpens {
    Param ([System.String[]]$Path)
    $global:FsReleaseOpenCalls | Should -HaveCount $Path.Count
    @($global:FsReleaseOpenCalls | ForEach-Object -Process { $PSItem.Path }) | Should -Be $Path
    ForEach ($OpenCall In $global:FsReleaseOpenCalls) {
      $OpenCall.IdentityName | Should -Be 'TCN\svc-fscluster-mgr'
      ($OpenCall.Password -ceq $script:Password) | Should -BeTrue
      [System.Int32]$OpenCall.AuthenticationType | Should -Be ([System.Int32]$script:ExpectedAuthenticationType)
    }
    $global:FsReleaseSearchCalls | Should -HaveCount 1
    $global:FsReleaseSearchCalls[0].SearchRoot.Path | Should -Be $script:SearchRootPath
    $global:FsReleaseSearchCalls[0].EscapedName | Should -Be 'TCNAW-FSCL01'
  }
}

AfterAll {
  Remove-Variable -Name 'SetPrestagedClusterNameObjectGetCurrentIdentityName', 'SetPrestagedClusterNameObjectOpenDirectoryEntry', 'SetPrestagedClusterNameObjectSearchComputerObjects', 'SetPrestagedClusterNameObjectGetUtcNow', 'SetPrestagedClusterNameObjectWaitForReplication', 'FsReleaseDefaultNamingContext', 'FsReleaseRootDsePath', 'FsReleaseSearchRootPath', 'FsReleaseTargetPath', 'FsReleaseOpenCalls', 'FsReleaseSearchCalls', 'FsReleaseMatches', 'FsReleaseObjectOpenCounts', 'FsReleasePollOpenCounts', 'FsReleasePollSequences', 'FsReleaseDirectoryUserAccountControl', 'FsReleaseReadbacks', 'FsReleaseCommits', 'FsReleaseOperations', 'FsReleaseCommitFailurePath', 'FsReleaseReadbackMismatchPath', 'FsReleaseUtcNow', 'FsReleaseWaitCalls', 'FsReleaseWaitAdvanceSeconds' -Scope Global -Force -ErrorAction SilentlyContinue
}

Describe 'Set-PrestagedClusterNameObject' {
  BeforeEach {
    Remove-AnsibleContext
    $global:FsReleaseOpenCalls = @()
    $global:FsReleaseSearchCalls = @()
    $global:FsReleaseMatches = @([PSCustomObject]@{ Path = $script:TargetPath })
    $global:FsReleaseObjectOpenCounts = @{}
    $global:FsReleasePollOpenCounts = @{}
    $global:FsReleasePollSequences = @{}
    $global:FsReleaseDirectoryUserAccountControl = @{}
    $global:FsReleaseDirectoryUserAccountControl[$script:TargetPath] = [System.Int32]4096
    $global:FsReleaseDirectoryUserAccountControl[$script:SecondControllerPath] = [System.Int32]4098
    $global:FsReleaseReadbacks = @()
    $global:FsReleaseCommits = @()
    $global:FsReleaseOperations = @()
    $global:FsReleaseCommitFailurePath = ''
    $global:FsReleaseReadbackMismatchPath = ''
    $global:FsReleaseUtcNow = [System.DateTime]'2000-01-01T00:00:00Z'
    $global:FsReleaseWaitCalls = 0
    $global:FsReleaseWaitAdvanceSeconds = 3
  }

  AfterEach { Remove-AnsibleContext }

  It 'disables an enabled prestaged CNO and reports the change' {
    $Result = Invoke-Release | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.name | Should -Be 'TCNAW-FSCL01'
    ([System.Int32]$Result.user_account_control -band 2) | Should -Be 2
    $global:FsReleaseCommits | Should -Be @($script:TargetPath)
    [System.Array]::IndexOf($global:FsReleaseOperations, ('Commit:{0}' -f $script:TargetPath)) |
      Should -BeLessThan ([System.Array]::IndexOf($global:FsReleaseOperations, ('Open:{0}' -f $script:SecondControllerPath)))
    Assert-DirectoryOpens -Path @(
      $script:RootDsePath, $script:SearchRootPath, $script:TargetPath,
      $script:TargetPath, $script:SecondControllerPath
    )
  }

  It 'performs no commit when the prestaged CNO is already disabled' {
    $global:FsReleaseDirectoryUserAccountControl[$script:TargetPath] = [System.Int32]4098

    $Result = Invoke-Release | ConvertFrom-Json

    $Result.changed | Should -BeFalse
    $global:FsReleaseCommits | Should -HaveCount 0
    Assert-DirectoryOpens -Path @(
      $script:RootDsePath, $script:SearchRootPath, $script:TargetPath,
      $script:TargetPath, $script:SecondControllerPath
    )
  }

  It 'names the prestaged object when its disable fails' {
    $global:FsReleaseCommitFailurePath = $script:TargetPath

    { Invoke-Release } |
      Should -Throw '*Prestage computer object TCNAW-FSCL01 disable failed:*injected directory commit failure*'
    Assert-DirectoryOpens -Path @($script:RootDsePath, $script:SearchRootPath, $script:TargetPath)
  }

  It 'fails when userAccountControl readback lacks the disable bit' {
    $global:FsReleaseReadbackMismatchPath = $script:TargetPath

    { Invoke-Release } |
      Should -Throw '*Prestage computer object TCNAW-FSCL01 disable failed:*userAccountControl readback 4096 does not contain the ACCOUNTDISABLE bit*'
    $global:FsReleaseReadbacks | Should -Be @($script:TargetPath, $script:TargetPath)
    Assert-DirectoryOpens -Path @($script:RootDsePath, $script:SearchRootPath, $script:TargetPath)
  }

  It 'predicts enabled-CNO disablement in check mode without a directory commit' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -Password $script:Password -DomainControllers $script:Controllers -WhatIf |
      ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $Result.check_mode | Should -BeTrue
    $global:FsReleaseCommits | Should -HaveCount 0
    Assert-DirectoryOpens -Path @($script:RootDsePath, $script:SearchRootPath, $script:TargetPath)
  }

  It 'binds every directory open with explicit credentials in check mode without writes' {
    $Context = New-AnsibleContext -CheckMode

    Invoke-Release | Out-Null

    $Context.Changed | Should -BeTrue
    $Context.Result.check_mode | Should -BeTrue
    $global:FsReleaseCommits | Should -HaveCount 0
    Assert-DirectoryOpens -Path @($script:RootDsePath, $script:SearchRootPath, $script:TargetPath)
  }

  It 'throws when the directory lookup returns no matching computer object' {
    $global:FsReleaseMatches = @()

    { Invoke-Release } | Should -Throw '*directory lookup returned 0 matching computer objects*'
    Assert-DirectoryOpens -Path @($script:RootDsePath, $script:SearchRootPath)
  }

  It 'throws when the directory lookup returns two matching computer objects' {
    $global:FsReleaseMatches = @(
      [PSCustomObject]@{ Path = $script:TargetPath },
      [PSCustomObject]@{ Path = $script:SecondTargetPath }
    )

    { Invoke-Release } | Should -Throw '*directory lookup returned 2 matching computer objects*'
    Assert-DirectoryOpens -Path @($script:RootDsePath, $script:SearchRootPath)
  }

  It 'waits for a lagging controller and returns after both controllers report disabled' {
    $global:FsReleasePollSequences[$script:SecondControllerPath] = @(
      [System.Int32]4096,
      [System.Int32]4098
    )

    $Result = Invoke-Release | ConvertFrom-Json

    $Result.changed | Should -BeTrue
    $global:FsReleaseWaitCalls | Should -Be 1
    Assert-DirectoryOpens -Path @(
      $script:RootDsePath, $script:SearchRootPath, $script:TargetPath,
      $script:TargetPath, $script:SecondControllerPath,
      $script:TargetPath, $script:SecondControllerPath
    )
  }

  It 'times out and names the controller that never reports disabled' {
    $global:FsReleasePollSequences[$script:SecondControllerPath] = @([System.Int32]4096)
    $global:FsReleaseWaitAdvanceSeconds = 60
    $Caught = $Null

    Try {
      Invoke-Release
    } Catch {
      $Caught = $PSItem
    }

    $Caught.Exception.Message | Should -Match 'Cluster name object TCNAW-FSCL01 did not reach disabled state on: tcnhq-dc02\.tcn\.trinitytechnicalservices\.com'
    $global:FsReleaseWaitCalls | Should -Be 1
    Assert-DirectoryOpens -Path @(
      $script:RootDsePath, $script:SearchRootPath, $script:TargetPath,
      $script:TargetPath, $script:SecondControllerPath,
      $script:TargetPath, $script:SecondControllerPath
    )
  }
}
