#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

<#
    .SYNOPSIS
        Converges one clustered file-server role and its exact static-IP surface.
    .DESCRIPTION
        Resolves the home disk and client networks from observed identity,
        computes one exact role-resource transaction, and verifies readback.
    .PARAMETER DebugLevel
        Three-digit debug preference control. Default '103'.
    .PARAMETER LogLevel
        Six-digit stream preference control. Default '002223'.
    .PARAMETER ClusterName
        Exact failover cluster name.
    .PARAMETER RoleName
        Exact clustered file-server role name.
    .PARAMETER HomeVolumeId
        EBS volume identity of the role's home disk.
    .PARAMETER Owners
        Exact ordered preferred owners.
    .PARAMETER StaticAddress
        Exact role static IPv4 addresses.
    .PARAMETER IgnoredNetworkAddress
        Exact client-eligible network base addresses without declared static IPs.
    .PARAMETER Password
        Password for the cluster service account that owns the batch logon.
    .PARAMETER TimeoutSeconds
        Maximum time to wait for the batch mutation. Default 1200.
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
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $RoleName,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $HomeVolumeId,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $Owners,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $StaticAddress,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String[]] $IgnoredNetworkAddress,
  [Parameter(DontShow = $False, Mandatory = $True, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)] [System.String] $Password,
  [Parameter(DontShow = $False, Mandatory = $False, ParameterSetName = 'default', ValueFromPipeline = $False, ValueFromPipelineByPropertyName = $False)]
  [ValidateRange(1, 86400)]
  [System.Int32] $TimeoutSeconds = 1200
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
Write-Debug -Message:'Entering Stage: Main'

$ConvertToIpv4UInt32 = {
  Param ([System.String]$Address)
  $Parsed = [System.Net.IPAddress]::None
  If (-not [System.Net.IPAddress]::TryParse($Address, [ref]$Parsed) -or
    $Parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
    Throw ('Not an IPv4 address: {0}.' -f $Address)
  }
  $Bytes = $Parsed.GetAddressBytes()
  [Array]::Reverse($Bytes)
  [System.BitConverter]::ToUInt32($Bytes, 0)
}

$GetResourceParameterValue = {
  Param ([System.Object]$Resource, [System.String]$Name)
  $Value = @(Get-ClusterParameter -InputObject $Resource -Name $Name)
  If ($Value.Count -ne 1) { Throw ('Resource {0} must expose one {1} parameter.' -f $Resource.Name, $Name) }
  $Value[0].Value
}

$GetHomeDiskResource = {
  Param ([System.Object]$Cluster, [System.String]$VolumeId)
  $Token = $VolumeId.ToLowerInvariant().Replace('-', '')
  $LocalDisks = @(Get-Disk)
  $LocalMatches = @($LocalDisks | Where-Object -FilterScript {
      (([System.String]$PSItem.UniqueId).ToLowerInvariant() -replace '[^0-9a-z]', '').Contains($Token)
    })
  If ($LocalMatches.Count -ne 1) { Throw ('Home volume {0} must match exactly one local disk.' -f $VolumeId) }
  $DiskResourceMatches = @()
  ForEach ($Resource In @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' })) {
    $Guid = ([System.String](& $GetResourceParameterValue -Resource $Resource -Name 'DiskIdGuid')).Trim('{}')
    $Mapped = @($LocalDisks | Where-Object -FilterScript { ([System.String]$PSItem.Guid).Trim('{}') -ieq $Guid })
    If ($Mapped.Count -eq 1 -and (([System.String]$Mapped[0].UniqueId).ToLowerInvariant() -replace '[^0-9a-z]', '').Contains($Token)) {
      $DiskResourceMatches += $Resource
    }
  }
  If ($DiskResourceMatches.Count -ne 1) { Throw ('Home volume {0} must map to exactly one Physical Disk resource.' -f $VolumeId) }
  $Resource = $DiskResourceMatches[0]
  $OwnerNodeState = Get-ClusterOwnerNode -InputObject $Resource
  $PossibleOwners = @($OwnerNodeState.OwnerNodes | ForEach-Object -Process { ([System.String]$PSItem.Name).ToLowerInvariant() } | Sort-Object)
  $DesiredOwners = @($Owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Sort-Object)
  # Available Storage is one single-owner group: a per-AZ home disk correctly owner-scoped to
  # this AZ's nodes may still sit Offline there while an other-AZ node owns the group. Only
  # owner-scoping is checked here; the role region below adopts the disk into its own group and
  # onlines it there.
  If (@(Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $PossibleOwners).Count -gt 0) {
    Throw ('Home disk {0} must be owner-scoped to the declared owners.' -f $Resource.Name)
  }
  $Resource
}

$GetRoleState = {
  Param ([System.Object]$Cluster, [System.String]$Name)
  $Groups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq $Name })
  If ($Groups.Count -gt 1) { Throw ('File-server role {0} is ambiguous.' -f $Name) }
  If ($Groups.Count -eq 0) { Return $Null }
  $Group = $Groups[0]
  $Resources = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.OwnerGroup -ieq $Name })
  $NameResources = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Network Name' })
  If ($NameResources.Count -ne 1) { Throw ('Role {0} must expose exactly one Network Name resource; refusing IP prune.' -f $Name) }
  $IpResources = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'IP Address' })
  $Ips = @(
    ForEach ($Resource In $IpResources) {
      [PSCustomObject]@{
        resource    = $Resource
        name        = [System.String]$Resource.Name
        state       = [System.String]$Resource.State
        address     = [System.String](& $GetResourceParameterValue -Resource $Resource -Name 'Address')
        network     = [System.String](& $GetResourceParameterValue -Resource $Resource -Name 'Network')
        subnet_mask = [System.String](& $GetResourceParameterValue -Resource $Resource -Name 'SubnetMask')
        enable_dhcp = [System.Int32](& $GetResourceParameterValue -Resource $Resource -Name 'EnableDhcp')
      }
    }
  )
  $DependencyRead = @(Get-ClusterResourceDependency -InputObject $NameResources[0])
  $Dependency = ''
  If ($DependencyRead.Count -eq 1) {
    If ($DependencyRead[0].PSObject.Properties.Name -contains 'DependencyExpression') {
      $Dependency = [System.String]$DependencyRead[0].DependencyExpression
    } Else {
      $Dependency = [System.String]$DependencyRead[0]
    }
  }
  [PSCustomObject]@{
    group            = $Group
    name             = [System.String]$Group.Name
    state            = [System.String]$Group.State
    owner_node       = [System.String]$Group.OwnerNode
    preferred_owners = @((Get-ClusterOwnerNode -InputObject $Group).OwnerNodes | ForEach-Object -Process { [System.String]$PSItem.Name })
    resources        = $Resources
    name_resource    = $NameResources[0]
    ip_resources     = $Ips
    physical_disks   = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' })
    dependency       = $Dependency
  }
}

# Result payloads contain primitives only; live cmdlet objects remain internal.
$ConvertToSafeRoleState = {
  Param ([System.Object]$State)
  If ($Null -eq $State) { Return $Null }
  [PSCustomObject]@{
    name               = [System.String]$State.name
    state              = [System.String]$State.state
    owner_node         = [System.String]$State.owner_node
    preferred_owners   = @($State.preferred_owners | ForEach-Object -Process { [System.String]$PSItem })
    resources          = @($State.resources | ForEach-Object -Process {
        [PSCustomObject]@{
          name          = [System.String]$PSItem.Name
          resource_type = [System.String]$PSItem.ResourceType
          state         = [System.String]$PSItem.State
        }
      })
    name_resource_name = [System.String]$State.name_resource.Name
    ip_resources       = @($State.ip_resources | ForEach-Object -Process {
        [PSCustomObject]@{
          name        = [System.String]$PSItem.name
          state       = [System.String]$PSItem.state
          address     = [System.String]$PSItem.address
          network     = [System.String]$PSItem.network
          subnet_mask = [System.String]$PSItem.subnet_mask
          enable_dhcp = [System.Int32]$PSItem.enable_dhcp
        }
      })
    physical_disks     = @($State.physical_disks | ForEach-Object -Process {
        [PSCustomObject]@{ name = [System.String]$PSItem.Name; state = [System.String]$PSItem.State }
      })
    dependency         = [System.String]$State.dependency
  }
}

