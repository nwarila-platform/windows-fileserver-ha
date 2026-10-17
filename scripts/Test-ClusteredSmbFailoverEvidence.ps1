#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Scores clustered SMB failover attempt evidence.

    .DESCRIPTION
        Validates the probe CSV schema and scores baseline cadence, event-window gaps,
        persistent-handle failures, open-close failures, in-flight attempts, and evidence coverage.

    .PARAMETER BaselineCadenceSeconds
        Maximum successful completion-to-completion gap before the first marker.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER EvidencePath
        Existing directory containing the two probe attempt CSV files.
    .PARAMETER Events
        Ordered event objects with exactly name, kind, and marker_utc properties.
    .PARAMETER IntervalSeconds
        Probe interval from 0.1 through 60 seconds.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER PlannedGapSeconds
        Maximum successful completion-to-completion gap in a planned event window.
    .PARAMETER PlannedOpenCloseFailures
        Maximum open-close failures in a planned event window.
    .PARAMETER UnplannedGapSeconds
        Maximum successful completion-to-completion gap in an unplanned event window.
    .PARAMETER UnplannedOpenCloseFailures
        Maximum open-close failures in an unplanned event window.

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
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(0.001, 86400.0)]
  [System.Double]
  $BaselineCadenceSeconds,

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String]
  $DebugLevel = '103',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.String]
  $EvidencePath,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateNotNullOrEmpty()]
  [System.Object[]]
  $Events,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(0.1, 60.0)]
  [System.Double]
  $IntervalSeconds,

  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String]
  $LogLevel = '002223',

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(0.001, 86400.0)]
  [System.Double]
  $PlannedGapSeconds,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(0, 2147483647)]
  [System.Int32]
  $PlannedOpenCloseFailures,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(0.001, 86400.0)]
  [System.Double]
  $UnplannedGapSeconds,

  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(0, 2147483647)]
  [System.Int32]
  $UnplannedOpenCloseFailures
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
$Ansible.Changed = $False
$Ansible.Failed = $False

$InvariantCulture = [Globalization.CultureInfo]::InvariantCulture
$ExpectedEventProperties = @('kind', 'marker_utc', 'name')
$NormalizedEvents = [Collections.Generic.List[Object]]::new()
$EventNames = [Collections.Generic.HashSet[String]]::new([StringComparer]::Ordinal)
If ($Events.Count -eq 0) {
  Throw 'Contract: Events must contain at least one event.'
}
ForEach ($EventInput In @($Events)) {
  If ($Null -eq $EventInput) {
    Throw 'Contract: Events cannot contain null.'
  }
  If ($EventInput -is [Collections.IDictionary]) {
    $EventProperties = @($EventInput.Keys | ForEach-Object -Process { [System.String]$PSItem } | Sort-Object)
    $EventName = [System.String]$EventInput['name']
    $EventKind = [System.String]$EventInput['kind']
    $EventMarkerText = [System.String]$EventInput['marker_utc']
  } Else {
    $EventProperties = @($EventInput.PSObject.Properties.Name | Sort-Object)
    $EventName = [System.String]$EventInput.name
    $EventKind = [System.String]$EventInput.kind
    $EventMarkerText = [System.String]$EventInput.marker_utc
  }
  If (($EventProperties -join ',') -cne ($ExpectedEventProperties -join ',')) {
    Throw ('Contract: event schema must be exactly {0}; received {1}.' -f @(
        ($ExpectedEventProperties -join ',')
        ($EventProperties -join ',')
      ))
  }
  If ($EventName -notmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') {
    Throw ('Contract: invalid event name: {0}.' -f $EventName)
  }
  If (-not $EventNames.Add($EventName)) {
    Throw ('Contract: duplicate event name: {0}.' -f $EventName)
  }
  If ($EventKind -cnotin @('planned', 'unplanned')) {
    Throw ('Contract: event {0} kind must be planned or unplanned.' -f $EventName)
  }
  Try {
    $EventMarker = [DateTimeOffset]::ParseExact(
      $EventMarkerText,
      'o',
      $InvariantCulture,
      [Globalization.DateTimeStyles]::None
    )
  } Catch {
    Throw ('Contract: event {0} marker_utc is not a round-trip timestamp: {1}.' -f @(
        $EventName
        $EventMarkerText
      ))
  }
  If ($EventMarker.Offset -ne [TimeSpan]::Zero) {
    Throw ('Contract: event {0} marker_utc is not UTC: {1}.' -f @($EventName, $EventMarkerText))
  }
  If ($NormalizedEvents.Count -gt 0 -and $EventMarker -le $NormalizedEvents[$NormalizedEvents.Count - 1].Marker) {
    Throw ('Contract: event markers must be strictly increasing at {0}.' -f $EventName)
  }
  $NormalizedEvents.Add([PSCustomObject]@{
      Kind       = $EventKind
      Marker     = $EventMarker
      MarkerText = $EventMarkerText
      Name       = $EventName
    })
}

