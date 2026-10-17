#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:ScriptPath = Join-Path -Path $PSScriptRoot -ChildPath 'Test-ClusteredSmbFailoverEvidence.ps1'
  $script:SourceText = [IO.File]::ReadAllText($script:ScriptPath)
  $script:CaseNumber = 0
  $script:SavedCulture = [Threading.Thread]::CurrentThread.CurrentCulture
  $script:SavedUiCulture = [Threading.Thread]::CurrentThread.CurrentUICulture
  $script:Origin = [DateTimeOffset]::ParseExact(
    '2026-10-15T00:00:00.0000000Z',
    'o',
    [Globalization.CultureInfo]::InvariantCulture,
    [Globalization.DateTimeStyles]::None
  )

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

  Function New-TestRow {
    Param (
      [System.Double]$Second,
      [ValidateSet('success', 'failure', 'in_flight')]
      [System.String]$Outcome = 'success',
      [System.Int64]$ElapsedMilliseconds = 0
    )
    [PSCustomObject]@{
      ElapsedMilliseconds = $ElapsedMilliseconds
      Outcome             = $Outcome
      Timestamp           = $script:Origin.AddTicks([Int64][Math]::Round($Second * [TimeSpan]::TicksPerSecond))
    }
  }

  Function New-TestRows {
    Param ([System.Double[]]$Seconds)
    @($Seconds | ForEach-Object -Process { New-TestRow -Second $PSItem })
  }

  Function New-TestEvent {
    Param (
      [System.String]$Name,
      [ValidateSet('planned', 'unplanned')]
      [System.String]$Kind,
      [System.Double]$Second
    )
    [PSCustomObject][Ordered]@{
      name       = $Name
      kind       = $Kind
      marker_utc = $script:Origin.AddTicks([Int64][Math]::Round($Second * [TimeSpan]::TicksPerSecond)).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    }
  }

  Function New-EvidenceSet {
    Param (
      [System.String]$Name,
      [System.Object[]]$OpenCloseRows,
      [System.Object[]]$PersistRows = $OpenCloseRows
    )
    $script:CaseNumber++
    $EvidencePath = Join-Path -Path $TestDrive -ChildPath ('case-{0:00}-{1}' -f @($script:CaseNumber, $Name))
    [IO.Directory]::CreateDirectory($EvidencePath) | Out-Null
    $Utf8 = [Text.UTF8Encoding]::new($False)
    $Header = 'timestamp_utc,loop,attempt,op,elapsed_ms,outcome,exception_type,exception_hresult,exception_message,dns_a_records,server_ip,network_sample_utc'
    ForEach ($Definition In @(
        [PSCustomObject]@{ File = 'attempts-openclose.csv'; Loop = 'openclose'; Rows = @($OpenCloseRows) }
        [PSCustomObject]@{ File = 'attempts-persist.csv'; Loop = 'persist'; Rows = @($PersistRows) }
      )) {
      $Lines = [Collections.Generic.List[String]]::new()
      $Lines.Add($Header)
      $Attempt = 0
      ForEach ($InputRow In @($Definition.Rows)) {
        $Attempt++
        $ExceptionType = $(If ($InputRow.Outcome -ceq 'failure') { 'System.IO.IOException' } Else { '' })
        $ExceptionHResult = $(If ($InputRow.Outcome -ceq 'failure') { '0x80070035' } Else { '' })
        $ExceptionMessage = $(If ($InputRow.Outcome -ceq 'failure') { 'The network path was not found.' } Else { '' })
        $Operation = $(If ($Definition.Loop -ceq 'openclose') { 'write_read_close' } Else { 'append_flush' })
        $Row = [PSCustomObject][Ordered]@{
          timestamp_utc      = $InputRow.Timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
          loop               = $Definition.Loop
          attempt            = $Attempt.ToString([Globalization.CultureInfo]::InvariantCulture)
          op                 = $Operation
          elapsed_ms         = $InputRow.ElapsedMilliseconds.ToString([Globalization.CultureInfo]::InvariantCulture)
          outcome            = $InputRow.Outcome
          exception_type     = $ExceptionType
          exception_hresult  = $ExceptionHResult
          exception_message  = $ExceptionMessage
          dns_a_records      = '192.0.2.10;192.0.2.11'
          server_ip          = '192.0.2.10'
          network_sample_utc = $InputRow.Timestamp.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        }
        $Lines.Add(@($Row | ConvertTo-Csv -Delimiter ',' -NoTypeInformation)[1])
      }
      [IO.File]::WriteAllText(
        (Join-Path -Path $EvidencePath -ChildPath $Definition.File),
        (($Lines.ToArray() -join "`r`n") + "`r`n"),
        $Utf8
      )
    }
    $JsonLines = [Collections.Generic.List[String]]::new()
    $FixtureRunId = 'fixture-{0:00}' -f $script:CaseNumber
    $JsonLines.Add((ConvertTo-Json -Compress -Depth:6 -InputObject:([Ordered]@{
            kind                = 'process'
            process_id          = 1234
            process_started_utc = $script:Origin.AddSeconds(-1).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            run_id              = $FixtureRunId
            run_leaf            = ('C:\fixture\ha-probe-fixture-{0:00}' -f $script:CaseNumber)
          })))
    $JsonLines.Add((ConvertTo-Json -Compress -Depth:6 -InputObject:([Ordered]@{
            kind                   = 'sample'
            timestamp_utc          = $script:Origin.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            sample_error           = ''
            continuously_available = $True
            dns_a_records          = @('192.0.2.10', '192.0.2.11')
            server_ip              = '192.0.2.10'
            network_sample_utc     = $script:Origin.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
            openclose_attempt      = 1
            openclose_op           = 'write_read_close'
            openclose_in_flight_ms = 0
            persist_attempt        = 1
            persist_op             = 'append_flush'
            persist_in_flight_ms   = 0
          })))
    $JsonLines.Add((ConvertTo-Json -Compress -Depth:6 -InputObject:([Ordered]@{
            kind              = 'terminal'
            run_id            = $FixtureRunId
            exception_type    = ''
            exception_hresult = ''
            exception_message = ''
            cleanup_deferred  = $False
          })))
    [IO.File]::WriteAllText(
      (Join-Path -Path $EvidencePath -ChildPath 'smb-samples.jsonl'),
      (($JsonLines.ToArray() -join "`r`n") + "`r`n"),
      $Utf8
    )
    $EvidencePath
  }

  Function New-ScoreParameters {
    Param (
      [System.String]$EvidencePath,
      [System.Object[]]$Events,
      [System.Double]$BaselineCadenceSeconds = 2.0,
      [System.Double]$PlannedGapSeconds = 2.0,
      [System.Int32]$PlannedOpenCloseFailures = 1,
      [System.Double]$UnplannedGapSeconds = 3.0,
      [System.Int32]$UnplannedOpenCloseFailures = 2
    )
    @{
      BaselineCadenceSeconds       = $BaselineCadenceSeconds
      EvidencePath                 = $EvidencePath
      Events                       = $Events
      IntervalSeconds              = 1.0
      PlannedGapSeconds            = $PlannedGapSeconds
      PlannedOpenCloseFailures     = $PlannedOpenCloseFailures
      UnplannedGapSeconds          = $UnplannedGapSeconds
      UnplannedOpenCloseFailures   = $UnplannedOpenCloseFailures
    }
  }

  Function Invoke-Score {
    Param ([Collections.IDictionary]$Parameters)
    $Context = New-AnsibleContext
    $Output = @(& $script:ScriptPath @Parameters)
    [PSCustomObject]@{
      Context = $Context
      Output  = $(If ($Output.Count -gt 0) { $Output[-1] })
    }
  }
}

