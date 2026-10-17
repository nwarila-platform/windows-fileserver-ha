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
    $Null = $State
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
  Set-StrictMode -Version 3.0
  $ErrorActionPreference = 'Stop'
  $ProgressPreference = 'SilentlyContinue'
  $Culture = [Globalization.CultureInfo]::InvariantCulture
  $LoopName = [String]$env:FSHA_PROBE_LOOP
  $WorkerRunId = [String]$env:FSHA_PROBE_RUN_ID
  $LoopDirectory = [String]$env:FSHA_PROBE_DIRECTORY
  $CsvPath = [String]$env:FSHA_PROBE_CSV
  $MarkerPath = [String]$env:FSHA_PROBE_MARKER
  $WorkerStopRequestPath = [String]$env:FSHA_PROBE_STOP_REQUEST
  $WorkerDeadlineUtc = [DateTime]::Parse([String]$env:FSHA_PROBE_DEADLINE_UTC, $Culture).ToUniversalTime()
  $WorkerIntervalMilliseconds = [Int32]::Parse([String]$env:FSHA_PROBE_INTERVAL_MS, $Culture)
  $SupervisorPid = [Int32]::Parse([String]$env:FSHA_PROBE_SUPERVISOR_PID, $Culture)
  $SupervisorStartedUtc = [String]$env:FSHA_PROBE_SUPERVISOR_STARTED_UTC
  $HoldAfterRowPath = [String]$env:FSHA_PROBE_HOLD_AFTER_ROW
  $WatchdogSource = @'
using System;
using System.Diagnostics;
using System.Globalization;
using System.Threading;

