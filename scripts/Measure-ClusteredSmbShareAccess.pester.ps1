#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Measure-ClusteredSmbShareAccess.ps1'
  $script:SourceText = [IO.File]::ReadAllText($script:ScriptPath)
  $script:CaseNumber = 0
  $script:SavedCulture = [Threading.Thread]::CurrentThread.CurrentCulture
  $script:SavedUiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture

  $script:FindCompatViolation = {
    Param ([System.Management.Automation.Language.Ast]$Ast)
    @($Ast.FindAll({
          Param ($Node)
          (
            $Node -is [System.Management.Automation.Language.CommandParameterAst] -and
            $Node.ParameterName -ieq 'DnsOnly'
          ) -or (
            $Node.GetType().Name -in @('PipelineChainAst', 'TernaryExpressionAst')
          )
        }, $True))
  }

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

  Function Reset-ProbeState {
    $global:MeasureClusteredSmbShareAccessState = [Hashtable]::Synchronized(@{})
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      [PSCustomObject]@{
        continuously_available = $True
        dns_a_records           = @('192.0.2.10')
        server_ip               = '192.0.2.10'
      }
    }
    Remove-Variable -Name 'MeasureClusteredSmbShareAccessOpenCloseAttempt', 'MeasureClusteredSmbShareAccessPersistAttempt', 'MeasureClusteredSmbShareAccessTerminalAppend' -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
  }

  Function New-ProbeCase {
    Param ([System.String]$Name)
    $script:CaseNumber++
    $Root = Join-Path -Path $TestDrive -ChildPath ('case-{0:00}-{1}' -f @($script:CaseNumber, $Name))
    $Share = Join-Path -Path $Root -ChildPath 'share'
    $Evidence = Join-Path -Path $Root -ChildPath 'evidence'
    [IO.Directory]::CreateDirectory($Share) | Out-Null
    [PSCustomObject]@{
      Evidence = $Evidence
      Root     = $Root
      RunId    = 'run-{0:00}-{1}' -f @($script:CaseNumber, $Name)
      Share    = $Share
    }
  }

  Function Invoke-Probe {
    Param (
      [Parameter(Mandatory = $True)]$Case,
      [System.Int32]$DurationSeconds = 3,
      [System.Double]$IntervalSeconds = 0.1,
      [System.String]$RunId = $Case.RunId,
      [System.String]$EvidencePath = $Case.Evidence,
      [System.String]$SharePath = $Case.Share,
      [System.String]$ServerName = 'files'
    )
    $Context = New-AnsibleContext
    $Output = @(& $script:ScriptPath `
        -DurationSeconds $DurationSeconds `
        -EvidencePath $EvidencePath `
        -IntervalSeconds $IntervalSeconds `
        -RunId $RunId `
        -ServerName $ServerName `
        -SharePath $SharePath)
    [PSCustomObject]@{
      Context = $Context
      Output  = $(If ($Output.Count -gt 0) { $Output[-1] })
    }
  }

  Function Set-ProbeStopAfterRows {
    Param ([Parameter(Mandatory = $True)]$Case)
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $OpenRows = @(Import-Csv -LiteralPath ([IO.Path]::Combine([String]$State['evidence_path'], 'attempts-openclose.csv')) -ErrorAction SilentlyContinue)
      $PersistRows = @(Import-Csv -LiteralPath ([IO.Path]::Combine([String]$State['evidence_path'], 'attempts-persist.csv')) -ErrorAction SilentlyContinue)
      If ($OpenRows.Count -gt 0 -and $PersistRows.Count -gt 0) {
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
  }

  Function Set-ProbeStopAfterMarkers {
    Param (
      [Parameter(Mandatory = $True)]$Case,
      [Parameter(Mandatory = $True)][System.String[]]$Names
    )
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessState['marker_names'] = $Names
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $Ready = $True
      ForEach ($Name In @($State['marker_names'])) {
        $MarkerPath = [IO.Path]::Combine([String]$State['evidence_path'], ('{0}.inflight' -f $Name))
        If (-not [IO.File]::Exists($MarkerPath) -or [String]::IsNullOrEmpty([IO.File]::ReadAllText($MarkerPath))) {
          $Ready = $False
        }
      }
      If ($Ready) {
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
  }

  Function Read-JsonLines {
    Param ([System.String]$Path)
    @([IO.File]::ReadAllLines($Path) | ForEach-Object -Process { $PSItem | ConvertFrom-Json })
  }

  Function Wait-ForProcessExit {
    Param (
      [System.Int32]$Id,
      [System.String]$StartedUtc,
      [System.Int32]$Seconds = 30
    )
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    $Absent = $False
    While ($Timer.Elapsed.TotalSeconds -lt $Seconds -and -not $Absent) {
      Try {
        $Process = [Diagnostics.Process]::GetProcessById($Id)
        $Absent = $Process.StartTime.ToUniversalTime().ToString('o') -cne $StartedUtc
      } Catch [ArgumentException] {
        $Absent = $True
      }
      If (-not $Absent) {
        [Threading.Thread]::Sleep(50)
      }
    }
    If (-not $Absent) {
      [Threading.Thread]::Sleep(50)
    }
    $Absent
  }

  Function global:wevtutil.exe {
    Param (
      [Parameter()]$Operation,
      [Parameter()]$Channel,
      [Parameter()]$Destination,
      [Parameter()]$Query,
      [Parameter()]$Overwrite
    )
    $CallIndex = $global:FsHaProbeWevtCalls.Count
    $global:FsHaProbeWevtCalls.Add([PSCustomObject]@{
        Channel     = [String]$Channel
        Destination = [String]$Destination
        Operation   = [String]$Operation
        Overwrite   = [String]$Overwrite
        Query       = [String]$Query
      })
    $ExitCodes = @($global:FsHaProbeWevtExit)
    $ExitCode = [Int32]$ExitCodes[[Math]::Min($CallIndex, $ExitCodes.Count - 1)]
    $global:LASTEXITCODE = $ExitCode
    If ($ExitCode -eq 0) {
      [IO.File]::WriteAllBytes([String]$Destination, [Byte[]]@())
    }
  }

  Function global:MeasureClusteredSmbShareAccessOpenCloseAttempt {
    $global:FsHaProbeParentSeamCalled = $True
  }

  Function global:MeasureClusteredSmbShareAccessPersistAttempt {
    $global:FsHaProbeParentSeamCalled = $True
  }

  Function global:MeasureClusteredSmbShareAccessObservation {
    $global:FsHaProbeParentSeamCalled = $True
  }
}

AfterAll {
  [Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
  [Threading.Thread]::CurrentThread.CurrentUICulture = $script:SavedUiCulture
  Remove-AnsibleContext
  Remove-Item -Path 'Function:\wevtutil.exe', 'Function:\MeasureClusteredSmbShareAccessOpenCloseAttempt', 'Function:\MeasureClusteredSmbShareAccessPersistAttempt', 'Function:\MeasureClusteredSmbShareAccessObservation' -Force -ErrorAction SilentlyContinue
  Remove-Variable -Name @(
    'FsHaProbeParentSeamCalled'
    'FsHaProbeWevtCalls'
    'FsHaProbeWevtExit'
    'MeasureClusteredSmbShareAccessObservation'
    'MeasureClusteredSmbShareAccessOpenCloseAttempt'
    'MeasureClusteredSmbShareAccessPersistAttempt'
    'MeasureClusteredSmbShareAccessState'
    'MeasureClusteredSmbShareAccessTerminalAppend'
  ) -Scope 'Global' -Force -ErrorAction 'SilentlyContinue'
}

Describe 'Measure-ClusteredSmbShareAccess' {
  BeforeEach {
    Remove-AnsibleContext
    Reset-ProbeState
    $global:FsHaProbeWevtCalls = [Collections.Generic.List[Object]]::new()
    $global:FsHaProbeWevtExit = 0
    $global:LASTEXITCODE = 0
    $global:FsHaProbeParentSeamCalled = $False
  }

  AfterEach {
    Remove-AnsibleContext
    [Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture = $script:SavedUiCulture
  }

  It 'T01 returns the happy-path result with matching first process and last terminal records' {
    @([Regex]::Matches($script:SourceText, '\[DateTime\]::UtcNow -ge \$WorkerDeadlineUtc')).Count | Should -Be 2
    $Case = New-ProbeCase -Name 'happy'
    Set-ProbeStopAfterRows -Case $Case

    $Run = Invoke-Probe -Case $Case -DurationSeconds 30

    $Run.Output.changed | Should -BeTrue
    $Run.Output.check_mode | Should -BeFalse
    $Run.Output.failed | Should -BeFalse
    $Run.Output.cleanup_deferred | Should -BeFalse
    $Run.Output.openclose.attempts | Should -BeGreaterThan 0
    $Run.Output.persist.attempts | Should -BeGreaterThan 0
    $Run.Output.openclose.kill_requested | Should -BeFalse
    $Run.Output.persist.kill_requested | Should -BeFalse
    $Run.Context.Result.run_leaf | Should -Be $Run.Output.run_leaf
    $Records = @(Read-JsonLines -Path (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Records[0].kind | Should -Be 'process'
    $Records[0].process_id | Should -Be $PID
    If ($env:OS -eq 'Windows_NT') {
      ([DateTime]$Records[0].process_started_utc).ToUniversalTime().ToString('o') | Should -Be (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    } Else {
      [Math]::Abs(((Get-Process -Id $PID).StartTime.ToUniversalTime() - ([DateTime]$Records[0].process_started_utc).ToUniversalTime()).TotalMilliseconds) | Should -BeLessThan 1000
    }
    $Records[0].run_id | Should -Be $Case.RunId
    $Records[0].run_leaf | Should -Be $Run.Output.run_leaf
    @($Records | Where-Object kind -EQ 'process') | Should -HaveCount 1
    $Workers = @($Records | Where-Object kind -EQ 'worker')
    $Workers | Should -HaveCount 2
    @($Workers.loop | Sort-Object) | Should -Be @('openclose', 'persist')
    ForEach ($Worker In $Workers) {
      $Worker.process_id | Should -Not -Be $PID
      (Wait-ForProcessExit -Id $Worker.process_id -StartedUtc $Worker.process_started_utc) | Should -BeTrue
    }
    $Records[-1].kind | Should -Be 'terminal'
    $Records[-1].run_id | Should -Be $Case.RunId
    $Records[-1].exception_type | Should -Be ''
    $Records[-1].exception_hresult | Should -Be ''
    $Records[-1].exception_message | Should -Be ''
    $Records[-1].cleanup_deferred | Should -BeFalse
    @($Records | Where-Object kind -EQ 'terminal') | Should -HaveCount 1
    $Samples = @($Records | Where-Object kind -EQ 'sample')
    $Samples | Should -Not -BeNullOrEmpty
    $Samples[-1].continuously_available | Should -BeTrue
    [Array]::IndexOf($Records, $Samples[0]) | Should -BeLessThan ([Array]::IndexOf($Records, $Workers[0]))
  }

  It 'T02 emits equivalent Ansible and standalone result shapes' {
    $script:SourceText | Should -Match '\$StartInfo\.RedirectStandardError = \$True'
    $AnsibleCase = New-ProbeCase -Name 'ansible'
    $StandaloneCase = New-ProbeCase -Name 'standalone'
    $AnsibleRun = Invoke-Probe -Case $AnsibleCase
    Remove-AnsibleContext
    Reset-ProbeState

    $Json = & $script:ScriptPath -DurationSeconds 3 -EvidencePath $StandaloneCase.Evidence -IntervalSeconds 0.1 -RunId $StandaloneCase.RunId -ServerName 'files' -SharePath $StandaloneCase.Share
    $Standalone = ($Json -join '') | ConvertFrom-Json

    $Standalone.changed | Should -Be $AnsibleRun.Output.changed
    $Standalone.failed | Should -Be $AnsibleRun.Output.failed
    $Standalone.msg | Should -Be $AnsibleRun.Output.msg
    $Standalone.openclose.PSObject.Properties.Name | Should -Contain 'attempts'
  }

  It 'T03 rejects invalid parameter values during binding' {
    $Case = New-ProbeCase -Name 'binding'
    { & $script:ScriptPath -DurationSeconds 0 -EvidencePath $Case.Evidence -IntervalSeconds 1 -RunId $Case.RunId -ServerName files -SharePath $Case.Share } | Should -Throw
    { & $script:ScriptPath -DurationSeconds 1 -EvidencePath $Case.Evidence -IntervalSeconds 0.01 -RunId $Case.RunId -ServerName files -SharePath $Case.Share } | Should -Throw
    { & $script:ScriptPath -DurationSeconds 1 -EvidencePath $Case.Evidence -IntervalSeconds 1 -RunId 'bad id' -ServerName files -SharePath $Case.Share } | Should -Throw
    { & $script:ScriptPath -DurationSeconds 1 -EvidencePath $Case.Evidence -IntervalSeconds 1 -RunId valid -ServerName 'bad_name' -SharePath $Case.Share } | Should -Throw
  }

  It 'T04 refuses a mismatched UNC host before probing the share' {
    $Case = New-ProbeCase -Name 'unc'
    { & $script:ScriptPath -DurationSeconds 1 -EvidencePath $Case.Evidence -IntervalSeconds 1 -RunId $Case.RunId -ServerName 'files' -SharePath '\\other\data' } | Should -Throw '*does not match ServerName*'
    [IO.Directory]::Exists($Case.Evidence) | Should -BeFalse
  }

  It 'T05 reports the inspecting identity and base exception for a missing SharePath' {
    $Case = New-ProbeCase -Name 'missing'
    $Missing = Join-Path $Case.Root 'absent'
    $ExpectedIdentity = [Environment]::UserName
    $Thrown = $Null
    Try {
      & $script:ScriptPath -DurationSeconds 1 -EvidencePath $Case.Evidence -IntervalSeconds 1 -RunId $Case.RunId -ServerName files -SharePath $Missing
    } Catch {
      $Thrown = $PSItem.Exception.GetBaseException()
    }
    $ExpectedPrefix = 'Precondition: cannot inspect SharePath as {0}: System.IO.DirectoryNotFoundException [0x80070003] ' -f $ExpectedIdentity
    $Thrown.Message | Should -Match ('^{0}.+$' -f [Regex]::Escape($ExpectedPrefix))
    [IO.Directory]::Exists($Case.Evidence) | Should -BeFalse
  }

  It 'T06 refuses a pre-existing exact leaf or EvidencePath without deleting either' {
    $LeafCase = New-ProbeCase -Name 'leaf-exists'
    $Leaf = Join-Path $LeafCase.Share ('ha-probe-{0}' -f $LeafCase.RunId)
    [IO.Directory]::CreateDirectory($Leaf) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Leaf 'owner.txt'), 'owned')
    { Invoke-Probe -Case $LeafCase } | Should -Throw '*probe leaf already exists*'
    [IO.File]::ReadAllText((Join-Path $Leaf 'owner.txt')) | Should -Be 'owned'

    $EvidenceCase = New-ProbeCase -Name 'evidence-exists'
    [IO.Directory]::CreateDirectory($EvidenceCase.Evidence) | Out-Null
    [IO.File]::WriteAllText((Join-Path $EvidenceCase.Evidence 'owner.txt'), 'owned')
    { Invoke-Probe -Case $EvidenceCase } | Should -Throw '*EvidencePath already exists*'
    [IO.File]::ReadAllText((Join-Path $EvidenceCase.Evidence 'owner.txt')) | Should -Be 'owned'
  }

  It 'T07 performs byte canary write, readback, delete, and leaves no canary' {
    $script:SourceText | Should -Match '\[IO\.File\]::WriteAllBytes\(\$CanaryPath'
    $script:SourceText | Should -Match '\[IO\.File\]::ReadAllBytes\(\$CanaryPath\)'
    $script:SourceText | Should -Match '\[IO\.File\]::Delete\(\$CanaryPath\)'
    $Case = New-ProbeCase -Name 'canary'
    $Run = Invoke-Probe -Case $Case
    $Run.Output.failed | Should -BeFalse
    Get-ChildItem -LiteralPath $Case.Share -Recurse -Filter 'canary.txt' | Should -HaveCount 0
  }

  It 'T08 accepts a second RunId after exact-leaf cleanup' {
    $CaseOne = New-ProbeCase -Name 'first-run'
    $First = Invoke-Probe -Case $CaseOne
    Reset-ProbeState
    $EvidenceTwo = Join-Path $CaseOne.Root 'evidence-two'
    $Second = Invoke-Probe -Case $CaseOne -RunId 'second-run' -EvidencePath $EvidenceTwo
    $First.Output.run_leaf | Should -Not -Be $Second.Output.run_leaf
    [IO.Directory]::Exists($First.Output.run_leaf) | Should -BeFalse
    [IO.Directory]::Exists($Second.Output.run_leaf) | Should -BeFalse
  }

  It 'T09 records a persistent-open failure and later recovers without probe failure' {
    $script:SourceText | Should -Match '\$WorkerStopRequestPath'
    $Case = New-ProbeCase -Name 'persist-retry'
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessPersistAttempt = {
      Param ($Context, $State)
      $PersistFile = [IO.Path]::Combine($Context.Directory, 'p.txt')
      If ([Int32]$State['persist_attempts'] -eq 0 -and -not [Boolean]$State['persist_fault_armed']) {
        [IO.File]::WriteAllText($PersistFile, 'block')
        $State['persist_fault_armed'] = $True
      }
      If ([Int32]$State['persist_failures'] -gt 0 -and -not [Boolean]$State['persist_fault_recovered']) {
        [IO.File]::Delete($PersistFile)
        $State['persist_fault_recovered'] = $True
      }
      If ($Null -eq $State['persist_stream']) {
        $State['persist_stream'] = [IO.FileStream]::new(
          $PersistFile,
          [IO.FileMode]::CreateNew,
          [IO.FileAccess]::ReadWrite,
          [IO.FileShare]::ReadWrite,
          4096,
          [IO.FileOptions]::WriteThrough
        )
      }
      $Payload = [Text.UTF8Encoding]::new($False).GetBytes(('retry|{0}' -f $Context.Attempt))
      $State['persist_stream'].Write($Payload, 0, $Payload.Length)
      $State['persist_stream'].Flush($True)
    }
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $Rows = @(Import-Csv -LiteralPath ([IO.Path]::Combine([String]$State['evidence_path'], 'attempts-persist.csv')) -ErrorAction SilentlyContinue)
      If (
        @($Rows | Where-Object outcome -EQ 'failure').Count -gt 0 -and
        @($Rows | Where-Object outcome -EQ 'success').Count -gt 0
      ) {
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Run = Invoke-Probe -Case $Case -DurationSeconds 30
    $Rows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-persist.csv'))
    @($Rows | Where-Object outcome -EQ 'failure').Count | Should -BeGreaterThan 0
    @($Rows | Where-Object outcome -EQ 'success').Count | Should -BeGreaterThan 0
    $Run.Output.failed | Should -BeFalse
  }

  It 'T10 records base DirectoryNotFoundException outage rows and persistent successes' {
    $script:SourceText | Should -Match "EnvironmentVariables\['FSHA_PROBE_DIRECTORY'\]"
    $Case = New-ProbeCase -Name 'rename'
    $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
    $global:MeasureClusteredSmbShareAccessState['openclose'] = Join-Path $Leaf 'openclose'
    $global:MeasureClusteredSmbShareAccessState['renamed'] = Join-Path $Leaf 'openclose-x'
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessState['openclose_csv'] = Join-Path $Case.Evidence 'attempts-openclose.csv'
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $Rows = @(Import-Csv -LiteralPath ([String]$State['openclose_csv']) -ErrorAction SilentlyContinue)
      If ($Rows.Count -gt 0 -and -not [Boolean]$State['openclose_outage_started']) {
        [IO.Directory]::Move([String]$State['openclose'], [String]$State['renamed'])
        $State['openclose_outage_started'] = $True
      }
      If (@($Rows | Where-Object outcome -EQ 'failure').Count -gt 0 -and -not [Boolean]$State['openclose_outage_recovered']) {
        [IO.Directory]::Move([String]$State['renamed'], [String]$State['openclose'])
        $State['openclose_outage_recovered'] = $True
      }
      If (
        [Boolean]$State['openclose_outage_recovered'] -and
        $Rows.Count -gt 0 -and
        $Rows[-1].outcome -eq 'success'
      ) {
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Run = Invoke-Probe -Case $Case -DurationSeconds 30
    $OpenRows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv'))
    $Outages = @($OpenRows | Where-Object outcome -EQ 'failure')
    $Outages.Count | Should -BeGreaterThan 0
    @($Outages.exception_type | Sort-Object -Unique) | Should -Be @('System.IO.DirectoryNotFoundException')
    @($Outages.exception_hresult | Sort-Object -Unique) | Should -Be @('0x80070003')
    @($OpenRows | Where-Object outcome -EQ 'success').Count | Should -BeGreaterThan 0
    $Run.Output.persist.failures | Should -Be 0
  }

  It 'T11 keeps observation failures in sample_error and returns normally' {
    $Case = New-ProbeCase -Name 'observation-failure'
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      Throw 'DNS and SMB observation failed'
    }
    $Run = Invoke-Probe -Case $Case
    $Samples = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl') | Where-Object kind -EQ 'sample')
    @($Samples | Where-Object sample_error -Match 'observation failed').Count | Should -BeGreaterThan 1
    $global:MeasureClusteredSmbShareAccessState['observation_calls'] | Should -BeGreaterThan 1
    $Run.Output.failed | Should -BeFalse
  }

  It 'T12 passes only Name and Type in the observation DnsQuery map' {
    $Case = New-ProbeCase -Name 'dns-input'
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['dns_keys'] = @($DnsQuery.Keys | Sort-Object)
      $State['dns_name'] = [String]$DnsQuery.Name
      $State['dns_type'] = [String]$DnsQuery.Type
      If ($DnsQuery.ContainsKey('DnsOnly')) { Throw 'DnsOnly is forbidden' }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Null = Invoke-Probe -Case $Case
    @($global:MeasureClusteredSmbShareAccessState['dns_keys']) | Should -Be @('Name', 'Type')
    $global:MeasureClusteredSmbShareAccessState['dns_name'] | Should -Be 'files'
    $global:MeasureClusteredSmbShareAccessState['dns_type'] | Should -Be 'A'
  }

  It 'T13 runs common shutdown before rethrow when one loop ends and the other blocks' {
    $script:SourceText | Should -Not -Match '\$WorkersStarted'
    @([Regex]::Matches($script:SourceText, '(?m)^\s+Throw \$PendingException$')).Count | Should -Be 2
    $script:SourceText | Should -Match 'If \(\$LoopHandle\.Process\.HasExited -and \[DateTime\]::UtcNow -lt \$RunDeadlineUtc\)'
    $script:SourceText | Should -Match '\$JsonWriter\.WriteLine\(\(ConvertTo-Json -InputObject:\$TerminalRecord -Compress -Depth:6\)\)'
    $ShutdownIndex = $script:SourceText.IndexOf('$GraceTimer = [Diagnostics.Stopwatch]::StartNew()', [StringComparison]::Ordinal)
    $RethrowMatch = [Regex]::Match($script:SourceText, '(?m)^  If \(\$Null -ne \$PendingException\) \{\r?\n    Throw \$PendingException\r?\n  \}$')
    $RethrowIndex = $(If ($RethrowMatch.Success) { $RethrowMatch.Index } Else { -1 })
    $ShutdownIndex | Should -BeGreaterOrEqual 0
    $RethrowIndex | Should -BeGreaterThan $ShutdownIndex
    $Case = New-ProbeCase -Name 'early-loop'
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $State['openclose_force_end'] = $True
    }
    $global:MeasureClusteredSmbShareAccessPersistAttempt = {
      Param ($Context, $State)
      [Threading.Thread]::Sleep(600000)
    }
    $global:MeasureClusteredSmbShareAccessState['openclose_shutdown_exception'] = [IO.IOException]::new('injected openclose shutdown failure')
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    { Invoke-Probe -Case $Case -DurationSeconds 30 } | Should -Throw '*Probe: loop openclose ended before the deadline*'
    $Timer.Elapsed.TotalSeconds | Should -BeLessThan 150
    $Records = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Records[-1].kind | Should -Be 'terminal'
    $Records[-1].exception_type | Should -Be 'System.InvalidOperationException'
    $Records[-1].exception_message | Should -Match '^Probe:'
    $Records[-1].cleanup_deferred | Should -BeTrue
    $PersistWorker = @($Records | Where-Object { $PSItem.kind -eq 'worker' -and $PSItem.loop -eq 'persist' })[0]
    (Wait-ForProcessExit -Id $PersistWorker.process_id -StartedUtc $PersistWorker.process_started_utc) | Should -BeTrue
    $global:MeasureClusteredSmbShareAccessState['persist_kill_requested'] | Should -BeTrue
    $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
    [IO.Directory]::Exists($Leaf) | Should -BeTrue
    [IO.Directory]::Delete($Leaf, $True)
    [IO.Directory]::Exists($Leaf) | Should -BeFalse

    Reset-ProbeState
    $global:FsHaProbeWevtCalls = [Collections.Generic.List[Object]]::new()
    $global:FsHaProbeWevtExit = @(15007, 0)
    $ExportCase = New-ProbeCase -Name 'early-loop-export-failure'
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $State['openclose_force_end'] = $True
    }
    $WarningOutput = [Collections.Generic.List[Object]]::new()
    $Thrown = $Null
    Try {
      Invoke-Probe -Case $ExportCase -DurationSeconds 30 3>&1 | ForEach-Object -Process { $WarningOutput.Add($PSItem) }
    } Catch {
      $Thrown = $PSItem.Exception.GetBaseException()
    }
    $Thrown.GetType().FullName | Should -Be 'System.InvalidOperationException'
    $Thrown.Message | Should -Match '^Probe: loop openclose ended before the deadline:'
    @($WarningOutput | Where-Object { [String]$PSItem -match '^Probe: secondary shutdown failure: Probe: wevtutil failed for SMBClient/Connectivity with exit code 15007\.$' }) | Should -HaveCount 1
    $ExportRecords = @(Read-JsonLines (Join-Path $ExportCase.Evidence 'smb-samples.jsonl'))
    $ExportRecords[-1].kind | Should -Be 'terminal'
    $ExportRecords[-1].exception_type | Should -Be 'System.InvalidOperationException'
    $ExportRecords[-1].exception_message | Should -Match '^Probe: loop openclose ended before the deadline:'
  }

  It 'T14 checks each wevtutil exit code immediately and fails on 15007' {
    $Case = New-ProbeCase -Name 'wevt-failure'
    $global:FsHaProbeWevtExit = @(15007, 0)
    { Invoke-Probe -Case $Case } | Should -Throw '*wevtutil failed*15007*'
    $global:FsHaProbeWevtCalls | Should -HaveCount 2
    $SourceLines = @($script:SourceText -split "`n")
    @($SourceLines | Where-Object { $PSItem -match '^\s*\$EventExitCode = \$LASTEXITCODE\r?$' }) | Should -HaveCount 2
  }

  It 'T15a/b wraps scalar-prone results and rejects incompatible AST nodes including DnsOnly' {
    $script:SourceText | Should -Match '\$ExistingLeaves = @\(\[IO\.Directory\]::GetDirectories'
    $script:SourceText | Should -Match '\$DnsAnswers = @\(Resolve-DnsName @DnsQuery\)'
    $Tokens = $Null
    $Errors = $Null
    $Ast = [Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [Ref]$Tokens, [Ref]$Errors)
    $Errors | Should -HaveCount 0
    @(& $script:FindCompatViolation $Ast) | Should -HaveCount 0
    $SeedTokens = $Null
    $SeedErrors = $Null
    $SeedAst = [Management.Automation.Language.Parser]::ParseInput('Resolve-DnsName -Name files -DnsOnly', [Ref]$SeedTokens, [Ref]$SeedErrors)
    @(& $script:FindCompatViolation $SeedAst) | Should -HaveCount 1
  }

  It 'T16 writes every text evidence file with explicit CRLF and no lone LF' {
    $Case = New-ProbeCase -Name 'crlf'
    $Null = Invoke-Probe -Case $Case
    ForEach ($Name In @('attempts-openclose.csv', 'attempts-persist.csv', 'smb-samples.jsonl')) {
      $Bytes = [IO.File]::ReadAllBytes((Join-Path $Case.Evidence $Name))
      $Text = [Text.UTF8Encoding]::new($False).GetString($Bytes)
      $Text | Should -Match "`r`n$"
      ($Text -replace "`r`n", '') | Should -Not -Match "`n"
    }
  }

  It 'T17 keeps the production script ASCII-only' {
    $Bytes = [IO.File]::ReadAllBytes($script:ScriptPath)
    @($Bytes | Where-Object { $PSItem -gt 127 }) | Should -HaveCount 0
  }

  It 'T18 formats elapsed milliseconds with invariant integer text under de-DE' {
    $script:SourceText | Should -Match '\$WorkerIntervalMilliseconds'
    $script:SourceText | Should -Match '\$InvariantCulture = \[Globalization\.CultureInfo\]::InvariantCulture'
    $script:SourceText | Should -Match '\$Culture = \[Globalization\.CultureInfo\]::InvariantCulture'
    $Case = New-ProbeCase -Name 'culture'
    Set-ProbeStopAfterRows -Case $Case
    $German = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $SavedLang = $env:LANG
    $SavedLcAll = $env:LC_ALL
    [Threading.Thread]::CurrentThread.CurrentCulture = $German
    [Threading.Thread]::CurrentThread.CurrentUICulture = $German
    $env:LANG = 'de_DE.UTF-8'
    $env:LC_ALL = 'de_DE.UTF-8'
    Try {
      $Null = Invoke-Probe -Case $Case -DurationSeconds 30
    } Finally {
      $env:LANG = $SavedLang
      $env:LC_ALL = $SavedLcAll
    }
    $Rows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv'))
    $Rows | Should -Not -BeNullOrEmpty
    ForEach ($Row In $Rows) { $Row.elapsed_ms | Should -Match '^\d+$' }
    $script:SourceText | Should -Match '\[Globalization\.CultureInfo\]::InvariantCulture'
    $script:SourceText | Should -Match '\.ElapsedMilliseconds'
    $script:SourceText | Should -Not -Match '\.TotalMilliseconds'
  }

  It 'T19 does not use Start-Job or thread-job machinery' {
    $script:SourceText | Should -Not -Match '(?im)^\s*Start-(Thread)?Job\b'
    $script:SourceText | Should -Match '\[PowerShell\]::Create\(\)'
  }

  It 'T20 terminates a blocked worker and reconciles exactly one in_flight row' {
    $script:SourceText | Should -Match '\$LoopHandle\.Process\.Kill\(\)'
    $script:SourceText | Should -Match '\$Null = \$LoopHandle\.Process\.WaitForExit\(30000\)'
    $script:SourceText | Should -Match 'If \(\$TerminalAttempt -gt \$LastAttempt\)'
    @([Regex]::Matches($script:SourceText, '\$MarkerStream = \[IO\.FileStream\]::new\(\$MarkerPath, \[IO\.FileMode\]::Create')).Count | Should -Be 2
    $script:SourceText | Should -Match 'in_flight_at_stop = @\(\$FinalRows \| Where-Object -FilterScript \{ \$PSItem\.outcome -eq ''in_flight'' \}\)\.Count -gt 0'
    $Case = New-ProbeCase -Name 'one-blocked'
    Set-ProbeStopAfterMarkers -Case $Case -Names @('openclose')
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      [Threading.Thread]::Sleep(600000)
    }
    $ReturnedAt = $Null
    $Run = Invoke-Probe -Case $Case -DurationSeconds 30
    $ReturnedAt = [DateTime]::UtcNow
    $Run.Output.cleanup_deferred | Should -BeTrue
    $Run.Output.openclose.in_flight_at_stop | Should -BeTrue
    $Run.Output.openclose.kill_requested | Should -BeTrue
    $Rows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv'))
    @($Rows | Where-Object outcome -EQ 'in_flight') | Should -HaveCount 1
    $Terminal = @($Rows | Where-Object outcome -EQ 'in_flight')[0]
    [Int64]$Terminal.elapsed_ms | Should -BeGreaterOrEqual 120000
    $Started = [DateTime]::Parse($Terminal.timestamp_utc).ToUniversalTime()
    [Int64]$Terminal.elapsed_ms | Should -BeLessOrEqual ([Int64][Math]::Floor(($ReturnedAt - $Started).TotalMilliseconds))
    $Records = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Worker = @($Records | Where-Object { $PSItem.kind -eq 'worker' -and $PSItem.loop -eq 'openclose' })[0]
    (Wait-ForProcessExit -Id $Worker.process_id -StartedUtc $Worker.process_started_utc) | Should -BeTrue
    $Records[-1].kind | Should -Be 'terminal'
    $Records[-1].cleanup_deferred | Should -BeTrue
    $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
    [IO.Directory]::Exists($Leaf) | Should -BeTrue
    $BeforeHash = (Get-FileHash (Join-Path $Case.Evidence 'attempts-openclose.csv') -Algorithm SHA256).Hash
    $BeforeCount = $Rows.Count
    [Threading.Thread]::Sleep(200)
    (Get-FileHash (Join-Path $Case.Evidence 'attempts-openclose.csv') -Algorithm SHA256).Hash | Should -Be $BeforeHash
    @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv')) | Should -HaveCount $BeforeCount
    [IO.Directory]::Delete($Leaf, $True)
    [IO.Directory]::Exists($Leaf) | Should -BeFalse

    Reset-ProbeState
    $LandedCase = New-ProbeCase -Name 'row-landed'
    $HoldPath = Join-Path $LandedCase.Root 'hold-after-row'
    [IO.File]::WriteAllText($HoldPath, '')
    $global:MeasureClusteredSmbShareAccessState['openclose_hold_after_row_path'] = $HoldPath
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $LandedCase.Evidence
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $Rows = @(Import-Csv -LiteralPath ([IO.Path]::Combine([String]$State['evidence_path'], 'attempts-openclose.csv')) -ErrorAction SilentlyContinue)
      If ($Rows.Count -gt 0) {
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Landed = Invoke-Probe -Case $LandedCase -DurationSeconds 30
    $Landed.Output.cleanup_deferred | Should -BeTrue
    $Landed.Output.openclose.in_flight_at_stop | Should -BeFalse
    $Landed.Output.openclose.kill_requested | Should -BeTrue
    $LandedRows = @(Import-Csv (Join-Path $LandedCase.Evidence 'attempts-openclose.csv'))
    $LandedRows | Should -HaveCount 1
    $LandedRows[0].attempt | Should -Be '1'
    $LandedRows[0].outcome | Should -Be 'success'
    @($LandedRows | Where-Object outcome -EQ 'in_flight') | Should -HaveCount 0
    $LandedRecords = @(Read-JsonLines (Join-Path $LandedCase.Evidence 'smb-samples.jsonl'))
    $LandedWorker = @($LandedRecords | Where-Object { $PSItem.kind -eq 'worker' -and $PSItem.loop -eq 'openclose' })[0]
    (Wait-ForProcessExit -Id $LandedWorker.process_id -StartedUtc $LandedWorker.process_started_utc) | Should -BeTrue
    $LandedLeaf = Join-Path $LandedCase.Share ('ha-probe-{0}' -f $LandedCase.RunId)
    [IO.Directory]::Delete($LandedLeaf, $True)
  }

  It 'T21 samples strictly increasing in-flight ages before the terminal age' {
    $script:SourceText | Should -Match '\$MarkerText = ''\{0\}\|\{1\}\|\{2\}'' -f'
    $Case = New-ProbeCase -Name 'ages'
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $SamplesPath = [IO.Path]::Combine([String]$State['evidence_path'], 'smb-samples.jsonl')
      If ([IO.File]::Exists($SamplesPath)) {
        $InFlightSamples = @(
          [IO.File]::ReadAllLines($SamplesPath) |
            ForEach-Object -Process { $PSItem | ConvertFrom-Json } |
            Where-Object -FilterScript { $PSItem.kind -eq 'sample' -and [Int64]$PSItem.openclose_in_flight_ms -gt 0 }
        )
        If ($InFlightSamples.Count -ge 3) {
          [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
        }
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      [Threading.Thread]::Sleep(600000)
    }
    $Run = Invoke-Probe -Case $Case -DurationSeconds 30
    $Samples = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl') | Where-Object { $PSItem.kind -eq 'sample' -and [Int64]$PSItem.openclose_in_flight_ms -gt 0 })
    $Samples.Count | Should -BeGreaterThan 1
    For ($Index = 1; $Index -lt $Samples.Count; $Index++) {
      [Int64]$Samples[$Index].openclose_in_flight_ms | Should -BeGreaterThan ([Int64]$Samples[$Index - 1].openclose_in_flight_ms)
    }
    $Terminal = @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv') | Where-Object outcome -EQ 'in_flight')[0]
    [Int64]$Terminal.elapsed_ms | Should -BeGreaterOrEqual ([Int64]$Samples[-1].openclose_in_flight_ms)
    $Run.Output.openclose.max_elapsed_ms | Should -Be ([Int64]$Terminal.elapsed_ms)
    $Run.Output.openclose.kill_requested | Should -BeTrue
    $Records = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Worker = @($Records | Where-Object { $PSItem.kind -eq 'worker' -and $PSItem.loop -eq 'openclose' })[0]
    (Wait-ForProcessExit -Id $Worker.process_id -StartedUtc $Worker.process_started_utc) | Should -BeTrue
    [IO.Directory]::Delete((Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)), $True)
  }

  It 'T22 honors stop.request and distinguishes request from deadline' {
    @([Regex]::Matches($script:SourceText, '\[IO\.File\]::Exists\(\$StopRequestPath\)')).Count | Should -Be 3
    @([Regex]::Matches($script:SourceText, '\[IO\.File\]::Exists\(\$WorkerStopRequestPath\)')).Count | Should -Be 2
    $RequestCase = New-ProbeCase -Name 'request'
    $global:MeasureClusteredSmbShareAccessState['stop_path'] = $RequestCase.Evidence
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $OpenRows = @(Import-Csv -LiteralPath ([IO.Path]::Combine([String]$State['stop_path'], 'attempts-openclose.csv')) -ErrorAction SilentlyContinue)
      $PersistRows = @(Import-Csv -LiteralPath ([IO.Path]::Combine([String]$State['stop_path'], 'attempts-persist.csv')) -ErrorAction SilentlyContinue)
      If (
        $OpenRows.Count -gt 0 -and
        $PersistRows.Count -gt 0 -and
        -not [Boolean]$State['stop_request_written']
      ) {
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['stop_path'], 'stop.request'), '')
        $State['stop_request_written'] = $True
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Requested = Invoke-Probe -Case $RequestCase -DurationSeconds 30
    $Requested.Output.stop_reason | Should -Be 'request'
    ([DateTime]$Requested.Output.stopped_utc - [DateTime]$Requested.Output.started_utc).TotalSeconds | Should -BeLessThan 30
    $Requested.Output.openclose.kill_requested | Should -BeFalse
    $Requested.Output.persist.kill_requested | Should -BeFalse
    Reset-ProbeState
    $DeadlineCase = New-ProbeCase -Name 'deadline'
    (Invoke-Probe -Case $DeadlineCase).Output.stop_reason | Should -Be 'deadline'
  }

  It 'T23 allows a second reader to tail both complete CRLF CSV streams' {
    @([Regex]::Matches($script:SourceText, '\[IO\.FileMode\]::Append')).Count | Should -Be 2
    @([Regex]::Matches($script:SourceText, '\$\w+File = \[IO\.FileStream\]::new\(\$\w+CsvPath, \[IO\.FileMode\]::CreateNew, \[IO\.FileAccess\]::Write, \[IO\.FileShare\]::ReadWrite\)')).Count | Should -Be 2
    $Case = New-ProbeCase -Name 'tail'
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $OpenRows = @(Import-Csv -LiteralPath ([IO.Path]::Combine([String]$State['evidence_path'], 'attempts-openclose.csv')) -ErrorAction SilentlyContinue)
      $PersistRows = @(Import-Csv -LiteralPath ([IO.Path]::Combine([String]$State['evidence_path'], 'attempts-persist.csv')) -ErrorAction SilentlyContinue)
      If (
        $OpenRows.Count -gt 0 -and
        $PersistRows.Count -gt 0 -and
        -not [Boolean]$State['tail_checked']
      ) {
        $State['tail_checked'] = $True
        $State['tail_success'] = $True
        ForEach ($Name In @('attempts-openclose.csv', 'attempts-persist.csv')) {
          $Path = [IO.Path]::Combine([String]$State['evidence_path'], $Name)
          $Stream = [IO.FileStream]::new($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
          Try {
            $Reader = [IO.StreamReader]::new($Stream, [Text.UTF8Encoding]::new($False))
            $Text = $Reader.ReadToEnd()
            If (-not $Text.EndsWith("`r`n") -or @($Text -split "`r`n").Count -lt 3) { $State['tail_success'] = $False }
            $Reader.Dispose()
          } Finally {
            $Stream.Dispose()
          }
        }
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Null = Invoke-Probe -Case $Case -DurationSeconds 30
    $global:MeasureClusteredSmbShareAccessState['tail_success'] | Should -BeTrue
    $script:SourceText | Should -Match '\[IO\.FileShare\]::ReadWrite'
  }

  It 'T24 creates exactly the five fixed evidence basenames' {
    $script:SourceText | Should -Match '\$OpenCloseMarkerPath = \[IO\.Path\]::Combine\(\$EvidencePath, ''openclose\.inflight''\)'
    $Case = New-ProbeCase -Name 'basenames'
    $Null = Invoke-Probe -Case $Case
    @(Get-ChildItem -LiteralPath $Case.Evidence -File | Select-Object -ExpandProperty Name | Sort-Object) | Should -Be @(
      'attempts-openclose.csv'
      'attempts-persist.csv'
      'smb-samples.jsonl'
      'smbclient-connectivity.evtx'
      'smbclient-operational.evtx'
    )
    @(Get-ChildItem -LiteralPath $Case.Evidence -Filter '*.inflight' -File) | Should -HaveCount 0
  }

  It 'T25 caps a blocked observation, starts no replacement, and honors a later stop request' {
    $script:SourceText | Should -Match '\$Observation = \[PowerShell\]::Create\(\)'
    $script:SourceText | Should -Match '\$ObservationCapMilliseconds = 5000'
    $script:SourceText | Should -Match '\$InjectedState\[''observation_async''\] = \$ObservationAsync'
    $script:SourceText | Should -Match '\$Observation\.BeginStop\(\$Null, \$Null\)'
    $Case = New-ProbeCase -Name 'blocked-observation'
    $State = [Hashtable]::Synchronized(@{ observation_gate = [Threading.ManualResetEvent]::new($False) })
    $Observation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      $Null = $State['observation_gate'].WaitOne()
      $State['observation_released'] = $True
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Parameters = @{
      DurationSeconds = 60
      EvidencePath = $Case.Evidence
      IntervalSeconds = 0.1
      RunId = $Case.RunId
      ServerName = 'files'
      SharePath = $Case.Share
    }
    $AsyncSource = {
      Param ($ScriptPath, $Parameters, $Observation, $State)
      $global:MeasureClusteredSmbShareAccessObservation = $Observation
      $global:MeasureClusteredSmbShareAccessState = $State
      Function global:wevtutil.exe {
        Param ($Operation, $Channel, $Destination, $Query, $Overwrite)
        [IO.File]::WriteAllBytes([String]$Destination, [Byte[]]@())
        $global:LASTEXITCODE = 0
      }
      & $ScriptPath @Parameters
    }
    $PowerShell = [PowerShell]::Create()
    $Null = $PowerShell.AddScript($AsyncSource.ToString()).AddArgument($script:ScriptPath).AddArgument($Parameters).AddArgument($Observation).AddArgument($State)
    $Async = $PowerShell.BeginInvoke()
    $Ended = $False
    Try {
      $SamplesPath = Join-Path $Case.Evidence 'smb-samples.jsonl'
      $Wait = [Diagnostics.Stopwatch]::StartNew()
      $SawTimeout = $False
      While ($Wait.Elapsed.TotalSeconds -lt 30 -and -not $SawTimeout) {
        If ([IO.File]::Exists($SamplesPath)) {
          $SawTimeout = @([IO.File]::ReadAllLines($SamplesPath) | Where-Object { $PSItem -match '"sample_error":"timeout"' }).Count -gt 0
        }
        If (-not $SawTimeout) { [Threading.Thread]::Sleep(100) }
      }
      $SawTimeout | Should -BeTrue
      [IO.File]::WriteAllText((Join-Path $Case.Evidence 'stop.request'), '')
      $ReturnTimer = [Diagnostics.Stopwatch]::StartNew()
      While (-not $Async.IsCompleted -and $ReturnTimer.Elapsed.TotalSeconds -lt 30) { [Threading.Thread]::Sleep(100) }
      $Async.IsCompleted | Should -BeTrue
      $Output = @($PowerShell.EndInvoke($Async))
      $Ended = $True
      $Result = ($Output -join '') | ConvertFrom-Json
      $Result.stop_reason | Should -Be 'request'
      $Result.cleanup_deferred | Should -BeTrue
      $State['observation_calls'] | Should -Be 1
    } Finally {
      If ([IO.Directory]::Exists($Case.Evidence)) {
        [IO.File]::WriteAllText((Join-Path $Case.Evidence 'stop.request'), '')
      }
      $Null = $State['observation_gate'].Set()
      $PublishedObservation = $State['observation_async']
      $PublishedObservation | Should -Not -BeNullOrEmpty
      $CleanupTimer = [Diagnostics.Stopwatch]::StartNew()
      While (-not $PublishedObservation.IsCompleted -and $CleanupTimer.Elapsed.TotalSeconds -lt 30) { [Threading.Thread]::Sleep(100) }
      $PublishedObservation.IsCompleted | Should -BeTrue
      If (-not $Ended -and $Async.IsCompleted) {
        Try { $Null = $PowerShell.EndInvoke($Async) } Catch { }
      }
      $PowerShell.Dispose()
      $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
      If ([IO.Directory]::Exists($Leaf)) { [IO.Directory]::Delete($Leaf, $True) }
    }
    [IO.Directory]::Exists($Leaf) | Should -BeFalse
  }

  It 'T26 executes isolated child seams without seeing same-named parent functions' {
    $script:SourceText | Should -Match '\$AttemptBase64 = \[Convert\]::ToBase64String\(\$AttemptBytes\)'
    $Case = New-ProbeCase -Name 'isolated-seams'
    $OpenMarker = (Join-Path $Case.Evidence 'openclose-seam.txt').Replace("'", "''")
    $PersistMarker = (Join-Path $Case.Evidence 'persist-seam.txt').Replace("'", "''")
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = [ScriptBlock]::Create(@"
Param (`$Context, `$State)
[IO.File]::WriteAllText('$OpenMarker', [String](`$Null -ne (Get-Command -Name 'MeasureClusteredSmbShareAccessOpenCloseAttempt' -CommandType Function -ErrorAction SilentlyContinue)))
"@)
    $global:MeasureClusteredSmbShareAccessPersistAttempt = [ScriptBlock]::Create(@"
Param (`$Context, `$State)
[IO.File]::WriteAllText('$PersistMarker', [String](`$Null -ne (Get-Command -Name 'MeasureClusteredSmbShareAccessPersistAttempt' -CommandType Function -ErrorAction SilentlyContinue)))
"@)
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_seam_calls'] = [Int32]$State['observation_seam_calls'] + 1
      $State['observation_saw_parent'] = $Null -ne (Get-Command -Name 'MeasureClusteredSmbShareAccessObservation' -CommandType Function -ErrorAction SilentlyContinue)
      If (
        [IO.File]::Exists([String]$State['open_marker']) -and
        [IO.File]::Exists([String]$State['persist_marker'])
      ) {
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessState['open_marker'] = Join-Path $Case.Evidence 'openclose-seam.txt'
    $global:MeasureClusteredSmbShareAccessState['persist_marker'] = Join-Path $Case.Evidence 'persist-seam.txt'
    $Null = Invoke-Probe -Case $Case -DurationSeconds 30
    [IO.File]::ReadAllText((Join-Path $Case.Evidence 'openclose-seam.txt')) | Should -Be 'False'
    [IO.File]::ReadAllText((Join-Path $Case.Evidence 'persist-seam.txt')) | Should -Be 'False'
    $global:MeasureClusteredSmbShareAccessState['observation_seam_calls'] | Should -BeGreaterThan 0
    $global:MeasureClusteredSmbShareAccessState['observation_saw_parent'] | Should -BeFalse
    $global:FsHaProbeParentSeamCalled | Should -BeFalse
  }

  It 'T27 uses one shared grace deadline when both attempt seams block' {
    $script:SourceText | Should -Match '\$LoopHandle\.Process\.Kill\(\)'
    $script:SourceText | Should -Match '\$GraceDeadline = \[TimeSpan\]::FromSeconds\('
    @([Regex]::Matches($script:SourceText, '\$GraceDeadline =')).Count | Should -Be 1
    $script:SourceText | Should -Not -Match '\$LoopGraceDeadline'
    $Case = New-ProbeCase -Name 'both-blocked'
    Set-ProbeStopAfterMarkers -Case $Case -Names @('openclose', 'persist')
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      [Threading.Thread]::Sleep(600000)
    }
    $global:MeasureClusteredSmbShareAccessPersistAttempt = {
      Param ($Context, $State)
      [Threading.Thread]::Sleep(600000)
    }
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    $Run = Invoke-Probe -Case $Case -DurationSeconds 30
    $Timer.Elapsed.TotalSeconds | Should -BeLessThan 151
    $Run.Output.openclose.in_flight_at_stop | Should -BeTrue
    $Run.Output.persist.in_flight_at_stop | Should -BeTrue
    $Run.Output.openclose.kill_requested | Should -BeTrue
    $Run.Output.persist.kill_requested | Should -BeTrue
    $OpenRows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv'))
    $PersistRows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-persist.csv'))
    @($OpenRows | Where-Object outcome -EQ 'in_flight') | Should -HaveCount 1
    @($PersistRows | Where-Object outcome -EQ 'in_flight') | Should -HaveCount 1
    $Records = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    ForEach ($Worker In @($Records | Where-Object kind -EQ 'worker')) {
      (Wait-ForProcessExit -Id $Worker.process_id -StartedUtc $Worker.process_started_utc) | Should -BeTrue
    }
    $OpenHash = (Get-FileHash (Join-Path $Case.Evidence 'attempts-openclose.csv') -Algorithm SHA256).Hash
    $PersistHash = (Get-FileHash (Join-Path $Case.Evidence 'attempts-persist.csv') -Algorithm SHA256).Hash
    [Threading.Thread]::Sleep(200)
    (Get-FileHash (Join-Path $Case.Evidence 'attempts-openclose.csv') -Algorithm SHA256).Hash | Should -Be $OpenHash
    (Get-FileHash (Join-Path $Case.Evidence 'attempts-persist.csv') -Algorithm SHA256).Hash | Should -Be $PersistHash
    $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
    [IO.Directory]::Delete($Leaf, $True)
    [IO.Directory]::Exists($Leaf) | Should -BeFalse
  }

  It 'T28 throws when the terminal evidence append fails on a normal run' {
    $Case = New-ProbeCase -Name 'terminal-failure'
    $global:MeasureClusteredSmbShareAccessTerminalAppend = {
      Param ($Writer)
      $Writer.Dispose()
    }
    $Thrown = $Null
    Try {
      $Null = Invoke-Probe -Case $Case
    } Catch {
      $Thrown = $PSItem.Exception
    }
    $Thrown.GetType().FullName | Should -Be 'System.InvalidOperationException'
    $Thrown.Message | Should -Match '^Probe: terminal evidence write failed:'
    $Thrown.InnerException.GetType().FullName | Should -Be 'System.ObjectDisposedException'
  }

  It 'T29 preserves an early loop failure when the terminal evidence append also fails' {
    $Case = New-ProbeCase -Name 'early-terminal-failure'
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $State['openclose_force_end'] = $True
    }
    $global:MeasureClusteredSmbShareAccessTerminalAppend = {
      Param ($Writer)
      $Writer.Dispose()
    }
    $WarningOutput = [Collections.Generic.List[Object]]::new()
    $Thrown = $Null
    Try {
      Invoke-Probe -Case $Case -DurationSeconds 30 3>&1 | ForEach-Object -Process { $WarningOutput.Add($PSItem) }
    } Catch {
      $Thrown = $PSItem.Exception.GetBaseException()
    }
    $Thrown.GetType().FullName | Should -Be 'System.InvalidOperationException'
    $Thrown.Message | Should -Match '^Probe: loop openclose ended before the deadline:'
    @($WarningOutput | Where-Object { [String]$PSItem -match '^Probe: secondary terminal evidence failure:' }) | Should -HaveCount 1
  }

  It 'T30 launches two workers with the complete process and environment contract' {
    $script:SourceText | Should -Match '\$WorkerEngine = \(Get-Process -Id \$PID\)\.Path'
    $script:SourceText | Should -Match '\$StartInfo\.UseShellExecute = \$False'
    $script:SourceText | Should -Match '\$StartInfo\.CreateNoWindow = \$True'
    $script:SourceText | Should -Match '\$StartInfo\.RedirectStandardInput = \$True'
    $script:SourceText | Should -Match '\$StartInfo\.RedirectStandardOutput = \$True'
    $script:SourceText | Should -Match '\$StartInfo\.RedirectStandardError = \$True'
    $script:SourceText | Should -Match '-NoLogo -NoProfile -NonInteractive -EncodedCommand'
    ForEach ($Name In @(
        'FSHA_PROBE_LOOP',
        'FSHA_PROBE_RUN_ID',
        'FSHA_PROBE_DIRECTORY',
        'FSHA_PROBE_CSV',
        'FSHA_PROBE_MARKER',
        'FSHA_PROBE_STOP_REQUEST',
        'FSHA_PROBE_DEADLINE_UTC',
        'FSHA_PROBE_INTERVAL_MS',
        'FSHA_PROBE_SUPERVISOR_PID',
        'FSHA_PROBE_SUPERVISOR_STARTED_UTC',
        'FSHA_PROBE_HOLD_AFTER_ROW'
      )) {
      @([Regex]::Matches($script:SourceText, [Regex]::Escape($Name))).Count | Should -Be 2
    }
    $Case = New-ProbeCase -Name 'worker-launch'
    $Run = Invoke-Probe -Case $Case
    $Records = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Workers = @($Records | Where-Object kind -EQ 'worker')
    $Workers | Should -HaveCount 2
    ForEach ($Worker In $Workers) {
      $WorkerStarted = ([DateTime]$Worker.process_started_utc).ToUniversalTime()
      $WorkerStarted | Should -BeGreaterOrEqual ([DateTime]$Run.Output.started_utc).ToUniversalTime()
      $WorkerStarted | Should -BeLessOrEqual ([DateTime]$Run.Output.stopped_utc).ToUniversalTime()
    }
  }

  It 'T31 ends both workers when their supervisor process disappears' {
    $script:SourceText | Should -Match '\[Diagnostics\.Process\]::GetProcessById\(\$SupervisorPid\)'
    $script:SourceText | Should -Match 'observed\.ToString\("o", CultureInfo\.InvariantCulture\)'
    $script:SourceText | Should -Match '\[FsHaProbeSupervisorWatchdog\]::Start\(\$SupervisorPid, \$SupervisorStartedUtc\)'
    $Case = New-ProbeCase -Name 'orphan-guard'
    $ChildSource = @'
function global:wevtutil.exe {
  param($Operation, $Channel, $Destination, $Query, $Overwrite)
  [IO.File]::WriteAllBytes([String]$Destination, [Byte[]]@())
  $global:LASTEXITCODE = 0
}
$global:MeasureClusteredSmbShareAccessObservation = {
  param($DnsQuery, $ServerName, $State)
  [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
}
$global:MeasureClusteredSmbShareAccessPersistAttempt = {
  param($Context, $State)
  [Threading.Thread]::Sleep(600000)
}
& $env:FSHA_TEST_SCRIPT -DurationSeconds 60 -EvidencePath $env:FSHA_TEST_EVIDENCE -IntervalSeconds 0.1 -RunId $env:FSHA_TEST_RUN_ID -ServerName files -SharePath $env:FSHA_TEST_SHARE
'@
    $StartInfo = [Diagnostics.ProcessStartInfo]::new()
    $StartInfo.FileName = (Get-Process -Id $PID).Path
    $StartInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand {0}' -f [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($ChildSource))
    $StartInfo.UseShellExecute = $False
    $StartInfo.CreateNoWindow = $True
    $StartInfo.RedirectStandardInput = $True
    $StartInfo.RedirectStandardOutput = $True
    $StartInfo.RedirectStandardError = $True
    $StartInfo.EnvironmentVariables['FSHA_TEST_SCRIPT'] = $script:ScriptPath
    $StartInfo.EnvironmentVariables['FSHA_TEST_EVIDENCE'] = $Case.Evidence
    $StartInfo.EnvironmentVariables['FSHA_TEST_RUN_ID'] = $Case.RunId
    $StartInfo.EnvironmentVariables['FSHA_TEST_SHARE'] = $Case.Share
    $Probe = [Diagnostics.Process]::new()
    $Probe.StartInfo = $StartInfo
    $Null = $Probe.Start()
    $Probe.StandardInput.Close()
    $Probe.BeginOutputReadLine()
    $Workers = @()
    Try {
      $SamplesPath = Join-Path $Case.Evidence 'smb-samples.jsonl'
      $Wait = [Diagnostics.Stopwatch]::StartNew()
      While ($Wait.Elapsed.TotalSeconds -lt 30 -and $Workers.Count -lt 2) {
        If ([IO.File]::Exists($SamplesPath)) {
          Try {
            $Workers = @(Read-JsonLines $SamplesPath | Where-Object kind -EQ 'worker')
          } Catch {
            $Workers = @()
          }
        }
        If ($Workers.Count -lt 2) { [Threading.Thread]::Sleep(50) }
      }
      $Workers | Should -HaveCount 2
      $Probe.Kill()
      $Null = $Probe.WaitForExit(30000)
      $Probe.HasExited | Should -BeTrue
      ForEach ($Worker In $Workers) {
        (Wait-ForProcessExit -Id $Worker.process_id -StartedUtc $Worker.process_started_utc -Seconds 5) | Should -BeTrue
      }
      $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
      [IO.Directory]::Delete($Leaf, $True)
      [IO.Directory]::Exists($Leaf) | Should -BeFalse
    } Finally {
      If (-not $Probe.HasExited) {
        $Probe.Kill()
        $Null = $Probe.WaitForExit(30000)
      }
      ForEach ($Worker In $Workers) {
        Try {
          $FoundWorker = [Diagnostics.Process]::GetProcessById([Int32]$Worker.process_id)
          $WorkerIdentityMatches = $(If ($env:OS -eq 'Windows_NT') {
              $FoundWorker.StartTime.ToUniversalTime().ToString('o') -ceq [String]$Worker.process_started_utc
            } Else {
              [Math]::Abs(($FoundWorker.StartTime.ToUniversalTime() - ([DateTime]$Worker.process_started_utc).ToUniversalTime()).Ticks) -lt [TimeSpan]::TicksPerSecond
            })
          If ($WorkerIdentityMatches) {
            $FoundWorker.Kill()
            $Null = $FoundWorker.WaitForExit(30000)
          }
          $FoundWorker.Dispose()
        } Catch [ArgumentException] { }
      }
      $Probe.Dispose()
    }
  }

  It 'T32 reports a Kill request honestly across the already-exited race' {
    $script:SourceText | Should -Match '\$OpenCloseKillRequested = \$True'
    $KillIndex = $script:SourceText.IndexOf('$LoopHandle.Process.Kill()', [StringComparison]::Ordinal)
    $WaitIndex = $script:SourceText.IndexOf('$Null = $LoopHandle.Process.WaitForExit(30000)', [StringComparison]::Ordinal)
    $ProofIndex = $script:SourceText.IndexOf('If (-not $LoopHandle.Process.HasExited)', $WaitIndex, [StringComparison]::Ordinal)
    $MessageIndex = $script:SourceText.IndexOf('Probe: worker {0} did not end after termination', $ProofIndex, [StringComparison]::Ordinal)
    $ExitGuardIndex = $script:SourceText.IndexOf('If (-not $ExitProven)', $ProofIndex, [StringComparison]::Ordinal)
    $ContinueIndex = $script:SourceText.IndexOf('Continue', $ExitGuardIndex, [StringComparison]::Ordinal)
    $FinalizationIndex = $script:SourceText.IndexOf('$TerminationInstant = [DateTime]::UtcNow', $ExitGuardIndex, [StringComparison]::Ordinal)
    $ReadIndex = $script:SourceText.IndexOf('$MarkerText = $MarkerReader.ReadToEnd()', $ProofIndex, [StringComparison]::Ordinal)
    $ReconcileIndex = $script:SourceText.IndexOf('If ($MarkerText -match', $ProofIndex, [StringComparison]::Ordinal)
    $KillIndex | Should -BeGreaterOrEqual 0
    $WaitIndex | Should -BeGreaterThan $KillIndex
    $ProofIndex | Should -BeGreaterThan $WaitIndex
    $MessageIndex | Should -BeGreaterThan $ProofIndex
    $ExitGuardIndex | Should -BeGreaterThan $MessageIndex
    $ContinueIndex | Should -BeGreaterThan $ExitGuardIndex
    $FinalizationIndex | Should -BeGreaterThan $ContinueIndex
    $ReadIndex | Should -BeGreaterThan $MessageIndex
    $ReconcileIndex | Should -BeGreaterThan $ReadIndex
    $script:SourceText | Should -Match 'If \(-not \$ExitProven\) \{\r?\n\s+\$CleanupDeferred = \$True'

    $NoThrowCase = New-ProbeCase -Name 'kill-race-no-throw'
    $NoThrowGate = Join-Path $NoThrowCase.Root 'openclose-hold.gate'
    [IO.File]::WriteAllText($NoThrowGate, '')
    $global:MeasureClusteredSmbShareAccessState['in_flight_grace_seconds'] = 0
    $global:MeasureClusteredSmbShareAccessState['openclose_hold_after_row_path'] = $NoThrowGate
    $global:MeasureClusteredSmbShareAccessState['openclose_exit_before_kill'] = $NoThrowGate

    $NoThrowRun = Invoke-Probe -Case $NoThrowCase -DurationSeconds 1

    $NoThrowRecords = @(Read-JsonLines (Join-Path $NoThrowCase.Evidence 'smb-samples.jsonl'))
    $NoThrowWorkers = @($NoThrowRecords | Where-Object kind -EQ 'worker')
    $NoThrowWorkers | Should -HaveCount 2
    ForEach ($Worker In $NoThrowWorkers) {
      (Wait-ForProcessExit -Id $Worker.process_id -StartedUtc $Worker.process_started_utc -Seconds 5) | Should -BeTrue
    }
    $global:MeasureClusteredSmbShareAccessState['openclose_exit_before_kill_observed'] | Should -BeTrue
    $global:MeasureClusteredSmbShareAccessState['openclose_kill_returned'] | Should -BeTrue
    $global:MeasureClusteredSmbShareAccessState['openclose_kill_requested'] | Should -BeTrue
    $NoThrowRun.Output.openclose.kill_requested | Should -BeTrue
    $NoThrowRun.Output.cleanup_deferred | Should -BeTrue
    $NoThrowRecords[-1].cleanup_deferred | Should -BeTrue
    $NoThrowLeaf = Join-Path $NoThrowCase.Share ('ha-probe-{0}' -f $NoThrowCase.RunId)
    [IO.Directory]::Delete($NoThrowLeaf, $True)
    [IO.Directory]::Exists($NoThrowLeaf) | Should -BeFalse

    Reset-ProbeState
    $ExceptionCase = New-ProbeCase -Name 'kill-race-exception'
    $ExceptionGate = Join-Path $ExceptionCase.Root 'openclose-hold.gate'
    [IO.File]::WriteAllText($ExceptionGate, '')
    $OriginalException = [InvalidOperationException]::new(('second-launch-{0}' -f $ExceptionCase.RunId))
    $global:MeasureClusteredSmbShareAccessState['openclose_hold_after_row_path'] = $ExceptionGate
    $global:MeasureClusteredSmbShareAccessState['openclose_exit_before_kill'] = $ExceptionGate
    $global:MeasureClusteredSmbShareAccessState['openclose_kill_exception'] = [InvalidOperationException]::new('simulated already-exited Kill exception')
    $global:MeasureClusteredSmbShareAccessState['persist_launch_exception'] = $OriginalException
    $Thrown = $Null
    Try {
      $Null = Invoke-Probe -Case $ExceptionCase -DurationSeconds 3
    } Catch {
      $Thrown = $PSItem.Exception.GetBaseException()
    }

    [Object]::ReferenceEquals($Thrown, $OriginalException) | Should -BeTrue
    $ExceptionRecords = @(Read-JsonLines (Join-Path $ExceptionCase.Evidence 'smb-samples.jsonl'))
    $ExceptionWorkers = @($ExceptionRecords | Where-Object kind -EQ 'worker')
    $ExceptionWorkers | Should -HaveCount 1
    (Wait-ForProcessExit -Id $ExceptionWorkers[0].process_id -StartedUtc $ExceptionWorkers[0].process_started_utc -Seconds 5) | Should -BeTrue
    $global:MeasureClusteredSmbShareAccessState['openclose_exit_before_kill_observed'] | Should -BeTrue
    $global:MeasureClusteredSmbShareAccessState['openclose_kill_returned'] | Should -BeTrue
    $global:MeasureClusteredSmbShareAccessState['openclose_kill_requested'] | Should -BeTrue
    $global:MeasureClusteredSmbShareAccessState['openclose_kill_exception_type'] | Should -Be 'System.InvalidOperationException'
    $ExceptionRecords[-1].exception_message | Should -Be $OriginalException.Message
    $ExceptionRecords[-1].cleanup_deferred | Should -BeTrue
    $ExceptionLeaf = Join-Path $ExceptionCase.Share ('ha-probe-{0}' -f $ExceptionCase.RunId)
    [IO.Directory]::Delete($ExceptionLeaf, $True)
    [IO.Directory]::Exists($ExceptionLeaf) | Should -BeFalse
  }

  It 'T33 carries a worker stderr line into an early-end failure' {
    $Case = New-ProbeCase -Name 'worker-stderr'
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $State['openclose_force_end'] = $True
      Throw ('boom-{0}' -f $Context.RunId)
    }
    $Thrown = $Null
    Try {
      $Null = Invoke-Probe -Case $Case -DurationSeconds 30
    } Catch {
      $Thrown = $PSItem.Exception.GetBaseException()
    }
    $Thrown.GetType().FullName | Should -Be 'System.InvalidOperationException'
    $Thrown.Message | Should -Match ('^Probe: loop openclose ended before the deadline: boom-{0} \[System\.Management\.Automation\.RuntimeException\]' -f [Regex]::Escape($Case.RunId))
    $global:MeasureClusteredSmbShareAccessState['persist_kill_requested'] | Should -BeTrue
  }

  It 'T34 disposes the healthy persist stream after its own completed row' {
    $script:SourceText | Should -Not -Match '\$WorkersStarted'
    $Case = New-ProbeCase -Name 'persist-dispose'
    $DisposeMarker = Join-Path $Case.Root ('disposed-{0}.marker' -f $Case.RunId)
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $PersistCsv = [IO.Path]::Combine([String]$State['evidence_path'], 'attempts-persist.csv')
      $PersistRows = @(Import-Csv -LiteralPath $PersistCsv -ErrorAction SilentlyContinue)
      If ($PersistRows.Count -gt 0) {
        [IO.File]::WriteAllText([IO.Path]::Combine([String]$State['evidence_path'], 'stop.request'), '')
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $global:MeasureClusteredSmbShareAccessPersistAttempt = {
      Param ($Context, $State)
      If ($Null -eq $State['persist_stream']) {
        $LeafDirectory = [IO.Directory]::GetParent([String]$Context.Directory)
        $ShareDirectory = $LeafDirectory.Parent
        $CaseRoot = $ShareDirectory.Parent
        $Disposable = [PSCustomObject]@{
          MarkerPath = [IO.Path]::Combine($CaseRoot.FullName, ('disposed-{0}.marker' -f $Context.RunId))
          RunId      = $Context.RunId
        }
        $Disposable | Add-Member -MemberType ScriptMethod -Name Dispose -Value {
          [IO.File]::WriteAllText([String]$this.MarkerPath, ('disposed|{0}' -f $this.RunId))
        }
        $State['persist_stream'] = $Disposable
      }
    }
    $Run = Invoke-Probe -Case $Case -DurationSeconds 30
    @(Import-Csv (Join-Path $Case.Evidence 'attempts-persist.csv')) | Should -Not -BeNullOrEmpty
    [IO.File]::Exists($DisposeMarker) | Should -BeTrue
    [IO.File]::ReadAllText($DisposeMarker) | Should -Be ('disposed|{0}' -f $Case.RunId)
    $Run.Output.persist.kill_requested | Should -BeFalse
    $Run.Output.cleanup_deferred | Should -BeFalse
  }

  It 'T35 shuts down a recorded first worker when the second launch fails' {
    $script:SourceText | Should -Not -Match '\$WorkersStarted'
    $script:SourceText | Should -Match "ContainsKey\('persist_launch_exception'\)"
    $Case = New-ProbeCase -Name 'second-launch-failure'
    $Expected = [InvalidOperationException]::new(('second-launch-{0}' -f $Case.RunId))
    $global:MeasureClusteredSmbShareAccessState['persist_launch_exception'] = $Expected
    $Thrown = $Null
    Try {
      $Null = Invoke-Probe -Case $Case -DurationSeconds 3
    } Catch {
      $Thrown = $PSItem.Exception.GetBaseException()
    }
    $Thrown.GetType().FullName | Should -Be 'System.InvalidOperationException'
    $Thrown.Message | Should -Be $Expected.Message
    [Object]::ReferenceEquals($Thrown, $Expected) | Should -BeTrue
    $Records = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Workers = @($Records | Where-Object kind -EQ 'worker')
    $Workers | Should -HaveCount 1
    $Workers[0].loop | Should -Be 'openclose'
    (Wait-ForProcessExit -Id $Workers[0].process_id -StartedUtc $Workers[0].process_started_utc) | Should -BeTrue
    [IO.File]::Exists((Join-Path $Case.Evidence 'openclose.inflight')) | Should -BeFalse
    [IO.File]::Exists((Join-Path $Case.Evidence 'persist.inflight')) | Should -BeFalse
    $Records[-1].kind | Should -Be 'terminal'
    $Records[-1].exception_type | Should -Be 'System.InvalidOperationException'
    $Records[-1].exception_message | Should -Be $Expected.Message
    $Records[-1].cleanup_deferred | Should -BeTrue
    $global:MeasureClusteredSmbShareAccessState['openclose_kill_requested'] | Should -BeTrue
    $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
    [IO.Directory]::Delete($Leaf, $True)
    [IO.Directory]::Exists($Leaf) | Should -BeFalse

    Reset-ProbeState
    $UnprovenCase = New-ProbeCase -Name 'second-launch-unproven'
    $Original = [InvalidOperationException]::new(('original-launch-{0}' -f $UnprovenCase.RunId))
    $global:MeasureClusteredSmbShareAccessState['persist_launch_exception'] = $Original
    $global:MeasureClusteredSmbShareAccessState['openclose_shutdown_exception'] = [IO.IOException]::new('injected exit-proof failure')
    $UnprovenThrown = $Null
    Try {
      $Null = Invoke-Probe -Case $UnprovenCase -DurationSeconds 1
    } Catch {
      $UnprovenThrown = $PSItem.Exception.GetBaseException()
    }
    [Object]::ReferenceEquals($UnprovenThrown, $Original) | Should -BeTrue
    $UnprovenRecords = @(Read-JsonLines (Join-Path $UnprovenCase.Evidence 'smb-samples.jsonl'))
    $UnprovenWorker = @($UnprovenRecords | Where-Object kind -EQ 'worker')[0]
    (Wait-ForProcessExit -Id $UnprovenWorker.process_id -StartedUtc $UnprovenWorker.process_started_utc -Seconds 5) | Should -BeTrue
    $UnprovenRecords[-1].kind | Should -Be 'terminal'
    $UnprovenRecords[-1].exception_message | Should -Be $Original.Message
    $UnprovenRecords[-1].cleanup_deferred | Should -BeTrue
    $UnprovenLeaf = Join-Path $UnprovenCase.Share ('ha-probe-{0}' -f $UnprovenCase.RunId)
    [IO.Directory]::Delete($UnprovenLeaf, $True)
    [IO.Directory]::Exists($UnprovenLeaf) | Should -BeFalse
  }
}