$GetCurrentIdentityName = Get-Variable -Name:'SetClusteredFileServerGetCurrentIdentityName' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $GetCurrentIdentityName) {
  $GetCurrentIdentityName = { [System.Security.Principal.WindowsIdentity]::GetCurrent().Name }
}

$ReadTranscriptTail = Get-Variable -Name:'SetClusteredFileServerReadTranscriptTail' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $ReadTranscriptTail) {
  $ReadTranscriptTail = {
    Param ([System.String]$Path)
    $Lines = @(Get-Content -LiteralPath $Path -Tail 40 -ErrorAction SilentlyContinue)
    If ($Lines.Count -eq 0) { Return '(transcript unavailable)' }
    $Lines -join [System.Environment]::NewLine
  }
}

$SetRestrictedAcl = Get-Variable -Name:'SetClusteredFileServerSetRestrictedAcl' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $SetRestrictedAcl) {
  $SetRestrictedAcl = {
    Param ([System.String]$Path, [System.Boolean]$Directory)
    $System = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-18')
    $Administrators = [System.Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $Acl = If ($Directory) {
      [System.Security.AccessControl.DirectorySecurity]::new()
    } Else {
      [System.Security.AccessControl.FileSecurity]::new()
    }
    $Acl.SetOwner($System)
    $Acl.SetAccessRuleProtection($True, $False)
    $Inheritance = If ($Directory) {
      [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
      [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } Else {
      [System.Security.AccessControl.InheritanceFlags]::None
    }
    ForEach ($Identity In @($System, $Administrators)) {
      $Rule = [System.Security.AccessControl.FileSystemAccessRule]::new(
        $Identity,
        [System.Security.AccessControl.FileSystemRights]::FullControl,
        $Inheritance,
        [System.Security.AccessControl.PropagationFlags]::None,
        [System.Security.AccessControl.AccessControlType]::Allow
      )
      $Null = $Acl.AddAccessRule($Rule)
    }
    Set-Acl -LiteralPath $Path -AclObject $Acl -ErrorAction Stop
  }
}

$ReadAcl = Get-Variable -Name:'SetClusteredFileServerReadAcl' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $ReadAcl) { $ReadAcl = { Param ([System.String]$Path) Get-Acl -LiteralPath $Path -ErrorAction Stop } }

$AssertRestrictedAcl = {
  Param ([System.String]$Path, [System.Boolean]$Directory)
  $AclReadback = @(& $ReadAcl -Path $Path)
  If ($AclReadback.Count -ne 1 -or $Null -eq $AclReadback[0]) {
    Throw ('Restricted ACL readback for {0} must return exactly one non-null object.' -f $Path)
  }
  $Acl = $AclReadback[0]
  $Owner = [System.String]$Acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value
  $Rules = @($Acl.GetAccessRules($True, $True, [System.Security.Principal.SecurityIdentifier]))
  $ExpectedInheritance = If ($Directory) {
    [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
    [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
  } Else {
    [System.Security.AccessControl.InheritanceFlags]::None
  }
  $ExpectedIdentities = @('S-1-5-18', 'S-1-5-32-544')
  $ObservedIdentities = @($Rules | ForEach-Object -Process { [System.String]$PSItem.IdentityReference.Value } | Sort-Object)
  $InvalidRules = @($Rules | Where-Object -FilterScript {
      $PSItem.IsInherited -or
      $PSItem.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow -or
      $PSItem.FileSystemRights -ne [System.Security.AccessControl.FileSystemRights]::FullControl -or
      $PSItem.InheritanceFlags -ne $ExpectedInheritance -or
      $PSItem.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None
    })
  If (-not $Acl.AreAccessRulesProtected -or $Owner -ne 'S-1-5-18' -or $Rules.Count -ne 2 -or
    $InvalidRules.Count -gt 0 -or
    (Compare-Object -ReferenceObject $ExpectedIdentities -DifferenceObject $ObservedIdentities -SyncWindow 0)) {
    Throw ('Restricted ACL readback failed for {0}; expected only SYSTEM and BUILTIN\Administrators FullControl with inheritance disabled.' -f $Path)
  }
}

$RegisterScheduledTask = Get-Variable -Name:'SetClusteredFileServerRegisterScheduledTask' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $RegisterScheduledTask) {
  $RegisterScheduledTask = {
    Param ($TaskName, $Action, $User, $Password)
    Register-ScheduledTask -TaskName $TaskName -Action $Action -User $User -Password $Password -RunLevel Highest -Force -ErrorAction Stop
  }
}
$GetScheduledTask = Get-Variable -Name:'SetClusteredFileServerGetScheduledTask' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $GetScheduledTask) { $GetScheduledTask = { Param ($TaskName) Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop } }
$StartScheduledTask = Get-Variable -Name:'SetClusteredFileServerStartScheduledTask' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $StartScheduledTask) { $StartScheduledTask = { Param ($TaskName) Start-ScheduledTask -TaskName $TaskName -ErrorAction Stop } }
$GetScheduledTaskInfo = Get-Variable -Name:'SetClusteredFileServerGetScheduledTaskInfo' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $GetScheduledTaskInfo) { $GetScheduledTaskInfo = { Param ($TaskName) Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop } }
$StopScheduledTask = Get-Variable -Name:'SetClusteredFileServerStopScheduledTask' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $StopScheduledTask) { $StopScheduledTask = { Param ($TaskName) Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop } }
$UnregisterScheduledTask = Get-Variable -Name:'SetClusteredFileServerUnregisterScheduledTask' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $UnregisterScheduledTask) {
  $UnregisterScheduledTask = { Param ($TaskName) Unregister-ScheduledTask -TaskName $TaskName -Confirm:$False -ErrorAction Stop }
}
$GetUtcNow = Get-Variable -Name:'SetClusteredFileServerGetUtcNow' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $GetUtcNow) { $GetUtcNow = { [System.DateTime]::UtcNow } }
$WaitForScheduledTask = Get-Variable -Name:'SetClusteredFileServerWaitForScheduledTask' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $WaitForScheduledTask) { $WaitForScheduledTask = { Start-Sleep -Seconds 5 } }
$RemoveArtifact = Get-Variable -Name:'SetClusteredFileServerRemoveArtifact' -ValueOnly -ErrorAction:'SilentlyContinue'
If ($Null -eq $RemoveArtifact) {
  $RemoveArtifact = { Param ([System.String]$Path) Remove-Item -LiteralPath $Path -Force -ErrorAction Stop }
}
$FormatScheduledTaskError = {
  Param ([System.String]$Label, [System.Management.Automation.ErrorRecord]$Record)
  $Native = If ($Record.Exception -is [System.Management.Automation.CmdletInvocationException]) {
    $Code = [System.BitConverter]::ToUInt32([System.BitConverter]::GetBytes([System.Int32]$Record.Exception.HResult), 0)
    ' (HRESULT 0x{0:X8})' -f $Code
  } Else { '' }
  '{0} failed{1}: {2}' -f $Label, $Native, $Record.Exception.Message
}