#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Main'

$ExpectedHeader = 'timestamp_utc,loop,attempt,op,elapsed_ms,outcome,exception_type,exception_hresult,exception_message,dns_a_records,server_ip,network_sample_utc'
$RowsByLoop = @{}
$Utf8 = [Text.UTF8Encoding]::new($False, $True)
ForEach ($FileSpec In @(
    [PSCustomObject]@{ Loop = 'openclose'; Name = 'attempts-openclose.csv' }
    [PSCustomObject]@{ Loop = 'persist'; Name = 'attempts-persist.csv' }
  )) {
  $CsvPath = [IO.Path]::Combine($EvidencePath, $FileSpec.Name)
  If (-not [IO.File]::Exists($CsvPath)) {
    Throw ('Contract: missing evidence file: {0}.' -f $FileSpec.Name)
  }
  Try {
    $CsvBytes = [IO.File]::ReadAllBytes($CsvPath)
    $CsvText = $Utf8.GetString($CsvBytes)
  } Catch {
    Throw ('Contract: evidence file {0} is not valid UTF-8: {1}.' -f @(
        $FileSpec.Name
        $PSItem.Exception.GetBaseException().Message
      ))
  }
  If (
    $CsvBytes.Length -ge 3 -and
    $CsvBytes[0] -eq 0xEF -and
    $CsvBytes[1] -eq 0xBB -and
    $CsvBytes[2] -eq 0xBF
  ) {
    Throw ('Contract: evidence file {0} has a UTF-8 BOM.' -f $FileSpec.Name)
  }
  If (-not $CsvText.EndsWith("`r`n", [StringComparison]::Ordinal)) {
    Throw ('Contract: evidence file {0} does not end with a complete CRLF row.' -f $FileSpec.Name)
  }
  $WithoutCrLf = $CsvText.Replace("`r`n", '')
  If ($WithoutCrLf.Contains("`r") -or $WithoutCrLf.Contains("`n")) {
    Throw ('Contract: evidence file {0} contains a non-CRLF line ending.' -f $FileSpec.Name)
  }
  $HeaderEnd = $CsvText.IndexOf("`r`n", [StringComparison]::Ordinal)
  $ActualHeader = $CsvText.Substring(0, $HeaderEnd)
  If ($ActualHeader -cne $ExpectedHeader) {
    Throw ('Contract: evidence file {0} schema differs: {1}.' -f @($FileSpec.Name, $ActualHeader))
  }
  $CsvRows = @($CsvText | ConvertFrom-Csv -Delimiter ',')
  If ($CsvRows.Count -eq 0) {
    Throw ('Contract: evidence file {0} has no attempt rows.' -f $FileSpec.Name)
  }
  $NormalizedRows = [Collections.Generic.List[Object]]::new()
  $PreviousAttempt = 0
  $PreviousTimestamp = [DateTimeOffset]::MinValue
  ForEach ($Row In $CsvRows) {
    Try {
      $Timestamp = [DateTimeOffset]::ParseExact(
        [System.String]$Row.timestamp_utc,
        'o',
        $InvariantCulture,
        [Globalization.DateTimeStyles]::None
      )
      $Attempt = [Int32]::Parse(
        [System.String]$Row.attempt,
        [Globalization.NumberStyles]::None,
        $InvariantCulture
      )
      $ElapsedMilliseconds = [Int64]::Parse(
        [System.String]$Row.elapsed_ms,
        [Globalization.NumberStyles]::None,
        $InvariantCulture
      )
    } Catch {
      Throw ('Contract: evidence file {0} has an invalid timestamp, attempt, or elapsed_ms value: {1}.' -f @(
          $FileSpec.Name
          $PSItem.Exception.GetBaseException().Message
        ))
    }
    If ($Timestamp.Offset -ne [TimeSpan]::Zero) {
      Throw ('Contract: evidence file {0} has a non-UTC timestamp: {1}.' -f @(
          $FileSpec.Name
          $Row.timestamp_utc
        ))
    }
    If ([System.String]$Row.loop -cne $FileSpec.Loop) {
      Throw ('Contract: evidence file {0} has loop {1}; expected {2}.' -f @(
          $FileSpec.Name
          $Row.loop
          $FileSpec.Loop
        ))
    }
    If ($Attempt -le $PreviousAttempt) {
      Throw ('Contract: evidence file {0} attempts are not strictly increasing at {1}.' -f @(
          $FileSpec.Name
          $Attempt
        ))
    }
    If ($Timestamp -lt $PreviousTimestamp) {
      Throw ('Contract: evidence file {0} timestamps move backward at attempt {1}.' -f @(
          $FileSpec.Name
          $Attempt
        ))
    }
    If ([System.String]$Row.outcome -cnotin @('success', 'failure', 'in_flight')) {
      Throw ('Contract: evidence file {0} has invalid outcome {1}.' -f @(
          $FileSpec.Name
          $Row.outcome
        ))
    }
    If (
      [System.String]$Row.outcome -cne 'failure' -and
      -not [String]::IsNullOrEmpty([System.String]$Row.exception_type + [System.String]$Row.exception_hresult + [System.String]$Row.exception_message)
    ) {
      Throw ('Contract: evidence file {0} attempt {1} has exception data for outcome {2}.' -f @(
          $FileSpec.Name
          $Attempt
          $Row.outcome
        ))
    }
    $NormalizedRows.Add([PSCustomObject]@{
        Attempt       = $Attempt
        CompletionUtc = $Timestamp.AddMilliseconds($ElapsedMilliseconds)
        ElapsedMs     = $ElapsedMilliseconds
        Outcome       = [System.String]$Row.outcome
        TimestampUtc  = $Timestamp
      })
    $PreviousAttempt = $Attempt
    $PreviousTimestamp = $Timestamp
  }
  $RowsByLoop[$FileSpec.Loop] = $NormalizedRows.ToArray()
}