public static class FsHaProbeSupervisorWatchdog
{
    public static void Start(int supervisorPid, string supervisorStartedUtc)
    {
        Thread watchdog = new Thread(delegate()
        {
            DateTime expected = DateTime.Parse(supervisorStartedUtc, CultureInfo.InvariantCulture).ToUniversalTime();
            while (true)
            {
                bool alive = true;
                Process supervisor = null;
                try
                {
                    supervisor = Process.GetProcessById(supervisorPid);
                    DateTime observed = supervisor.StartTime.ToUniversalTime();
                    if (Environment.OSVersion.Platform == PlatformID.Win32NT)
                    {
                        alive = String.Equals(observed.ToString("o", CultureInfo.InvariantCulture), supervisorStartedUtc, StringComparison.Ordinal);
                    }
                    else
                    {
                        alive = Math.Abs((observed - expected).Ticks) < TimeSpan.TicksPerSecond;
                    }
                }
                catch (ArgumentException)
                {
                    alive = false;
                }
                finally
                {
                    if (supervisor != null)
                    {
                        supervisor.Dispose();
                    }
                }
                if (!alive)
                {
                    Environment.Exit(0);
                }
                Thread.Sleep(100);
            }
        });
        watchdog.IsBackground = true;
        watchdog.Start();
    }
}
'@
  $Null = Add-Type -TypeDefinition $WatchdogSource
  [FsHaProbeSupervisorWatchdog]::Start($SupervisorPid, $SupervisorStartedUtc)
  $AttemptSourceText = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('__FSHA_ATTEMPT_BASE64__'))
  $AttemptBlock = [ScriptBlock]::Create($AttemptSourceText)
  $Utf8 = [Text.UTF8Encoding]::new($False)
  $State = @{
    openclose_attempts  = 0
    openclose_failures  = 0
    openclose_force_end = $False
    persist_attempts    = 0
    persist_failures    = 0
    persist_force_end   = $False
    persist_stream      = $Null
  }
  $Attempt = 0
  $CsvStream = $Null
  $WorkerExitCode = 0
  Try {
    $CsvStream = [IO.FileStream]::new(
      $CsvPath,
      [IO.FileMode]::Append,
      [IO.FileAccess]::Write,
      [IO.FileShare]::ReadWrite,
      1
    )
    While ($True) {
      If ([DateTime]::UtcNow -ge $WorkerDeadlineUtc -or [IO.File]::Exists($WorkerStopRequestPath)) {
        Break
      }
      $SupervisorAlive = $True
      Try {
        $Supervisor = [Diagnostics.Process]::GetProcessById($SupervisorPid)
        $ObservedSupervisorStarted = $Supervisor.StartTime.ToUniversalTime()
        If ($env:OS -eq 'Windows_NT') {
          $SupervisorAlive = $ObservedSupervisorStarted.ToString('o', $Culture) -ceq $SupervisorStartedUtc
        } Else {
          $ExpectedSupervisorStarted = [DateTime]::Parse($SupervisorStartedUtc, $Culture).ToUniversalTime()
          $SupervisorAlive = [Math]::Abs(($ObservedSupervisorStarted - $ExpectedSupervisorStarted).Ticks) -lt [TimeSpan]::TicksPerSecond
        }
        $Supervisor.Dispose()
      } Catch [ArgumentException] {
        $SupervisorAlive = $False
      }
      If (-not $SupervisorAlive) {
        Break
      }

      $Attempt++
      $Timestamp = [DateTime]::UtcNow
      $TimestampText = $Timestamp.ToString('o', $Culture)
      $Operation = $(If ($LoopName -eq 'openclose') { 'write_read_close' } Else { 'append_flush' })
      $MarkerText = '{0}|{1}|{2}' -f @($Attempt, $Operation, $TimestampText)
      $MarkerBytes = $Utf8.GetBytes($MarkerText)
      $MarkerStream = [IO.FileStream]::new($MarkerPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
      Try {
        $MarkerStream.Write($MarkerBytes, 0, $MarkerBytes.Length)
        $MarkerStream.Flush()
      } Finally {
        $MarkerStream.Dispose()
      }

      $Timer = [Diagnostics.Stopwatch]::StartNew()
      $Outcome = 'success'
      $ExceptionType = ''
      $ExceptionHResult = ''
      $ExceptionMessage = ''
      $AttemptException = $Null
      Try {
        & $AttemptBlock ([PSCustomObject]@{
            Attempt   = $Attempt
            Directory = $LoopDirectory
            Loop      = $LoopName
            RunId     = $WorkerRunId
          }) $State
      } Catch {
        $AttemptException = $PSItem.Exception.GetBaseException()
        $Outcome = 'failure'
        $ExceptionType = $AttemptException.GetType().FullName
        $ExceptionHResult = '0x{0:X8}' -f $AttemptException.HResult
        $ExceptionMessage = ([String]$AttemptException.Message -replace '[\r\n]+', ' ')
        If ($ExceptionMessage.Length -gt 512) {
          $ExceptionMessage = $ExceptionMessage.Substring(0, 512)
        }
      }
      $Timer.Stop()
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
        dns_a_records      = ''
        server_ip          = ''
        network_sample_utc = ''
      }
      $CsvLine = @($Row | ConvertTo-Csv -Delimiter ',' -NoTypeInformation)[1]
      $RowBytes = $Utf8.GetBytes(("{0}`r`n" -f $CsvLine))
      $CsvStream.Write($RowBytes, 0, $RowBytes.Length)
      $CsvStream.Flush()
      $State[('{0}_attempts' -f $LoopName)] = $Attempt
      If ($Outcome -eq 'failure') {
        $State[('{0}_failures' -f $LoopName)] = [Int32]$State[('{0}_failures' -f $LoopName)] + 1
      }
      If (-not [String]::IsNullOrEmpty($HoldAfterRowPath)) {
        While ([IO.File]::Exists($HoldAfterRowPath)) {
          [Threading.Thread]::Sleep(20)
        }
      }
      $MarkerStream = [IO.FileStream]::new($MarkerPath, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read)
      $MarkerStream.Dispose()
      If ([Boolean]$State[('{0}_force_end' -f $LoopName)]) {
        If ($Null -ne $AttemptException) {
          Throw $AttemptException
        }
        Throw ('Forced {0} loop completion.' -f $LoopName)
      }

      $Remaining = $WorkerIntervalMilliseconds - [Int32][Math]::Min([Int64]::MaxValue, $Timer.ElapsedMilliseconds)
      While ($Remaining -gt 0) {
        If ([DateTime]::UtcNow -ge $WorkerDeadlineUtc -or [IO.File]::Exists($WorkerStopRequestPath)) {
          Break
        }
        $Slice = [Math]::Min(100, $Remaining)
        [Threading.Thread]::Sleep($Slice)
        $Remaining -= $Slice
      }
    }
  } Catch {
    $WorkerException = $PSItem.Exception.GetBaseException()
    $WorkerMessage = ([String]$WorkerException.Message -replace '[\r\n]+', ' ')
    If ($WorkerMessage.Length -gt 512) {
      $WorkerMessage = $WorkerMessage.Substring(0, 512)
    }
    [Console]::Error.WriteLine(('{0} [{1}]' -f @($WorkerMessage, $WorkerException.GetType().FullName)))
    $WorkerExitCode = 1
  } Finally {
    If ($LoopName -eq 'persist' -and $Null -ne $State['persist_stream']) {
      $State['persist_stream'].Dispose()
      $State['persist_stream'] = $Null
    }
    If ($Null -ne $CsvStream) {
      $CsvStream.Dispose()
    }
  }
  Exit $WorkerExitCode
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