# Add-ClusterFileServerRole enables the role Virtual Computer Object in Active Directory, a second
# hop off the node that a direct network logon cannot delegate. The whole role create/converge runs
# inside a batch-logon scheduled task, which can delegate, exactly as cluster formation does.
$InvokeBatchMutation = {
  Param ([System.Object]$Mutation, [System.String]$RunAsPassword, [System.Int32]$DeadlineSeconds)
  $TaskName = 'Set-ClusteredFileServer-{0}' -f [System.Guid]::NewGuid().ToString('N')
  $RunDirectory = Join-Path -Path (Join-Path -Path $env:SystemRoot -ChildPath 'Temp') -ChildPath ([System.Guid]::NewGuid().ToString('D'))
  $PayloadPath = Join-Path -Path $RunDirectory -ChildPath 'mutation.ps1'
  $TranscriptPath = Join-Path -Path $RunDirectory -ChildPath 'mutation.log'
  $RunDirectoryCreated = $False
  $TaskRegistered = $False
  $TaskRegistrationAttempted = $False
  $PrimaryError = $Null
  Try {
    $Null = New-Item -ItemType Directory -Path $RunDirectory -ErrorAction Stop
    $RunDirectoryCreated = $True
    $RunDirectoryItem = Get-Item -LiteralPath $RunDirectory -Force -ErrorAction Stop
    If (($RunDirectoryItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
      Throw ('Batch role mutation directory is a reparse point: {0}.' -f $RunDirectory)
    }
    & $SetRestrictedAcl -Path $RunDirectory -Directory $True
    & $AssertRestrictedAcl -Path $RunDirectory -Directory $True
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
    $GetParameterValue = {
      Param ([System.Object]$Resource, [System.String]$Name)
      $Value = @(Get-ClusterParameter -InputObject $Resource -Name $Name)
      If ($Value.Count -ne 1) { Throw ('Resource {0} must expose one {1} parameter.' -f $Resource.Name, $Name) }
      $Value[0].Value
    }
    $ReadRoleState = {
      Param ([System.Object]$Cluster, [System.String]$Name)
      $Groups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq $Name })
      If ($Groups.Count -gt 1) { Throw ('File-server role {0} is ambiguous.' -f $Name) }
      If ($Groups.Count -eq 0) { Return $Null }
      $Group = $Groups[0]
      $Resources = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.OwnerGroup -ieq $Name })
      $NameResources = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Network Name' })
      If ($NameResources.Count -ne 1) { Throw ('Role {0} must expose exactly one Network Name resource; refusing IP prune.' -f $Name) }
      $Ips = @(
        ForEach ($Resource In @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'IP Address' })) {
          [PSCustomObject]@{
            resource    = $Resource
            name        = [System.String]$Resource.Name
            state       = [System.String]$Resource.State
            address     = [System.String](& $GetParameterValue -Resource $Resource -Name 'Address')
            network     = [System.String](& $GetParameterValue -Resource $Resource -Name 'Network')
            subnet_mask = [System.String](& $GetParameterValue -Resource $Resource -Name 'SubnetMask')
            enable_dhcp = [System.Int32](& $GetParameterValue -Resource $Resource -Name 'EnableDhcp')
          }
        }
      )
      $DependencyRead = @(Get-ClusterResourceDependency -InputObject $NameResources[0])
      $Dependency = ''
      If ($DependencyRead.Count -eq 1) {
        If ($DependencyRead[0].PSObject.Properties.Name -contains 'DependencyExpression') { $Dependency = [System.String]$DependencyRead[0].DependencyExpression }
        Else { $Dependency = [System.String]$DependencyRead[0] }
      }
      [PSCustomObject]@{
        state            = [System.String]$Group.State
        owner_node       = [System.String]$Group.OwnerNode
        preferred_owners = @((Get-ClusterOwnerNode -InputObject $Group).OwnerNodes | ForEach-Object -Process { [System.String]$PSItem.Name })
        name_resource    = $NameResources[0]
        ip_resources     = $Ips
        physical_disks   = @($Resources | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' })
        dependency       = [System.String]$Dependency
      }
    }
    $DesiredAddresses = @($Mutation.desired_ips | ForEach-Object -Process { [System.String]$PSItem.address })
    $DesiredOwners = @($Mutation.owners | ForEach-Object -Process { ([System.String]$PSItem).ToLowerInvariant() })

    $Clusters = @(Get-Cluster)
    If ($Clusters.Count -ne 1) { Throw ('Expected one local cluster; found {0}.' -f $Clusters.Count) }
    $Cluster = $Clusters[0]
    If ([System.String]$Cluster.Name -ine [System.String]$Mutation.cluster_name) {
      Throw ('The local node belongs to cluster {0}, not {1}.' -f $Cluster.Name, $Mutation.cluster_name)
    }

    If ($Mutation.create_role) {
      $ReadHomeDisk = {
        @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript {
            [System.String]$PSItem.ResourceType -eq 'Physical Disk' -and
            [System.String]$PSItem.Name -ieq [System.String]$Mutation.home_disk_name
          })
      }
      $GetHomeDiskState = {
        $Observed = @(& $ReadHomeDisk)
        If ($Observed.Count -eq 1) { Return [System.String]$Observed[0].State }
        'Unavailable ({0} exact matches)' -f $Observed.Count
      }
      $HomeMatches = @(& $ReadHomeDisk)
      If ($HomeMatches.Count -ne 1) {
        Throw ('Home disk {0} could not be resolved for placement; observed state: {1}.' -f $Mutation.home_disk_name, (& $GetHomeDiskState))
      }
      $HomeDisk = $HomeMatches[0]
      $HomeGroupName = [System.String]$HomeDisk.OwnerGroup
      $HomeGroups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq $HomeGroupName })
      If ($HomeGroups.Count -ne 1) {
        Throw ('Home disk {0} group {1} could not be resolved for placement; observed state: {2}.' -f $Mutation.home_disk_name, $HomeGroupName, (& $GetHomeDiskState))
      }
      Try {
        $Null = Move-ClusterGroup -InputObject $HomeGroups[0] -Node $Mutation.owners[0] -Wait 600
      } Catch {
        Throw ('Home disk {0} failed group placement; observed state: {1}. {2}' -f $Mutation.home_disk_name, (& $GetHomeDiskState), $PSItem.Exception.Message)
      }
      $HomeGroupReadback = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq $HomeGroupName })
      If ($HomeGroupReadback.Count -ne 1 -or [System.String]$HomeGroupReadback[0].OwnerNode -ine [System.String]$Mutation.owners[0]) {
        $ObservedOwner = If ($HomeGroupReadback.Count -eq 1) { [System.String]$HomeGroupReadback[0].OwnerNode } Else { 'Unavailable' }
        Throw ('Home disk {0} failed group-placement readback; observed state: {1}; group owner: {2}.' -f $Mutation.home_disk_name, (& $GetHomeDiskState), $ObservedOwner)
      }
      Try {
        $Null = Start-ClusterResource -InputObject $HomeDisk -Wait 300
      } Catch {
        Throw ('Home disk {0} failed start; observed state: {1}. {2}' -f $Mutation.home_disk_name, (& $GetHomeDiskState), $PSItem.Exception.Message)
      }
      $HomeReadback = @(& $ReadHomeDisk)
      $ObservedState = If ($HomeReadback.Count -eq 1) { [System.String]$HomeReadback[0].State } Else { 'Unavailable' }
      If ($HomeReadback.Count -ne 1 -or $ObservedState -ne 'Online') {
        Throw ('Home disk {0} failed Online readback; observed state: {1}.' -f $Mutation.home_disk_name, $ObservedState)
      }
      # Add-ClusterFileServerRole runs a per-node IsDomainJoined WMI/RPC check that can return
      # RPC-unavailable while a freshly formed cluster's node-to-node path becomes ready. This
      # readiness pre-screen retries every node for up to five minutes, every 15 seconds.
      $PreScreenDeadlineSeconds = 300
      $PreScreenIntervalSeconds = 15
      $PreScreenDeadline = [System.DateTime]::UtcNow.AddSeconds($PreScreenDeadlineSeconds)
      $ClusterNodeNames = @(Get-ClusterNode -InputObject $Cluster | ForEach-Object -Process { [System.String]$PSItem.Name })
      $UseCimProbe = $Null -ne (Get-Command -Name 'Get-CimInstance' -ErrorAction SilentlyContinue)
      Do {
        $LastProbeFailures = [ordered]@{}
        ForEach ($ClusterNodeName In $ClusterNodeNames) {
          Try {
            If ($UseCimProbe) {
              $ProbeResult = @(Get-CimInstance -ClassName Win32_ComputerSystem -ComputerName $ClusterNodeName -ErrorAction Stop)
            } Else {
              $ProbeResult = @(Get-WmiObject -Class Win32_ComputerSystem -ComputerName $ClusterNodeName -ErrorAction Stop)
            }
            If ($ProbeResult.Count -ne 1 -or $Null -eq $ProbeResult[0]) {
              Throw ('Expected one Win32_ComputerSystem result; found {0}.' -f $ProbeResult.Count)
            }
          } Catch {
            $LastProbeFailures[$ClusterNodeName] = [System.String]$PSItem.Exception.Message
          }
        }
        If ($LastProbeFailures.Count -eq 0) { Break }
        $RemainingMilliseconds = [System.Int64][Math]::Floor(($PreScreenDeadline - [System.DateTime]::UtcNow).TotalMilliseconds)
        If ($RemainingMilliseconds -le 0) {
          $FailureDetails = @(ForEach ($Failure In $LastProbeFailures.GetEnumerator()) {
              '{0} (last error: {1})' -f $Failure.Key, $Failure.Value
            })
          Throw ('Cluster node readiness pre-screen timed out after {0} seconds; nodes that did not respond: {1}.' -f $PreScreenDeadlineSeconds, ($FailureDetails -join '; '))
        }
        $WaitMilliseconds = [System.Int32][Math]::Min(
          [System.Int64]$PreScreenIntervalSeconds * 1000,
          $RemainingMilliseconds
        )
        If ($WaitMilliseconds -gt 0) { Start-Sleep -Milliseconds $WaitMilliseconds }
      } While ($True)
      $Null = Add-ClusterFileServerRole -InputObject $Cluster -Name $Mutation.role_name -Storage $Mutation.home_disk_name -StaticAddress $Mutation.static_addresses -Wait 600
    }

    $Current = & $ReadRoleState -Cluster $Cluster -Name $Mutation.role_name
    If ($Null -eq $Current) { Throw ('Role {0} is absent after creation.' -f $Mutation.role_name) }

    If (@($Current.physical_disks | ForEach-Object -Process { [System.String]$PSItem.Name }).Count -eq 0) {
      $HomeMatches = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.ResourceType -eq 'Physical Disk' -and [System.String]$PSItem.Name -ieq [System.String]$Mutation.home_disk_name })
      If ($HomeMatches.Count -ne 1) { Throw ('Home disk {0} was not acquired for placement.' -f $Mutation.home_disk_name) }
      $Null = Move-ClusterResource -InputObject $HomeMatches[0] -Group $Mutation.role_name
    }

    $CurrentOwners = @($Current.preferred_owners | ForEach-Object -Process { ([System.String]$PSItem).ToLowerInvariant() })
    If ($CurrentOwners.Count -ne $DesiredOwners.Count -or (Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $CurrentOwners -SyncWindow 0)) {
      $Null = Set-ClusterOwnerNode -Group $Mutation.role_name -Owners $Mutation.owners
    }

    $IpTransaction = $False
    ForEach ($Desired In $Mutation.desired_ips) {
      $IpMatches = @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -eq [System.String]$Desired.address })
      If ($IpMatches.Count -gt 1) { Throw ('Role {0} has duplicate IP resources for {1}.' -f $Mutation.role_name, $Desired.address) }
      If ($IpMatches.Count -eq 0) {
        $IpTransaction = $True
      } ElseIf ($IpMatches[0].network -ne [System.String]$Desired.network -or $IpMatches[0].subnet_mask -ne [System.String]$Desired.subnet_mask -or $IpMatches[0].enable_dhcp -ne 0) {
        $IpTransaction = $True
      }
    }
    If ($Mutation.create_role) {
      $IpTransaction = $True
      If ($Current.state -ne 'Offline') { $Null = Stop-ClusterGroup -Name $Mutation.role_name -Wait 600 }
      $Current = & $ReadRoleState -Cluster $Cluster -Name $Mutation.role_name
    }
    $ExtraIps = @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -notin $DesiredAddresses })
    If ($ExtraIps.Count -gt 0) {
      $IpTransaction = $True
      ForEach ($Extra In $ExtraIps) {
        If (-not $Mutation.create_role -and $Extra.enable_dhcp -ne 0) {
          Throw ('Refusing to prune IP resource {0}: DHCP is enabled.' -f $Extra.name)
        }
      }
      $OtherNameResources = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript {
          [System.String]$PSItem.ResourceType -eq 'Network Name' -and
          [System.String]$PSItem.Name -ine [System.String]$Current.name_resource.Name
        })
      ForEach ($NameResource In $OtherNameResources) {
        $DependencyRead = @(Get-ClusterResourceDependency -InputObject $NameResource)
        $Dependency = ''
        If ($DependencyRead.Count -eq 1) {
          If ($DependencyRead[0].PSObject.Properties.Name -contains 'DependencyExpression') { $Dependency = [System.String]$DependencyRead[0].DependencyExpression }
          Else { $Dependency = [System.String]$DependencyRead[0] }
        }
        $DependencyNames = @([System.Text.RegularExpressions.Regex]::Matches($Dependency, '\[([^\]]+)\]') | ForEach-Object -Process { [System.String]$PSItem.Groups[1].Value })
        ForEach ($Extra In $ExtraIps) {
          If ([System.String]$Extra.name -iin $DependencyNames) {
            Throw ('Refusing to prune IP resource {0}: it is a dependency of Network Name resource {1}.' -f $Extra.name, $NameResource.Name)
          }
        }
      }
    }
    $PreDependency = ((@($Mutation.desired_ips | ForEach-Object -Process {
            $DesiredAddress = [System.String]$PSItem.address
            $Existing = @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -eq $DesiredAddress })
            $IpName = If ($Existing.Count -eq 1) { [System.String]$Existing[0].name } Else { [System.String]$PSItem.name }
            [PSCustomObject]@{ address = $DesiredAddress; ip_name = $IpName }
          }) | Sort-Object -Property address | ForEach-Object -Process { '[{0}]' -f $PSItem.ip_name }) -join ' or ')
    If ($Current.dependency -ne $PreDependency) { $IpTransaction = $True }

    If ($IpTransaction) {
      If ($Current.state -ne 'Offline') { $Null = Stop-ClusterGroup -Name $Mutation.role_name -Wait 600 }
      ForEach ($Desired In $Mutation.desired_ips) {
        $IpMatches = @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -eq [System.String]$Desired.address })
        $IpToConfigure = $Null
        If ($IpMatches.Count -eq 0) {
          $Added = @(Add-ClusterResource -Name $Desired.name -ResourceType 'IP Address' -Group $Mutation.role_name)
          If ($Added.Count -ne 1) { Throw ('Adding role IP {0} did not return one resource.' -f $Desired.address) }
          $IpToConfigure = $Added[0]
        } ElseIf ($IpMatches[0].network -ne [System.String]$Desired.network -or $IpMatches[0].subnet_mask -ne [System.String]$Desired.subnet_mask -or $IpMatches[0].enable_dhcp -ne 0) {
          $IpToConfigure = $IpMatches[0].resource
        }
        If ($Null -ne $IpToConfigure) {
          $Null = $IpToConfigure | Set-ClusterParameter -Name 'Network' -Value ([System.String]$Desired.network)
          $Null = $IpToConfigure | Set-ClusterParameter -Name 'SubnetMask' -Value ([System.String]$Desired.subnet_mask)
          $Null = $IpToConfigure | Set-ClusterParameter -Name 'Address' -Value ([System.String]$Desired.address)
          $Null = $IpToConfigure | Set-ClusterParameter -Name 'EnableDhcp' -Value 0
        }
      }
      ForEach ($Extra In $ExtraIps) {
        If ($Extra.state -ne 'Offline') { $Null = Stop-ClusterResource -InputObject $Extra.resource -Wait 300 }
        $Null = Remove-ClusterResource -InputObject $Extra.resource -Force
      }
      $Current = & $ReadRoleState -Cluster $Cluster -Name $Mutation.role_name
      $DesiredDependency = ((@($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -in $DesiredAddresses }) | Sort-Object -Property address | ForEach-Object -Process { '[{0}]' -f $PSItem.name }) -join ' or ')
      $Null = Set-ClusterResourceDependency -InputObject $Current.name_resource -Dependency $DesiredDependency
      If (-not $Mutation.create_role) { $Null = Start-ClusterGroup -Name $Mutation.role_name -Wait 600 }
    } ElseIf (-not $Mutation.create_role -and $Current.state -ne 'Online') {
      $Null = Start-ClusterGroup -Name $Mutation.role_name -Wait 600
    }

    If ($Mutation.create_role) {
      $Null = Start-ClusterGroup -Name $Mutation.role_name -Wait 600
      # Upstream validates two disjoint owner pairs covering all four nodes; this readback refuses
      # the realistic state where disk adoption did not leave that exact away disk behind.
      $ClusterNodeNames = @(Get-ClusterNode -InputObject $Cluster | ForEach-Object -Process {
          ([System.String]$PSItem.Name).ToLowerInvariant()
        } | Sort-Object -Unique)
      $ExpectedAwayOwners = [System.String[]]@($ClusterNodeNames | Where-Object -FilterScript { $PSItem -notin $DesiredOwners })
      [System.Array]::Sort($ExpectedAwayOwners, [System.StringComparer]::OrdinalIgnoreCase)
      $AwayDisks = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript {
          [System.String]$PSItem.ResourceType -eq 'Physical Disk' -and
          [System.String]$PSItem.OwnerGroup -ieq 'Available Storage'
        })
      If ($AwayDisks.Count -ne 1) {
        Throw ('Expected exactly one Physical Disk in Available Storage after role creation; found {0}.' -f $AwayDisks.Count)
      }
      $AwayOwnerReadback = @(Get-ClusterOwnerNode -InputObject $AwayDisks[0])
      If ($AwayOwnerReadback.Count -ne 1 -or $Null -eq $AwayOwnerReadback[0]) {
        Throw 'Away-disk owner readback must return exactly one non-null object.'
      }
      $AwayOwners = [System.String[]]@($AwayOwnerReadback[0].OwnerNodes | ForEach-Object -Process {
          ([System.String]$PSItem.Name).ToLowerInvariant()
        })
      [System.Array]::Sort($AwayOwners, [System.StringComparer]::OrdinalIgnoreCase)
      If ($AwayOwners.Count -ne $ExpectedAwayOwners.Count -or
        (Compare-Object -ReferenceObject $ExpectedAwayOwners -DifferenceObject $AwayOwners -SyncWindow 0)) {
        Throw 'The Physical Disk in Available Storage is not scoped to the expected away owners.'
      }
      $AvailableStorageGroups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript {
          [System.String]$PSItem.Name -ieq 'Available Storage'
        })
      If ($AvailableStorageGroups.Count -ne 1) { Throw 'Expected exactly one local Available Storage group.' }
      $AwayTarget = $ExpectedAwayOwners[0]
      $Null = Move-ClusterGroup -InputObject $AvailableStorageGroups[0] -Node $AwayTarget -Wait 600
      $AvailableStorageReadback = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript {
          [System.String]$PSItem.Name -ieq 'Available Storage'
        })
      If ($AvailableStorageReadback.Count -ne 1 -or [System.String]$AvailableStorageReadback[0].OwnerNode -ine $AwayTarget) {
        Throw 'Available Storage failed away-owner readback.'
      }
      $Null = Start-ClusterResource -InputObject $AwayDisks[0] -Wait 300
      $AwayDiskReadback = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript {
          [System.String]$PSItem.ResourceType -eq 'Physical Disk' -and
          [System.String]$PSItem.Name -ieq [System.String]$AwayDisks[0].Name
        })
      If ($AwayDiskReadback.Count -ne 1 -or [System.String]$AwayDiskReadback[0].State -ne 'Online') {
        Throw ('Physical Disk resource {0} failed Online readback after away placement.' -f $AwayDisks[0].Name)
      }
      $AllDisks = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript {
          [System.String]$PSItem.ResourceType -eq 'Physical Disk'
        })
      If ($AllDisks.Count -ne 2 -or @($AllDisks | Where-Object -FilterScript { [System.String]$PSItem.State -ne 'Online' }).Count -gt 0) {
        Throw 'Both declared Physical Disk resources must be Online after final placement.'
      }
    }

    $After = & $ReadRoleState -Cluster $Cluster -Name $Mutation.role_name
    $Failures = @()
    If ($Null -eq $After) {
      $Failures += ('Role {0} was not acquired after mutation.' -f $Mutation.role_name)
    } Else {
      If ($After.state -ne 'Online' -or ([System.String]$After.owner_node).ToLowerInvariant() -notin $DesiredOwners) {
        $Failures += ('Role {0} failed group-state readback.' -f $Mutation.role_name)
      }
      $AfterOwners = @($After.preferred_owners | ForEach-Object -Process { ([System.String]$PSItem).ToLowerInvariant() })
      If ($AfterOwners.Count -ne $DesiredOwners.Count -or (Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $AfterOwners -SyncWindow 0)) {
        $Failures += 'Role preferred-owner readback failed.'
      }
      If ($After.physical_disks.Count -ne 1 -or [System.String]$After.physical_disks[0].Name -ine [System.String]$Mutation.home_disk_name -or [System.String]$After.physical_disks[0].State -ne 'Online') {
        $Failures += 'Role home-disk readback failed.'
      }
      If ($After.ip_resources.Count -ne $DesiredAddresses.Count -or @($After.ip_resources | Where-Object -FilterScript { $PSItem.address -notin $DesiredAddresses }).Count -gt 0 -or
        @($After.ip_resources | Where-Object -FilterScript { $PSItem.enable_dhcp -ne 0 }).Count -gt 0 -or
        @($After.ip_resources | Where-Object -FilterScript { $PSItem.state -eq 'Online' }).Count -ne 1) {
        $Failures += 'Role static-IP membership/state readback failed.'
      }
      $ExactDependency = ((@($After.ip_resources | Sort-Object -Property address | ForEach-Object -Process { '[{0}]' -f $PSItem.name })) -join ' or ')
      If ($After.dependency -ne $ExactDependency) { $Failures += 'Role Network Name dependency readback failed.' }
    }
    If ($Failures.Count -eq 0) {
      $ExitCode = 0
    } Else {
      ForEach ($Failure In $Failures) { Write-Output -InputObject ([System.String]$Failure) }
    }
  } Catch {
    Write-Output -InputObject ([System.String]$PSItem.Exception.Message)
  }
} *> $TranscriptPath
Exit $ExitCode
'@
    $InnerCommand = $InnerCommand.Replace('__MUTATION_PAYLOAD__', $MutationPayload).Replace('__TRANSCRIPT_PAYLOAD__', $TranscriptPayload)
    [System.IO.File]::WriteAllText($PayloadPath, $InnerCommand, [System.Text.UTF8Encoding]::new($False))
    & $SetRestrictedAcl -Path $PayloadPath -Directory $False
    & $AssertRestrictedAcl -Path $PayloadPath -Directory $False
    # -File bounds the action length. Process-scoped bypass is safe for this locally generated file
    # in the read-back restricted directory; MachinePolicy and App Control remain authoritative.
    $ActionArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $PayloadPath
    $Action = New-ScheduledTaskAction -Execute (Join-Path -Path $PSHOME -ChildPath 'powershell.exe') -Argument $ActionArguments
    $CurrentUser = & $GetCurrentIdentityName
    $TaskRegistrationAttempted = $True
    Try {
      $Null = & $RegisterScheduledTask -TaskName $TaskName -Action $Action -User $CurrentUser -Password $RunAsPassword
    } Catch {
      Throw (& $FormatScheduledTaskError -Label 'Scheduled task registration' -Record $PSItem)
    }
    $TaskRegistered = $True
    Try {
      $RegisteredTask = @(& $GetScheduledTask -TaskName $TaskName | Where-Object -FilterScript { $Null -ne $PSItem })
    } Catch {
      Throw (& $FormatScheduledTaskError -Label 'Scheduled task registration readback' -Record $PSItem)
    }
    If ($RegisteredTask.Count -ne 1) {
      Throw ('Scheduled task registration readback must return exactly one non-null task; found {0}.' -f $RegisteredTask.Count)
    }
    Try {
      $PreStartInfo = @(& $GetScheduledTaskInfo -TaskName $TaskName | Where-Object -FilterScript { $Null -ne $PSItem })
    } Catch {
      Throw (& $FormatScheduledTaskError -Label 'Scheduled task pre-start runtime-info readback' -Record $PSItem)
    }
    If ($PreStartInfo.Count -ne 1) {
      Throw ('Scheduled task pre-start runtime-info readback must return exactly one non-null object; found {0}.' -f $PreStartInfo.Count)
    }
    If ($PreStartInfo[0].PSObject.Properties.Name -notcontains 'LastRunTime' -or $Null -eq $PreStartInfo[0].LastRunTime) {
      Throw 'Scheduled task pre-start runtime-info readback lacks LastRunTime.'
    }
    $PreStartLastRunTime = [System.DateTime]$PreStartInfo[0].LastRunTime
    Try {
      $Null = & $StartScheduledTask -TaskName $TaskName
    } Catch {
      Throw (& $FormatScheduledTaskError -Label 'Scheduled task start' -Record $PSItem)
    }
    $Deadline = (& $GetUtcNow).AddSeconds($DeadlineSeconds)
    $PendingResults = [System.UInt32[]]@(267009, 267011, 267045)
    Do {
      Try {
        $TaskInfo = @(& $GetScheduledTaskInfo -TaskName $TaskName | Where-Object -FilterScript { $Null -ne $PSItem })
      } Catch {
        Throw (& $FormatScheduledTaskError -Label 'Scheduled task runtime-info poll' -Record $PSItem)
      }
      If ($TaskInfo.Count -ne 1) {
        Throw ('Scheduled task runtime-info poll must return exactly one non-null object; found {0}.' -f $TaskInfo.Count)
      }
      If ($TaskInfo[0].PSObject.Properties.Name -notcontains 'LastRunTime' -or $Null -eq $TaskInfo[0].LastRunTime -or
        $TaskInfo[0].PSObject.Properties.Name -notcontains 'LastTaskResult' -or $Null -eq $TaskInfo[0].LastTaskResult) {
        Throw 'Scheduled task runtime-info poll lacks LastRunTime or LastTaskResult.'
      }
      $TaskResult = [System.UInt32]$TaskInfo[0].LastTaskResult
      $LastRunTime = [System.DateTime]$TaskInfo[0].LastRunTime
      If ($LastRunTime -gt $PreStartLastRunTime -and $TaskResult -notin $PendingResults) { Break }
      If ((& $GetUtcNow) -ge $Deadline) {
        $Tail = & $ReadTranscriptTail -Path $TranscriptPath
        Throw ('Batch role mutation timed out after {0} seconds. Transcript tail:{1}{2}' -f $DeadlineSeconds, [System.Environment]::NewLine, $Tail)
      }
      & $WaitForScheduledTask
    } While ($True)
    If ($TaskResult -ne 0) {
      $Tail = & $ReadTranscriptTail -Path $TranscriptPath
      If (($TaskResult -band 0xFFFF) -eq 1260 -or $Tail -match '(?i)(AppLocker|App Control|execution policy|running scripts is disabled|blocked.+policy|method invocation is supported only on core types in this language mode)') {
        Throw ('Batch role mutation was blocked by execution policy or App Control, including constrained language mode (scheduled task result {0}). Transcript tail:{1}{2}' -f $TaskResult, [System.Environment]::NewLine, $Tail)
      }
      Throw ('Batch role mutation failed with scheduled task result {0}. Transcript tail:{1}{2}' -f $TaskResult, [System.Environment]::NewLine, $Tail)
    }
  } Catch {
    $PrimaryError = $PSItem
  }

  $CleanupFailures = [System.Collections.Generic.List[System.String]]::new()
  $CleanupTask = @()
  If ($TaskRegistrationAttempted) {
    Try {
      $CleanupTask = @(& $GetScheduledTask -TaskName $TaskName | Where-Object -FilterScript { $Null -ne $PSItem })
      If ($CleanupTask.Count -gt 1) { Throw ('Scheduled task cleanup readback returned {0} objects.' -f $CleanupTask.Count) }
      If ($CleanupTask.Count -eq 1 -and [System.String]$CleanupTask[0].State -eq 'Running') {
        $Null = & $StopScheduledTask -TaskName $TaskName
      }
    } Catch {
      $CleanupFailures.Add(('stop-if-running {0}: {1}' -f $TaskName, $PSItem.Exception.Message))
    }
    If ($TaskRegistered -or $CleanupTask.Count -eq 1) {
      Try {
        $Null = & $UnregisterScheduledTask -TaskName $TaskName
      } Catch {
        $CleanupFailures.Add(('unregister {0}: {1}' -f $TaskName, $PSItem.Exception.Message))
      }
    }
  }
  ForEach ($Artifact In @(
      [PSCustomObject]@{ label = 'payload'; path = $PayloadPath },
      [PSCustomObject]@{ label = 'transcript'; path = $TranscriptPath }
    )) {
    Try {
      If (Test-Path -LiteralPath $Artifact.path) { $Null = & $RemoveArtifact -Path $Artifact.path }
      If (Test-Path -LiteralPath $Artifact.path) { Throw ('{0} still exists after removal.' -f $Artifact.path) }
    } Catch {
      $CleanupFailures.Add(('{0} {1}: {2}' -f $Artifact.label, $Artifact.path, $PSItem.Exception.Message))
    }
  }
  If ($RunDirectoryCreated) {
    Try {
      If (Test-Path -LiteralPath $RunDirectory) {
        $RemainingArtifacts = @(Get-ChildItem -LiteralPath $RunDirectory -Force -ErrorAction Stop)
        If ($RemainingArtifacts.Count -gt 0) {
          Throw ('{0} contains {1} artifacts after file cleanup.' -f $RunDirectory, $RemainingArtifacts.Count)
        }
        $Null = & $RemoveArtifact -Path $RunDirectory
      }
      If (Test-Path -LiteralPath $RunDirectory) { Throw ('{0} still exists after removal.' -f $RunDirectory) }
    } Catch {
      $CleanupFailures.Add(('directory {0}: {1}' -f $RunDirectory, $PSItem.Exception.Message))
    }
  }
  If ($Null -ne $PrimaryError) {
    $CleanupText = If ($CleanupFailures.Count -gt 0) {
      '{0}Cleanup failures: {1}' -f [System.Environment]::NewLine, ($CleanupFailures -join '; ')
    } Else { '' }
    Throw ('{0}{1}' -f $PrimaryError.Exception.Message, $CleanupText)
  }
  If ($CleanupFailures.Count -gt 0) {
    Throw ('Batch role mutation cleanup failed: {0}' -f ($CleanupFailures -join '; '))
  }
}