$Misses = [Collections.Generic.List[String]]::new()
$Scores = [Collections.Generic.List[Object]]::new()
$FirstMarker = $NormalizedEvents[0].Marker
$LastMarker = $NormalizedEvents[$NormalizedEvents.Count - 1].Marker
ForEach ($LoopName In @('openclose', 'persist')) {
  $LoopRows = @($RowsByLoop[$LoopName])
  If ($LoopRows[0].TimestampUtc -ge $FirstMarker) {
    $Misses.Add(('baseline/{0}/coverage_start measured={1} limit=before-{2}' -f @(
          $LoopName
          $LoopRows[0].TimestampUtc.ToString('o', $InvariantCulture)
          $NormalizedEvents[0].MarkerText
        )))
  }
  $SuccessAfterLastMarker = @($LoopRows | Where-Object -FilterScript {
      $PSItem.Outcome -ceq 'success' -and $PSItem.TimestampUtc -ge $LastMarker
    })
  If ($SuccessAfterLastMarker.Count -eq 0) {
    $Misses.Add(('{0}/{1}/coverage_end measured=0 limit=1' -f @(
          $NormalizedEvents[$NormalizedEvents.Count - 1].Name
          $LoopName
        )))
  }
  $BaselineSuccesses = @($LoopRows | Where-Object -FilterScript {
      $PSItem.Outcome -ceq 'success' -and $PSItem.TimestampUtc -lt $FirstMarker
    })
  $BaselineGap = 0.0
  For ($BaselineIndex = 1; $BaselineIndex -lt $BaselineSuccesses.Count; $BaselineIndex++) {
    $Gap = ($BaselineSuccesses[$BaselineIndex].CompletionUtc - $BaselineSuccesses[$BaselineIndex - 1].CompletionUtc).TotalSeconds
    If ($Gap -gt $BaselineGap) {
      $BaselineGap = $Gap
    }
  }
  If ($BaselineGap -gt $BaselineCadenceSeconds) {
    $Misses.Add(('baseline/{0}/gap measured={1} limit={2}' -f @(
          $LoopName
          $BaselineGap.ToString('0.#######', $InvariantCulture)
          $BaselineCadenceSeconds.ToString('0.#######', $InvariantCulture)
        )))
  }
}