AfterAll {
  [Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
  [Threading.Thread]::CurrentThread.CurrentUICulture = $script:SavedUiCulture
  Remove-AnsibleContext
}

Describe 'Test-ClusteredSmbFailoverEvidence' {
  BeforeEach {
    Remove-AnsibleContext
    [Threading.Thread]::CurrentThread.CurrentCulture = $script:SavedCulture
    [Threading.Thread]::CurrentThread.CurrentUICulture = $script:SavedUiCulture
  }

  It 'T01 scores a clean producer-shaped evidence set' -Tag 'T01' {
    $Rows = New-TestRows -Seconds (0..30)
    $Evidence = New-EvidenceSet -Name 'clean' -OpenCloseRows $Rows
    $Events = @(
      New-TestEvent -Name 'E1' -Kind 'planned' -Second 10
      New-TestEvent -Name 'E2' -Kind 'unplanned' -Second 20
    )
    $Result = Invoke-Score -Parameters (New-ScoreParameters -EvidencePath $Evidence -Events $Events)
    $Result.Context.Changed | Should -BeFalse
    $Result.Context.Failed | Should -BeFalse
    $Result.Output.contract | Should -BeExactly 'pass'
    $Result.Output.events.Count | Should -Be 2
    $Result.Output.events[0].loops[0].attempts | Should -Be 10
    $Result.Output.events[1].loops[1].failures | Should -Be 0
  }

  It 'T02 accepts the exact gap limit and rejects limit plus one millisecond' -Tag 'T02' {
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 10)
    $Boundary = New-EvidenceSet -Name 'boundary' -OpenCloseRows (New-TestRows -Seconds @(8, 9, 10, 12))
    $Parameters = New-ScoreParameters -EvidencePath $Boundary -Events $Events
    (Invoke-Score -Parameters $Parameters).Output.contract | Should -BeExactly 'pass'

    $Over = New-EvidenceSet -Name 'over-boundary' -OpenCloseRows (New-TestRows -Seconds @(8, 9, 10, 12.001))
    $Parameters.EvidencePath = $Over
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*measured=2.001 limit=2*'
  }

  It 'T03 attributes an outage more than 120 seconds after E2 marker to E2' -Tag 'T03' {
    $Rows = New-TestRows -Seconds @(8, 9, 10, 50, 99, 100, 150, 200, 250, 300, 500, 600)
    $Evidence = New-EvidenceSet -Name 'late-outage' -OpenCloseRows $Rows
    $Events = @(
      New-TestEvent -Name 'E1' -Kind 'planned' -Second 10
      New-TestEvent -Name 'E2' -Kind 'planned' -Second 100
      New-TestEvent -Name 'E3' -Kind 'planned' -Second 600
    )
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events -PlannedGapSeconds 100
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*E2/openclose/gap measured=200 limit=100*'
  }

  It 'T04 rejects a persistent-handle failure even when open-close stays clean' -Tag 'T04' {
    $Rows = New-TestRows -Seconds (7..12)
    $PersistRows = @(
      New-TestRow -Second 7
      New-TestRow -Second 8
      New-TestRow -Second 9
      New-TestRow -Second 10
      New-TestRow -Second 11 -Outcome 'failure'
      New-TestRow -Second 12
    )
    $Evidence = New-EvidenceSet -Name 'persist-failure' -OpenCloseRows $Rows -PersistRows $PersistRows
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 10)
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*E1/persist/failures measured=1 limit=0*'
  }

  It 'T05 rejects open-close failures above the event limit' -Tag 'T05' {
    $OpenRows = @(
      New-TestRow -Second 7
      New-TestRow -Second 8
      New-TestRow -Second 9
      New-TestRow -Second 10
      New-TestRow -Second 11 -Outcome 'failure'
      New-TestRow -Second 12 -Outcome 'failure'
      New-TestRow -Second 13
    )
    $Evidence = New-EvidenceSet -Name 'openclose-failures' -OpenCloseRows $OpenRows -PersistRows (New-TestRows -Seconds (7..13))
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 10)
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*E1/openclose/failures measured=2 limit=1*'
  }

  It 'T06 rejects a first marker before the evidence row span' -Tag 'T06' {
    $Evidence = New-EvidenceSet -Name 'marker-before-span' -OpenCloseRows (New-TestRows -Seconds (7..12))
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 5)
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*baseline/openclose/coverage_start*'
  }

  It 'T07 rejects evidence with no successful row after the last marker' -Tag 'T07' {
    $Rows = @(
      New-TestRow -Second 7
      New-TestRow -Second 8
      New-TestRow -Second 9
      New-TestRow -Second 10 -Outcome 'in_flight'
    )
    $Evidence = New-EvidenceSet -Name 'no-success-after' -OpenCloseRows $Rows
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 10)
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*E1/openclose/coverage_end measured=0 limit=1*'
  }

  It 'T08 rejects baseline cadence above its limit' -Tag 'T08' {
    $Evidence = New-EvidenceSet -Name 'baseline-cadence' -OpenCloseRows (New-TestRows -Seconds @(0, 1, 9, 10, 11))
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 10)
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*baseline/openclose/gap measured=8 limit=2*'
  }

  It 'T09 rejects an unknown or missing CSV column' -Tag 'T09' {
    $Rows = New-TestRows -Seconds (7..12)
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 10)
    $Unknown = New-EvidenceSet -Name 'unknown-column' -OpenCloseRows $Rows
    $UnknownPath = Join-Path -Path $Unknown -ChildPath 'attempts-openclose.csv'
    $UnknownText = [IO.File]::ReadAllText($UnknownPath).Replace('network_sample_utc', 'network_sample_utc,future')
    [IO.File]::WriteAllText($UnknownPath, $UnknownText, [Text.UTF8Encoding]::new($False))
    { Invoke-Score -Parameters (New-ScoreParameters -EvidencePath $Unknown -Events $Events) } |
      Should -Throw -ExpectedMessage 'Contract:*schema differs*future*'

    $Missing = New-EvidenceSet -Name 'missing-column' -OpenCloseRows $Rows
    $MissingPath = Join-Path -Path $Missing -ChildPath 'attempts-persist.csv'
    $MissingText = [IO.File]::ReadAllText($MissingPath).Replace(',network_sample_utc', '')
    [IO.File]::WriteAllText($MissingPath, $MissingText, [Text.UTF8Encoding]::new($False))
    { Invoke-Score -Parameters (New-ScoreParameters -EvidencePath $Missing -Events $Events) } |
      Should -Throw -ExpectedMessage 'Contract:*schema differs*'
  }

  It 'T10 parses producer comma CSV with CRLF under de-DE culture' -Tag 'T10' {
    $Evidence = New-EvidenceSet -Name 'de-culture' -OpenCloseRows (New-TestRows -Seconds (7..12))
    ForEach ($Name In @('attempts-openclose.csv', 'attempts-persist.csv', 'smb-samples.jsonl')) {
      $Bytes = [IO.File]::ReadAllBytes((Join-Path -Path $Evidence -ChildPath $Name))
      $HasUtf8Bom = $Bytes.Length -ge 3 -and $Bytes[0] -eq 0xEF -and $Bytes[1] -eq 0xBB -and $Bytes[2] -eq 0xBF
      $HasUtf8Bom | Should -BeFalse
      For ($Index = 0; $Index -lt $Bytes.Length; $Index++) {
        If ($Bytes[$Index] -eq 0x0A) {
          $Index | Should -BeGreaterThan 0
          $Bytes[$Index - 1] | Should -Be 0x0D
        }
      }
    }
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    [Threading.Thread]::CurrentThread.CurrentUICulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 10)
    $Result = Invoke-Score -Parameters (New-ScoreParameters -EvidencePath $Evidence -Events $Events)
    $Result.Output.contract | Should -BeExactly 'pass'
  }

  It 'T11 applies unplanned limits to an unplanned event' -Tag 'T11' {
    $Evidence = New-EvidenceSet -Name 'kind-limits' -OpenCloseRows (New-TestRows -Seconds @(8, 9, 10, 17))
    $Events = @(New-TestEvent -Name 'E1' -Kind 'unplanned' -Second 10)
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events -PlannedGapSeconds 10 -UnplannedGapSeconds 5
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*E1/openclose/gap measured=7 limit=5*'
  }

  It 'T12 has a clean Windows PowerShell 5.1 syntax guard' -Tag 'T12' {
    $Tokens = $Null
    $ParseErrors = $Null
    $Ast = [Management.Automation.Language.Parser]::ParseFile($script:ScriptPath, [ref]$Tokens, [ref]$ParseErrors)
    @($ParseErrors).Count | Should -Be 0
    $Violations = @($Ast.FindAll({
          Param ($Node)
          $Node -is [Management.Automation.Language.FunctionDefinitionAst] -or
          $Node.GetType().Name -in @('PipelineChainAst', 'TernaryExpressionAst')
        }, $True))
    $Violations.Count | Should -Be 0
    $script:SourceText | Should -Not -Match '\?\?'
    $script:SourceText | Should -Not -Match 'ForEach-Object\s+-Parallel'

    $BadTokens = $Null
    $BadErrors = $Null
    $BadAst = [Management.Automation.Language.Parser]::ParseInput('$value = $true ? 1 : 0', [ref]$BadTokens, [ref]$BadErrors)
    @($BadAst.FindAll({ Param ($Node) $Node.GetType().Name -eq 'TernaryExpressionAst' }, $True)).Count | Should -Be 1
  }

  It 'T13 keeps both published pair files ASCII-only' -Tag 'T13' {
    ForEach ($Path In @($script:ScriptPath, $PSCommandPath)) {
      $Bytes = [IO.File]::ReadAllBytes($Path)
      @($Bytes | Where-Object -FilterScript { $PSItem -gt 0x7F }).Count | Should -Be 0
    }
  }

  It 'T14 rejects an in-flight row after a post-marker success' -Tag 'T14' {
    $OpenRows = @(
      New-TestRow -Second 7
      New-TestRow -Second 8
      New-TestRow -Second 9
      New-TestRow -Second 10
      New-TestRow -Second 11 -Outcome 'in_flight'
    )
    $Evidence = New-EvidenceSet -Name 'trailing-in-flight' -OpenCloseRows $OpenRows -PersistRows (New-TestRows -Seconds (7..11))
    $Events = @(New-TestEvent -Name 'E1' -Kind 'planned' -Second 10)
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*E1/openclose/in_flight measured=1 limit=0*'
  }

  It 'T15 measures the first in-window success from its preceding cross-marker success' -Tag 'T15' {
    $Rows = New-TestRows -Seconds @(8, 9, 19, 21, 22)
    $Evidence = New-EvidenceSet -Name 'one-success-window' -OpenCloseRows $Rows
    $Events = @(
      New-TestEvent -Name 'E1' -Kind 'planned' -Second 10
      New-TestEvent -Name 'E2' -Kind 'unplanned' -Second 20
    )
    $Parameters = New-ScoreParameters -EvidencePath $Evidence -Events $Events -PlannedGapSeconds 5 -UnplannedGapSeconds 5
    { Invoke-Score -Parameters $Parameters } | Should -Throw -ExpectedMessage 'Contract:*E1/openclose/gap measured=10 limit=5*'
  }
}
