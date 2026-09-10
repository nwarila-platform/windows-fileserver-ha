#Requires -Version 5.1
# SPDX-FileCopyrightText: 2026 Nicholas Warila
# SPDX-License-Identifier: MIT

Param (
  [Parameter(Mandatory = $False)]
  [System.String] $SourcePath = (Join-Path -Path $PSScriptRoot -ChildPath 'Set-ClusteredFileServer.ps1'),
  [Parameter(Mandatory = $False)]
  [System.String] $PlaybookPath = (Join-Path -Path $PSScriptRoot -ChildPath '../ansible/playbooks/fileserver-aws.yml')
)

class FsHaVendorNameTransformationAttribute : System.Management.Automation.ArgumentTransformationAttribute {
  [System.Object] Transform([System.Management.Automation.EngineIntrinsics]$EngineIntrinsics, [System.Object]$InputData) {
    If ($InputData -isnot [System.String] -and $InputData -isnot [System.String[]] -and
      $InputData -isnot [System.Collections.Specialized.StringCollection]) {
      Throw [System.Management.Automation.ArgumentTransformationMetadataException]::new('Vendor name binding rejects an object.')
    }
    Return $InputData
  }
}

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

BeforeAll {
  $script:SelectedSourcePath = (Resolve-Path -LiteralPath $SourcePath).Path
  If ([System.IO.Path]::GetExtension($script:SelectedSourcePath) -ieq '.ps1') {
    $script:ScriptPath = $script:SelectedSourcePath
  } Else {
    $script:ScriptPath = Join-Path -Path $TestDrive -ChildPath 'Set-ClusteredFileServer.selected.ps1'
    Copy-Item -LiteralPath $script:SelectedSourcePath -Destination $script:ScriptPath
  }
  If ($PlaybookPath -eq ':git-index:') {
    $script:PlaybookText = (& git show ':ansible/playbooks/fileserver-aws.yml') -join [System.Environment]::NewLine
    If ($LASTEXITCODE -ne 0) { Throw 'Could not read the indexed playbook baseline.' }
  } Else {
    $script:PlaybookPath = (Resolve-Path -LiteralPath $PlaybookPath).Path
    $script:PlaybookText = Get-Content -LiteralPath $script:PlaybookPath -Raw
  }
  $ParserTokens = $Null
  $ParserErrors = $Null
  $script:ScriptAst = [System.Management.Automation.Language.Parser]::ParseFile($script:SelectedSourcePath, [ref]$ParserTokens, [ref]$ParserErrors)
  If ($ParserErrors.Count -gt 0) { Throw 'The selected clustered File Server source does not parse.' }
  $SourceText = Get-Content -LiteralPath $script:SelectedSourcePath -Raw
  If ($SourceText -notmatch "(?s)\`$InnerCommand\s*=\s*@'\r?\n(?<Inner>.*?)\r?\n'@") {
    Throw 'The selected clustered File Server source lacks one inner mutation payload.'
  }
  $InnerTokens = $Null
  $InnerErrors = $Null
  $script:InnerAst = [System.Management.Automation.Language.Parser]::ParseInput($Matches.Inner, [ref]$InnerTokens, [ref]$InnerErrors)
  If ($InnerErrors.Count -gt 0) { Throw 'The selected inner mutation payload does not parse.' }
  $script:Owners = @('tcnaw-hafs01a', 'tcnaw-hafs02a')
  $script:Addresses = @('10.0.1.12', '10.0.33.12')
  $script:Ignored = @('10.0.64.0', '10.0.96.0')
  $global:FsHaRoleNetworkMask = '255.255.224.0'
  $script:Password = 'pester-role-password'
  $script:OriginalTemp = $env:TEMP
  $script:OriginalSystemRoot = $env:SystemRoot
  If ([System.String]::IsNullOrWhiteSpace($env:TEMP)) { $env:TEMP = [System.IO.Path]::GetTempPath() }
  $env:SystemRoot = $TestDrive

  $global:SetClusteredFileServerGetCurrentIdentityName = { 'TCN\svc-fscluster-mgr' }
  $global:SetClusteredFileServerSetRestrictedAcl = {
    Param ([System.String]$Path, [System.Boolean]$Directory)
    $global:FsHaRoleAclWrites += [PSCustomObject]@{ Path = $Path; Directory = $Directory }
  }
  $global:SetClusteredFileServerReadAcl = {
    Param ([System.String]$Path)
    $Directory = -not $Path.EndsWith('.ps1')
    $IncludeUsers = $global:FsHaRoleAclFault -eq 'all' -or
      ($global:FsHaRoleAclFault -eq 'directory' -and $Directory) -or
      ($global:FsHaRoleAclFault -eq 'file' -and -not $Directory)
    $MatchingWrites = @($global:FsHaRoleAclWrites | Where-Object -FilterScript { $PSItem.Path -eq $Path })
    $OwnerSid = If ($global:FsHaRoleAclFault -eq 'wrong_owner' -or $MatchingWrites.Count -eq 0) { 'S-1-5-32-544' } Else { 'S-1-5-18' }
    New-AclReadback -Directory:$Directory -IncludeUsers:$IncludeUsers -OwnerSid $OwnerSid
  }

  Function New-AnsibleContext {
    Param ([Switch]$CheckMode)
    $global:Ansible = [PSCustomObject]@{ Changed = $True; CheckMode = $CheckMode.IsPresent; Failed = $False; Result = $Null }
    $global:Ansible
  }
  Function Remove-AnsibleContext { Remove-Variable -Name Ansible -Scope Global -Force -ErrorAction SilentlyContinue }
  Function Assert-ResultPrimitiveLeaves {
    Param ([AllowNull()] [System.Object]$Value, [System.String]$Path = '$')
    If ($Null -eq $Value -or $Value -is [System.String] -or $Value -is [System.Int32] -or $Value -is [System.Boolean]) { Return }
    If ($Value -is [PSCustomObject]) {
      ForEach ($Property In $Value.PSObject.Properties) {
        Assert-ResultPrimitiveLeaves -Value $Property.Value -Path ('{0}.{1}' -f $Path, $Property.Name)
      }
      Return
    }
    If ($Value -is [System.Array]) {
      For ($Index = 0; $Index -lt $Value.Count; $Index++) {
        Assert-ResultPrimitiveLeaves -Value $Value[$Index] -Path ('{0}[{1}]' -f $Path, $Index)
      }
      Return
    }
    Throw ('Result leaf {0} has forbidden type {1}.' -f $Path, $Value.GetType().FullName)
  }
  Function Get-SourceCommand {
    Param ([System.String]$Name)
    $Predicate = {
      Param ($Ast)
      $Ast -is [System.Management.Automation.Language.CommandAst] -and $Ast.GetCommandName() -eq $Name
    }
    @($script:ScriptAst.FindAll($Predicate, $True))
    @($script:InnerAst.FindAll($Predicate, $True))
  }
  Function Get-BoundParameterName {
    Param ([System.Management.Automation.Language.CommandAst]$Command)
    @($Command.CommandElements | Where-Object -FilterScript {
        $PSItem -is [System.Management.Automation.Language.CommandParameterAst]
      } | ForEach-Object -Process { $PSItem.ParameterName })
  }
  Function Invoke-VendorNameBinding {
    Param (
      [FsHaVendorNameTransformationAttribute()]
      [System.Collections.Specialized.StringCollection]$Resource,
      [FsHaVendorNameTransformationAttribute()]
      [System.Collections.Specialized.StringCollection]$Group
    )
  }
  Function New-Resource {
    Param ([System.String]$Name, [System.String]$Type, [System.String]$Group, [System.String]$State = 'Online', [System.Collections.IDictionary]$Parameters = @{})
    [PSCustomObject]@{ Name = $Name; ResourceType = $Type; OwnerGroup = $Group; State = $State; Parameters = $Parameters }
  }
  Function New-AclReadback {
    Param ([System.Boolean]$Directory, [Switch]$IncludeUsers, [System.String]$OwnerSid = 'S-1-5-18')
    $Inheritance = If ($Directory) {
      [System.Security.AccessControl.InheritanceFlags]::ContainerInherit -bor
      [System.Security.AccessControl.InheritanceFlags]::ObjectInherit
    } Else {
      [System.Security.AccessControl.InheritanceFlags]::None
    }
    $Rules = @(
      [PSCustomObject]@{
        IdentityReference = [PSCustomObject]@{ Value = 'S-1-5-18' }
        IsInherited = $False
        AccessControlType = [System.Security.AccessControl.AccessControlType]::Allow
        FileSystemRights = [System.Security.AccessControl.FileSystemRights]::FullControl
        InheritanceFlags = $Inheritance
        PropagationFlags = [System.Security.AccessControl.PropagationFlags]::None
      },
      [PSCustomObject]@{
        IdentityReference = [PSCustomObject]@{ Value = 'S-1-5-32-544' }
        IsInherited = $False
        AccessControlType = [System.Security.AccessControl.AccessControlType]::Allow
        FileSystemRights = [System.Security.AccessControl.FileSystemRights]::FullControl
        InheritanceFlags = $Inheritance
        PropagationFlags = [System.Security.AccessControl.PropagationFlags]::None
      }
    )
    If ($IncludeUsers) {
      $Rules += [PSCustomObject]@{
        IdentityReference = [PSCustomObject]@{ Value = 'S-1-5-32-545' }
        IsInherited = $False
        AccessControlType = [System.Security.AccessControl.AccessControlType]::Allow
        FileSystemRights = [System.Security.AccessControl.FileSystemRights]::Read
        InheritanceFlags = $Inheritance
        PropagationFlags = [System.Security.AccessControl.PropagationFlags]::None
      }
    }
    $Acl = [PSCustomObject]@{
      AreAccessRulesProtected = $True
      OwnerSid = $OwnerSid
      Rules = $Rules
    }
    $Acl | Add-Member -MemberType ScriptMethod -Name GetOwner -Value { Param ($TargetType) [PSCustomObject]@{ Value = $this.OwnerSid } }
    $Acl | Add-Member -MemberType ScriptMethod -Name GetAccessRules -Value { Param ($Explicit, $Inherited, $TargetType) @($this.Rules) }
    $Acl
  }
  Function Get-Cluster {
    $global:FsHaRoleClusterReads++
    [PSCustomObject]@{ Name = $global:FsHaRoleClusterName }
  }
  Function Get-Disk { @($global:FsHaRoleLocalDisks) }
  Function Get-ClusterResource {
    Param ([System.Object]$InputObject)
    $global:FsHaRoleClusterInputs += [System.String]$InputObject.Name
    $Snapshot = @($global:FsHaRoleResources)
    If ($global:FsHaRolePendingAutoIps) {
      $global:FsHaRolePendingAutoIps = $False
      $global:FsHaRoleResources += New-Resource -Name 'Auto IP 10.0.64.0' -Type 'IP Address' -Group 'TCNAW-HAFS01' -State 'Offline' -Parameters @{ Address = '10.0.64.0'; Network = 'Cluster Network 3'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 1 }
      $global:FsHaRoleResources += New-Resource -Name 'Auto IP 10.0.96.0' -Type 'IP Address' -Group 'TCNAW-HAFS01' -State 'Offline' -Parameters @{ Address = '10.0.96.0'; Network = 'Cluster Network 4'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 1 }
    }
    @($Snapshot)
  }
  Function Get-ClusterParameter {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.String]$Name)
    If (-not $InputObject.Parameters.Contains($Name)) { Return @() }
    [PSCustomObject]@{ Name = $Name; Value = $InputObject.Parameters[$Name] }
  }
  Function Get-ClusterOwnerNode {
    Param ([Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject, [System.Object]$Group)
    If ($PSBoundParameters.ContainsKey('Group')) {
      $OwnerNames = $global:FsHaRoleOwners
    } ElseIf ([System.String]$InputObject.Name -eq 'TCNAW-HAFS01') {
      $OwnerNames = $global:FsHaRoleOwners
    } Else {
      $OwnerNames = $global:FsHaResourceOwners[$InputObject.Name]
    }
    [PSCustomObject]@{
      OwnerNodes = @($OwnerNames | ForEach-Object -Process { [PSCustomObject]@{ Name = $PSItem } })
    }
  }
  Function Get-ClusterGroup {
    Param ([System.Object]$InputObject)
    $global:FsHaRoleClusterInputs += [System.String]$InputObject.Name
    $global:FsHaAvailableStorageGroup
    If ($global:FsHaRolePresent) {
      For ($Index = 0; $Index -lt $global:FsHaRoleGroupCount; $Index++) { $global:FsHaRoleGroup }
    }
  }
  Function Get-ClusterNetwork {
    Param ([System.Object]$InputObject)
    $global:FsHaRoleClusterInputs += [System.String]$InputObject.Name
    @($global:FsHaRoleNetworks)
  }
  Function Get-ClusterNode {
    Param ([System.Object]$InputObject)
    @('tcnaw-hafs02b', 'tcnaw-hafs01a', 'tcnaw-hafs01b', 'tcnaw-hafs02a') |
      ForEach-Object -Process { [PSCustomObject]@{ Name = $PSItem } }
  }
  Function Get-WmiObject {
    Param ([System.String]$Class, [System.String]$ComputerName, [System.Object]$ErrorAction)
    $global:FsHaRoleProbeCalls += [PSCustomObject]@{ Class = $Class; ComputerName = $ComputerName; ErrorAction = [System.String]$ErrorAction }
    $global:FsHaRoleOperations += 'Probe:{0}' -f $ComputerName
    $CallCount = @($global:FsHaRoleProbeCalls | Where-Object -FilterScript { $PSItem.ComputerName -eq $ComputerName }).Count
    If ($global:FsHaRoleProbeFailures.ContainsKey($ComputerName) -and
      $CallCount -le [System.Int32]$global:FsHaRoleProbeFailures[$ComputerName]) {
      Throw ('Readiness probe failed for {0}.' -f $ComputerName)
    }
    [PSCustomObject]@{ Name = $ComputerName; PartOfDomain = $True }
  }
  Function Get-ClusterResourceDependency {
    Param ([System.Object]$Resource, [System.Object]$InputObject)
    $BoundResource = If ($PSBoundParameters.ContainsKey('InputObject')) { $InputObject } Else { $Resource }
    $Dependency = $global:FsHaRoleDependency
    If ($global:FsHaRoleDependencies.ContainsKey([System.String]$BoundResource.Name)) {
      $Dependency = $global:FsHaRoleDependencies[[System.String]$BoundResource.Name]
    }
    [PSCustomObject]@{ DependencyExpression = $Dependency }
  }
  Function Add-ClusterFileServerRole {
    Param (
      [System.Object]$InputObject, [System.String]$Name, [System.String]$Storage,
      [System.String[]]$StaticAddress, [System.String[]]$IgnoreNetwork, [System.Int32]$Wait
    )
    If ($PSBoundParameters.ContainsKey('IgnoreNetwork')) {
      ForEach ($Address In @($IgnoreNetwork)) {
        $Parsed = [System.Net.IPAddress]::None
        If (-not [System.Net.IPAddress]::TryParse($Address, [ref]$Parsed) -or
          $Parsed.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
          Throw ("The specified IP address '{0}' is invalid." -f $Address)
        }
      }
    }
    $global:FsHaRoleOperations += 'Create'
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'Create'; Cluster = $InputObject.Name; Name = $Name; Storage = $Storage; StaticAddress = $StaticAddress; IgnoreNetwork = $IgnoreNetwork; Wait = $Wait }
    If ($global:FsHaRoleFrozen) { Return }
    $global:FsHaRolePresent = $True
    $global:FsHaRoleGroup.State = 'Online'
    $global:FsHaRoleGroup.OwnerNode = $script:Owners[0]
    # Add-ClusterFileServerRole has no preferred-owner parameter; creation therefore cannot
    # fabricate the declared two-node preference that Set-ClusterOwnerNode owns.
    $global:FsHaRoleOwners = @(
      'tcnaw-hafs01a', 'tcnaw-hafs02a', 'tcnaw-hafs01b', 'tcnaw-hafs02b'
    )
    $HomeResource = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })[0]
    $HomeResource.OwnerGroup = $Name
    $global:FsHaRoleResources += New-Resource -Name 'File Server Name' -Type 'Network Name' -Group $Name
    $global:FsHaRoleResources += New-Resource -Name 'IP Address 10.0.1.12' -Type 'IP Address' -Group $Name -Parameters @{ Address = '10.0.1.12'; Network = 'Cluster Network 1'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    $global:FsHaRoleResources += New-Resource -Name 'IP Address 10.0.33.12' -Type 'IP Address' -Group $Name -State 'Offline' -Parameters @{ Address = '10.0.33.12'; Network = 'Cluster Network 2'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    If ($global:FsHaRoleDelayAutoIps) {
      $global:FsHaRolePendingAutoIps = $True
    } Else {
      $global:FsHaRoleResources += New-Resource -Name 'Auto IP 10.0.64.0' -Type 'IP Address' -Group $Name -State 'Offline' -Parameters @{ Address = '10.0.64.0'; Network = 'Cluster Network 3'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 1 }
      $global:FsHaRoleResources += New-Resource -Name 'Auto IP 10.0.96.0' -Type 'IP Address' -Group $Name -State 'Offline' -Parameters @{ Address = '10.0.96.0'; Network = 'Cluster Network 4'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 1 }
    }
    $global:FsHaRoleDependency = '[IP Address 10.0.1.12] or [IP Address 10.0.33.12]'
  }
  Function Move-ClusterResource {
    Param ([System.Object]$InputObject, [System.String]$Group)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'Move'; Name = $InputObject.Name; Group = $Group }
    If (-not $global:FsHaRoleFrozen) { $InputObject.OwnerGroup = $Group }
  }
  Function Move-ClusterGroup {
    Param ([System.Object]$InputObject, [System.String]$Node, [System.Int32]$Wait)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'MoveAvailable'; InputObject = $InputObject; Node = $Node; Wait = $Wait }
    If (-not $global:FsHaRoleFrozen) {
      $InputObject.OwnerNode = $Node
      ForEach ($Disk In @($global:FsHaRoleResources | Where-Object -FilterScript {
            $PSItem.ResourceType -eq 'Physical Disk' -and $PSItem.OwnerGroup -eq $InputObject.Name
          })) {
        If ($Node -inotin @($global:FsHaResourceOwners[$Disk.Name])) { $Disk.State = 'Offline' }
      }
    }
  }
  Function Set-ClusterOwnerNode {
    Param ([System.Object]$Group, [System.String[]]$Owners)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'Owners'; Group = $Group; Owners = $Owners }
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleOwners = @($Owners) }
  }
  Function Stop-ClusterGroup {
    Param ([System.String]$Name, [System.Int32]$Wait)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'StopGroup'; Name = $Name; Wait = $Wait }
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleGroup.State = 'Offline' }
  }
  Function Add-ClusterResource {
    Param ([System.String]$Name, [System.String]$ResourceType, [System.String]$Group)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'AddIp'; Name = $Name; ResourceType = $ResourceType; Group = $Group }
    $Resource = New-Resource -Name $Name -Type $ResourceType -Group $Group -State 'Offline'
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleResources += $Resource }
    $Resource
  }
  Function Set-ClusterParameter {
    Param (
      [Parameter(ValueFromPipeline = $True)] [System.Object]$InputObject,
      [System.Collections.IDictionary]$Multiple,
      [System.String]$Name,
      [System.Object]$Value
    )
    If ($PSBoundParameters.ContainsKey('Multiple')) {
      If ($global:FsHaRoleRejectMultipleIpParameters) {
        Throw ("The specified IP address '{0}' is invalid." -f $Multiple.Network)
      }
      $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'SetIp'; Resource = $InputObject.Name; Multiple = $Multiple }
      If (-not $global:FsHaRoleFrozen) { ForEach ($Key In $Multiple.Keys) { $InputObject.Parameters[$Key] = $Multiple[$Key] } }
    } Else {
      $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'SetIp'; Resource = $InputObject.Name; Parameter = $Name; Value = $Value }
      If (-not $global:FsHaRoleFrozen) { $InputObject.Parameters[$Name] = $Value }
    }
  }
  Function Stop-ClusterResource {
    Param ([System.Object]$InputObject, [System.Int32]$Wait)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'StopIp'; Name = $InputObject.Name; Wait = $Wait }
    If (-not $global:FsHaRoleFrozen) { $InputObject.State = 'Offline' }
  }
  Function Start-ClusterResource {
    Param ([System.Object]$InputObject, [System.Int32]$Wait)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'StartDisk'; Name = $InputObject.Name; Wait = $Wait }
    If (-not $global:FsHaRoleFrozen -and -not $global:FsHaRoleStartFrozen) { $InputObject.State = 'Online' }
  }
  Function Remove-ClusterResource {
    Param ([System.Object]$InputObject, [Switch]$Force)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'RemoveIp'; Name = $InputObject.Name; Force = $Force.IsPresent }
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem -ne $InputObject }) }
  }
  Function Set-ClusterResourceDependency {
    Param ([System.Object]$Resource, [System.Object]$InputObject, [System.String]$Dependency)
    $BoundResource = If ($PSBoundParameters.ContainsKey('InputObject')) { $InputObject } Else { $Resource }
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'Dependency'; Name = $BoundResource.Name; Dependency = $Dependency }
    If (-not $global:FsHaRoleFrozen) { $global:FsHaRoleDependency = $Dependency }
  }
  Function Start-ClusterGroup {
    Param ([System.String]$Name, [System.Int32]$Wait)
    $global:FsHaRoleWrites += [PSCustomObject]@{ Command = 'StartGroup'; Name = $Name; Wait = $Wait }
    If (-not $global:FsHaRoleFrozen) {
      $global:FsHaRoleGroup.State = 'Online'
      $Ips = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'IP Address' -and $PSItem.OwnerGroup -eq $Name } | Sort-Object -Property Name)
      For ($Index = 0; $Index -lt $Ips.Count; $Index++) { $Ips[$Index].State = $(If ($Index -eq 0) { 'Online' } Else { 'Offline' }) }
    }
  }
  Function New-ScheduledTaskAction {
    Param ([System.String]$Execute, [System.String]$Argument)
    $global:FsHaRoleTaskActionArgument = $Argument
    If ($Argument -match '-EncodedCommand\s+(?<Payload>\S+)$') {
      $InnerCommand = [System.Text.Encoding]::Unicode.GetString([System.Convert]::FromBase64String($Matches.Payload))
    } ElseIf ($Argument -match '-File\s+"(?<Path>[^"]+)"$') {
      $global:FsHaRolePayloadPath = $Matches.Path
      $InnerCommand = [System.IO.File]::ReadAllText($Matches.Path)
      $global:FsHaRolePayloadText = $InnerCommand
    } Else {
      Throw 'Mutation action has no terminal encoded-command or file payload.'
    }
    $ParserTokens = $Null
    $ParserErrors = $Null
    $Null = [System.Management.Automation.Language.Parser]::ParseInput($InnerCommand, [ref]$ParserTokens, [ref]$ParserErrors)
    If ($ParserErrors.Count -gt 0) { Throw 'Mutation command did not parse.' }
    If ($InnerCommand -notmatch "FromBase64String\('(?<Payload>[A-Za-z0-9+/=]+)'\)") { Throw 'Mutation payload was not encoded.' }
    $MutationXml = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($Matches.Payload))
    $global:FsHaRoleInnerCommand = $InnerCommand
    $global:FsHaRoleScheduledMutation = [System.Management.Automation.PSSerializer]::Deserialize($MutationXml)
    [PSCustomObject]@{ Execute = $Execute; Argument = $Argument }
  }
  Function Register-ScheduledTask {
    Param (
      [System.String]$TaskName, [System.Object]$Action, [System.String]$User,
      [System.String]$Password, [System.String]$RunLevel, [Switch]$Force
    )
    $global:FsHaRoleTaskRegistrations += [PSCustomObject]@{
      TaskName        = $TaskName
      User            = $User
      PasswordMatches = $Password -ceq $script:Password
      RunLevel        = $RunLevel
      Force           = $Force.IsPresent
      AclWriteCount   = $global:FsHaRoleAclWrites.Count
    }
    $global:FsHaRoleTaskExists = $True
    $global:FsHaRoleTaskState = 'Ready'
    [PSCustomObject]@{ TaskName = $TaskName; State = $global:FsHaRoleTaskState }
  }
  Function Get-ScheduledTask {
    Param ([System.String]$TaskName)
    If ($global:FsHaRoleTaskExists) { [PSCustomObject]@{ TaskName = $TaskName; State = $global:FsHaRoleTaskState } }
  }
  Function Start-ScheduledTask {
    Param ([System.String]$TaskName)
    $global:FsHaRoleTaskStarts += $TaskName
    $global:FsHaRoleTaskState = 'Running'
    If ($global:FsHaRoleTaskResult -eq 0) {
      # Replay the real batch payload in-process so its converge runs against these mocks.
      $Executable = $global:FsHaRoleInnerCommand.
        Replace('$PreScreenDeadlineSeconds = 300', ('$PreScreenDeadlineSeconds = {0}' -f $global:FsHaRolePreScreenDeadlineSeconds)).
        Replace('$PreScreenIntervalSeconds = 15', ('$PreScreenIntervalSeconds = {0}' -f $global:FsHaRolePreScreenIntervalSeconds)).
        Replace('Exit $ExitCode', 'Write-Output -InputObject $ExitCode')
      $Output = @(& ([System.Management.Automation.ScriptBlock]::Create($Executable)))
      $global:FsHaRoleTaskResult = [System.Int32]$Output[-1]
    }
    $global:FsHaRoleTaskLastRunTime = $global:FsHaRoleTaskLastRunTime.AddSeconds(1)
    $global:FsHaRoleTaskState = 'Ready'
  }
  Function Get-ScheduledTaskInfo {
    Param ([System.String]$TaskName)
    [PSCustomObject]@{ LastTaskResult = $global:FsHaRoleTaskResult; LastRunTime = $global:FsHaRoleTaskLastRunTime }
  }
  Function Stop-ScheduledTask {
    Param ([System.String]$TaskName)
    $global:FsHaRoleTaskStops += $TaskName
    $global:FsHaRoleTaskState = 'Ready'
  }
  Function Unregister-ScheduledTask {
    Param ([System.String]$TaskName, [Switch]$Confirm)
    $global:FsHaRoleTaskUnregistrations += $TaskName
    $global:FsHaRoleTaskExists = $False
  }
  Function Invoke-RoleMutationInner {
    Param (
      [System.String]$Command,
      [System.Int32]$PreScreenDeadlineSeconds = $global:FsHaRolePreScreenDeadlineSeconds,
      [System.Int32]$PreScreenIntervalSeconds = $global:FsHaRolePreScreenIntervalSeconds
    )
    $PayloadMatches = [System.Text.RegularExpressions.Regex]::Matches($Command, "FromBase64String\('(?<Payload>[A-Za-z0-9+/=]+)'\)")
    If ($PayloadMatches.Count -ne 2) { Throw 'Encoded mutation command did not contain exactly two payloads.' }
    $TranscriptPath = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($PayloadMatches[1].Groups['Payload'].Value))
    $TranscriptDirectory = Split-Path -Path $TranscriptPath -Parent
    $TranscriptDirectoryCreated = -not (Test-Path -LiteralPath $TranscriptDirectory)
    If ($TranscriptDirectoryCreated) { $Null = New-Item -ItemType Directory -Path $TranscriptDirectory }
    $ExecutableCommand = $Command.
      Replace('$PreScreenDeadlineSeconds = 300', ('$PreScreenDeadlineSeconds = {0}' -f $PreScreenDeadlineSeconds)).
      Replace('$PreScreenIntervalSeconds = 15', ('$PreScreenIntervalSeconds = {0}' -f $PreScreenIntervalSeconds)).
      Replace('Exit $ExitCode', 'Write-Output -InputObject $ExitCode')
    Try {
      $Output = @(& ([System.Management.Automation.ScriptBlock]::Create($ExecutableCommand)))
      [PSCustomObject]@{
        exit_code  = [System.Int32]$Output[-1]
        transcript = [System.String](Get-Content -LiteralPath $TranscriptPath -Raw)
      }
    } Finally {
      Remove-Item -LiteralPath $TranscriptPath -Force -ErrorAction SilentlyContinue
      If ($TranscriptDirectoryCreated) { Remove-Item -LiteralPath $TranscriptDirectory -Force -ErrorAction SilentlyContinue }
    }
  }
}

