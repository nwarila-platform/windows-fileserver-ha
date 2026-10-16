#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Releases a stale prestaged cluster name object for cluster formation.
    .DESCRIPTION
        Disables an enabled prestaged cluster name object through an explicit
        directory bind, then proves both declared controllers report it disabled.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER ClusterName
        Exact prestaged cluster name object.
    .PARAMETER Password
        Password for the directory identity running the script.
    .PARAMETER DomainControllers
        Exact ordered domain-controller FQDNs used for lookup and readback.
    .OUTPUTS
        System.String
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'DirectoryEntry requires the supplied password as System.String.')]
[CmdletBinding(
  ConfirmImpact = 'None',
  DefaultParameterSetName = 'default',
  HelpUri = '',
  PositionalBinding = $False,
  RemotingCapability = 'PowerShell',
  SupportsPaging = $False,
  SupportsShouldProcess = $True
)]
Param (
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5][0-4][0-3]$')]
  [System.String] $DebugLevel = '103',
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidatePattern('^[0-5]{6}$')]
  [System.String] $LogLevel = '002223',
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $ClusterName,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $Password,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $DomainControllers
)

#region ------ [ Script ] -------------------------------------------------------------------- #
#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'
$WhatIfRequested = [System.Boolean]$WhatIfPreference
$WhatIfPreference = $false
New-Variable -Force -Name:'LOG_LEVELS' -Option:('Private', 'ReadOnly') -Value:(
  [System.String[]]@('Verbose', 'Debug', 'Information', 'Warning', 'Error', 'Fatal')
)
New-Variable -Verbose:$False -Force -Name:'ErrorPreference' -Value:([System.Management.Automation.ActionPreference]::Stop)
New-Variable -Verbose:$False -Force -Name:'FatalPreference' -Value:([System.Management.Automation.ActionPreference]::Stop)
For ($L = 0; $L -lt 6; $L++) {
  Set-Variable -Verbose:$False -Force -Name:('{0}Preference' -f $LOG_LEVELS[$L]) -Value:(
    [System.Int32]::Parse([System.String]$LogLevel[$L]) -as [System.Management.Automation.ActionPreference]
  )
}
$ErrorActionPreference = [System.Management.Automation.ActionPreference][System.Int32]::Parse($DebugLevel.Substring(0, 1))
Switch ($DebugLevel.Substring(1, 1)) {
  '0' { Set-PSDebug -Off }
  '1' { Set-PSDebug -Trace:1 }
  '2' { Set-PSDebug -Trace:2 }
  '3' { Set-PSDebug -Trace:1 -Step }
  '4' { Set-PSDebug -Trace:2 -Step }
}
If ($DebugLevel.Substring(2, 1) -eq '0') { Set-StrictMode -Off } Else { Set-StrictMode -Version:([System.String]$DebugLevel.Substring(2, 1)) }
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
  } Catch { Write-Debug -Message:'Trap diagnostics unavailable for this error record.' }
  Break
}
$StandaloneRun = $Null -eq (Get-Variable -Name:'Ansible' -ValueOnly -ErrorAction:'SilentlyContinue')
If ($StandaloneRun) {
  $Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $WhatIfRequested; Failed = $False; Result = $Null }
}
$Ansible.Changed = $False
#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Try {
  Write-Debug -Message:'Entering Stage: Main'

  $GetCurrentIdentityName = Get-Variable -Name:'SetPrestagedClusterNameObjectGetCurrentIdentityName' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $GetCurrentIdentityName) {
    $GetCurrentIdentityName = { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
  }

  $OpenDirectoryEntry = Get-Variable -Name:'SetPrestagedClusterNameObjectOpenDirectoryEntry' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $OpenDirectoryEntry) {
    $OpenDirectoryEntry = {
      Param (
        [System.String]$Path,
        [System.String]$IdentityName,
        [System.String]$Password,
        [System.DirectoryServices.AuthenticationTypes]$AuthenticationType
      )
      [System.DirectoryServices.DirectoryEntry]::new($Path, $IdentityName, $Password, $AuthenticationType)
    }
  }

  $SearchComputerObjects = Get-Variable -Name:'SetPrestagedClusterNameObjectSearchComputerObjects' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $SearchComputerObjects) {
    $SearchComputerObjects = {
      Param (
        [System.Object]$SearchRoot,
        [System.String]$EscapedName
      )
      $Searcher = $Null
      $SearchResults = $Null
      Try {
        $Searcher = [System.DirectoryServices.DirectorySearcher]::new($SearchRoot)
        $Searcher.Filter = '(&(objectCategory=computer)(sAMAccountName={0}$))' -f $EscapedName
        $Searcher.PageSize = 2
        $SearchResults = $Searcher.FindAll()
        @($SearchResults | ForEach-Object -Process { [PSCustomObject]@{ Path = [System.String]$PSItem.Path } })
      } Finally {
        If ($Null -ne $SearchResults) { $SearchResults.Dispose() }
        If ($Null -ne $Searcher) { $Searcher.Dispose() }
      }
    }
  }

  $FindPrestageComputerObject = {
    Param (
      [System.String]$Name,
      [System.String]$DomainController,
      [System.String]$IdentityName,
      [System.String]$Password,
      [System.DirectoryServices.AuthenticationTypes]$AuthenticationType
    )
    $RootDse = $Null
    $SearchRoot = $Null
    Try {
      $RootDse = & $OpenDirectoryEntry -Path ('LDAP://{0}/RootDSE' -f $DomainController) -IdentityName $IdentityName -Password $Password -AuthenticationType $AuthenticationType
      $DefaultNamingContext = [System.String]$RootDse.Properties['defaultNamingContext'][0]
      If ([System.String]::IsNullOrWhiteSpace($DefaultNamingContext)) {
        Throw 'RootDSE returned no defaultNamingContext.'
      }
      $SearchRoot = & $OpenDirectoryEntry -Path ('LDAP://{0}/{1}' -f $DomainController, $DefaultNamingContext) -IdentityName $IdentityName -Password $Password -AuthenticationType $AuthenticationType
      $EscapedName = $Name.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace([System.String][System.Char]0, '\00')
      $ComputerMatches = @(& $SearchComputerObjects -SearchRoot $SearchRoot -EscapedName $EscapedName)
      If ($ComputerMatches.Count -ne 1) {
        Throw ('directory lookup returned {0} matching computer objects.' -f $ComputerMatches.Count)
      }
      & $OpenDirectoryEntry -Path ([System.String]$ComputerMatches[0].Path) -IdentityName $IdentityName -Password $Password -AuthenticationType $AuthenticationType
    } Finally {
      If ($SearchRoot -is [System.IDisposable]) { $SearchRoot.Dispose() }
      If ($RootDse -is [System.IDisposable]) { $RootDse.Dispose() }
    }
  }

  $GetUtcNow = Get-Variable -Name:'SetPrestagedClusterNameObjectGetUtcNow' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $GetUtcNow) {
    $GetUtcNow = { [System.DateTime]::UtcNow }
  }

  $WaitForReplication = Get-Variable -Name:'SetPrestagedClusterNameObjectWaitForReplication' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $WaitForReplication) {
    $WaitForReplication = { Start-Sleep -Seconds 3 }
  }

  $Computer = $Null
  Try {
    $IdentityName = & $GetCurrentIdentityName
    $AuthenticationType = [System.DirectoryServices.AuthenticationTypes]::Secure -bor
    [System.DirectoryServices.AuthenticationTypes]::Sealing -bor
    [System.DirectoryServices.AuthenticationTypes]::Signing -bor
    [System.DirectoryServices.AuthenticationTypes]::ServerBind
    $Computer = & $FindPrestageComputerObject -Name $ClusterName -DomainController $DomainControllers[0] -IdentityName $IdentityName -Password $Password -AuthenticationType $AuthenticationType
    If ($Null -eq $Computer) { Throw 'directory lookup returned no computer object.' }
    $Computer.RefreshCache([System.String[]]@('userAccountControl'))
    $BeforeValue = $Computer.Properties['userAccountControl'].Value
    If ($Null -eq $BeforeValue) { Throw 'initial userAccountControl read returned no value.' }
    $BeforeUserAccountControl = [System.Int32]$BeforeValue
    $Changed = ($BeforeUserAccountControl -band 2) -eq 0
    $FinalUserAccountControl = $BeforeUserAccountControl

    If ($Changed -and -not $Ansible.CheckMode) {
      $Computer.Properties['userAccountControl'].Value = $BeforeUserAccountControl -bor 2
      $Computer.CommitChanges()
      $Computer.RefreshCache([System.String[]]@('userAccountControl'))
      $AfterValue = $Computer.Properties['userAccountControl'].Value
      If ($Null -eq $AfterValue) { Throw 'userAccountControl readback returned no value.' }
      $FinalUserAccountControl = [System.Int32]$AfterValue
      If (($FinalUserAccountControl -band 2) -eq 0) {
        Throw ('userAccountControl readback {0} does not contain the ACCOUNTDISABLE bit.' -f $FinalUserAccountControl)
      }
    }

    If (-not $Ansible.CheckMode) {
      $ObjectPath = [System.String]$Computer.Path
      $ObjectPathMatch = [System.Text.RegularExpressions.Regex]::Match($ObjectPath, '^LDAP://[^/]+/(?<DistinguishedName>.+)$', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
      If (-not $ObjectPathMatch.Success) {
        Throw ('directory lookup returned a non-server-qualified object path: {0}.' -f $ObjectPath)
      }
      $ObjectDistinguishedName = $ObjectPathMatch.Groups['DistinguishedName'].Value
      $ReplicationDeadline = (& $GetUtcNow).AddSeconds(60)
      Do {
        $PendingEndpoints = [System.Collections.Generic.List[System.String]]::new()
        ForEach ($DomainController In $DomainControllers) {
          $PollComputer = $Null
          Try {
            $PollComputer = & $OpenDirectoryEntry -Path ('LDAP://{0}/{1}' -f $DomainController, $ObjectDistinguishedName) -IdentityName $IdentityName -Password $Password -AuthenticationType $AuthenticationType
            $PollComputer.RefreshCache([System.String[]]@('userAccountControl'))
            $PollValue = $PollComputer.Properties['userAccountControl'].Value
            If ($Null -eq $PollValue) { Throw ('userAccountControl readback from {0} returned no value.' -f $DomainController) }
            $UserAccountControl = [System.Int32]$PollValue
            If (-not (($UserAccountControl -band 2) -ne 0)) {
              $PendingEndpoints.Add($DomainController)
            }
          } Finally {
            If ($PollComputer -is [System.IDisposable]) { $PollComputer.Dispose() }
          }
        }
        If ($PendingEndpoints.Count -eq 0) { Break }
        If ((& $GetUtcNow) -ge $ReplicationDeadline) {
          Throw ('Cluster name object {0} did not reach disabled state on: {1}' -f $ClusterName, ($PendingEndpoints -join ', '))
        }
        & $WaitForReplication
      } While ($True)
    }

    $Result = [PSCustomObject]@{
      changed              = [System.Boolean]$Changed
      check_mode           = [System.Boolean]$Ansible.CheckMode
      name                 = [System.String]$ClusterName
      user_account_control = [System.Int32]$FinalUserAccountControl
      msg                  = $(If (-not $Changed) { 'Prestaged cluster name object already disabled.' } ElseIf ($Ansible.CheckMode) { 'Check mode: prestaged cluster name object would be disabled.' } Else { 'Prestaged cluster name object disabled.' })
    }
  } Catch {
    Throw ('Prestage computer object {0} disable failed: {1}' -f $ClusterName, $PSItem.Exception.Message)
  } Finally {
    If ($Computer -is [System.IDisposable]) { $Computer.Dispose() }
  }
} Catch {
  $FailureMessage = [System.String]$PSItem.Exception.Message
  $FailureScriptStackTrace = [System.String]$PSItem.ScriptStackTrace
  $FailureBaseExceptionMessage = [System.String]$PSItem.Exception.GetBaseException().Message
  If (-not [System.String]::IsNullOrWhiteSpace($FailureScriptStackTrace)) {
    $FailureMessage = [System.String]('{0}{1}Script stack trace: {2}' -f $FailureMessage, [System.Environment]::NewLine, $FailureScriptStackTrace)
  }
  If (-not [System.String]::IsNullOrWhiteSpace($FailureBaseExceptionMessage)) {
    $FailureMessage = [System.String]('{0}{1}Innermost exception: {2}' -f $FailureMessage, [System.Environment]::NewLine, $FailureBaseExceptionMessage)
  }
  Throw $FailureMessage
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) { $Result | ConvertTo-Json -Depth:5 }
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