If ($HomeVolumeId -notmatch '^vol-[0-9a-fA-F]+$') { Throw ('Malformed HomeVolumeId: {0}.' -f $HomeVolumeId) }
$OwnerNames = @($Owners | ForEach-Object -Process { ([System.String]$PSItem).Trim() })
If ($OwnerNames.Count -ne 2 -or @($OwnerNames | ForEach-Object -Process { $PSItem.ToLowerInvariant() } | Select-Object -Unique).Count -ne 2) {
  Throw 'Owners must contain exactly two unique node names.'
}
$DesiredAddresses = @($StaticAddress | ForEach-Object -Process { ([System.String]$PSItem).Trim() })
$IgnoredAddresses = @($IgnoredNetworkAddress | ForEach-Object -Process { ([System.String]$PSItem).Trim() })
If ($DesiredAddresses.Count -ne 2 -or @($DesiredAddresses | Select-Object -Unique).Count -ne 2 -or
  $IgnoredAddresses.Count -ne 2 -or @($IgnoredAddresses | Select-Object -Unique).Count -ne 2) {
  Throw 'StaticAddress and IgnoredNetworkAddress must each contain two unique IPv4 values.'
}
ForEach ($Address In ($DesiredAddresses + $IgnoredAddresses)) { $Null = & $ConvertToIpv4UInt32 -Address $Address }