AfterAll {
  $env:TEMP = $script:OriginalTemp
  $env:SystemRoot = $script:OriginalSystemRoot
  Remove-Variable -Name 'SetClusteredFileServerGetCurrentIdentityName', 'SetClusteredFileServerReadTranscriptTail', 'SetClusteredFileServerSetRestrictedAcl', 'SetClusteredFileServerReadAcl', 'SetClusteredFileServerRegisterScheduledTask', 'SetClusteredFileServerGetScheduledTask', 'SetClusteredFileServerStartScheduledTask', 'SetClusteredFileServerGetScheduledTaskInfo', 'SetClusteredFileServerStopScheduledTask', 'SetClusteredFileServerUnregisterScheduledTask', 'SetClusteredFileServerGetUtcNow', 'SetClusteredFileServerWaitForScheduledTask', 'SetClusteredFileServerRemoveArtifact', 'FsHaRoleClusterName', 'FsHaRoleClusterReads', 'FsHaRoleClusterInputs', 'FsHaRoleLocalDisks', 'FsHaRoleResources', 'FsHaResourceOwners', 'FsHaAvailableStorageGroup', 'FsHaRolePresent', 'FsHaRoleGroupCount', 'FsHaRoleGroup', 'FsHaRoleOwners', 'FsHaRoleNetworks', 'FsHaRoleDependency', 'FsHaRoleDependencies', 'FsHaRoleWrites', 'FsHaRoleFrozen', 'FsHaRoleStartFrozen', 'FsHaRoleDelayAutoIps', 'FsHaRolePendingAutoIps', 'FsHaRoleInnerCommand', 'FsHaRoleScheduledMutation', 'FsHaRoleTaskRegistrations', 'FsHaRoleTaskStarts', 'FsHaRoleTaskResult', 'FsHaRoleTaskUnregistrations', 'FsHaRoleTaskActionArgument', 'FsHaRolePayloadPath', 'FsHaRolePayloadText', 'FsHaRoleTaskExists', 'FsHaRoleTaskState', 'FsHaRoleTaskLastRunTime', 'FsHaRoleTaskStops', 'FsHaRoleAclWrites', 'FsHaRoleAclFault', 'FsHaRoleRejectMultipleIpParameters', 'FsHaRoleCleanupAttempts', 'FsHaRoleInfoReads', 'FsHaRoleProbeCalls', 'FsHaRoleProbeFailures', 'FsHaRoleOperations', 'FsHaRolePreScreenDeadlineSeconds', 'FsHaRolePreScreenIntervalSeconds', 'FsHaRoleNetworkMask' -Scope Global -ErrorAction SilentlyContinue
}

