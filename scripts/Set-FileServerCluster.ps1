#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Forms the declared failover cluster or completes an interrupted node join.
    .DESCRIPTION
        Reads and validates cluster identity, creates an absent cluster or adds
        declared missing nodes, then reacquires and proves exact state.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER ClusterName
        Exact failover cluster name.
    .PARAMETER Node
        Exact ordered cluster node names.
    .PARAMETER StaticAddress
        Exact ordered cluster-core static IPv4 addresses.
    .PARAMETER Password
        Password for the cluster service account that owns the batch logon.
    .PARAMETER TimeoutSeconds
        Maximum time to wait for the batch mutation. Default 1200.
    .PARAMETER ReacquireTimeoutSeconds
        Maximum time to wait for post-mutation cluster reacquisition. Default 120.
    .OUTPUTS
        System.String
#>
[System.Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Register-ScheduledTask requires the supplied password as System.String.')]
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
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $Node,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $StaticAddress,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $Password,
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(1, 86400)]
  [System.Int32] $TimeoutSeconds = 1200,
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(1, 86400)]
  [System.Int32] $ReacquireTimeoutSeconds = 120
)

#region ------ [ Script ] -------------------------------------------------------------------- #
#region ------ [ Initialization ] ------------------------------------------------------------ #
Write-Debug -Message:'Entering Stage: Initialization'
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
  $Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $False; Failed = $False; Result = $Null }
}
$Ansible.Changed = $False
#endregion --- [ Initialization ] ------------------------------------------------------------ #