For ($EventIndex = 0; $EventIndex -lt $NormalizedEvents.Count; $EventIndex++) {
  $CurrentEvent = $NormalizedEvents[$EventIndex]
  $WindowEnd = $(If ($EventIndex + 1 -lt $NormalizedEvents.Count) {
      $NormalizedEvents[$EventIndex + 1].Marker
    } Else {
      [DateTimeOffset]::MaxValue
    })
  If ($CurrentEvent.Kind -ceq 'planned') {
    $GapLimit = $PlannedGapSeconds
    $OpenCloseFailureLimit = $PlannedOpenCloseFailures
  } Else {
    $GapLimit = $UnplannedGapSeconds
    $OpenCloseFailureLimit = $UnplannedOpenCloseFailures
  }
  $LoopScores = [Collections.Generic.List[Object]]::new()
  ForEach ($LoopName In @('openclose', 'persist')) {
    $LoopRows = @($RowsByLoop[$LoopName])
    $WindowRows = @($LoopRows | Where-Object -FilterScript {
        $PSItem.TimestampUtc -ge $CurrentEvent.Marker -and $PSItem.TimestampUtc -lt $WindowEnd
      })
    $Failures = @($WindowRows | Where-Object -FilterScript { $PSItem.Outcome -ceq 'failure' }).Count
    $InFlight = @($WindowRows | Where-Object -FilterScript { $PSItem.Outcome -ceq 'in_flight' }).Count
    $SuccessfulRows = @($LoopRows | Where-Object -FilterScript { $PSItem.Outcome -ceq 'success' })
    $MaxGap = 0.0
    For ($SuccessIndex = 1; $SuccessIndex -lt $SuccessfulRows.Count; $SuccessIndex++) {
      $LaterSuccess = $SuccessfulRows[$SuccessIndex]
      If ($LaterSuccess.TimestampUtc -ge $CurrentEvent.Marker -and $LaterSuccess.TimestampUtc -lt $WindowEnd) {
        $Gap = ($LaterSuccess.CompletionUtc - $SuccessfulRows[$SuccessIndex - 1].CompletionUtc).TotalSeconds
        If ($Gap -gt $MaxGap) {
          $MaxGap = $Gap
        }
      }
    }
    $LoopScores.Add([PSCustomObject][Ordered]@{
        loop        = $LoopName
        gap_seconds = [Math]::Round($MaxGap, 7)
        failures    = $Failures
        attempts    = $WindowRows.Count
      })
    If ($MaxGap -gt $GapLimit) {
      $Misses.Add(('{0}/{1}/gap measured={2} limit={3}' -f @(
            $CurrentEvent.Name
            $LoopName
            $MaxGap.ToString('0.#######', $InvariantCulture)
            $GapLimit.ToString('0.#######', $InvariantCulture)
          )))
    }
    $FailureLimit = $(If ($LoopName -ceq 'persist') { 0 } Else { $OpenCloseFailureLimit })
    If ($Failures -gt $FailureLimit) {
      $Misses.Add(('{0}/{1}/failures measured={2} limit={3}' -f @(
            $CurrentEvent.Name
            $LoopName
            $Failures.ToString($InvariantCulture)
            $FailureLimit.ToString($InvariantCulture)
          )))
    }
    If ($InFlight -gt 0) {
      $Misses.Add(('{0}/{1}/in_flight measured={2} limit=0' -f @(
            $CurrentEvent.Name
            $LoopName
            $InFlight.ToString($InvariantCulture)
          )))
    }
  }
  $Scores.Add([PSCustomObject][Ordered]@{
      name       = $CurrentEvent.Name
      kind       = $CurrentEvent.Kind
      marker_utc = $CurrentEvent.MarkerText
      loops      = $LoopScores.ToArray()
    })
}

If ($Misses.Count -gt 0) {
  Throw ('Contract: {0} clause(s) missed: {1}' -f @($Misses.Count, ($Misses -join '; ')))
}
$Result = [PSCustomObject][Ordered]@{
  contract         = 'pass'
  interval_seconds = $IntervalSeconds
  events           = $Scores.ToArray()
}

#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $False
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
