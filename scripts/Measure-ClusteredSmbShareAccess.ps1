#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Measures timed read and write access to a clustered SMB share.

    .DESCRIPTION
        Runs independent open-close and persistent-handle loops, samples DNS and SMB client
        state, and preserves attempt, process, terminal, and event evidence. Share access
        failures are rows; probe machinery failures terminate the script.

    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER DurationSeconds
        Probe duration from 1 through 86400 seconds.
    .PARAMETER EvidencePath
        New local directory that receives the evidence files.
    .PARAMETER IntervalSeconds
        Attempt and observation interval from 0.1 through 60 seconds.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER RunId
        Unique run identifier used in the probe-owned share leaf.
    .PARAMETER ServerName
        Clustered SMB server name used for DNS and SMB observations.
    .PARAMETER SharePath
        Existing share root. A local directory is accepted only for pair tests.

    .OUTPUTS
        System.Object
#>
[CmdletBinding(
  ConfirmImpact = 'None',
  DefaultParameterSetName = 'default',
  HelpUri = '',
  PositionalBinding = $False,
  RemotingCapability = 'PowerShell',
  SupportsPaging = $False,
  SupportsShouldProcess = $False
)]
[OutputType([System.Object])]
Param (
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(1, 86400)]
  [System.Int32]
  $DurationSeconds,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $EvidencePath,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(0.1, 60.0)]
  [System.Double]
  $IntervalSeconds,

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]{0,63}$')]
  [System.String]
  $RunId,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9.-]*$')]
  [System.String]
  $ServerName,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $SharePath
)

#region ------ [ Script ] -------------------------------------------------------------------- #

#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'

[System.String[]]$Private:LogLevels = @(
  'Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal'
)
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Force -Verbose:$False -Name:('{0}Preference' -f $LogLevels[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}
$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse(
  $DebugLevel.Substring(0, 1)
)
Switch ($DebugLevel.Substring(1, 1)) {
  '0' { Set-PSDebug -Off }
  '1' { Set-PSDebug -Trace:1 }
  '2' { Set-PSDebug -Trace:2 }
  '3' { Set-PSDebug -Trace:1 -Step }
  '4' { Set-PSDebug -Trace:2 -Step }
}
If ($DebugLevel.Substring(2, 1) -eq '0') {
  Set-StrictMode -Off
} Else {
  Set-StrictMode -Version:([System.String]$DebugLevel.Substring(2, 1))
}
Trap {
  Try {
    If ($PSItem.Exception.PSObject.Properties.Name -contains 'ErrorRecord') {
      Write-Debug -Message:('Failed to execute command: {0}' -f [System.String]$PSItem.Exception.ErrorRecord.InvocationInfo.Line)
    }
    Write-Warning -Message:('[{0:0000}] {1} [{2}]' -f @(
        [System.Int64]$PSItem.InvocationInfo.ScriptLineNumber
        [System.String]$PSItem.Exception.Message
        [System.String]$PSItem.Exception.GetBaseException().GetType().FullName
      ))
  } Catch {
    Write-Debug -Message:'Trap diagnostics unavailable for this error record.'
  }
  Break
}

$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $False; Failed = $False; Result = $Null }
}
$Ansible.Changed = $True
$Ansible.Failed = $False