# Cluster truth is local until the cluster name can resolve.
$Clusters = @(Get-Cluster)
If ($Clusters.Count -ne 1) { Throw ('Expected one local cluster; found {0}.' -f $Clusters.Count) }
$Cluster = $Clusters[0]
If ([System.String]$Cluster.Name -ine $ClusterName) {
  Throw ('The local node belongs to cluster {0}, not {1}.' -f $Cluster.Name, $ClusterName)
}
$HomeDisk = & $GetHomeDiskResource -Cluster $Cluster -VolumeId $HomeVolumeId
$Networks = @(Get-ClusterNetwork -InputObject $Cluster)
$StaticNetworks = @{}
ForEach ($Address In $DesiredAddresses) {
  $AddressInteger = & $ConvertToIpv4UInt32 -Address $Address
  $NetworkMatches = @($Networks | Where-Object -FilterScript {
      $MaskInteger = & $ConvertToIpv4UInt32 -Address ([System.String]$PSItem.AddressMask)
      $NetworkInteger = & $ConvertToIpv4UInt32 -Address ([System.String]$PSItem.Address)
      ($AddressInteger -band $MaskInteger) -eq ($NetworkInteger -band $MaskInteger)
    })
  If ($NetworkMatches.Count -ne 1) { Throw ('Static address {0} must map to exactly one cluster network.' -f $Address) }
  $StaticNetworks[$Address] = $NetworkMatches[0]
}
$IgnoredNetworks = @()
ForEach ($Address In $IgnoredAddresses) {
  $NetworkMatches = @($Networks | Where-Object -FilterScript { [System.String]$PSItem.Address -eq $Address })
  If ($NetworkMatches.Count -ne 1) { Throw ('Ignored network address {0} must map to exactly one cluster network.' -f $Address) }
  $IgnoredNetworks += $NetworkMatches[0]
}
$StaticNetworkNames = @($StaticNetworks.Values | ForEach-Object -Process { [System.String]$PSItem.Name } | Sort-Object -Unique)
$IgnoredNetworkNames = @($IgnoredNetworks | ForEach-Object -Process { [System.String]$PSItem.Name } | Sort-Object -Unique)
If (@(Compare-Object -ReferenceObject $StaticNetworkNames -DifferenceObject $IgnoredNetworkNames -IncludeEqual -ExcludeDifferent).Count -gt 0) {
  Throw 'Static and ignored network declarations overlap.'
}
$EligibleNetworkNames = @($Networks | Where-Object -FilterScript { [System.Int32]$PSItem.Role -in @(2, 3) } | ForEach-Object -Process { [System.String]$PSItem.Name } | Sort-Object -Unique)
$DeclaredNetworkNames = @(($StaticNetworkNames + $IgnoredNetworkNames) | Sort-Object -Unique)
If (@(Compare-Object -ReferenceObject $EligibleNetworkNames -DifferenceObject $DeclaredNetworkNames).Count -gt 0) {
  Throw 'Static and ignored declarations must cover every client-eligible cluster network exactly.'
}

