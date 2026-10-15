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
      [System.Int32]$DurationSeconds = 1,
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

  Function Read-JsonLines {
    Param ([System.String]$Path)
    @([IO.File]::ReadAllLines($Path) | ForEach-Object -Process { $PSItem | ConvertFrom-Json })
  }

  Function Wait-ForState {
    Param (
      [Hashtable]$State,
      [System.String]$Key,
      [System.Int32]$Seconds = 30
    )
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    While ($Timer.Elapsed.TotalSeconds -lt $Seconds -and -not [Boolean]$State[$Key]) {
      [Threading.Thread]::Sleep(50)
    }
    [Boolean]$State[$Key]
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
    ForEach ($GateName In @('openclose_gate', 'persist_gate', 'observation_gate')) {
      If (
        $Null -ne $global:MeasureClusteredSmbShareAccessState -and
        $global:MeasureClusteredSmbShareAccessState.ContainsKey($GateName) -and
        $Null -ne $global:MeasureClusteredSmbShareAccessState[$GateName]
      ) {
        $Null = $global:MeasureClusteredSmbShareAccessState[$GateName].Set()
      }
    }
    Remove-AnsibleContext
    [Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture = $script:SavedUiCulture
  }

  It 'T01 returns the happy-path result with matching first process and last terminal records' {
    $Case = New-ProbeCase -Name 'happy'

    $Run = Invoke-Probe -Case $Case

    $Run.Output.changed | Should -BeTrue
    $Run.Output.check_mode | Should -BeFalse
    $Run.Output.failed | Should -BeFalse
    $Run.Output.cleanup_deferred | Should -BeFalse
    $Run.Output.openclose.attempts | Should -BeGreaterThan 0
    $Run.Output.persist.attempts | Should -BeGreaterThan 0
    $Run.Context.Result.run_leaf | Should -Be $Run.Output.run_leaf
    $Records = @(Read-JsonLines -Path (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Records[0].kind | Should -Be 'process'
    $Records[0].process_id | Should -Be $PID
    ([DateTime]$Records[0].process_started_utc).ToUniversalTime().ToString('o') | Should -Be (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o')
    $Records[0].run_id | Should -Be $Case.RunId
    $Records[0].run_leaf | Should -Be $Run.Output.run_leaf
    @($Records | Where-Object kind -EQ 'process') | Should -HaveCount 1
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
  }

  It 'T02 emits equivalent Ansible and standalone result shapes' {
    $AnsibleCase = New-ProbeCase -Name 'ansible'
    $StandaloneCase = New-ProbeCase -Name 'standalone'
    $AnsibleRun = Invoke-Probe -Case $AnsibleCase
    Remove-AnsibleContext
    Reset-ProbeState

    $Json = & $script:ScriptPath -DurationSeconds 1 -EvidencePath $StandaloneCase.Evidence -IntervalSeconds 0.1 -RunId $StandaloneCase.RunId -ServerName 'files' -SharePath $StandaloneCase.Share
    $Standalone = ($Json -join '') | ConvertFrom-Json

    $Standalone.changed | Should -Be $AnsibleRun.Output.changed
    $Standalone.failed | Should -Be $AnsibleRun.Output.failed
    $Standalone.msg | Should -Be $AnsibleRun.Output.msg
    $Standalone.openclose.attempts | Should -BeGreaterThan 0
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
    $Case = New-ProbeCase -Name 'persist-retry'
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
    $Run = Invoke-Probe -Case $Case -DurationSeconds 2
    $Rows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-persist.csv'))
    @($Rows | Where-Object outcome -EQ 'failure').Count | Should -BeGreaterThan 0
    @($Rows | Where-Object outcome -EQ 'success').Count | Should -BeGreaterThan 0
    $Run.Output.failed | Should -BeFalse
  }

  It 'T10 records base DirectoryNotFoundException outage rows and persistent successes' {
    $Case = New-ProbeCase -Name 'rename'
    $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
    $global:MeasureClusteredSmbShareAccessState['openclose'] = Join-Path $Leaf 'openclose'
    $global:MeasureClusteredSmbShareAccessState['renamed'] = Join-Path $Leaf 'openclose-x'
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      If ([Int32]$State['openclose_attempts'] -gt 0 -and -not [Boolean]$State['openclose_outage_started']) {
        [IO.Directory]::Move([String]$State['openclose'], [String]$State['renamed'])
        $State['openclose_outage_started'] = $True
      }
      If ([Int32]$State['openclose_failures'] -gt 0 -and -not [Boolean]$State['openclose_outage_recovered']) {
        [IO.Directory]::Move([String]$State['renamed'], [String]$State['openclose'])
        $State['openclose_outage_recovered'] = $True
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Run = Invoke-Probe -Case $Case -DurationSeconds 2
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
    $script:SourceText | Should -Match 'If \(\$LoopHandle\.Async\.IsCompleted -and -not \[Boolean\]\$SharedState\[''stop_requested''\]\)'
    $script:SourceText | Should -Match '\$JsonWriter\.WriteLine\(\(ConvertTo-Json -InputObject:\$TerminalRecord -Compress -Depth:6\)\)'
    $ShutdownIndex = $script:SourceText.IndexOf("`$SharedState['stop_requested'] = `$True", [StringComparison]::Ordinal)
    $RethrowMatch = [Regex]::Match($script:SourceText, '(?m)^  If \(\$Null -ne \$PendingException\) \{\r?\n    Throw \$PendingException\r?\n  \}$')
    $RethrowIndex = $(If ($RethrowMatch.Success) { $RethrowMatch.Index } Else { -1 })
    $ShutdownIndex | Should -BeGreaterOrEqual 0
    $RethrowIndex | Should -BeGreaterThan $ShutdownIndex
    $Case = New-ProbeCase -Name 'early-loop'
    $Gate = [Threading.ManualResetEvent]::new($False)
    $global:MeasureClusteredSmbShareAccessState['persist_gate'] = $Gate
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $State['openclose_force_end'] = $True
    }
    $global:MeasureClusteredSmbShareAccessPersistAttempt = {
      Param ($Context, $State)
      $State['persist_block_started_utc'] = [DateTime]::UtcNow.ToString('o')
      $Null = $State['persist_gate'].WaitOne()
    }
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    { Invoke-Probe -Case $Case -DurationSeconds 30 } | Should -Throw '*Probe: loop openclose ended before the deadline*'
    $Timer.Elapsed.TotalSeconds | Should -BeLessThan 150
    $Records = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Records[-1].kind | Should -Be 'terminal'
    $Records[-1].exception_type | Should -Be 'System.InvalidOperationException'
    $Records[-1].exception_message | Should -Match '^Probe:'
    $Records[-1].cleanup_deferred | Should -BeTrue
    $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
    [IO.Directory]::Exists($Leaf) | Should -BeTrue
    $Gate.Set() | Should -BeTrue
    (Wait-ForState -State $global:MeasureClusteredSmbShareAccessState -Key 'persist_released') | Should -BeTrue
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
    $script:SourceText | Should -Match '\$InvariantCulture = \[Globalization\.CultureInfo\]::InvariantCulture'
    $script:SourceText | Should -Match '\$Culture = \[Globalization\.CultureInfo\]::InvariantCulture'
    $Case = New-ProbeCase -Name 'culture'
    $German = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    [Threading.Thread]::CurrentThread.CurrentCulture = $German
    [Threading.Thread]::CurrentThread.CurrentUICulture = $German
    $Null = Invoke-Probe -Case $Case
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

  It 'T20 writes one locked terminal in_flight row and no late row after release' {
    $script:SourceText | Should -Match '\$State\[\(''\{0\}_inflight'' -f \$LoopName\)\] = \[PSCustomObject\]@\{'
    $script:SourceText | Should -Match '\$SharedState\[\(''\{0\}_shutdown_lock_gate_reached'' -f \$LoopHandle\.Name\)\] = \$True'
    $script:SourceText | Should -Match '\$StopAsync = \$LoopHandle\.PowerShell\.BeginStop\(\$Null, \$Null\)'
    $script:SourceText | Should -Match '\$LoopHandle\.Terminal\[''terminal_written''\] = \$True'
    $script:SourceText | Should -Match 'If \(-not \$LoopHandle\.Async\.IsCompleted\)'
    $Case = New-ProbeCase -Name 'one-blocked'
    $Gate = [Threading.ManualResetEvent]::new($False)
    $global:MeasureClusteredSmbShareAccessState['openclose_gate'] = $Gate
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $State['openclose_block_started_utc'] = [DateTime]::UtcNow.ToString('o')
      $Null = $State['openclose_gate'].WaitOne()
    }
    $ReturnedAt = $Null
    $Run = Invoke-Probe -Case $Case
    $ReturnedAt = [DateTime]::UtcNow
    $Run.Output.cleanup_deferred | Should -BeTrue
    $Run.Output.openclose.in_flight_at_stop | Should -BeTrue
    $Rows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv'))
    @($Rows | Where-Object outcome -EQ 'in_flight') | Should -HaveCount 1
    $Terminal = @($Rows | Where-Object outcome -EQ 'in_flight')[0]
    [Int64]$Terminal.elapsed_ms | Should -BeGreaterOrEqual 120000
    $Started = [DateTime]::Parse($Terminal.timestamp_utc).ToUniversalTime()
    [Int64]$Terminal.elapsed_ms | Should -BeLessOrEqual ([Int64][Math]::Floor(($ReturnedAt - $Started).TotalMilliseconds))
    $Records = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl'))
    $Records[-1].kind | Should -Be 'terminal'
    $Records[-1].cleanup_deferred | Should -BeTrue
    $Leaf = Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)
    [IO.Directory]::Exists($Leaf) | Should -BeTrue
    $BeforeHash = (Get-FileHash (Join-Path $Case.Evidence 'attempts-openclose.csv') -Algorithm SHA256).Hash
    $BeforeCount = $Rows.Count
    $Gate.Set() | Should -BeTrue
    (Wait-ForState -State $global:MeasureClusteredSmbShareAccessState -Key 'openclose_released') | Should -BeTrue
    [Threading.Thread]::Sleep(200)
    (Get-FileHash (Join-Path $Case.Evidence 'attempts-openclose.csv') -Algorithm SHA256).Hash | Should -Be $BeforeHash
    @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv')) | Should -HaveCount $BeforeCount
    [IO.Directory]::Delete($Leaf, $True)
    [IO.Directory]::Exists($Leaf) | Should -BeFalse

    Reset-ProbeState
    $RaceCase = New-ProbeCase -Name 'completed-under-lock'
    $RaceState = $global:MeasureClusteredSmbShareAccessState
    $AttemptGate = [Threading.ManualResetEvent]::new($False)
    $ShutdownGate = [Threading.ManualResetEvent]::new($False)
    $RaceState['openclose_gate'] = $AttemptGate
    $RaceState['openclose_shutdown_lock_gate'] = $ShutdownGate
    $RaceAttempt = {
      Param ($Context, $State)
      $Null = $State['openclose_gate'].WaitOne()
    }
    $RaceParameters = @{
      DurationSeconds = 1
      EvidencePath = $RaceCase.Evidence
      IntervalSeconds = 0.1
      RunId = $RaceCase.RunId
      ServerName = 'files'
      SharePath = $RaceCase.Share
    }
    $RaceSource = {
      Param ($ScriptPath, $Parameters, $Attempt, $State)
      $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = $Attempt
      $global:MeasureClusteredSmbShareAccessState = $State
      Function global:wevtutil.exe {
        Param ($Operation, $Channel, $Destination, $Query, $Overwrite)
        [IO.File]::WriteAllBytes([String]$Destination, [Byte[]]@())
        $global:LASTEXITCODE = 0
      }
      & $ScriptPath @Parameters
    }
    $RacePowerShell = [PowerShell]::Create()
    $Null = $RacePowerShell.AddScript($RaceSource.ToString()).AddArgument($script:ScriptPath).AddArgument($RaceParameters).AddArgument($RaceAttempt).AddArgument($RaceState)
    $RaceAsync = $RacePowerShell.BeginInvoke()
    $RaceEnded = $False
    Try {
      (Wait-ForState -State $RaceState -Key 'openclose_shutdown_lock_gate_reached' -Seconds 150) | Should -BeTrue
      $AttemptGate.Set() | Should -BeTrue
      (Wait-ForState -State $RaceState -Key 'openclose_released') | Should -BeTrue
      $ShutdownGate.Set() | Should -BeTrue
      $RaceTimer = [Diagnostics.Stopwatch]::StartNew()
      While (-not $RaceAsync.IsCompleted -and $RaceTimer.Elapsed.TotalSeconds -lt 30) { [Threading.Thread]::Sleep(100) }
      $RaceAsync.IsCompleted | Should -BeTrue
      $RaceOutput = @($RacePowerShell.EndInvoke($RaceAsync))
      $RaceEnded = $True
      $RaceResult = ($RaceOutput -join '') | ConvertFrom-Json
      $RaceResult.cleanup_deferred | Should -BeFalse
      $RaceRows = @(Import-Csv (Join-Path $RaceCase.Evidence 'attempts-openclose.csv'))
      $RaceRows | Should -HaveCount 1
      @($RaceRows | Where-Object outcome -EQ 'in_flight') | Should -HaveCount 0
      $RaceLeaf = Join-Path $RaceCase.Share ('ha-probe-{0}' -f $RaceCase.RunId)
      [IO.Directory]::Exists($RaceLeaf) | Should -BeFalse
      $Exclusive = [IO.FileStream]::new((Join-Path $RaceCase.Evidence 'attempts-openclose.csv'), [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
      $Exclusive.Dispose()
    } Finally {
      $Null = $AttemptGate.Set()
      $Null = $ShutdownGate.Set()
      If (-not $RaceEnded -and $RaceAsync.IsCompleted) {
        Try { $Null = $RacePowerShell.EndInvoke($RaceAsync) } Catch { }
      }
      $RacePowerShell.Dispose()
    }
  }

  It 'T21 samples strictly increasing in-flight ages before the terminal age' {
    $script:SourceText | Should -Match '\$State\[\(''\{0\}_inflight'' -f \$LoopName\)\] = \[PSCustomObject\]@\{'
    $Case = New-ProbeCase -Name 'ages'
    $Gate = [Threading.ManualResetEvent]::new($False)
    $global:MeasureClusteredSmbShareAccessState['openclose_gate'] = $Gate
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $Null = $State['openclose_gate'].WaitOne()
    }
    $Run = Invoke-Probe -Case $Case
    $Samples = @(Read-JsonLines (Join-Path $Case.Evidence 'smb-samples.jsonl') | Where-Object { $PSItem.kind -eq 'sample' -and [Int64]$PSItem.openclose_in_flight_ms -gt 0 })
    $Samples.Count | Should -BeGreaterThan 1
    For ($Index = 1; $Index -lt $Samples.Count; $Index++) {
      [Int64]$Samples[$Index].openclose_in_flight_ms | Should -BeGreaterThan ([Int64]$Samples[$Index - 1].openclose_in_flight_ms)
    }
    $Terminal = @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv') | Where-Object outcome -EQ 'in_flight')[0]
    [Int64]$Terminal.elapsed_ms | Should -BeGreaterOrEqual ([Int64]$Samples[-1].openclose_in_flight_ms)
    $Run.Output.openclose.max_elapsed_ms | Should -Be ([Int64]$Terminal.elapsed_ms)
    $Gate.Set() | Should -BeTrue
    (Wait-ForState -State $global:MeasureClusteredSmbShareAccessState -Key 'openclose_released') | Should -BeTrue
    [IO.Directory]::Delete((Join-Path $Case.Share ('ha-probe-{0}' -f $Case.RunId)), $True)
  }

  It 'T22 honors stop.request and distinguishes request from deadline' {
    @([Regex]::Matches($script:SourceText, '\[IO\.File\]::Exists\(\$StopRequestPath\)')).Count | Should -Be 3
    $RequestCase = New-ProbeCase -Name 'request'
    $global:MeasureClusteredSmbShareAccessState['stop_path'] = $RequestCase.Evidence
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      If (
        [Int32]$State['openclose_attempts'] -gt 0 -and
        [Int32]$State['persist_attempts'] -gt 0 -and
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
    Reset-ProbeState
    $DeadlineCase = New-ProbeCase -Name 'deadline'
    (Invoke-Probe -Case $DeadlineCase).Output.stop_reason | Should -Be 'deadline'
  }

  It 'T23 allows a second reader to tail both complete CRLF CSV streams' {
    @([Regex]::Matches($script:SourceText, '\$\w+File = \[IO\.FileStream\]::new\(\$\w+CsvPath, \[IO\.FileMode\]::CreateNew, \[IO\.FileAccess\]::Write, \[IO\.FileShare\]::ReadWrite\)')).Count | Should -Be 2
    $Case = New-ProbeCase -Name 'tail'
    $global:MeasureClusteredSmbShareAccessState['evidence_path'] = $Case.Evidence
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_calls'] = [Int32]$State['observation_calls'] + 1
      If (
        [Int32]$State['openclose_rows'] -gt 0 -and
        [Int32]$State['persist_rows'] -gt 0 -and
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
      }
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Null = Invoke-Probe -Case $Case -DurationSeconds 2
    $global:MeasureClusteredSmbShareAccessState['tail_success'] | Should -BeTrue
    $script:SourceText | Should -Match '\[IO\.FileShare\]::ReadWrite'
  }

  It 'T24 creates exactly the five fixed evidence basenames' {
    $Case = New-ProbeCase -Name 'basenames'
    $Null = Invoke-Probe -Case $Case
    @(Get-ChildItem -LiteralPath $Case.Evidence -File | Select-Object -ExpandProperty Name | Sort-Object) | Should -Be @(
      'attempts-openclose.csv'
      'attempts-persist.csv'
      'smb-samples.jsonl'
      'smbclient-connectivity.evtx'
      'smbclient-operational.evtx'
    )
  }

  It 'T25 caps a blocked observation, starts no replacement, and honors a later stop request' {
    $script:SourceText | Should -Match '\$Observation = \[PowerShell\]::Create\(\)'
    $script:SourceText | Should -Match '\$ObservationCapMilliseconds = 5000'
    $script:SourceText | Should -Match '\$InjectedState\[''observation_async''\] = \$ObservationAsync'
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
      (Wait-ForState -State $State -Key 'observation_released') | Should -BeTrue
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
    $Case = New-ProbeCase -Name 'isolated-seams'
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $State['openclose_seam_calls'] = [Int32]$State['openclose_seam_calls'] + 1
      $State['openclose_saw_parent'] = $Null -ne (Get-Command -Name 'MeasureClusteredSmbShareAccessOpenCloseAttempt' -CommandType Function -ErrorAction SilentlyContinue)
    }
    $global:MeasureClusteredSmbShareAccessPersistAttempt = {
      Param ($Context, $State)
      $State['persist_seam_calls'] = [Int32]$State['persist_seam_calls'] + 1
      $State['persist_saw_parent'] = $Null -ne (Get-Command -Name 'MeasureClusteredSmbShareAccessPersistAttempt' -CommandType Function -ErrorAction SilentlyContinue)
    }
    $global:MeasureClusteredSmbShareAccessObservation = {
      Param ($DnsQuery, $ServerName, $State)
      $State['observation_seam_calls'] = [Int32]$State['observation_seam_calls'] + 1
      $State['observation_saw_parent'] = $Null -ne (Get-Command -Name 'MeasureClusteredSmbShareAccessObservation' -CommandType Function -ErrorAction SilentlyContinue)
      [PSCustomObject]@{ continuously_available = $True; dns_a_records = @('192.0.2.10'); server_ip = '192.0.2.10' }
    }
    $Null = Invoke-Probe -Case $Case
    $global:MeasureClusteredSmbShareAccessState['openclose_seam_calls'] | Should -BeGreaterThan 0
    $global:MeasureClusteredSmbShareAccessState['persist_seam_calls'] | Should -BeGreaterThan 0
    $global:MeasureClusteredSmbShareAccessState['observation_seam_calls'] | Should -BeGreaterThan 0
    $global:MeasureClusteredSmbShareAccessState['openclose_saw_parent'] | Should -BeFalse
    $global:MeasureClusteredSmbShareAccessState['persist_saw_parent'] | Should -BeFalse
    $global:MeasureClusteredSmbShareAccessState['observation_saw_parent'] | Should -BeFalse
    $global:FsHaProbeParentSeamCalled | Should -BeFalse
  }

  It 'T27 uses one shared grace deadline when both attempt seams block' {
    $script:SourceText | Should -Match '\$GraceDeadline = \[TimeSpan\]::FromSeconds\(\$InFlightGraceSeconds\)'
    @([Regex]::Matches($script:SourceText, '\$GraceDeadline =')).Count | Should -Be 1
    $script:SourceText | Should -Not -Match '\$LoopGraceDeadline'
    $Case = New-ProbeCase -Name 'both-blocked'
    $OpenGate = [Threading.ManualResetEvent]::new($False)
    $PersistGate = [Threading.ManualResetEvent]::new($False)
    $global:MeasureClusteredSmbShareAccessState['openclose_gate'] = $OpenGate
    $global:MeasureClusteredSmbShareAccessState['persist_gate'] = $PersistGate
    $global:MeasureClusteredSmbShareAccessOpenCloseAttempt = {
      Param ($Context, $State)
      $Null = $State['openclose_gate'].WaitOne()
    }
    $global:MeasureClusteredSmbShareAccessPersistAttempt = {
      Param ($Context, $State)
      $Null = $State['persist_gate'].WaitOne()
    }
    $Timer = [Diagnostics.Stopwatch]::StartNew()
    $Run = Invoke-Probe -Case $Case
    $Timer.Elapsed.TotalSeconds | Should -BeLessThan 151
    $Run.Output.openclose.in_flight_at_stop | Should -BeTrue
    $Run.Output.persist.in_flight_at_stop | Should -BeTrue
    $OpenRows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-openclose.csv'))
    $PersistRows = @(Import-Csv (Join-Path $Case.Evidence 'attempts-persist.csv'))
    @($OpenRows | Where-Object outcome -EQ 'in_flight') | Should -HaveCount 1
    @($PersistRows | Where-Object outcome -EQ 'in_flight') | Should -HaveCount 1
    $OpenHash = (Get-FileHash (Join-Path $Case.Evidence 'attempts-openclose.csv') -Algorithm SHA256).Hash
    $PersistHash = (Get-FileHash (Join-Path $Case.Evidence 'attempts-persist.csv') -Algorithm SHA256).Hash
    $OpenGate.Set() | Should -BeTrue
    $PersistGate.Set() | Should -BeTrue
    (Wait-ForState -State $global:MeasureClusteredSmbShareAccessState -Key 'openclose_released') | Should -BeTrue
    (Wait-ForState -State $global:MeasureClusteredSmbShareAccessState -Key 'persist_released') | Should -BeTrue
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
}