$OpenCloseAttempt = Get-Variable -Name:'MeasureClusteredSmbShareAccessOpenCloseAttempt' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $OpenCloseAttempt) {
  $OpenCloseAttempt = {
    Param ($Context, $State)
    $Payload = '{0}|{1}|{2}' -f @(
      $Context.RunId
      $Context.Attempt
      [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
    )
    $CurrentPath = [IO.Path]::Combine($Context.Directory, ('oc-{0}.txt' -f $Context.Attempt))
    [IO.File]::WriteAllText($CurrentPath, $Payload, [Text.UTF8Encoding]::new($False))
    $Readback = [IO.File]::ReadAllText($CurrentPath, [Text.UTF8Encoding]::new($False))
    If ($Readback -cne $Payload) {
      Throw 'Open-close byte readback differed from the write.'
    }
    If ($Context.Attempt -gt 1) {
      $PreviousPath = [IO.Path]::Combine($Context.Directory, ('oc-{0}.txt' -f ($Context.Attempt - 1)))
      If ([IO.File]::Exists($PreviousPath)) {
        [IO.File]::Delete($PreviousPath)
      }
    }
    $State['openclose_default_calls'] = [Int32]$State['openclose_default_calls'] + 1
  }
}
$PersistAttempt = Get-Variable -Name:'MeasureClusteredSmbShareAccessPersistAttempt' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $PersistAttempt) {
  $PersistAttempt = {
    Param ($Context, $State)
    If ($Null -eq $State['persist_stream']) {
      $PersistPath = [IO.Path]::Combine($Context.Directory, 'p.txt')
      $State['persist_stream'] = [IO.FileStream]::new(
        $PersistPath,
        [IO.FileMode]::CreateNew,
        [IO.FileAccess]::ReadWrite,
        [IO.FileShare]::ReadWrite,
        4096,
        [IO.FileOptions]::WriteThrough
      )
    }
    $Payload = [Text.UTF8Encoding]::new($False).GetBytes(('{0}|{1}|{2}`r`n' -f @(
          $Context.RunId
          $Context.Attempt
          [DateTime]::UtcNow.ToString('o', [Globalization.CultureInfo]::InvariantCulture)
        )))
    $State['persist_stream'].Write($Payload, 0, $Payload.Length)
    $State['persist_stream'].Flush($True)
    $State['persist_default_calls'] = [Int32]$State['persist_default_calls'] + 1
  }
}
$ObservationSource = Get-Variable -Name:'MeasureClusteredSmbShareAccessObservation' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $ObservationSource) {
  $ObservationSource = {
    Param ($DnsQuery, $ServerName, $State)
    $DnsAnswers = @(Resolve-DnsName @DnsQuery)
    $DnsRecords = @($DnsAnswers | Where-Object -FilterScript { $PSItem.PSObject.Properties.Name -contains 'IPAddress' } | ForEach-Object -Process { [System.String]$PSItem.IPAddress })
    $Multichannel = @(Get-SmbMultichannelConnection -ServerName $ServerName -ErrorAction Stop)
    $Connections = @(Get-SmbConnection -ServerName $ServerName -ErrorAction Stop)
    $State['observation_default_calls'] = [Int32]$State['observation_default_calls'] + 1
    [PSCustomObject]@{
      continuously_available = [Boolean]($Connections.Count -gt 0 -and @($Connections | Where-Object -FilterScript { $PSItem.ContinuouslyAvailable }).Count -eq $Connections.Count)
      dns_a_records          = [String[]]$DnsRecords
      server_ip              = [String]$(If ($Multichannel.Count -gt 0) { $Multichannel[0].ServerIpAddress })
    }
  }
}
$InjectedState = Get-Variable -Name:'MeasureClusteredSmbShareAccessState' -ValueOnly -ErrorAction:'SilentlyContinue'
$TerminalAppend = Get-Variable -Name:'MeasureClusteredSmbShareAccessTerminalAppend' -ValueOnly -ErrorAction:'SilentlyContinue'