$Before = & $GetRoleState -Cluster $Cluster -Name $RoleName
$Current = $Before
$Actions = [System.Collections.Generic.List[System.String]]::new()
$IpTransaction = $False
$DesiredDependency = ''
# Creation is planned here but executed in the batch task below; the residual IP/owner/dependency
# convergence for a freshly created role is computed and applied there against live state.
If ($Null -eq $Before) {
  $Actions.Add('create_role')
}

If ($Null -ne $Current) {
  $RolePhysicalNames = @($Current.physical_disks | ForEach-Object -Process { [System.String]$PSItem.Name })
  If ($RolePhysicalNames.Count -gt 0 -and ($RolePhysicalNames.Count -ne 1 -or $RolePhysicalNames[0] -ine [System.String]$HomeDisk.Name)) {
    Throw ('Role {0} contains a wrong or extra Physical Disk resource.' -f $RoleName)
  }
  If ($RolePhysicalNames.Count -eq 0) {
    If ([System.String]$HomeDisk.OwnerGroup -ne 'Available Storage') { Throw 'The home disk belongs to a foreign cluster group.' }
    $Actions.Add('move_home_disk')
  }
  $CurrentOwners = @($Current.preferred_owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  $DesiredOwners = @($OwnerNames | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  If ($CurrentOwners.Count -ne $DesiredOwners.Count -or (Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $CurrentOwners -SyncWindow 0)) {
    $Actions.Add('set_preferred_owners')
  }
  $DesiredIpObjects = @()
  ForEach ($Address In $DesiredAddresses) {
    $IpMatches = @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -eq $Address })
    If ($IpMatches.Count -gt 1) { Throw ('Role {0} has duplicate IP resources for {1}.' -f $RoleName, $Address) }
    $Network = $StaticNetworks[$Address]
    If ($IpMatches.Count -eq 0) {
      $Actions.Add(('add_ip:{0}' -f $Address))
      $IpTransaction = $True
      $DesiredIpObjects += [PSCustomObject]@{ address = $Address; name = "IP Address $Address"; network = [System.String]$Network.Name; subnet_mask = [System.String]$Network.AddressMask }
    } Else {
      $Ip = $IpMatches[0]
      $DesiredIpObjects += $Ip
      If ($Ip.network -ne [System.String]$Network.Name -or $Ip.subnet_mask -ne [System.String]$Network.AddressMask -or $Ip.enable_dhcp -ne 0) {
        $Actions.Add(('correct_ip:{0}' -f $Address))
        $IpTransaction = $True
      }
    }
  }
  ForEach ($Extra In @($Current.ip_resources | Where-Object -FilterScript { $PSItem.address -notin $DesiredAddresses })) {
    $Actions.Add(('remove_ip:{0}' -f $Extra.name))
    $IpTransaction = $True
  }
  $DesiredDependency = (($DesiredIpObjects | Sort-Object -Property address | ForEach-Object -Process { '[{0}]' -f $PSItem.name }) -join ' or ')
  If ($IpTransaction -or $Current.dependency -ne $DesiredDependency) {
    $Actions.Add('set_dependency')
    $IpTransaction = $True
  }
  If ($Current.state -ne 'Online' -and -not $IpTransaction) { $Actions.Add('start_group') }
}