#region ------ [ Main ] ---------------------------------------------------------------------- #
Try {
  Write-Debug -Message:'Entering Stage: Main'

  $ConvertToNormalizedNameSet = {
    Param ([System.String[]]$Value, [System.String]$Label)
    $Normalized = @($Value | ForEach-Object -Process { ([System.String]$PSItem).Trim().ToLowerInvariant() })
    If ($Normalized.Count -eq 0 -or @($Normalized | Where-Object -FilterScript { [System.String]::IsNullOrWhiteSpace($PSItem) }).Count -gt 0 -or
      @($Normalized | Select-Object -Unique).Count -ne $Normalized.Count) {
      Throw ('{0} must contain non-empty unique values.' -f $Label)
    }
    $Normalized
  }

  $GetLocalMembershipStatus = Get-Variable -Name:'SetFileServerClusterGetLocalMembershipStatus' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $GetLocalMembershipStatus) {
    $GetLocalMembershipStatus = {
      $Service = Get-Service -Name:'ClusSvc' -ErrorAction:'SilentlyContinue'
      If ($Null -eq $Service) {
        Throw 'ClusSvc is absent after failover clustering should have been installed; the deployment lifecycle was violated.'
      }
      $ClusDbPath = Join-Path -Path:$env:SystemRoot -ChildPath:'Cluster\CLUSDB'
      $ClusDbPresent = Test-Path -LiteralPath:$ClusDbPath -PathType:'Leaf'
      $ServiceStatus = [System.String]$Service.Status
      $StartType = [System.String]$Service.StartType
      If ($ServiceStatus -ieq 'Running') {
        # Running is the normal joined-member path.
        $Status = 'member-running'
      } ElseIf ($ServiceStatus -ine 'Stopped') {
        Throw ('ClusSvc state {0} cannot prove local cluster membership.' -f $ServiceStatus)
      } ElseIf (-not $ClusDbPresent -and $StartType -ine 'Automatic') {
        # Stopped without CLUSDB and without Automatic start is every first deployment.
        $Status = 'fresh'
      } Else {
        # Stopped with CLUSDB or Automatic start is a crashed or maintained member.
        $Status = 'stopped-member'
      }
      [PSCustomObject]@{
        status         = [System.String]$Status
        service_status = [System.String]$ServiceStatus
        clusdb_present = [System.Boolean]$ClusDbPresent
        start_type     = [System.String]$StartType
      }
    }
  }

  $GetClusterCoreState = Get-Variable -Name:'SetFileServerClusterGetClusterCoreState' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $GetClusterCoreState) {
    $GetClusterCoreState = {
      Param ([System.String]$Name)
      # Cluster truth is local until the cluster name can resolve.
      $Clusters = @(Get-Cluster)
      If ($Clusters.Count -eq 0) { Return $Null }
      If ($Clusters.Count -ne 1) { Throw ('Cluster identity {0} is ambiguous.' -f $Name) }
      $Cluster = $Clusters[0]
      If ([System.String]$Cluster.Name -ine $Name) {
        Throw ('The local node already belongs to a differently named cluster: {0}.' -f $Cluster.Name)
      }
      $Nodes = @(Get-ClusterNode -InputObject $Cluster)
      $CoreGroups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.GroupType -eq 'Cluster' })
      If ($CoreGroups.Count -ne 1) { Throw ('Cluster {0} must expose exactly one core group.' -f $Name) }
      $CoreGroupName = [System.String]$CoreGroups[0].Name
      $Resources = @(Get-ClusterResource -InputObject $Cluster)
      $IpResources = @($Resources | Where-Object -FilterScript {
          [System.String]$PSItem.ResourceType -eq 'IP Address' -and [System.String]$PSItem.OwnerGroup -eq $CoreGroupName
        })
      $Addresses = @(
        ForEach ($Resource In $IpResources) {
          $Parameter = @(Get-ClusterParameter -InputObject $Resource -Name 'Address')
          If ($Parameter.Count -ne 1 -or [System.String]::IsNullOrWhiteSpace([System.String]$Parameter[0].Value)) {
            Throw ('Core IP resource {0} has no single Address parameter.' -f $Resource.Name)
          }
          ([System.String]$Parameter[0].Value).Trim()
        }
      )
      [PSCustomObject]@{
        cluster        = $Cluster
        name           = [System.String]$Cluster.Name
        nodes          = @($Nodes | ForEach-Object -Process { [PSCustomObject]@{ name = [System.String]$PSItem.Name; state = [System.String]$PSItem.State } })
        addresses      = $Addresses
        physical_disks = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' })
      }
    }
  }

  # Result payloads contain primitives only; live cmdlet objects remain internal.
  $ConvertToSafeClusterCoreState = {
    Param ([System.Object]$State)
    If ($Null -eq $State) { Return $Null }
    [PSCustomObject]@{
      name                = [System.String]$State.name
      nodes               = @($State.nodes | ForEach-Object -Process {
          [PSCustomObject]@{ name = [System.String]$PSItem.name; state = [System.String]$PSItem.state }
        })
      addresses           = @($State.addresses | ForEach-Object -Process { [System.String]$PSItem })
      physical_disk_names = @($State.physical_disks | ForEach-Object -Process { [System.String]$PSItem.Name })
    }
  }

  $ConvertToLdapFilterValue = {
    Param ([System.String]$Value)
    $Value.Replace('\', '\5c').Replace('*', '\2a').Replace('(', '\28').Replace(')', '\29').Replace("$([System.Char]0)", '\00')
  }

  $FindComputerAccount = Get-Variable -Name:'SetFileServerClusterFindComputerAccount' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $FindComputerAccount) {
    $FindComputerAccount = {
      Param ([System.String]$SamAccountName)
      $RootDse = [ADSI]'LDAP://RootDSE'
      Try {
        $SearchRoot = [ADSI]('LDAP://{0}' -f [System.String]$RootDse.Properties['defaultNamingContext'].Value)
        Try {
          $Searcher = [System.DirectoryServices.DirectorySearcher]::new($SearchRoot)
          Try {
            $Searcher.Filter = '(&(objectCategory=computer)(sAMAccountName={0}))' -f (& $ConvertToLdapFilterValue -Value $SamAccountName)
            $Null = $Searcher.PropertiesToLoad.Add('userAccountControl')
            $SearchResults = $Searcher.FindAll()
            Try {
              $DirectoryMatches = @($SearchResults)
              If ($DirectoryMatches.Count -gt 1) { Throw ('Computer account {0} is ambiguous.' -f $SamAccountName) }
              If ($DirectoryMatches.Count -eq 0) { Return $Null }
              $UserAccountControl = @($DirectoryMatches[0].Properties['useraccountcontrol'])
              If ($UserAccountControl.Count -ne 1) { Throw ('Computer account {0} has no single userAccountControl value.' -f $SamAccountName) }
              [PSCustomObject]@{
                path                 = [System.String]$DirectoryMatches[0].Path
                user_account_control = [System.Int32]$UserAccountControl[0]
              }
            } Finally {
              $SearchResults.Dispose()
            }
          } Finally {
            $Searcher.Dispose()
          }
        } Finally {
          $SearchRoot.Dispose()
        }
      } Finally {
        $RootDse.Dispose()
      }
    }
  }

  $SetComputerAccountControl = Get-Variable -Name:'SetFileServerClusterSetComputerAccountControl' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $SetComputerAccountControl) {
    $SetComputerAccountControl = {
      Param ([System.String]$Path, [System.Int32]$UserAccountControl)
      $ComputerAccount = [ADSI]$Path
      Try {
        $ComputerAccount.Properties['userAccountControl'].Value = $UserAccountControl
        $ComputerAccount.CommitChanges()
      } Finally {
        $ComputerAccount.Dispose()
      }
    }
  }

  $GetCurrentIdentityName = Get-Variable -Name:'SetFileServerClusterGetCurrentIdentityName' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $GetCurrentIdentityName) {
    $GetCurrentIdentityName = { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
  }

  $ReadTranscriptTail = Get-Variable -Name:'SetFileServerClusterReadTranscriptTail' -ValueOnly -ErrorAction:'SilentlyContinue'
  If ($Null -eq $ReadTranscriptTail) {
    $ReadTranscriptTail = {
      Param ([System.String]$Path)
      $Lines = @(Get-Content -LiteralPath $Path -Tail 40 -ErrorAction SilentlyContinue)
      If ($Lines.Count -eq 0) { Return '(transcript unavailable)' }
      $Lines -join [System.Environment]::NewLine
    }
  }

  $InvokeBatchMutation = {
    Param ([System.Object]$Mutation, [System.String]$RunAsPassword, [System.Int32]$DeadlineSeconds)
    $TaskName = 'Set-FileServerCluster-{0}' -f [System.Guid]::NewGuid().ToString('N')
    $TranscriptPath = Join-Path -Path $env:TEMP -ChildPath ('{0}.log' -f $TaskName)
    $TaskRegistered = $False
    Try {
      $MutationXml = [System.Management.Automation.PSSerializer]::Serialize($Mutation)
      $MutationPayload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($MutationXml))
      $TranscriptPayload = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($TranscriptPath))
      $InnerCommand = @'
$ErrorActionPreference = 'Stop'
$MutationXml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('__MUTATION_PAYLOAD__'))
$Mutation = [System.Management.Automation.PSSerializer]::Deserialize($MutationXml)
$TranscriptPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('__TRANSCRIPT_PAYLOAD__'))
$ExitCode = 1
. {
  Try {
    $MutationErrors = @()
    If ($Mutation.create_cluster) {
      Try {
        New-Cluster -Name $Mutation.cluster_name -Node $Mutation.nodes -StaticAddress $Mutation.static_addresses -NoStorage -Force -ErrorAction:'SilentlyContinue' -ErrorVariable:'+MutationErrors'
      } Catch {
        $MutationErrors += $PSItem
      }
    } Else {
      $Clusters = @(Get-Cluster)
      If ($Clusters.Count -ne 1) { Throw ('Cluster {0} could not be acquired locally.' -f $Mutation.cluster_name) }
      $Cluster = $Clusters[0]
      If ([System.String]$Cluster.Name -ine [System.String]$Mutation.cluster_name) {
        Throw ('The local node belongs to cluster {0}, not {1}.' -f $Cluster.Name, $Mutation.cluster_name)
      }
      ForEach ($MissingNode In $Mutation.missing_nodes) {
        Try {
          Add-ClusterNode -InputObject $Cluster -Name $MissingNode -NoStorage -ErrorAction:'SilentlyContinue' -ErrorVariable:'+MutationErrors'
        } Catch {
          $MutationErrors += $PSItem
        }
      }
    }
    # New-Cluster can form while emitting non-terminating multi-subnet/DNS errors; only local node membership proves the mutation.
    $Clusters = @(Get-Cluster)
    If ($Clusters.Count -ne 1) {
      Write-Output -InputObject ('Cluster reality found {0} local clusters; expected exactly one named {1}.' -f $Clusters.Count, $Mutation.cluster_name)
    } ElseIf ([System.String]$Clusters[0].Name -ine [System.String]$Mutation.cluster_name) {
      Write-Output -InputObject ('Cluster reality found local cluster {0}, not {1}.' -f $Clusters[0].Name, $Mutation.cluster_name)
    } Else {
      $ClusterNodes = @(Get-ClusterNode -InputObject $Clusters[0])
      If ($Mutation.create_cluster) {
        $RequiredNodes = @($Mutation.nodes)
      } Else {
        $RequiredNodes = @($Mutation.missing_nodes)
      }
      $StillMissingNodes = @($RequiredNodes | Where-Object -FilterScript {
          $RequiredNode = [System.String]$PSItem
          @($ClusterNodes | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq $RequiredNode }).Count -eq 0
        })
      $NodesNotUp = @($RequiredNodes | Where-Object -FilterScript {
          $RequiredNode = [System.String]$PSItem
          @($ClusterNodes | Where-Object -FilterScript {
              [System.String]$PSItem.Name -ieq $RequiredNode -and [System.String]$PSItem.State -ine 'Up'
            }).Count -gt 0
      })
      If ($StillMissingNodes.Count -gt 0) {
        Write-Output -InputObject ('Cluster mutation left nodes missing: {0}.' -f ($StillMissingNodes -join ', '))
      }
      If ($NodesNotUp.Count -gt 0) {
        Write-Output -InputObject ('Cluster mutation left nodes not Up: {0}.' -f ($NodesNotUp -join ', '))
      }
      If ($StillMissingNodes.Count -eq 0 -and $NodesNotUp.Count -eq 0) {
        $ExitCode = 0
      }
    }
    If ($ExitCode -ne 0) {
      ForEach ($MutationError In $MutationErrors) {
        Write-Output -InputObject ([System.String]$MutationError.Exception.Message)
      }
    }
  } Catch {
    Write-Output -InputObject ([System.String]$PSItem.Exception.Message)
  }
} *> $TranscriptPath
Exit $ExitCode
'@
      $InnerCommand = $InnerCommand.Replace('__MUTATION_PAYLOAD__', $MutationPayload).Replace('__TRANSCRIPT_PAYLOAD__', $TranscriptPayload)
      $EncodedCommand = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($InnerCommand))
      $Action = New-ScheduledTaskAction -Execute (Join-Path -Path $PSHOME -ChildPath 'powershell.exe') -Argument ('-NoLogo -NoProfile -NonInteractive -EncodedCommand {0}' -f $EncodedCommand)
      $CurrentUser = & $GetCurrentIdentityName
      $Null = Register-ScheduledTask -TaskName $TaskName -Action $Action -User $CurrentUser -Password $RunAsPassword -RunLevel Highest -Force
      $TaskRegistered = $True
      $Null = Start-ScheduledTask -TaskName $TaskName
      $Deadline = [System.DateTime]::UtcNow.AddSeconds($DeadlineSeconds)
      Do {
        $TaskInfo = Get-ScheduledTaskInfo -TaskName $TaskName
        $TaskResult = [System.UInt32]$TaskInfo.LastTaskResult
        If ($TaskResult -ne 267009) { Break }
        If ([System.DateTime]::UtcNow -ge $Deadline) {
          $Tail = & $ReadTranscriptTail -Path $TranscriptPath
          Throw ('Batch cluster mutation timed out after {0} seconds. Transcript tail:{1}{2}' -f $DeadlineSeconds, [System.Environment]::NewLine, $Tail)
        }
        Start-Sleep -Seconds 5
      } While ($True)
      If ($TaskResult -ne 0) {
        $Tail = & $ReadTranscriptTail -Path $TranscriptPath
        Throw ('Batch cluster mutation failed with scheduled task result {0}. Transcript tail:{1}{2}' -f $TaskResult, [System.Environment]::NewLine, $Tail)
      }
    } Finally {
      If ($TaskRegistered) { $Null = Unregister-ScheduledTask -TaskName $TaskName -Confirm:$False }
      Remove-Item -LiteralPath $TranscriptPath -Force -ErrorAction SilentlyContinue
    }
  }

  $DesiredNodes = @(& $ConvertToNormalizedNameSet -Value $Node -Label 'Node')
  $DesiredAddresses = @(& $ConvertToNormalizedNameSet -Value $StaticAddress -Label 'StaticAddress')
  ForEach ($Address In $StaticAddress) {
    $Parsed = [System.Net.IPAddress]::None
    If (-not [System.Net.IPAddress]::TryParse($Address, [ref]$Parsed) -or
      $Parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
      Throw ('StaticAddress contains a non-IPv4 value: {0}.' -f $Address)
    }
  }

  $LocalMembership = & $GetLocalMembershipStatus
  Switch -CaseSensitive ([System.String]$LocalMembership.status) {
    'member-running' {
      $Before = & $GetClusterCoreState -Name $ClusterName
      If ($Null -eq $Before) {
        Throw 'ClusSvc is running but no local cluster object was acquired; refusing cluster creation.'
      }
      Break
    }
    'fresh' {
      $Before = $Null
      Break
    }
    'stopped-member' {
      Throw ('ClusSvc is stopped on an existing member: CLUSDB present = {0}; StartType = {1}. Starting ClusSvc or evicting the node is an operator decision; refusing cluster creation.' -f
        $LocalMembership.clusdb_present, $LocalMembership.start_type)
    }
    Default {
      Throw ('Local cluster membership signal returned invalid status: {0}.' -f $LocalMembership.status)
    }
  }
  $Actions = [System.Collections.Generic.List[System.String]]::new()
  If ($LocalMembership.status -ceq 'fresh') {
    $Actions.Add('create_cluster')
  } Else {
    $CurrentNodes = @($Before.nodes | ForEach-Object -Process { $PSItem.name.ToLowerInvariant() })
    $UnexpectedNodes = @($CurrentNodes | Where-Object -FilterScript { $PSItem -notin $DesiredNodes })
    If ($UnexpectedNodes.Count -gt 0) {
      Throw ('Cluster {0} contains unexpected nodes: {1}.' -f $ClusterName, ($UnexpectedNodes -join ', '))
    }
    $CurrentAddresses = @($Before.addresses | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
    If (@(Compare-Object -ReferenceObject $DesiredAddresses -DifferenceObject $CurrentAddresses).Count -gt 0) {
      Throw ('Cluster {0} core address identity differs from the declaration.' -f $ClusterName)
    }
    For ($Index = 0; $Index -lt $DesiredNodes.Count; $Index++) {
      If ($DesiredNodes[$Index] -notin $CurrentNodes) { $Actions.Add(('add_node:{0}' -f $Node[$Index])) }
    }
  }

  If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
    $After = $Before
  } Else {
    If ($Actions.Contains('create_cluster')) {
      # Only the fresh local signal admits CNO adoption before formation.
      $ComputerAccount = & $FindComputerAccount -SamAccountName ($ClusterName + '$')
      If ($Null -ne $ComputerAccount -and ($ComputerAccount.user_account_control -band 0x2) -eq 0) {
        & $SetComputerAccountControl -Path $ComputerAccount.path -UserAccountControl ($ComputerAccount.user_account_control -bor 0x2)
      }
    }
    $MissingNodes = @($Actions | Where-Object -FilterScript { $PSItem.StartsWith('add_node:', [System.StringComparison]::Ordinal) } | ForEach-Object -Process { $PSItem.Substring(9) })
    $Mutation = [PSCustomObject]@{
      create_cluster   = $Actions.Contains('create_cluster')
      cluster_name     = [System.String]$ClusterName
      nodes            = [System.String[]]@($Node)
      static_addresses = [System.String[]]@($StaticAddress)
      missing_nodes    = [System.String[]]$MissingNodes
    }
    & $InvokeBatchMutation -Mutation $Mutation -RunAsPassword $Password -DeadlineSeconds $TimeoutSeconds
    # Formation can return before the caller's local clusapi view settles.
    $ReacquireDeadline = [System.DateTime]::UtcNow.AddSeconds($ReacquireTimeoutSeconds)
    Do {
      $After = & $GetClusterCoreState -Name $ClusterName
      If ($Null -ne $After -and $After.name -ieq $ClusterName) { Break }
      If ([System.DateTime]::UtcNow -ge $ReacquireDeadline) {
        Throw ('Cluster {0} was not reacquired after mutation. Waited {1} seconds.' -f $ClusterName, $ReacquireTimeoutSeconds)
      }
      Start-Sleep -Seconds 5
    } While ($True)
  }

  If (-not $Ansible.CheckMode -or $Actions.Count -eq 0) {
    If ($Null -eq $After -or $After.name -ine $ClusterName) {
      Throw ('Cluster {0} was not reacquired after mutation.' -f $ClusterName)
    }
    $AfterNodes = @($After.nodes | ForEach-Object -Process { $PSItem.name.ToLowerInvariant() })
    $AfterAddresses = @($After.addresses | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
    If (@(Compare-Object -ReferenceObject $DesiredNodes -DifferenceObject $AfterNodes).Count -gt 0 -or
      @($After.nodes | Where-Object -FilterScript { $PSItem.state -ne 'Up' }).Count -gt 0 -or
      @(Compare-Object -ReferenceObject $DesiredAddresses -DifferenceObject $AfterAddresses).Count -gt 0) {
      Throw ('Cluster {0} failed exact node/state/address readback.' -f $ClusterName)
    }
    If ($Actions.Contains('create_cluster') -and $After.physical_disks.Count -ne 0) {
      Throw ('Cluster {0} auto-added Physical Disk resources despite the -NoStorage formation contract.' -f $ClusterName)
    }
  }

  $Result = [PSCustomObject]@{
    changed    = $Actions.Count -gt 0
    check_mode = [System.Boolean]$Ansible.CheckMode
    actions    = @($Actions)
    before     = & $ConvertToSafeClusterCoreState -State $Before
    after      = & $ConvertToSafeClusterCoreState -State $After
    msg        = $(If ($Actions.Count -eq 0) { 'File server cluster already matches.' } ElseIf ($Ansible.CheckMode) { 'Check mode: file server cluster would be converged.' } Else { 'File server cluster converged.' })
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