Describe 'Set-ClusteredFileServer' {
  BeforeEach {
    Remove-Variable -Name 'SetClusteredFileServerReadTranscriptTail', 'SetClusteredFileServerRegisterScheduledTask', 'SetClusteredFileServerGetScheduledTask', 'SetClusteredFileServerStartScheduledTask', 'SetClusteredFileServerGetScheduledTaskInfo', 'SetClusteredFileServerStopScheduledTask', 'SetClusteredFileServerUnregisterScheduledTask', 'SetClusteredFileServerGetUtcNow', 'SetClusteredFileServerRemoveArtifact' -Scope Global -ErrorAction SilentlyContinue
    $global:SetClusteredFileServerSetRestrictedAcl = {
      Param ([System.String]$Path, [System.Boolean]$Directory)
      $global:FsHaRoleAclWrites += [PSCustomObject]@{ Path = $Path; Directory = $Directory }
    }
    $global:SetClusteredFileServerReadAcl = {
      Param ([System.String]$Path)
      $Directory = -not $Path.EndsWith('.ps1')
      $IncludeUsers = $global:FsHaRoleAclFault -eq 'all' -or
        ($global:FsHaRoleAclFault -eq 'directory' -and $Directory) -or
        ($global:FsHaRoleAclFault -eq 'file' -and -not $Directory)
      $MatchingWrites = @($global:FsHaRoleAclWrites | Where-Object -FilterScript { $PSItem.Path -eq $Path })
      $OwnerSid = If ($global:FsHaRoleAclFault -eq 'wrong_owner' -or $MatchingWrites.Count -eq 0) { 'S-1-5-32-544' } Else { 'S-1-5-18' }
      New-AclReadback -Directory:$Directory -IncludeUsers:$IncludeUsers -OwnerSid $OwnerSid
    }
    $global:SetClusteredFileServerWaitForScheduledTask = {}
    $global:FsHaRoleClusterName = 'TCNAW-FSCL01'
    $global:FsHaRoleClusterReads = 0
    $global:FsHaRoleClusterInputs = @()
    $Guid = '11111111-1111-1111-1111-111111111111'
    $global:FsHaRoleLocalDisks = @([PSCustomObject]@{ Guid = $Guid; UniqueId = 'AWS_vol0abc123' })
    $HomeResource = New-Resource -Name 'Cluster Disk 9' -Type 'Physical Disk' -Group 'TCNAW-HAFS01' -Parameters @{ DiskIdGuid = $Guid }
    $AwayResource = New-Resource -Name 'Cluster Disk 10' -Type 'Physical Disk' -Group 'Available Storage' -Parameters @{ DiskIdGuid = '22222222-2222-2222-2222-222222222222' }
    $Name = New-Resource -Name 'File Server Name' -Type 'Network Name' -Group 'TCNAW-HAFS01'
    $Ip1 = New-Resource -Name 'IP Address 10.0.1.12' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.1.12'; Network = 'Cluster Network 1'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    $Ip2 = New-Resource -Name 'IP Address 10.0.33.12' -Type 'IP Address' -Group 'TCNAW-HAFS01' -State 'Offline' -Parameters @{ Address = '10.0.33.12'; Network = 'Cluster Network 2'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    $global:FsHaRoleResources = @($HomeResource, $Name, $Ip1, $Ip2, $AwayResource)
    $global:FsHaResourceOwners = @{
      'Cluster Disk 9' = @($script:Owners)
      'Cluster Disk 10' = @('tcnaw-hafs02b', 'tcnaw-hafs01b')
    }
    $global:FsHaAvailableStorageGroup = [PSCustomObject]@{ Name = 'Available Storage'; OwnerNode = 'tcnaw-hafs01b' }
    $global:FsHaRolePresent = $True
    $global:FsHaRoleGroupCount = 1
    $global:FsHaRoleGroup = [PSCustomObject]@{ Name = 'TCNAW-HAFS01'; State = 'Online'; OwnerNode = 'tcnaw-hafs01a' }
    $global:FsHaRoleOwners = @($script:Owners)
    $global:FsHaRoleNetworks = @(
      [PSCustomObject]@{ Name = 'Cluster Network 1'; Address = '10.0.0.0'; AddressMask = $global:FsHaRoleNetworkMask; Role = 3 },
      [PSCustomObject]@{ Name = 'Cluster Network 2'; Address = '10.0.32.0'; AddressMask = $global:FsHaRoleNetworkMask; Role = 3 },
      [PSCustomObject]@{ Name = 'Cluster Network 3'; Address = '10.0.64.0'; AddressMask = $global:FsHaRoleNetworkMask; Role = 3 },
      [PSCustomObject]@{ Name = 'Cluster Network 4'; Address = '10.0.96.0'; AddressMask = $global:FsHaRoleNetworkMask; Role = 3 }
    )
    $global:FsHaRoleDependency = '[IP Address 10.0.1.12] or [IP Address 10.0.33.12]'
    $global:FsHaRoleDependencies = @{}
    $global:FsHaRoleWrites = @()
    $global:FsHaRoleFrozen = $False
    $global:FsHaRoleStartFrozen = $False
    $global:FsHaRoleDelayAutoIps = $False
    $global:FsHaRolePendingAutoIps = $False
    $global:FsHaRoleInnerCommand = ''
    $global:FsHaRoleScheduledMutation = $Null
    $global:FsHaRoleTaskRegistrations = @()
    $global:FsHaRoleTaskStarts = @()
    $global:FsHaRoleTaskResult = 0
    $global:FsHaRoleTaskUnregistrations = @()
    $global:FsHaRoleTaskActionArgument = ''
    $global:FsHaRolePayloadPath = ''
    $global:FsHaRolePayloadText = ''
    $global:FsHaRoleTaskExists = $False
    $global:FsHaRoleTaskState = 'Ready'
    $global:FsHaRoleTaskLastRunTime = [System.DateTime]'2000-01-01T00:00:00Z'
    $global:FsHaRoleTaskStops = @()
    $global:FsHaRoleAclWrites = @()
    $global:FsHaRoleAclFault = ''
    $global:FsHaRoleRejectMultipleIpParameters = $False
    $global:FsHaRoleCleanupAttempts = @()
    $global:FsHaRoleProbeCalls = @()
    $global:FsHaRoleProbeFailures = @{}
    $global:FsHaRoleOperations = @()
    $global:FsHaRolePreScreenDeadlineSeconds = 300
    $global:FsHaRolePreScreenIntervalSeconds = 0
  }
  AfterEach { Remove-AnsibleContext }

  It '<Id> uses the object overload proven necessary by the vendor name binder' -ForEach @(
    @{ Id = 'D1-S182'; Kind = 'dependency'; Index = 0; Legacy = 'Resource' },
    @{ Id = 'D1-S196'; Kind = 'owner-group'; Index = 0; Legacy = 'Group' },
    @{ Id = 'D1-S302'; Kind = 'dependency'; Index = 1; Legacy = 'Resource' },
    @{ Id = 'D1-S311'; Kind = 'owner-group'; Index = 1; Legacy = 'Group' },
    @{ Id = 'D1-S410'; Kind = 'dependency'; Index = 2; Legacy = 'Resource' },
    @{ Id = 'D1-S451'; Kind = 'set-dependency'; Index = 0; Legacy = 'Resource' }
  ) {
    $VendorArguments = @{ $Legacy = [PSCustomObject]@{ Name = 'live cluster object' } }
    { Invoke-VendorNameBinding @VendorArguments } | Should -Throw '*Vendor name binding rejects an object*'
    $Commands = Switch ($Kind) {
      'dependency' { @(Get-SourceCommand -Name 'Get-ClusterResourceDependency') }
      'owner-group' {
        @(Get-SourceCommand -Name 'Get-ClusterOwnerNode' | Where-Object -FilterScript {
            $PSItem.CommandElements[-1].Extent.Text -eq '$Group'
          })
      }
      'set-dependency' { @(Get-SourceCommand -Name 'Set-ClusterResourceDependency') }
    }
    $Commands.Count | Should -BeGreaterThan $Index
    $BoundNames = @(Get-BoundParameterName -Command $Commands[$Index])
    $BoundNames | Should -Contain 'InputObject'
    $BoundNames | Should -Not -Contain $Legacy
  }

  It 'D1-P643 binds the END dependency readback through InputObject' {
    $script:PlaybookText | Should -Match '\$DependencyResult\s*=\s*@\(Get-ClusterResourceDependency\s+-InputObject\s+\$RoleNameResources\[0\]\)'
  }

  It 'D1-P661 binds the END preferred-owner readback through InputObject' {
    $script:PlaybookText | Should -Match 'Get-ClusterOwnerNode\s+-InputObject\s+\$Role'
  }

  It 'D1b-P661 extracts OwnerNodes from the preferred-owner wrapper' {
    $script:PlaybookText | Should -Match '\(Get-ClusterOwnerNode\s+-InputObject\s+\$Role\)\.OwnerNodes'
  }

  It 'D1b-P736 extracts OwnerNodes from the disk-owner wrapper' {
    $script:PlaybookText | Should -Match '\(Get-ClusterOwnerNode\s+-InputObject\s+\$Match\.resource\)\.OwnerNodes'
  }

  It 'preserves the full parameter and result contract' {
    $Command = Get-Command -Name $script:ScriptPath
    $ExpectedParameters = @(
      'ClusterName', 'DebugLevel', 'HomeVolumeId', 'IgnoredNetworkAddress', 'LogLevel',
      'Owners', 'Password', 'RoleName', 'StaticAddress', 'TimeoutSeconds'
    )
    @($Command.Parameters.Keys | Where-Object -FilterScript { $PSItem -in $ExpectedParameters } | Sort-Object) |
      Should -Be $ExpectedParameters
    $Command.Parameters['Owners'].ParameterType | Should -Be ([System.String[]])
    $Command.Parameters['TimeoutSeconds'].Attributes.TypeId.Name | Should -Contain 'ValidateRangeAttribute'
    $Context = New-AnsibleContext
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    @($Context.Result.PSObject.Properties.Name) | Should -Be @('changed', 'check_mode', 'actions', 'before', 'after', 'msg')
    $Context.Result.msg | Should -Be 'Clustered file-server role already matches.'
  }

  It 'D2-ACTION-FILE stages a bounded absolute terminal File action after both ACL readbacks' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleTaskActionArgument | Should -Not -Match '-EncodedCommand'
    $global:FsHaRoleTaskActionArgument.Length | Should -BeLessThan 32767
    $global:FsHaRoleTaskActionArgument | Should -Match '-ExecutionPolicy Bypass -File "[^"]+\\mutation\.ps1"$|-ExecutionPolicy Bypass -File "[^"]+/mutation\.ps1"$'
    [System.IO.Path]::IsPathRooted($global:FsHaRolePayloadPath) | Should -BeTrue
    $global:FsHaRolePayloadPath | Should -Match '[\\/]Temp[\\/][0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}[\\/]mutation\.ps1$'
    $global:FsHaRoleTaskRegistrations[0].AclWriteCount | Should -Be 2
  }

  It 'D2-DIRECTORY-ACL-NEGATIVE rejects an extra Users ACE before writing or registering' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:FsHaRoleAclFault = 'directory'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*expected only SYSTEM and BUILTIN\Administrators*'
    $global:FsHaRoleTaskRegistrations | Should -HaveCount 0
    @(Get-ChildItem -LiteralPath (Join-Path -Path $env:SystemRoot -ChildPath 'Temp') -Force -ErrorAction SilentlyContinue) | Should -HaveCount 0
  }

  It 'D2-PAYLOAD-ACL-NEGATIVE rejects an extra Users ACE on the file before registering' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:FsHaRoleAclFault = 'file'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*expected only SYSTEM and BUILTIN\Administrators*'
    $global:FsHaRoleAclWrites | Should -HaveCount 2
    $global:FsHaRoleTaskRegistrations | Should -HaveCount 0
    @(Get-ChildItem -LiteralPath (Join-Path -Path $env:SystemRoot -ChildPath 'Temp') -Force -ErrorAction SilentlyContinue) | Should -HaveCount 0
  }

  It 'D2-ACL-NOOP-WRITER rejects a DACL writer that makes no change' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:SetClusteredFileServerSetRestrictedAcl = { Param ([System.String]$Path, [System.Boolean]$Directory) }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*expected only SYSTEM and BUILTIN\Administrators*'
    $global:FsHaRoleAclWrites | Should -HaveCount 0
    $global:FsHaRoleTaskRegistrations | Should -HaveCount 0
  }

  It 'D2-ACL-WRONG-OWNER rejects a restricted DACL owned by Administrators' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:FsHaRoleAclFault = 'wrong_owner'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*expected only SYSTEM and BUILTIN\Administrators*'
    $global:FsHaRoleAclWrites | Should -HaveCount 1
    $global:FsHaRoleTaskRegistrations | Should -HaveCount 0
  }

  It 'D2-PAYLOAD-SECRET stages a credential-free payload and removes every file boundary' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRolePayloadText | Should -Not -BeNullOrEmpty
    $global:FsHaRolePayloadText | Should -Not -Match ([System.Text.RegularExpressions.Regex]::Escape($script:Password))
    $Utf8Secret = [System.Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($script:Password))
    $Utf16Secret = [System.Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($script:Password))
    $global:FsHaRolePayloadText | Should -Not -Match "$Utf8Secret|$Utf16Secret"
    Test-Path -LiteralPath $global:FsHaRolePayloadPath | Should -BeFalse
    Test-Path -LiteralPath (Split-Path -Path $global:FsHaRolePayloadPath -Parent) | Should -BeFalse
  }

  It 'D3-REGISTRATION-NULL surfaces the named readback error and cleans all artifacts' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:SetClusteredFileServerGetScheduledTask = { Param ($TaskName) $Null }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*registration readback must return exactly one non-null task; found 0*'
    $global:FsHaRoleTaskStarts | Should -HaveCount 0
    $global:FsHaRoleTaskUnregistrations | Should -HaveCount 1
    Test-Path -LiteralPath $global:FsHaRolePayloadPath | Should -BeFalse
  }

  It 'D3-START-FAILURE surfaces the injected start error and cleans all artifacts' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:SetClusteredFileServerStartScheduledTask = { Param ($TaskName) Throw 'injected start failure' }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*Scheduled task start failed: injected start failure*'
    $global:FsHaRoleTaskUnregistrations | Should -HaveCount 1
    Test-Path -LiteralPath $global:FsHaRolePayloadPath | Should -BeFalse
  }

  It 'D3-DELAYED-TRANSITION waits through all non-terminal results and stale runtime data' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:FsHaRoleInfoReads = 0
    $global:SetClusteredFileServerGetScheduledTaskInfo = {
      Param ($TaskName)
      $global:FsHaRoleInfoReads++
      Switch ($global:FsHaRoleInfoReads) {
        1 { [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:00Z'; LastTaskResult = 267011 } }
        2 { [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:00Z'; LastTaskResult = 267011 } }
        3 { [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:01Z'; LastTaskResult = 267045 } }
        4 { [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:01Z'; LastTaskResult = 267009 } }
        Default { [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:01Z'; LastTaskResult = 0 } }
      }
    }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Not -Throw
    $global:FsHaRoleInfoReads | Should -Be 5
  }

  It 'D3-RUNTIME-INFO-MISSING surfaces the named poll error without a property exception' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:FsHaRoleInfoReads = 0
    $global:SetClusteredFileServerGetScheduledTaskInfo = {
      Param ($TaskName)
      $global:FsHaRoleInfoReads++
      If ($global:FsHaRoleInfoReads -eq 1) {
        [PSCustomObject]@{ LastRunTime = [System.DateTime]'2000-01-01T00:00:00Z'; LastTaskResult = 267011 }
      }
    }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*runtime-info poll must return exactly one non-null object; found 0*'
    $global:FsHaRoleTaskUnregistrations | Should -HaveCount 1
    Test-Path -LiteralPath $global:FsHaRolePayloadPath | Should -BeFalse
  }

  It 'D3-CLEANUP-INDEPENDENT surfaces cleanup-only failure after later artifact cleanup' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:SetClusteredFileServerUnregisterScheduledTask = { Param ($TaskName) Throw 'injected unregister failure' }
    $global:SetClusteredFileServerRemoveArtifact = {
      Param ([System.String]$Path)
      $global:FsHaRoleCleanupAttempts += $Path
      Microsoft.PowerShell.Management\Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*cleanup failed*unregister*injected unregister failure*'
    $global:FsHaRoleCleanupAttempts | Should -HaveCount 3
    $global:FsHaRoleCleanupAttempts[0] | Should -Match 'mutation\.ps1$'
    $global:FsHaRoleCleanupAttempts[1] | Should -Match 'mutation\.log$'
    Test-Path -LiteralPath (Split-Path -Path $global:FsHaRolePayloadPath -Parent) | Should -BeFalse
  }

  It 'D2-POLICY-BLOCK surfaces a distinct policy or App Control diagnostic' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:FsHaRoleTaskResult = [System.UInt32]2147943660
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*blocked by execution policy or App Control*'
  }

  It 'D2-POLICY-CLM classifies the Windows PowerShell constrained-language failure' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:FsHaRoleTaskResult = 1
    $global:SetClusteredFileServerReadTranscriptTail = {
      'Cannot invoke method. Method invocation is supported only on core types in this language mode.'
    }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*blocked by execution policy or App Control*language mode*'
  }

  It 'returns exact online standalone no-change state' {
    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | ConvertFrom-Json
    $Result.changed | Should -BeFalse
    $global:FsHaRoleWrites | Should -HaveCount 0
    $global:FsHaRoleClusterReads | Should -Be 1
    @($global:FsHaRoleClusterInputs | Where-Object { $PSItem -ne 'TCNAW-FSCL01' }) | Should -HaveCount 0
  }

  It 'exports only serialization-safe primitive result leaves' {
    $RawGroup = [System.IO.MemoryStream]::new()
    Try {
      $RawGroup | Add-Member -NotePropertyName Name -NotePropertyValue 'TCNAW-HAFS01'
      $RawGroup | Add-Member -NotePropertyName State -NotePropertyValue 'Online'
      $RawGroup | Add-Member -NotePropertyName OwnerNode -NotePropertyValue 'tcnaw-hafs01a'
      $global:FsHaRoleGroup = $RawGroup
      $Context = New-AnsibleContext

      $Output = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password

      $Output | Should -BeNullOrEmpty
      { $Context.Result | ConvertTo-Json -Depth 6 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop | Out-Null } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $Context.Result } | Should -Not -Throw
      { Assert-ResultPrimitiveLeaves -Value $RawGroup } | Should -Throw '*System.IO.MemoryStream*'
      $Context.Result.after.name | Should -Be 'TCNAW-HAFS01'
    } Finally {
      $RawGroup.Dispose()
    }
  }

  It 'rejects a differently named local cluster before role reads or writes' {
    $global:FsHaRoleClusterName = 'OTHER'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*belongs to cluster OTHER*'
    $global:FsHaRoleWrites | Should -HaveCount 0
    $global:FsHaRoleClusterInputs | Should -HaveCount 0
  }

  It 'F9-CREATION-ORDER creates the role then returns the away disk before rerun' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleResources[0].State = 'Offline'
    $global:FsHaAvailableStorageGroup.OwnerNode = 'tcnaw-hafs01b'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('MoveAvailable', 'StartDisk', 'Create', 'Owners', 'StopGroup', 'RemoveIp', 'RemoveIp', 'Dependency', 'StartGroup', 'MoveAvailable', 'StartDisk')
    $global:FsHaRoleWrites[0].InputObject | Should -Be $global:FsHaAvailableStorageGroup
    $global:FsHaRoleWrites[0].Node | Should -Be $script:Owners[0]
    $global:FsHaRoleWrites[0].Wait | Should -Be 600
    $global:FsHaRoleWrites[1].Name | Should -Be 'Cluster Disk 9'
    $global:FsHaRoleWrites[1].Wait | Should -Be 300
    $global:FsHaRoleWrites[2].StaticAddress | Should -Be $script:Addresses
    $global:FsHaRoleWrites[2].IgnoreNetwork | Should -BeNullOrEmpty
    $global:FsHaRoleWrites[2].Storage | Should -Be 'Cluster Disk 9'
    $global:FsHaRoleWrites[2].Wait | Should -Be 600
    $global:FsHaRoleWrites[3].Group | Should -Be 'TCNAW-HAFS01'
    $global:FsHaRoleWrites[3].Owners | Should -Be $script:Owners
    $global:FsHaRoleWrites[9].Node | Should -Be 'tcnaw-hafs01b'
    $global:FsHaRoleWrites[10].Name | Should -Be 'Cluster Disk 10'
    $global:FsHaRoleTaskRegistrations | Should -HaveCount 1
    $global:FsHaRoleTaskRegistrations[0].User | Should -Be 'TCN\svc-fscluster-mgr'
    $global:FsHaRoleTaskRegistrations[0].PasswordMatches | Should -BeTrue
    $global:FsHaRoleTaskRegistrations[0].RunLevel | Should -Be 'Highest'
    $global:FsHaRoleTaskRegistrations[0].Force | Should -BeTrue
    $global:FsHaRoleTaskUnregistrations | Should -HaveCount 1
    $global:FsHaRoleInnerCommand | Should -Not -Match ([System.Text.RegularExpressions.Regex]::Escape($script:Password))

    $global:FsHaRoleWrites = @()
    $global:FsHaRoleTaskRegistrations = @()
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleWrites | Should -HaveCount 0
    $global:FsHaRoleTaskRegistrations | Should -HaveCount 0
  }

  It 'D8-ROLE-CREATION-PRE-SCREEN retries every cold node and blocks creation at the deadline' {
    $NodeNames = @('tcnaw-hafs02b', 'tcnaw-hafs01a', 'tcnaw-hafs01b', 'tcnaw-hafs02a')
    $ColdNode = 'tcnaw-hafs01a'
    $WmiProbes = @(Get-SourceCommand -Name 'Get-WmiObject')
    $WmiProbes | Should -HaveCount 1
    @(Get-BoundParameterName -Command $WmiProbes[0]) | Should -Be @('Class', 'ComputerName', 'ErrorAction')
    @(Get-SourceCommand -Name 'Get-CimInstance') | Should -HaveCount 0
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleProbeFailures[$ColdNode] = 1

    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null

    $global:FsHaRoleProbeCalls.ComputerName | Should -Be @($NodeNames + $NodeNames)
    $global:FsHaRoleProbeCalls.Class | Select-Object -Unique | Should -Be 'Win32_ComputerSystem'
    $global:FsHaRoleProbeCalls.ErrorAction | Select-Object -Unique | Should -Be 'Stop'
    $global:FsHaRoleOperations[-1] | Should -Be 'Create'
    @($global:FsHaRoleWrites | Where-Object -FilterScript { $PSItem.Command -eq 'Create' }) | Should -HaveCount 1

    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleOwners = @($script:Owners)
    $global:FsHaRoleWrites = @()
    $global:FsHaRoleProbeCalls = @()
    $global:FsHaRoleOperations = @()
    $global:FsHaRoleProbeFailures = @{ $ColdNode = [System.Int32]::MaxValue }

    $InnerResult = Invoke-RoleMutationInner -Command $global:FsHaRoleInnerCommand -PreScreenDeadlineSeconds 0 -PreScreenIntervalSeconds 0

    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match ([System.Text.RegularExpressions.Regex]::Escape($ColdNode))
    $InnerResult.transcript | Should -Match 'last error: Readiness probe failed'
    $global:FsHaRoleProbeCalls.ComputerName | Should -Be $NodeNames
    $global:FsHaRoleWrites.Command | Should -Not -Contain 'Create'
    $global:FsHaRoleOperations | Should -Not -Contain 'Create'
  }

  It 'D7-CREATION-IP-PRUNE refreshes delayed auto-created IP resources before group start' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleResources[0].State = 'Offline'
    $global:FsHaRoleDelayAutoIps = $True

    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null

    $RoleIps = @($global:FsHaRoleResources | Where-Object -FilterScript {
        $PSItem.ResourceType -eq 'IP Address' -and $PSItem.OwnerGroup -eq 'TCNAW-HAFS01'
      })
    $RoleIps | Should -HaveCount 2
    @($RoleIps | ForEach-Object -Process { [System.String]$PSItem.Parameters.Address } | Sort-Object) |
      Should -Be @($script:Addresses | Sort-Object)
    $SortedRoleIps = @($RoleIps | Sort-Object -Property { [System.String]$PSItem.Parameters.Address })
    $SortedRoleIps[0].Parameters.Network | Should -Be 'Cluster Network 1'
    $SortedRoleIps[0].Parameters.SubnetMask | Should -Be $global:FsHaRoleNetworkMask
    $SortedRoleIps[0].Parameters.Address | Should -Be '10.0.1.12'
    $SortedRoleIps[0].Parameters.EnableDhcp | Should -Be 0
    $SortedRoleIps[1].Parameters.Network | Should -Be 'Cluster Network 2'
    $SortedRoleIps[1].Parameters.SubnetMask | Should -Be $global:FsHaRoleNetworkMask
    $SortedRoleIps[1].Parameters.Address | Should -Be '10.0.33.12'
    $SortedRoleIps[1].Parameters.EnableDhcp | Should -Be 0
    @($RoleIps | Where-Object -FilterScript { [System.String]$PSItem.Parameters.Address -in $script:Ignored }) |
      Should -HaveCount 0
    $Create = @($global:FsHaRoleWrites | Where-Object -FilterScript { $PSItem.Command -eq 'Create' })
    $Create | Should -HaveCount 1
    $Create[0].IgnoreNetwork | Should -BeNullOrEmpty
    $global:FsHaRoleWrites.Command | Should -Be @('MoveAvailable', 'StartDisk', 'Create', 'Owners', 'StopGroup', 'RemoveIp', 'RemoveIp', 'Dependency', 'StartGroup', 'MoveAvailable', 'StartDisk')
  }

  It 'D5-IGNORE-NETWORK-MOCK rejects a cluster network name before any write' {
    $Cluster = [PSCustomObject]@{ Name = 'TCNAW-FSCL01' }
    { Add-ClusterFileServerRole -InputObject $Cluster -Name 'TCNAW-HAFS01' -Storage 'Cluster Disk 9' -StaticAddress $script:Addresses -IgnoreNetwork @('Cluster Network 3') -Wait 600 } |
      Should -Throw "*The specified IP address 'Cluster Network 3' is invalid.*"
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'F9-INNER-ORDER proves the delegated seven-step payload and final readbacks' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null

    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleOwners = @($script:Owners)
    $global:FsHaRoleWrites = @()
    $InnerResult = Invoke-RoleMutationInner -Command $global:FsHaRoleInnerCommand
    $InnerResult.exit_code | Should -Be 0
    $global:FsHaRoleWrites.Command | Should -Be @('MoveAvailable', 'StartDisk', 'Create', 'Owners', 'StopGroup', 'RemoveIp', 'RemoveIp', 'Dependency', 'StartGroup', 'MoveAvailable', 'StartDisk')
  }

  It 'blocks role creation when starting the exact home disk does not land' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleResources[0].State = 'Offline'
    $global:FsHaAvailableStorageGroup.OwnerNode = 'tcnaw-hafs01b'
    $global:FsHaRoleStartFrozen = $True

    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*failed Online readback*'

    $global:FsHaRoleWrites.Command | Should -Be @('MoveAvailable', 'StartDisk')
    $global:FsHaRoleWrites.Command | Should -Not -Contain 'Create'
    $global:FsHaRoleWrites[1].Name | Should -Be 'Cluster Disk 9'
    $InnerResult = Invoke-RoleMutationInner -Command $global:FsHaRoleInnerCommand
    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match 'Home disk Cluster Disk 9 failed Online readback; observed state: Offline.'
  }

  It 'proves the delegated payload reports an unlanded converge with exit code one' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*group-placement readback*'
    $InnerResult = Invoke-RoleMutationInner -Command $global:FsHaRoleInnerCommand
    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match 'failed group-placement readback'
  }

  It 'D3-MISSING-TRANSCRIPT uses the production reader and unregisters the task' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    $global:FsHaRoleTaskResult = 1
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } |
      Should -Throw '*scheduled task result 1*(transcript unavailable)*'
    $global:FsHaRoleTaskUnregistrations | Should -HaveCount 1
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'corrects preferred-owner drift without bouncing the group' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('Owners')
  }

  It 'moves the exact home disk from Available Storage' {
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('Move')
  }

  It 'moves and starts only a remaining disk mismatched with the Available Storage owner' {
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.Name -ne 'Cluster Disk 10' })
    $global:FsHaAvailableStorageGroup.OwnerNode = 'tcnaw-hafs01a'
    $Placeable = New-Resource -Name 'Cluster Disk 10' -Type 'Physical Disk' -Group 'Available Storage' -Parameters @{ DiskIdGuid = '22222222-2222-2222-2222-222222222222' }
    $Deferred = New-Resource -Name 'Cluster Disk 11' -Type 'Physical Disk' -Group 'Available Storage' -State 'Offline' -Parameters @{ DiskIdGuid = '33333333-3333-3333-3333-333333333333' }
    $global:FsHaRoleResources += $Placeable, $Deferred
    $global:FsHaResourceOwners[$Placeable.Name] = @('tcnaw-hafs01a', 'tcnaw-hafs01b')
    $global:FsHaResourceOwners[$Deferred.Name] = @('tcnaw-hafs01b', 'tcnaw-hafs02b')

    $Result = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | ConvertFrom-Json

    $global:FsHaRoleWrites.Command | Should -Be @('MoveAvailable', 'StartDisk')
    $global:FsHaRoleWrites[0].InputObject | Should -Be $global:FsHaAvailableStorageGroup
    $global:FsHaRoleWrites[0].Node | Should -Be 'tcnaw-hafs01b'
    $global:FsHaRoleWrites[0].Wait | Should -Be 600
    $global:FsHaRoleWrites[1].Name | Should -Be $Deferred.Name
    $global:FsHaRoleWrites[1].Wait | Should -Be 300
    $Result.actions | Should -Be @('move_available_storage:Cluster Disk 11', 'start_shared_disk:Cluster Disk 11')

    $global:FsHaRoleWrites = @()
    $Second = & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | ConvertFrom-Json
    $Second.changed | Should -BeFalse
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'removes an arbitrary extra IP in one stop-start transaction' {
    $global:FsHaRoleResources += New-Resource -Name 'Observed AZ A Artifact' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.0.0'; Network = 'Cluster Network 1'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    $global:FsHaRoleResources += New-Resource -Name 'Observed AZ A Artifact 2' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.32.0'; Network = 'Cluster Network 2'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('StopGroup', 'StopIp', 'RemoveIp', 'StopIp', 'RemoveIp', 'Dependency', 'StartGroup')
    @($global:FsHaRoleWrites | Where-Object -FilterScript { $PSItem.Command -eq 'StopGroup' }) | Should -HaveCount 1
    @($global:FsHaRoleWrites | Where-Object -FilterScript { $PSItem.Command -eq 'StartGroup' }) | Should -HaveCount 1
  }

  It 'refuses to prune a DHCP-enabled extra IP before any cluster write' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleResources += New-Resource -Name 'DHCP Artifact' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.0.0'; Network = 'Cluster Network 1'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 1 }
    $global:FsHaRoleWrites = @()

    $InnerResult = Invoke-RoleMutationInner -Command $global:FsHaRoleInnerCommand

    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match 'Refusing to prune IP resource DHCP Artifact: DHCP is enabled.'
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'refuses to prune an extra IP used by another Network Name before any cluster write' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleResources += New-Resource -Name 'Shared Artifact' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.0.0'; Network = 'Cluster Network 1'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    $global:FsHaRoleResources += New-Resource -Name 'Other Service Name' -Type 'Network Name' -Group 'Other Service'
    $global:FsHaRoleDependencies['Other Service Name'] = '[Shared Artifact]'
    $global:FsHaRoleWrites = @()

    $InnerResult = Invoke-RoleMutationInner -Command $global:FsHaRoleInnerCommand

    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match 'Refusing to prune IP resource Shared Artifact: it is a dependency of Network Name resource Other Service Name.'
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'refuses to prune from a group carrying a second Network Name before any cluster write' {
    $global:FsHaRoleOwners = @('tcnaw-hafs02a', 'tcnaw-hafs01a')
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleResources += New-Resource -Name 'Extra Artifact' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.0.0'; Network = 'Cluster Network 1'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    $global:FsHaRoleResources += New-Resource -Name 'Second File Server Name' -Type 'Network Name' -Group 'TCNAW-HAFS01'
    $global:FsHaRoleWrites = @()

    $InnerResult = Invoke-RoleMutationInner -Command $global:FsHaRoleInnerCommand

    $InnerResult.exit_code | Should -Be 1
    $InnerResult.transcript | Should -Match 'must expose exactly one Network Name resource; refusing IP prune.'
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'D4-STATIC-IP-PARAMETERS writes each declared private property to its named parameter' {
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.Name -ne 'IP Address 10.0.33.12' })
    $global:FsHaRoleRejectMultipleIpParameters = $True
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleWrites.Command | Should -Contain 'AddIp'
    $global:FsHaRoleWrites.Command | Should -Not -Contain 'Create'
    $Set = @($global:FsHaRoleWrites | Where-Object -FilterScript { $PSItem.Command -eq 'SetIp' })
    $Set | Should -HaveCount 4
    $Set.Resource | Should -Be @('IP Address 10.0.33.12', 'IP Address 10.0.33.12', 'IP Address 10.0.33.12', 'IP Address 10.0.33.12')
    $Set.Parameter | Should -Be @('Network', 'SubnetMask', 'Address', 'EnableDhcp')
    $Set.Value | Should -Be @('Cluster Network 2', $global:FsHaRoleNetworkMask, '10.0.33.12', 0)
  }

  It 'repairs wrong DHCP network and mask in one transaction' {
    $global:FsHaRoleResources[2].Parameters.EnableDhcp = 1
    $global:FsHaRoleResources[2].Parameters.Network = 'Wrong'
    $global:FsHaRoleResources[2].Parameters.SubnetMask = '255.0.0.0'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('StopGroup', 'SetIp', 'SetIp', 'SetIp', 'SetIp', 'Dependency', 'StartGroup')
  }

  It 'repairs only the exact OR dependency with one stop-start' {
    $global:FsHaRoleDependency = '[IP Address 10.0.1.12] and [IP Address 10.0.33.12]'
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $global:FsHaRoleWrites.Command | Should -Be @('StopGroup', 'Dependency', 'StartGroup')
    $global:FsHaRoleWrites[1].Dependency | Should -Be '[IP Address 10.0.1.12] or [IP Address 10.0.33.12]'
  }

  It 'rejects an invalid no-change IP state without writes' {
    $global:FsHaRoleResources[3].State = 'Online'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*static-IP membership*'
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'fails readback after create or repair does not land' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $global:FsHaRoleFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*group-placement readback*'
  }

  It 'fails readback after a static-IP repair does not land' {
    $global:FsHaRoleResources[2].Parameters.EnableDhcp = 1
    $global:FsHaRoleFrozen = $True
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*static-IP*'
  }

  It 'predicts absent and partial role check mode with zero writes' {
    $global:FsHaRolePresent = $False
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -eq 'Physical Disk' })
    $global:FsHaRoleResources[0].OwnerGroup = 'Available Storage'
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $Context.Changed | Should -BeTrue
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'predicts a partial existing role in check mode without cluster writes' {
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.Name -ne 'IP Address 10.0.33.12' })
    $Context = New-AnsibleContext -CheckMode
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $Context.Result.actions | Should -Contain 'add_ip:10.0.33.12'
    $global:FsHaRoleWrites | Should -HaveCount 0
  }

  It 'rejects missing or ambiguous home disk identity' {
    $global:FsHaRoleLocalDisks = @()
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*exactly one local*'
    $global:FsHaRoleLocalDisks = @([PSCustomObject]@{ Guid = 'a'; UniqueId = 'vol0abc123' }, [PSCustomObject]@{ Guid = 'b'; UniqueId = 'vol0abc123' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*exactly one local*'
  }

  It 'rejects an ambiguous home Physical Disk resource identity' {
    $global:FsHaRoleResources += New-Resource -Name 'Duplicate Home Identity' -Type 'Physical Disk' -Group 'Available Storage' -Parameters @{ DiskIdGuid = '11111111-1111-1111-1111-111111111111' }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*exactly one Physical Disk*'
  }

  It 'rejects a wrong or extra disk in the role' {
    $global:FsHaRoleResources += New-Resource -Name 'Foreign Disk' -Type 'Physical Disk' -Group 'TCNAW-HAFS01' -Parameters @{ DiskIdGuid = '22222222-2222-2222-2222-222222222222' }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*wrong or extra*'
  }

  It 'rejects missing or extra client-eligible network coverage' {
    $global:FsHaRoleNetworks = @($global:FsHaRoleNetworks | Where-Object -FilterScript { $PSItem.Address -ne '10.0.96.0' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*Ignored network address*'
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Cluster Network 4'; Address = '10.0.96.0'; AddressMask = $global:FsHaRoleNetworkMask; Role = 3 }
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Unexpected'; Address = '172.16.0.0'; AddressMask = '255.255.0.0'; Role = 3 }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*cover every*'
  }

  It 'rejects missing or ambiguous static and ignored network identity' {
    $global:FsHaRoleNetworks = @($global:FsHaRoleNetworks | Where-Object -FilterScript { $PSItem.Address -ne '10.0.0.0' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*Static address*'
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Cluster Network 1'; Address = '10.0.0.0'; AddressMask = $global:FsHaRoleNetworkMask; Role = 3 }
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Overlapping Static'; Address = '10.0.0.0'; AddressMask = '255.255.0.0'; Role = 3 }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*Static address*'
    $global:FsHaRoleNetworks = @($global:FsHaRoleNetworks | Where-Object -FilterScript { $PSItem.Name -ne 'Overlapping Static' })
    $global:FsHaRoleNetworks += [PSCustomObject]@{ Name = 'Duplicate Ignored'; Address = '10.0.64.0'; AddressMask = $global:FsHaRoleNetworkMask; Role = 3 }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*Ignored network address*'
  }

  It 'rejects duplicate IP and missing or multiple Network Name resources' {
    $global:FsHaRoleResources += New-Resource -Name 'Duplicate' -Type 'IP Address' -Group 'TCNAW-HAFS01' -Parameters @{ Address = '10.0.1.12'; Network = 'Cluster Network 1'; SubnetMask = $global:FsHaRoleNetworkMask; EnableDhcp = 0 }
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*duplicate IP*'
    $global:FsHaRoleResources = @($global:FsHaRoleResources | Where-Object -FilterScript { $PSItem.ResourceType -ne 'Network Name' -and $PSItem.Name -ne 'Duplicate' })
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*exactly one Network Name*'
    $global:FsHaRoleResources += New-Resource -Name 'File Server Name' -Type 'Network Name' -Group 'TCNAW-HAFS01'
    $global:FsHaRoleResources += New-Resource -Name 'Second File Server Name' -Type 'Network Name' -Group 'TCNAW-HAFS01'
    { & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password } | Should -Throw '*exactly one Network Name*'
  }

  It 'sets Ansible Changed false from its initially true context' {
    $Context = New-AnsibleContext
    & $script:ScriptPath -ClusterName 'TCNAW-FSCL01' -RoleName 'TCNAW-HAFS01' -HomeVolumeId 'vol-0abc123' -Owners $script:Owners -StaticAddress $script:Addresses -IgnoredNetworkAddress $script:Ignored -Password $script:Password | Out-Null
    $Context.Changed | Should -BeFalse
  }
}