$LoopSource = {
  Param (
    $LoopName,
    $AttemptSource,
    $RunId,
    $LoopDirectory,
    $IntervalMilliseconds,
    $State,
    $Writer,
    $WriterLock,
    $TerminalState
  )
  Set-StrictMode -Version 3.0
  $ErrorActionPreference = 'Stop'
  $Culture = [Globalization.CultureInfo]::InvariantCulture
  $AttemptBlock = [ScriptBlock]::Create($AttemptSource)
  $Attempt = 0
  Try {
    While (-not [Boolean]$State['stop_requested']) {
      $Attempt++
      $Timestamp = [DateTime]::UtcNow
      $TimestampText = $Timestamp.ToString('o', $Culture)
      $Timer = [Diagnostics.Stopwatch]::StartNew()
      $Operation = $(If ($LoopName -eq 'openclose') { 'write_read_close' } Else { 'append_flush' })
      $State[('{0}_inflight' -f $LoopName)] = [PSCustomObject]@{
        attempt     = $Attempt
        op          = $Operation
        started_utc = $TimestampText
        stopwatch   = $Timer
      }
      $Outcome = 'success'
      $ExceptionType = ''
      $ExceptionHResult = ''
      $ExceptionMessage = ''
      Try {
        & $AttemptBlock ([PSCustomObject]@{
            Attempt   = $Attempt
            Directory = $LoopDirectory
            Loop      = $LoopName
            RunId     = $RunId
          }) $State
      } Catch {
        $BaseException = $PSItem.Exception.GetBaseException()
        $Outcome = 'failure'
        $ExceptionType = $BaseException.GetType().FullName
        $ExceptionHResult = '0x{0:X8}' -f $BaseException.HResult
        $ExceptionMessage = ([String]$BaseException.Message -replace '[\r\n]+', ' ')
        If ($ExceptionMessage.Length -gt 512) {
          $ExceptionMessage = $ExceptionMessage.Substring(0, 512)
        }
      }
      $Timer.Stop()
      [Threading.Monitor]::Enter($WriterLock)
      Try {
        If (-not [Boolean]$TerminalState['terminal_written']) {
          $DnsText = [String]$(If ($Null -ne $State['dns_a_records']) { @($State['dns_a_records']) -join ';' })
          $Row = [PSCustomObject][Ordered]@{
            timestamp_utc      = $TimestampText
            loop               = $LoopName
            attempt            = $Attempt.ToString($Culture)
            op                 = $Operation
            elapsed_ms         = $Timer.ElapsedMilliseconds.ToString($Culture)
            outcome            = $Outcome
            exception_type     = $ExceptionType
            exception_hresult  = $ExceptionHResult
            exception_message  = $ExceptionMessage
            dns_a_records      = $DnsText
            server_ip          = [String]$State['server_ip']
            network_sample_utc = [String]$State['network_sample_utc']
          }
          $CsvLine = @($Row | ConvertTo-Csv -Delimiter ',' -NoTypeInformation)[1]
          $Writer.WriteLine($CsvLine)
          $Writer.Flush()
          $State[('{0}_rows' -f $LoopName)] = [Int32]$State[('{0}_rows' -f $LoopName)] + 1
          $State[('{0}_attempts' -f $LoopName)] = $Attempt
          If ($Outcome -eq 'failure') {
            $State[('{0}_failures' -f $LoopName)] = [Int32]$State[('{0}_failures' -f $LoopName)] + 1
            If ([String]::IsNullOrEmpty([String]$State[('{0}_first_failure_utc' -f $LoopName)])) {
              $State[('{0}_first_failure_utc' -f $LoopName)] = $TimestampText
            }
            $State[('{0}_last_failure_utc' -f $LoopName)] = $TimestampText
          }
          If ($Timer.ElapsedMilliseconds -gt [Int64]$State[('{0}_max_elapsed_ms' -f $LoopName)]) {
            $State[('{0}_max_elapsed_ms' -f $LoopName)] = $Timer.ElapsedMilliseconds
          }
        }
      } Finally {
        [Threading.Monitor]::Exit($WriterLock)
      }
      $State[('{0}_inflight' -f $LoopName)] = $Null
      If ([Boolean]$State[('{0}_force_end' -f $LoopName)]) {
        Throw ('Forced {0} loop completion.' -f $LoopName)
      }
      $Remaining = $IntervalMilliseconds - [Int32][Math]::Min([Int64]::MaxValue, $Timer.ElapsedMilliseconds)
      If ($Remaining -gt 0 -and -not [Boolean]$State['stop_requested']) {
        [Threading.Thread]::Sleep($Remaining)
      }
    }
  } Finally {
    If ($LoopName -eq 'persist' -and $Null -ne $State['persist_stream']) {
      $State['persist_stream'].Dispose()
      $State['persist_stream'] = $Null
    }
    $State[('{0}_released' -f $LoopName)] = $True
  }
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

$InvariantCulture = [Globalization.CultureInfo]::InvariantCulture
$StartedUtc = [DateTime]::UtcNow
$StartedText = $StartedUtc.ToString('o', $InvariantCulture)
$ProcessId = $PID
$ProcessStartedText = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o', $InvariantCulture)
$Identity = $(If ($env:OS -eq 'Windows_NT') {
    [Security.Principal.WindowsIdentity]::GetCurrent().Name
  } Else {
    [Environment]::UserName
  })
$PowerShellVersion = $PSVersionTable.PSVersion.ToString()
$LeafName = 'ha-probe-{0}' -f $RunId
$Leaf = [IO.Path]::Combine($SharePath, $LeafName)
$OpenCloseDirectory = [IO.Path]::Combine($Leaf, 'openclose')
$PersistDirectory = [IO.Path]::Combine($Leaf, 'persist')
$SamplesPath = [IO.Path]::Combine($EvidencePath, 'smb-samples.jsonl')
$StopRequestPath = [IO.Path]::Combine($EvidencePath, 'stop.request')
$Utf8 = [Text.UTF8Encoding]::new($False)
$CrLf = "`r`n"
$InFlightGraceSeconds = 120
$ObservationCapMilliseconds = 5000
$IntervalMilliseconds = [Int32][Math]::Max(1, [Math]::Floor($IntervalSeconds * 1000.0))
$CleanupDeferred = $False
$LeafCreated = $False
$EvidenceCreated = $False
$TerminalWritten = $False
$PendingException = $Null
$StopReason = 'deadline'
$Result = $Null
$JsonWriter = $Null
$Observation = $Null
$ObservationAsync = $Null
$ObservationStopAsync = $Null
$ObservationTimedOut = $False
$LoopsStarted = $False
$OpenClosePowerShell = $Null
$OpenCloseAsync = $Null
$PersistPowerShell = $Null
$PersistAsync = $Null
$OpenCloseWriter = $Null
$PersistWriter = $Null
$OpenCloseFile = $Null
$PersistFile = $Null
$OpenCloseLock = [Object]::new()
$PersistLock = [Object]::new()
$OpenCloseTerminal = [Hashtable]::Synchronized(@{ terminal_written = $False })
$PersistTerminal = [Hashtable]::Synchronized(@{ terminal_written = $False })
$StateDefaults = @{
  continuously_available      = $False
  dns_a_records               = @()
  network_sample_utc          = ''
  observation_default_calls   = 0
  openclose_attempts          = 0
  openclose_default_calls     = 0
  openclose_failures          = 0
  openclose_first_failure_utc = ''
  openclose_force_end         = $False
  openclose_inflight          = $Null
  openclose_last_failure_utc  = ''
  openclose_max_elapsed_ms    = [Int64]0
  openclose_released          = $False
  openclose_rows              = 0
  persist_attempts            = 0
  persist_default_calls       = 0
  persist_failures            = 0
  persist_first_failure_utc   = ''
  persist_force_end           = $False
  persist_inflight            = $Null
  persist_last_failure_utc    = ''
  persist_max_elapsed_ms      = [Int64]0
  persist_released            = $False
  persist_rows                = 0
  persist_stream              = $Null
  server_ip                   = ''
  stop_requested              = $False
}
If ($Null -eq $InjectedState) {
  $SharedState = [Hashtable]::Synchronized(@{})
} Else {
  $SharedState = $InjectedState
}
ForEach ($StateKey In @($StateDefaults.Keys)) {
  If (-not $SharedState.ContainsKey($StateKey)) {
    $SharedState[$StateKey] = $StateDefaults[$StateKey]
  }
}

If ($EvidencePath -match '^\\\\' -or -not [IO.Path]::IsPathRooted($EvidencePath)) {
  Throw ('Precondition: EvidencePath must be an absolute local path: {0}' -f $EvidencePath)
}
If ($SharePath -match '^\\\\([^\\]+)\\') {
  $ShareHost = $Matches[1].Split('.')[0]
  $ServerLabel = $ServerName.Split('.')[0]
  If ($ShareHost -ine $ServerLabel) {
    Throw ('Precondition: SharePath host {0} does not match ServerName {1}.' -f @($ShareHost, $ServerName))
  }
}
Try {
  $ExistingLeaves = @([IO.Directory]::GetDirectories($SharePath, $LeafName))
} Catch {
  $BaseException = $PSItem.Exception.GetBaseException()
  Throw ('Precondition: cannot inspect SharePath as {0}: {1} [0x{2:X8}] {3}' -f @(
      $Identity
      $BaseException.GetType().FullName
      $BaseException.HResult
      $BaseException.Message
    ))
}
If ($ExistingLeaves.Count -ne 0) {
  Throw ('Precondition: probe leaf already exists: {0}' -f $Leaf)
}
If ([IO.Directory]::Exists($EvidencePath) -or [IO.File]::Exists($EvidencePath)) {
  Throw ('Precondition: EvidencePath already exists: {0}' -f $EvidencePath)
}

Try {
  [IO.Directory]::CreateDirectory($Leaf) | Out-Null
  $LeafCreated = $True
  [IO.Directory]::CreateDirectory($OpenCloseDirectory) | Out-Null
  [IO.Directory]::CreateDirectory($PersistDirectory) | Out-Null
  $CanaryPath = [IO.Path]::Combine($Leaf, 'canary.txt')
  $CanaryBytes = $Utf8.GetBytes(('canary|{0}' -f $RunId))
  [IO.File]::WriteAllBytes($CanaryPath, $CanaryBytes)
  $CanaryReadback = [IO.File]::ReadAllBytes($CanaryPath)
  If ([Convert]::ToBase64String($CanaryReadback) -cne [Convert]::ToBase64String($CanaryBytes)) {
    Throw 'Canary byte readback differed from the write.'
  }
  [IO.File]::Delete($CanaryPath)
} Catch {
  $BaseException = $PSItem.Exception.GetBaseException()
  If ($LeafCreated) {
    Try { [IO.Directory]::Delete($Leaf, $True) } Catch { Write-Debug -Message:'Canary rollback could not delete the probe leaf.' }
  }
  If ([IO.Directory]::Exists($Leaf)) {
    Throw ('Precondition: canary failed and rollback left the probe leaf: {0}' -f $Leaf)
  }
  Throw ('Precondition: canary failed as {0}: {1} [0x{2:X8}] {3}' -f @(
      $Identity
      $BaseException.GetType().FullName
      $BaseException.HResult
      $BaseException.Message
    ))
}

$EvidenceParent = [IO.Path]::GetDirectoryName($EvidencePath)
If (-not [String]::IsNullOrEmpty($EvidenceParent)) {
  [IO.Directory]::CreateDirectory($EvidenceParent) | Out-Null
}
[IO.Directory]::CreateDirectory($EvidencePath) | Out-Null
$EvidenceCreated = $True
$JsonFile = [IO.FileStream]::new($SamplesPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
$JsonWriter = [IO.StreamWriter]::new($JsonFile, $Utf8)
$JsonWriter.NewLine = $CrLf
$ProcessRecord = [Ordered]@{
  kind                = 'process'
  process_id          = $ProcessId
  process_started_utc = $ProcessStartedText
  run_id              = $RunId
  run_leaf            = $Leaf
}
$JsonWriter.WriteLine((ConvertTo-Json -InputObject:$ProcessRecord -Compress -Depth:6))
$JsonWriter.Flush()

Try {
  $CsvHeader = 'timestamp_utc,loop,attempt,op,elapsed_ms,outcome,exception_type,exception_hresult,exception_message,dns_a_records,server_ip,network_sample_utc'
  $OpenCloseCsvPath = [IO.Path]::Combine($EvidencePath, 'attempts-openclose.csv')
  $PersistCsvPath = [IO.Path]::Combine($EvidencePath, 'attempts-persist.csv')
  $OpenCloseFile = [IO.FileStream]::new($OpenCloseCsvPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
  $OpenCloseWriter = [IO.StreamWriter]::new($OpenCloseFile, $Utf8)
  $OpenCloseWriter.NewLine = $CrLf
  $OpenCloseWriter.WriteLine($CsvHeader)
  $OpenCloseWriter.Flush()
  $PersistFile = [IO.FileStream]::new($PersistCsvPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
  $PersistWriter = [IO.StreamWriter]::new($PersistFile, $Utf8)
  $PersistWriter.NewLine = $CrLf
  $PersistWriter.WriteLine($CsvHeader)
  $PersistWriter.Flush()

  $RunTimer = [Diagnostics.Stopwatch]::StartNew()
  $NextTickMilliseconds = [Int64]0
  While ($RunTimer.Elapsed.TotalSeconds -lt $DurationSeconds) {
    If ([IO.File]::Exists($StopRequestPath)) {
      $StopReason = 'request'
      Break
    }

    If ($LoopsStarted) {
      ForEach ($LoopHandle In @(
          [PSCustomObject]@{ Async = $OpenCloseAsync; Name = 'openclose'; PowerShell = $OpenClosePowerShell }
          [PSCustomObject]@{ Async = $PersistAsync; Name = 'persist'; PowerShell = $PersistPowerShell }
        )) {
        If ($LoopHandle.Async.IsCompleted -and -not [Boolean]$SharedState['stop_requested']) {
          $FirstError = $(If ($LoopHandle.PowerShell.Streams.Error.Count -gt 0) {
              $LoopHandle.PowerShell.Streams.Error[0].Exception.GetBaseException().Message
            } Else {
              'the invocation completed without an error record'
            })
          $PendingException = [InvalidOperationException]::new(('Probe: loop {0} ended before the deadline: {1}' -f @(
                $LoopHandle.Name
                $FirstError
              )))
          Break
        }
      }
      If ($Null -ne $PendingException) {
        Break
      }
    }

    $SampleError = ''
    $SampleNow = [DateTime]::UtcNow
    If ($Null -eq $Observation) {
      $DnsQuery = @{ Name = $ServerName; Type = 'A' }
      $Observation = [PowerShell]::Create()
      $Null = $Observation.AddScript($ObservationSource.ToString()).AddArgument($DnsQuery).AddArgument($ServerName).AddArgument($SharedState)
      $ObservationAsync = $Observation.BeginInvoke()
      If ($Null -ne $InjectedState) {
        $InjectedState['observation_async'] = $ObservationAsync
      }
      $ObservationTimedOut = $False
      $ObservationStarted = [Diagnostics.Stopwatch]::StartNew()
    }

    If ($ObservationAsync.IsCompleted) {
      Try {
        $ObservationOutput = @($Observation.EndInvoke($ObservationAsync))
        If ($ObservationOutput.Count -gt 0) {
          $ObservationValue = $ObservationOutput[0]
          $SharedState['continuously_available'] = [Boolean]$ObservationValue.continuously_available
          $SharedState['dns_a_records'] = @($ObservationValue.dns_a_records)
          $SharedState['server_ip'] = [String]$ObservationValue.server_ip
          $SharedState['network_sample_utc'] = $SampleNow.ToString('o', $InvariantCulture)
        }
      } Catch {
        $SampleError = $PSItem.Exception.GetBaseException().Message
      }
      $Observation.Dispose()
      $Observation = $Null
      $ObservationAsync = $Null
      $NextTickMilliseconds = $RunTimer.ElapsedMilliseconds + $IntervalMilliseconds
    } ElseIf ($ObservationStarted.ElapsedMilliseconds -ge $ObservationCapMilliseconds -and -not $ObservationTimedOut) {
      $SampleError = 'timeout'
      $ObservationTimedOut = $True
      $ObservationStopAsync = $Observation.BeginStop($Null, $Null)
    }

    $OpenCloseInFlight = $SharedState['openclose_inflight']
    $PersistInFlight = $SharedState['persist_inflight']
    $SampleRecord = [Ordered]@{
      kind                   = 'sample'
      timestamp_utc          = $SampleNow.ToString('o', $InvariantCulture)
      sample_error           = $SampleError
      continuously_available = [Boolean]$SharedState['continuously_available']
      dns_a_records          = @($SharedState['dns_a_records'])
      server_ip              = [String]$SharedState['server_ip']
      network_sample_utc     = [String]$SharedState['network_sample_utc']
      openclose_attempt      = $(If ($Null -ne $OpenCloseInFlight) { $OpenCloseInFlight.attempt })
      openclose_op           = $(If ($Null -ne $OpenCloseInFlight) { $OpenCloseInFlight.op } Else { '' })
      openclose_in_flight_ms = $(If ($Null -ne $OpenCloseInFlight) { $OpenCloseInFlight.stopwatch.ElapsedMilliseconds } Else { 0 })
      persist_attempt        = $(If ($Null -ne $PersistInFlight) { $PersistInFlight.attempt })
      persist_op             = $(If ($Null -ne $PersistInFlight) { $PersistInFlight.op } Else { '' })
      persist_in_flight_ms   = $(If ($Null -ne $PersistInFlight) { $PersistInFlight.stopwatch.ElapsedMilliseconds } Else { 0 })
    }
    $JsonWriter.WriteLine((ConvertTo-Json -InputObject:$SampleRecord -Compress -Depth:6))
    $JsonWriter.Flush()

    If (-not $LoopsStarted) {
      $OpenClosePowerShell = [PowerShell]::Create()
      $Null = $OpenClosePowerShell.AddScript($LoopSource.ToString()).AddArgument('openclose').AddArgument($OpenCloseAttempt.ToString()).AddArgument($RunId).AddArgument($OpenCloseDirectory).AddArgument($IntervalMilliseconds).AddArgument($SharedState).AddArgument($OpenCloseWriter).AddArgument($OpenCloseLock).AddArgument($OpenCloseTerminal)
      $OpenCloseAsync = $OpenClosePowerShell.BeginInvoke()
      $PersistPowerShell = [PowerShell]::Create()
      $Null = $PersistPowerShell.AddScript($LoopSource.ToString()).AddArgument('persist').AddArgument($PersistAttempt.ToString()).AddArgument($RunId).AddArgument($PersistDirectory).AddArgument($IntervalMilliseconds).AddArgument($SharedState).AddArgument($PersistWriter).AddArgument($PersistLock).AddArgument($PersistTerminal)
      $PersistAsync = $PersistPowerShell.BeginInvoke()
      $LoopsStarted = $True
    }

    If ([IO.File]::Exists($StopRequestPath)) {
      $StopReason = 'request'
      Break
    }
    If ($RunTimer.Elapsed.TotalSeconds -ge $DurationSeconds) {
      Break
    }
    If ($Null -ne $Observation -and -not $ObservationAsync.IsCompleted) {
      [Threading.Thread]::Sleep([Math]::Min(1000, $IntervalMilliseconds))
      If ([IO.File]::Exists($StopRequestPath)) {
        $StopReason = 'request'
        Break
      }
    } ElseIf ($RunTimer.ElapsedMilliseconds -lt $NextTickMilliseconds) {
      [Threading.Thread]::Sleep([Math]::Min(100, [Int32]($NextTickMilliseconds - $RunTimer.ElapsedMilliseconds)))
    }
  }

  $SharedState['stop_requested'] = $True
  $GraceTimer = [Diagnostics.Stopwatch]::StartNew()
  $GraceDeadline = [TimeSpan]::FromSeconds($InFlightGraceSeconds)
  While ($LoopsStarted -and $GraceTimer.Elapsed -lt $GraceDeadline -and (-not $OpenCloseAsync.IsCompleted -or -not $PersistAsync.IsCompleted)) {
    [Threading.Thread]::Sleep(50)
  }

  ForEach ($LoopHandle In @(
      [PSCustomObject]@{ Async = $OpenCloseAsync; Lock = $OpenCloseLock; Name = 'openclose'; PowerShell = $OpenClosePowerShell; Terminal = $OpenCloseTerminal; Writer = $OpenCloseWriter }
      [PSCustomObject]@{ Async = $PersistAsync; Lock = $PersistLock; Name = 'persist'; PowerShell = $PersistPowerShell; Terminal = $PersistTerminal; Writer = $PersistWriter }
    )) {
    If (-not $LoopsStarted) {
      Continue
    }
    If ($LoopHandle.Async.IsCompleted) {
      Try { $Null = $LoopHandle.PowerShell.EndInvoke($LoopHandle.Async) } Catch {
        $SecondaryException = $PSItem.Exception.GetBaseException()
        If ($Null -eq $PendingException) {
          $PendingException = $SecondaryException
        } Else {
          Write-Warning ('Probe: secondary shutdown failure: {0}' -f $SecondaryException.Message)
        }
      }
      [Threading.Monitor]::Enter($LoopHandle.Lock)
      Try { $LoopHandle.Writer.Dispose() } Finally { [Threading.Monitor]::Exit($LoopHandle.Lock) }
    } Else {
      $ShutdownLockGate = $SharedState[('{0}_shutdown_lock_gate' -f $LoopHandle.Name)]
      If ($Null -ne $ShutdownLockGate) {
        $SharedState[('{0}_shutdown_lock_gate_reached' -f $LoopHandle.Name)] = $True
        $Null = $ShutdownLockGate.WaitOne()
      }
      [Threading.Monitor]::Enter($LoopHandle.Lock)
      Try {
        If (-not $LoopHandle.Async.IsCompleted) {
          $LoopHandle.Terminal['terminal_written'] = $True
          $StopAsync = $LoopHandle.PowerShell.BeginStop($Null, $Null)
          $Null = $StopAsync
          $InFlight = $SharedState[('{0}_inflight' -f $LoopHandle.Name)]
          $TerminalElapsed = [Int64]$(If ($Null -ne $InFlight) { $InFlight.stopwatch.ElapsedMilliseconds } Else { 0 })
          $TerminalTimestamp = [String]$(If ($Null -ne $InFlight) { $InFlight.started_utc } Else { [DateTime]::UtcNow.ToString('o', $InvariantCulture) })
          $TerminalAttempt = [Int32]$(If ($Null -ne $InFlight) { $InFlight.attempt } Else { [Int32]$SharedState[('{0}_attempts' -f $LoopHandle.Name)] + 1 })
          $TerminalOperation = [String]$(If ($Null -ne $InFlight) { $InFlight.op } Else { '' })
          $TerminalRow = [PSCustomObject][Ordered]@{
            timestamp_utc      = $TerminalTimestamp
            loop               = $LoopHandle.Name
            attempt            = $TerminalAttempt.ToString($InvariantCulture)
            op                 = $TerminalOperation
            elapsed_ms         = $TerminalElapsed.ToString($InvariantCulture)
            outcome            = 'in_flight'
            exception_type     = ''
            exception_hresult  = ''
            exception_message  = ''
            dns_a_records      = @($SharedState['dns_a_records']) -join ';'
            server_ip          = [String]$SharedState['server_ip']
            network_sample_utc = [String]$SharedState['network_sample_utc']
          }
          $TerminalCsvLine = @($TerminalRow | ConvertTo-Csv -Delimiter ',' -NoTypeInformation)[1]
          $LoopHandle.Writer.WriteLine($TerminalCsvLine)
          $LoopHandle.Writer.Flush()
          $SharedState[('{0}_rows' -f $LoopHandle.Name)] = [Int32]$SharedState[('{0}_rows' -f $LoopHandle.Name)] + 1
          $SharedState[('{0}_attempts' -f $LoopHandle.Name)] = $TerminalAttempt
          $SharedState[('{0}_in_flight_at_stop' -f $LoopHandle.Name)] = $True
          If ($TerminalElapsed -gt [Int64]$SharedState[('{0}_max_elapsed_ms' -f $LoopHandle.Name)]) {
            $SharedState[('{0}_max_elapsed_ms' -f $LoopHandle.Name)] = $TerminalElapsed
          }
          $LoopHandle.Writer.Dispose()
          $CleanupDeferred = $True
        } Else {
          Try { $Null = $LoopHandle.PowerShell.EndInvoke($LoopHandle.Async) } Catch {
            $SecondaryException = $PSItem.Exception.GetBaseException()
            If ($Null -eq $PendingException) {
              $PendingException = $SecondaryException
            } Else {
              Write-Warning ('Probe: secondary shutdown failure: {0}' -f $SecondaryException.Message)
            }
          }
          $LoopHandle.Writer.Dispose()
        }
      } Finally {
        [Threading.Monitor]::Exit($LoopHandle.Lock)
      }
    }
  }

  If ($Null -ne $Observation) {
    If ($ObservationAsync.IsCompleted) {
      Try { $Null = $Observation.EndInvoke($ObservationAsync) } Catch { Write-Debug -Message:'The final observation ended with an error.' }
      $Observation.Dispose()
      $Observation = $Null
    } Else {
      If (-not $ObservationTimedOut) {
        $ObservationStopAsync = $Observation.BeginStop($Null, $Null)
      }
      $Null = $ObservationStopAsync
      $CleanupDeferred = $True
    }
  }

  If (-not $CleanupDeferred) {
    Try {
      [IO.Directory]::Delete($Leaf, $True)
      If ([IO.Directory]::Exists($Leaf)) {
        Throw 'leaf remained after deletion'
      }
    } Catch {
      $SecondaryException = $PSItem.Exception.GetBaseException()
      If ($Null -eq $PendingException) {
        $PendingException = $SecondaryException
      } Else {
        Write-Warning ('Probe: secondary shutdown failure: {0}' -f $SecondaryException.Message)
      }
    }
  }

  $StoppedUtc = [DateTime]::UtcNow
  $EventQuery = '*[System[TimeCreated[@SystemTime>=''{0}'']]]' -f $StartedUtc.AddSeconds(-5).ToString('o', $InvariantCulture)
  $ConnectivityPath = [IO.Path]::Combine($EvidencePath, 'smbclient-connectivity.evtx')
  Try {
    & wevtutil.exe 'epl' 'Microsoft-Windows-SMBClient/Connectivity' $ConnectivityPath ('/q:{0}' -f $EventQuery) '/ow:false'
    $EventExitCode = $LASTEXITCODE
    If ($EventExitCode -ne 0) {
      Throw ('Probe: wevtutil failed for SMBClient/Connectivity with exit code {0}.' -f $EventExitCode)
    }
  } Catch {
    $SecondaryException = $PSItem.Exception.GetBaseException()
    If ($Null -eq $PendingException) {
      $PendingException = $SecondaryException
    } Else {
      Write-Warning ('Probe: secondary shutdown failure: {0}' -f $SecondaryException.Message)
    }
  }
  $OperationalPath = [IO.Path]::Combine($EvidencePath, 'smbclient-operational.evtx')
  Try {
    & wevtutil.exe 'epl' 'Microsoft-Windows-SMBClient/Operational' $OperationalPath ('/q:{0}' -f $EventQuery) '/ow:false'
    $EventExitCode = $LASTEXITCODE
    If ($EventExitCode -ne 0) {
      Throw ('Probe: wevtutil failed for SMBClient/Operational with exit code {0}.' -f $EventExitCode)
    }
  } Catch {
    $SecondaryException = $PSItem.Exception.GetBaseException()
    If ($Null -eq $PendingException) {
      $PendingException = $SecondaryException
    } Else {
      Write-Warning ('Probe: secondary shutdown failure: {0}' -f $SecondaryException.Message)
    }
  }

  $Result = [PSCustomObject][Ordered]@{
    changed            = $True
    check_mode         = $False
    failed             = $False
    msg                = 'Measured clustered SMB share access and preserved the evidence.'
    identity           = $Identity
    process_id         = $ProcessId
    powershell_version = $PowerShellVersion
    server_name        = $ServerName
    share_path         = $SharePath
    run_leaf           = $Leaf
    evidence_path      = $EvidencePath
    started_utc        = $StartedText
    stopped_utc        = $StoppedUtc.ToString('o', $InvariantCulture)
    stop_reason        = $StopReason
    cleanup_deferred   = $CleanupDeferred
    interval_seconds   = $IntervalSeconds
    duration_seconds   = $DurationSeconds
    openclose          = [PSCustomObject]@{
      attempts          = [Int32]$SharedState['openclose_attempts']
      failures          = [Int32]$SharedState['openclose_failures']
      first_failure_utc = [String]$SharedState['openclose_first_failure_utc']
      last_failure_utc  = [String]$SharedState['openclose_last_failure_utc']
      max_elapsed_ms    = [Int64]$SharedState['openclose_max_elapsed_ms']
      in_flight_at_stop = [Boolean]$SharedState['openclose_in_flight_at_stop']
    }
    persist            = [PSCustomObject]@{
      attempts          = [Int32]$SharedState['persist_attempts']
      failures          = [Int32]$SharedState['persist_failures']
      first_failure_utc = [String]$SharedState['persist_first_failure_utc']
      last_failure_utc  = [String]$SharedState['persist_last_failure_utc']
      max_elapsed_ms    = [Int64]$SharedState['persist_max_elapsed_ms']
      in_flight_at_stop = [Boolean]$SharedState['persist_in_flight_at_stop']
    }
  }
  If ($Null -ne $PendingException) {
    Throw $PendingException
  }
} Catch {
  If ($Null -eq $PendingException) { $PendingException = $PSItem.Exception.GetBaseException() }
  Throw $PendingException
} Finally {
  If ($EvidenceCreated -and $Null -ne $JsonWriter -and -not $TerminalWritten) {
    $TerminalRecord = [Ordered]@{
      kind              = 'terminal'
      run_id            = $RunId
      exception_type    = $(If ($Null -ne $PendingException) { $PendingException.GetType().FullName } Else { '' })
      exception_hresult = $(If ($Null -ne $PendingException) { '0x{0:X8}' -f $PendingException.HResult } Else { '' })
      exception_message = $(If ($Null -ne $PendingException) { [String]$PendingException.Message } Else { '' })
      cleanup_deferred  = $CleanupDeferred
    }
    Try {
      If ($Null -ne $TerminalAppend) {
        & $TerminalAppend $JsonWriter
      }
      $JsonWriter.WriteLine((ConvertTo-Json -InputObject:$TerminalRecord -Compress -Depth:6))
      $JsonWriter.Flush()
      $TerminalWritten = $True
    } Catch {
      $BaseException = $PSItem.Exception.GetBaseException()
      If ($Null -eq $PendingException) {
        Throw [InvalidOperationException]::new(('Probe: terminal evidence write failed: {0}' -f $BaseException.Message), $BaseException)
      }
      Write-Warning ('Probe: secondary terminal evidence failure: {0}' -f $BaseException.Message)
    }
  }
  If ($Null -ne $JsonWriter) {
    $JsonWriter.Dispose()
  }
  If ($Null -ne $OpenClosePowerShell -and $OpenCloseAsync.IsCompleted) {
    $OpenClosePowerShell.Dispose()
  }
  If ($Null -ne $PersistPowerShell -and $PersistAsync.IsCompleted) {
    $PersistPowerShell.Dispose()
  }
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $True
$Ansible.Failed = $False
$Ansible.Result = $Result
If ($StandaloneRun) {
  $Result | ConvertTo-Json -Compress -Depth:6
} Else {
  Write-Output -InputObject:$Result
}
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #

#endregion --- [ Script ] -------------------------------------------------------------------- #