$InvariantCulture = [Globalization.CultureInfo]::InvariantCulture
$StartedUtc = [DateTime]::UtcNow
$StartedText = $StartedUtc.ToString('o', $InvariantCulture)
$ProcessId = $PID
$ProcessStartedText = (Get-Process -Id $PID).StartTime.ToUniversalTime().ToString('o', $InvariantCulture)
$WorkerEngine = (Get-Process -Id $PID).Path
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
$OpenCloseMarkerPath = [IO.Path]::Combine($EvidencePath, 'openclose.inflight')
$PersistMarkerPath = [IO.Path]::Combine($EvidencePath, 'persist.inflight')
$Utf8 = [Text.UTF8Encoding]::new($False)
$CrLf = "`r`n"
$InFlightGraceSeconds = $(If ($Null -ne $InjectedState -and $InjectedState.ContainsKey('in_flight_grace_seconds')) {
    [Int32]$InjectedState['in_flight_grace_seconds']
  } Else {
    120
  })
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
$OpenCloseProcess = $Null
$PersistProcess = $Null
$OpenCloseKillRequested = $False
$PersistKillRequested = $False
$OpenCloseStatistics = $Null
$PersistStatistics = $Null
$StateDefaults = @{
  continuously_available    = $False
  dns_a_records             = @()
  network_sample_utc        = ''
  observation_default_calls = 0
  server_ip                 = ''
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
  Try {
    $OpenCloseWriter = [IO.StreamWriter]::new($OpenCloseFile, $Utf8)
    $OpenCloseWriter.NewLine = $CrLf
    $OpenCloseWriter.WriteLine($CsvHeader)
    $OpenCloseWriter.Flush()
    $OpenCloseWriter.Dispose()
  } Finally {
    $OpenCloseFile.Dispose()
  }
  $PersistFile = [IO.FileStream]::new($PersistCsvPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
  Try {
    $PersistWriter = [IO.StreamWriter]::new($PersistFile, $Utf8)
    $PersistWriter.NewLine = $CrLf
    $PersistWriter.WriteLine($CsvHeader)
    $PersistWriter.Flush()
    $PersistWriter.Dispose()
  } Finally {
    $PersistFile.Dispose()
  }

  $RunTimer = [Diagnostics.Stopwatch]::StartNew()
  $RunDeadlineUtc = [DateTime]::UtcNow.AddSeconds($DurationSeconds)
  $NextTickMilliseconds = [Int64]0
  Try {
    While ($RunTimer.Elapsed.TotalSeconds -lt $DurationSeconds) {
      If ([IO.File]::Exists($StopRequestPath)) {
        $StopReason = 'request'
        Break
      }
      If ([DateTime]::UtcNow -ge $RunDeadlineUtc) {
        Break
      }

      ForEach ($LoopHandle In @(
          [PSCustomObject]@{ Name = 'openclose'; Process = $OpenCloseProcess }
          [PSCustomObject]@{ Name = 'persist'; Process = $PersistProcess }
        )) {
        If ($Null -eq $LoopHandle.Process) {
          Continue
        }
        If ($LoopHandle.Process.HasExited -and [DateTime]::UtcNow -lt $RunDeadlineUtc) {
          $LoopHandle.Process.WaitForExit()
          $ErrorText = $LoopHandle.Process.StandardError.ReadToEnd()
          $FirstError = $(If (-not [String]::IsNullOrWhiteSpace($ErrorText)) {
              @($ErrorText -split '[\r\n]+' | Where-Object -FilterScript { -not [String]::IsNullOrWhiteSpace($PSItem) })[0]
            } Else {
              'exit code {0}' -f $LoopHandle.Process.ExitCode
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

      $MarkerStates = @{}
      ForEach ($Marker In @(
          [PSCustomObject]@{ Name = 'openclose'; Path = $OpenCloseMarkerPath }
          [PSCustomObject]@{ Name = 'persist'; Path = $PersistMarkerPath }
        )) {
        $MarkerValue = $Null
        If ([IO.File]::Exists($Marker.Path)) {
          $MarkerFile = [IO.FileStream]::new(
            $Marker.Path,
            [IO.FileMode]::Open,
            [IO.FileAccess]::Read,
            ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
          )
          Try {
            $MarkerReader = [IO.StreamReader]::new($MarkerFile, $Utf8)
            $MarkerText = $MarkerReader.ReadToEnd()
            $MarkerReader.Dispose()
          } Finally {
            $MarkerFile.Dispose()
          }
          If ($MarkerText -match '^(\d+)\|([a-z_]+)\|(.+)$') {
            $MarkerStarted = [DateTime]::MinValue
            If ([DateTime]::TryParse($Matches[3], $InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [Ref]$MarkerStarted)) {
              $MarkerValue = [PSCustomObject]@{
                attempt     = [Int32]::Parse($Matches[1], $InvariantCulture)
                op          = $Matches[2]
                started_utc = $Matches[3]
                age_ms      = [Int64][Math]::Max(0, ([DateTime]::UtcNow - $MarkerStarted.ToUniversalTime()).Ticks / [TimeSpan]::TicksPerMillisecond)
              }
            }
          }
        }
        $MarkerStates[$Marker.Name] = $MarkerValue
      }
      $OpenCloseInFlight = $MarkerStates['openclose']
      $PersistInFlight = $MarkerStates['persist']
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
        openclose_in_flight_ms = $(If ($Null -ne $OpenCloseInFlight) { $OpenCloseInFlight.age_ms } Else { 0 })
        persist_attempt        = $(If ($Null -ne $PersistInFlight) { $PersistInFlight.attempt })
        persist_op             = $(If ($Null -ne $PersistInFlight) { $PersistInFlight.op } Else { '' })
        persist_in_flight_ms   = $(If ($Null -ne $PersistInFlight) { $PersistInFlight.age_ms } Else { 0 })
      }
      $JsonWriter.WriteLine((ConvertTo-Json -InputObject:$SampleRecord -Compress -Depth:6))
      $JsonWriter.Flush()

      If ($Null -eq $OpenCloseProcess -and $Null -eq $PersistProcess) {
        ForEach ($Worker In @(
            [PSCustomObject]@{ Attempt = $OpenCloseAttempt; Csv = $OpenCloseCsvPath; Directory = $OpenCloseDirectory; Marker = $OpenCloseMarkerPath; Name = 'openclose' }
            [PSCustomObject]@{ Attempt = $PersistAttempt; Csv = $PersistCsvPath; Directory = $PersistDirectory; Marker = $PersistMarkerPath; Name = 'persist' }
          )) {
          $AttemptBytes = [Text.Encoding]::Unicode.GetBytes($Worker.Attempt.ToString())
          $AttemptBase64 = [Convert]::ToBase64String($AttemptBytes)
          $WorkerSourceText = $LoopSource.ToString().Replace('__FSHA_ATTEMPT_BASE64__', $AttemptBase64)
          $WorkerBytes = [Text.Encoding]::Unicode.GetBytes($WorkerSourceText)
          $WorkerEncoded = [Convert]::ToBase64String($WorkerBytes)
          $StartInfo = [Diagnostics.ProcessStartInfo]::new()
          $StartInfo.FileName = $WorkerEngine
          $StartInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand {0}' -f $WorkerEncoded
          $StartInfo.UseShellExecute = $False
          $StartInfo.CreateNoWindow = $True
          $StartInfo.RedirectStandardInput = $True
          $StartInfo.RedirectStandardOutput = $True
          $StartInfo.RedirectStandardError = $True
          $StartInfo.EnvironmentVariables['FSHA_PROBE_LOOP'] = $Worker.Name
          $StartInfo.EnvironmentVariables['FSHA_PROBE_RUN_ID'] = $RunId
          $StartInfo.EnvironmentVariables['FSHA_PROBE_DIRECTORY'] = $Worker.Directory
          $StartInfo.EnvironmentVariables['FSHA_PROBE_CSV'] = $Worker.Csv
          $StartInfo.EnvironmentVariables['FSHA_PROBE_MARKER'] = $Worker.Marker
          $StartInfo.EnvironmentVariables['FSHA_PROBE_STOP_REQUEST'] = $StopRequestPath
          $StartInfo.EnvironmentVariables['FSHA_PROBE_DEADLINE_UTC'] = $RunDeadlineUtc.ToString('o', $InvariantCulture)
          $StartInfo.EnvironmentVariables['FSHA_PROBE_INTERVAL_MS'] = $IntervalMilliseconds.ToString($InvariantCulture)
          $StartInfo.EnvironmentVariables['FSHA_PROBE_SUPERVISOR_PID'] = $ProcessId.ToString($InvariantCulture)
          $StartInfo.EnvironmentVariables['FSHA_PROBE_SUPERVISOR_STARTED_UTC'] = $ProcessStartedText
          $HoldAfterRowKey = '{0}_hold_after_row_path' -f $Worker.Name
          $StartInfo.EnvironmentVariables['FSHA_PROBE_HOLD_AFTER_ROW'] = [String]$(If ($SharedState.ContainsKey($HoldAfterRowKey)) { $SharedState[$HoldAfterRowKey] } Else { '' })
          If ($Worker.Name -eq 'persist' -and $SharedState.ContainsKey('persist_launch_exception')) {
            Throw $SharedState['persist_launch_exception']
          }
          $WorkerProcess = [Diagnostics.Process]::new()
          $WorkerProcess.StartInfo = $StartInfo
          If (-not $WorkerProcess.Start()) {
            Throw ('Probe: worker {0} did not start.' -f $Worker.Name)
          }
          If ($Worker.Name -eq 'openclose') {
            $OpenCloseProcess = $WorkerProcess
          } Else {
            $PersistProcess = $WorkerProcess
          }
          $WorkerStartedText = $WorkerProcess.StartTime.ToUniversalTime().ToString('o', $InvariantCulture)
          $WorkerRecord = [Ordered]@{
            kind                = 'worker'
            loop                = $Worker.Name
            process_id          = $WorkerProcess.Id
            process_started_utc = $WorkerStartedText
            run_id              = $RunId
          }
          $JsonWriter.WriteLine((ConvertTo-Json -InputObject:$WorkerRecord -Compress -Depth:6))
          $JsonWriter.Flush()
          $WorkerProcess.StandardInput.Close()
          $WorkerProcess.BeginOutputReadLine()
        }
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
  } Catch {
    $SupervisorException = $PSItem.Exception.GetBaseException()
    If ($Null -eq $PendingException) {
      $PendingException = $SupervisorException
    } Else {
      Write-Warning ('Probe: secondary supervisor failure: {0}' -f $SupervisorException.Message)
    }
  }

  $GraceTimer = [Diagnostics.Stopwatch]::StartNew()
  $GraceDeadline = [TimeSpan]::FromSeconds($(If ($Null -eq $PendingException) { $InFlightGraceSeconds } Else { 0 }))
  $AllWorkersExited = $False
  Try {
    While (-not $AllWorkersExited -and $GraceTimer.Elapsed -lt $GraceDeadline) {
      $AllWorkersExited = $True
      ForEach ($WorkerProcess In @($OpenCloseProcess, $PersistProcess)) {
        If ($Null -ne $WorkerProcess) {
          $WorkerProcess.Refresh()
          If (-not $WorkerProcess.HasExited) {
            $AllWorkersExited = $False
          }
        }
      }
      If (-not $AllWorkersExited) {
        [Threading.Thread]::Sleep(50)
      }
    }
  } Catch {
    $GraceException = $PSItem.Exception.GetBaseException()
    $CleanupDeferred = $True
    If ($Null -eq $PendingException) {
      $PendingException = $GraceException
    } Else {
      Write-Warning ('Probe: secondary shutdown failure: {0}' -f $GraceException.Message)
    }
  }

  ForEach ($LoopHandle In @(
      [PSCustomObject]@{ Csv = $OpenCloseCsvPath; Marker = $OpenCloseMarkerPath; Name = 'openclose'; Process = $OpenCloseProcess }
      [PSCustomObject]@{ Csv = $PersistCsvPath; Marker = $PersistMarkerPath; Name = 'persist'; Process = $PersistProcess }
    )) {
    If ($Null -eq $LoopHandle.Process) {
      Continue
    }
    $ExitProven = $False
    $WorkerShutdownException = $Null
    Try {
      $ShutdownExceptionKey = '{0}_shutdown_exception' -f $LoopHandle.Name
      If ($Null -ne $InjectedState -and $InjectedState.ContainsKey($ShutdownExceptionKey)) {
        Throw $InjectedState[$ShutdownExceptionKey]
      }
      $LoopHandle.Process.Refresh()
      If ($LoopHandle.Process.HasExited) {
        $LoopHandle.Process.WaitForExit()
        $ExitProven = $True
      } Else {
        $CleanupDeferred = $True
        Try {
          $ExitBeforeKillKey = '{0}_exit_before_kill' -f $LoopHandle.Name
          If ($Null -ne $InjectedState -and $InjectedState.ContainsKey($ExitBeforeKillKey)) {
            $ExitBeforeKillGate = [String]$InjectedState[$ExitBeforeKillKey]
            [IO.File]::WriteAllText($StopRequestPath, '')
            If ([IO.File]::Exists($ExitBeforeKillGate)) {
              [IO.File]::Delete($ExitBeforeKillGate)
            }
            $ExitBeforeKillTimer = [Diagnostics.Stopwatch]::StartNew()
            While (-not $LoopHandle.Process.HasExited -and $ExitBeforeKillTimer.Elapsed.TotalSeconds -lt 5) {
              [Threading.Thread]::Sleep(20)
              $LoopHandle.Process.Refresh()
            }
            $InjectedState[('{0}_exit_before_kill_observed' -f $LoopHandle.Name)] = $LoopHandle.Process.HasExited
          }
          If ($LoopHandle.Name -eq 'openclose') {
            $OpenCloseKillRequested = $True
          } Else {
            $PersistKillRequested = $True
          }
          If ($Null -ne $InjectedState) {
            $InjectedState[('{0}_kill_requested' -f $LoopHandle.Name)] = $True
          }
          $LoopHandle.Process.Kill()
          If ($Null -ne $InjectedState) {
            $InjectedState[('{0}_kill_returned' -f $LoopHandle.Name)] = $True
          }
          $KillExceptionKey = '{0}_kill_exception' -f $LoopHandle.Name
          If ($Null -ne $InjectedState -and $InjectedState.ContainsKey($KillExceptionKey)) {
            Throw $InjectedState[$KillExceptionKey]
          }
        } Catch [InvalidOperationException] {
          $TerminationRaceException = $PSItem.Exception.GetBaseException()
          If ($Null -ne $InjectedState) {
            $InjectedState[('{0}_kill_exception_type' -f $LoopHandle.Name)] = $TerminationRaceException.GetType().FullName
          }
          $LoopHandle.Process.Refresh()
          If ($LoopHandle.Process.HasExited) {
            $ExitProven = $True
          } Else {
            $WorkerShutdownException = $TerminationRaceException
          }
        } Catch {
          $WorkerShutdownException = $PSItem.Exception.GetBaseException()
        }
        If ($Null -eq $WorkerShutdownException -and -not $ExitProven) {
          Try {
            $Null = $LoopHandle.Process.WaitForExit(30000)
            $LoopHandle.Process.Refresh()
            If (-not $LoopHandle.Process.HasExited) {
              $WorkerShutdownException = [InvalidOperationException]::new(('Probe: worker {0} did not end after termination' -f $LoopHandle.Name))
            } Else {
              $LoopHandle.Process.WaitForExit()
              $ExitProven = $True
            }
          } Catch {
            $WaitException = $PSItem.Exception.GetBaseException()
            Try {
              $LoopHandle.Process.Refresh()
              If ($LoopHandle.Process.HasExited) {
                $ExitProven = $True
              } Else {
                $WorkerShutdownException = $WaitException
              }
            } Catch {
              $WorkerShutdownException = $WaitException
            }
          }
        }
      }
    } Catch {
      $WorkerShutdownException = $PSItem.Exception.GetBaseException()
    }
    If (-not $ExitProven) {
      $CleanupDeferred = $True
      If ($Null -eq $WorkerShutdownException) {
        $WorkerShutdownException = [InvalidOperationException]::new(('Probe: worker {0} exit could not be proven' -f $LoopHandle.Name))
      }
      If ($Null -eq $PendingException) {
        $PendingException = $WorkerShutdownException
      } Else {
        Write-Warning ('Probe: secondary shutdown failure: {0}' -f $WorkerShutdownException.Message)
      }
      Continue
    }
    Try {
      $TerminationInstant = [DateTime]::UtcNow
      $MarkerText = ''
      If ([IO.File]::Exists($LoopHandle.Marker)) {
        $MarkerFile = [IO.FileStream]::new(
          $LoopHandle.Marker,
          [IO.FileMode]::Open,
          [IO.FileAccess]::Read,
          ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
        )
        Try {
          $MarkerReader = [IO.StreamReader]::new($MarkerFile, $Utf8)
          $MarkerText = $MarkerReader.ReadToEnd()
          $MarkerReader.Dispose()
        } Finally {
          $MarkerFile.Dispose()
        }
      }
      If ($MarkerText -match '^(\d+)\|([a-z_]+)\|(.+)$') {
        $TerminalAttempt = [Int32]::Parse($Matches[1], $InvariantCulture)
        $TerminalOperation = $Matches[2]
        $TerminalTimestamp = $Matches[3]
        $Rows = @(Import-Csv -LiteralPath $LoopHandle.Csv)
        $LastAttempt = $(If ($Rows.Count -gt 0) { [Int32]$Rows[-1].attempt } Else { 0 })
        If ($TerminalAttempt -gt $LastAttempt) {
          $TerminalStarted = [DateTime]::Parse($TerminalTimestamp, $InvariantCulture).ToUniversalTime()
          $TerminalElapsed = [Int64][Math]::Max(0, ($TerminationInstant - $TerminalStarted).Ticks / [TimeSpan]::TicksPerMillisecond)
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
          $TerminalBytes = $Utf8.GetBytes(("{0}`r`n" -f $TerminalCsvLine))
          $TerminalFile = [IO.FileStream]::new(
            $LoopHandle.Csv,
            [IO.FileMode]::Append,
            [IO.FileAccess]::Write,
            [IO.FileShare]::ReadWrite,
            1
          )
          Try {
            $TerminalFile.Write($TerminalBytes, 0, $TerminalBytes.Length)
            $TerminalFile.Flush()
          } Finally {
            $TerminalFile.Dispose()
          }
        }
      }
      $Null = $LoopHandle.Process.StandardError.ReadToEnd()
    } Catch {
      $WorkerFinalizationException = $PSItem.Exception.GetBaseException()
      If ($Null -eq $PendingException) {
        $PendingException = $WorkerFinalizationException
      } Else {
        Write-Warning ('Probe: secondary shutdown failure: {0}' -f $WorkerFinalizationException.Message)
      }
    }
  }

  ForEach ($MarkerPath In @($OpenCloseMarkerPath, $PersistMarkerPath)) {
    $MarkerException = $Null
    Try {
      If ([IO.File]::Exists($MarkerPath)) {
        [IO.File]::Delete($MarkerPath)
      }
      If ([IO.File]::Exists($MarkerPath)) {
        Throw [InvalidOperationException]::new(('Probe: marker cleanup failed: {0}' -f $MarkerPath))
      }
    } Catch {
      $MarkerException = $PSItem.Exception.GetBaseException()
    }
    If ($Null -ne $MarkerException) {
      If ($Null -eq $PendingException) {
        $PendingException = $MarkerException
      } Else {
        Write-Warning ('Probe: secondary shutdown failure: {0}' -f $MarkerException.Message)
      }
    }
  }

  If ($Null -ne $Observation) {
    Try {
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
    } Catch {
      $ObservationShutdownException = $PSItem.Exception.GetBaseException()
      $CleanupDeferred = $True
      If ($Null -eq $PendingException) {
        $PendingException = $ObservationShutdownException
      } Else {
        Write-Warning ('Probe: secondary shutdown failure: {0}' -f $ObservationShutdownException.Message)
      }
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

  ForEach ($StatisticsSource In @(
      [PSCustomObject]@{ Name = 'openclose'; Path = $OpenCloseCsvPath }
      [PSCustomObject]@{ Name = 'persist'; Path = $PersistCsvPath }
    )) {
    $FinalRows = @(Import-Csv -LiteralPath $StatisticsSource.Path)
    $FailureRows = @($FinalRows | Where-Object -FilterScript { $PSItem.outcome -eq 'failure' })
    $Statistics = [PSCustomObject]@{
      attempts          = $(If ($FinalRows.Count -gt 0) { [Int32]$FinalRows[-1].attempt } Else { 0 })
      failures          = $FailureRows.Count
      first_failure_utc = $(If ($FailureRows.Count -gt 0) { [String]$FailureRows[0].timestamp_utc } Else { '' })
      last_failure_utc  = $(If ($FailureRows.Count -gt 0) { [String]$FailureRows[-1].timestamp_utc } Else { '' })
      max_elapsed_ms    = [Int64]$(If ($FinalRows.Count -gt 0) {
          @($FinalRows | ForEach-Object -Process { [Int64]$PSItem.elapsed_ms } | Measure-Object -Maximum)[0].Maximum
        } Else {
          0
        })
      in_flight_at_stop = @($FinalRows | Where-Object -FilterScript { $PSItem.outcome -eq 'in_flight' }).Count -gt 0
    }
    If ($StatisticsSource.Name -eq 'openclose') {
      $OpenCloseStatistics = $Statistics
    } Else {
      $PersistStatistics = $Statistics
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
      attempts          = $OpenCloseStatistics.attempts
      failures          = $OpenCloseStatistics.failures
      first_failure_utc = $OpenCloseStatistics.first_failure_utc
      last_failure_utc  = $OpenCloseStatistics.last_failure_utc
      max_elapsed_ms    = $OpenCloseStatistics.max_elapsed_ms
      in_flight_at_stop = $OpenCloseStatistics.in_flight_at_stop
      kill_requested    = $OpenCloseKillRequested
    }
    persist            = [PSCustomObject]@{
      attempts          = $PersistStatistics.attempts
      failures          = $PersistStatistics.failures
      first_failure_utc = $PersistStatistics.first_failure_utc
      last_failure_utc  = $PersistStatistics.last_failure_utc
      max_elapsed_ms    = $PersistStatistics.max_elapsed_ms
      in_flight_at_stop = $PersistStatistics.in_flight_at_stop
      kill_requested    = $PersistKillRequested
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
  If ($Null -ne $OpenCloseProcess) {
    $OpenCloseProcess.Dispose()
  }
  If ($Null -ne $PersistProcess) {
    $PersistProcess.Dispose()
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