If ($Actions.Count -eq 0 -or $Ansible.CheckMode) {
  $After = $Before
} Else {
  # The mutation payload carries primitives only; the batch task re-acquires live objects from them.
  $DesiredIps = @(
    ForEach ($Address In $DesiredAddresses) {
      $Network = $StaticNetworks[$Address]
      [PSCustomObject]@{ address = [System.String]$Address; name = ('IP Address {0}' -f $Address); network = [System.String]$Network.Name; subnet_mask = [System.String]$Network.AddressMask }
    }
  )
  $Mutation = [PSCustomObject]@{
    cluster_name          = [System.String]$ClusterName
    role_name             = [System.String]$RoleName
    create_role           = $Actions.Contains('create_role')
    home_disk_name        = [System.String]$HomeDisk.Name
    owners                = [System.String[]]@($OwnerNames)
    static_addresses      = [System.String[]]@($DesiredAddresses)
    desired_ips           = @($DesiredIps)
  }
  & $InvokeBatchMutation -Mutation $Mutation -RunAsPassword $Password -DeadlineSeconds $TimeoutSeconds
  $After = & $GetRoleState -Cluster $Cluster -Name $RoleName
}

If (-not $Ansible.CheckMode -or $Actions.Count -eq 0) {
  If ($Null -eq $After -or $After.state -ne 'Online' -or $After.owner_node.ToLowerInvariant() -notin @($OwnerNames | ForEach-Object -Process { $PSItem.ToLowerInvariant() })) {
    Throw ('Role {0} failed group-state readback.' -f $RoleName)
  }
  $AfterOwners = @($After.preferred_owners | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  $DesiredOwners = @($OwnerNames | ForEach-Object -Process { $PSItem.ToLowerInvariant() })
  If ($AfterOwners.Count -ne 2 -or (Compare-Object -ReferenceObject $DesiredOwners -DifferenceObject $AfterOwners -SyncWindow 0)) { Throw 'Role preferred-owner readback failed.' }
  If ($After.physical_disks.Count -ne 1 -or [System.String]$After.physical_disks[0].Name -ine [System.String]$HomeDisk.Name -or [System.String]$After.physical_disks[0].State -ne 'Online') {
    Throw 'Role home-disk readback failed.'
  }
  If ($After.ip_resources.Count -ne 2 -or @($After.ip_resources | Where-Object -FilterScript { $PSItem.address -notin $DesiredAddresses }).Count -gt 0 -or
    @($After.ip_resources | Where-Object -FilterScript { $PSItem.enable_dhcp -ne 0 }).Count -gt 0 -or
    @($After.ip_resources | Where-Object -FilterScript { $PSItem.state -eq 'Online' }).Count -ne 1) {
    Throw 'Role static-IP membership/state readback failed.'
  }
  ForEach ($Ip In $After.ip_resources) {
    $Network = $StaticNetworks[$Ip.address]
    If ($Ip.network -ne [System.String]$Network.Name -or $Ip.subnet_mask -ne [System.String]$Network.AddressMask) { Throw 'Role static-IP network readback failed.' }
  }
  $ExactDependency = (($After.ip_resources | Sort-Object -Property address | ForEach-Object -Process { '[{0}]' -f $PSItem.name }) -join ' or ')
  If ($After.dependency -ne $ExactDependency) { Throw 'Role Network Name dependency readback failed.' }
}

# The adoption region deliberately deferred disks that Available Storage's one owner could not
# host. Once the home disk leaves, this role region can place each remaining mismatched disk.
If ($Null -ne $After -and $After.physical_disks.Count -eq 1) {
  $RemainingDisks = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript {
      [System.String]$PSItem.ResourceType -eq 'Physical Disk' -and [System.String]$PSItem.OwnerGroup -ieq 'Available Storage'
    })
  If ($RemainingDisks.Count -gt 0) {
    $AvailableStorageGroups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq 'Available Storage' })
    If ($AvailableStorageGroups.Count -ne 1) { Throw 'Expected exactly one local Available Storage group.' }
    $AvailableStorageGroup = $AvailableStorageGroups[0]
    ForEach ($Resource In $RemainingDisks) {
      $PossibleOwners = @((Get-ClusterOwnerNode -InputObject $Resource).OwnerNodes | ForEach-Object -Process { [System.String]$PSItem.Name })
      If ([System.String]$AvailableStorageGroup.OwnerNode -iin $PossibleOwners) { Continue }
      $Actions.Add(('move_available_storage:{0}' -f $Resource.Name))
      $Actions.Add(('start_shared_disk:{0}' -f $Resource.Name))
      If ($Ansible.CheckMode) { Continue }
      $TargetOwner = $PossibleOwners[0]
      $Null = Move-ClusterGroup -InputObject $AvailableStorageGroup -Node $TargetOwner -Wait 600
      $AvailableStorageGroups = @(Get-ClusterGroup -InputObject $Cluster | Where-Object -FilterScript { [System.String]$PSItem.Name -ieq 'Available Storage' })
      If ($AvailableStorageGroups.Count -ne 1 -or [System.String]$AvailableStorageGroups[0].OwnerNode -ine $TargetOwner) {
        Throw ('Available Storage failed owner readback for Physical Disk resource {0}.' -f $Resource.Name)
      }
      $AvailableStorageGroup = $AvailableStorageGroups[0]
      $Null = Start-ClusterResource -InputObject $Resource -Wait 300
      $ResourceReadback = @(Get-ClusterResource -InputObject $Cluster | Where-Object -FilterScript {
          [System.String]$PSItem.ResourceType -eq 'Physical Disk' -and [System.String]$PSItem.Name -ieq [System.String]$Resource.Name
        })
      If ($ResourceReadback.Count -ne 1 -or [System.String]$ResourceReadback[0].State -ne 'Online') {
        Throw ('Physical Disk resource {0} failed Online readback after final placement.' -f $Resource.Name)
      }
    }
  }
}

$Result = [PSCustomObject]@{
  changed    = $Actions.Count -gt 0
  check_mode = [System.Boolean]$Ansible.CheckMode
  actions    = @($Actions)
  before     = & $ConvertToSafeRoleState -State $Before
  after      = & $ConvertToSafeRoleState -State $After
  msg        = $(If ($Actions.Count -eq 0) { 'Clustered file-server role already matches.' } ElseIf ($Ansible.CheckMode) { 'Check mode: clustered file-server role would be converged.' } Else { 'Clustered file-server role converged.' })
}
#endregion --- [ Main ] ---------------------------------------------------------------------- #

#region ------ [ Output ] -------------------------------------------------------------------- #
Write-Debug -Message:'Entering Stage: Output'
$Ansible.Changed = $Result.changed
$Ansible.Result = $Result
If ($StandaloneRun) { $Result | ConvertTo-Json -Depth:7 }
Write-Debug -Message:'Exiting Script'
#endregion --- [ Output ] -------------------------------------------------------------------- #
#endregion --- [ Script ] -------------------------------------------------------------------- #
