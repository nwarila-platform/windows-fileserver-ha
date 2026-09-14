# fileserver

Windows Server 2025 highly available file service (WSFC stretch cluster) — the single
application role this repository carries.

## Implemented scope

The role's Administrator phase converges the SMB server baseline, Failover Clustering and File
Services prerequisites, AWS NVMe reservation support, and cluster-service-account membership in
local Administrators. The fleet playbook then connects to the inventory-proven singleton former
as the cluster service account. The role’s cluster scope performs the whole cluster convergence: it
forms `TCNAW-FSCL01`, converges its name parameters, adopts both declared disks by EBS identity,
creates the AZ-a role `TCNAW-HAFS01`, and publishes its encrypted CA `data` share. The cluster play
only invokes that scope. A final controller-only play forgets the in-memory cluster credential.

## How this role does complex work

Every mutation too complex for a native `ansible.windows` module is a **first-class PowerShell
script** executed through `ansible.windows.win_powershell`. The role carries only a stub
marker per script (the org three-file convention); the script itself lives once, with its
spec, under `scripts/`:

| Stub in this role | Source pair | Converges |
|---|---|---|
| `files/Get-ClusteredFileServerOwner.ps1.stub` | `scripts/Get-ClusteredFileServerOwner.ps1` + `.pester.ps1` | Exact Online clustered file-server role owner for node-local delegation |
| `files/Set-DomainControllerReverseZone.ps1.stub` | `scripts/Set-DomainControllerReverseZone.ps1` + `.pester.ps1` | Exact domain-controller reverse-zone NRPT rule with failure-honest readback |
| `files/Set-SmbServerHardening.ps1.stub` | `scripts/Set-SmbServerHardening.ps1` + `.pester.ps1` | SMB server configuration against the declared baseline (`fileserver.smb.settings`) |
| `files/Set-FileServerCluster.ps1.stub` | `scripts/Set-FileServerCluster.ps1` + `.pester.ps1` | Exact four-node cluster and core static addresses |
| `files/Set-ClusterNameParameters.ps1.stub` | `scripts/Set-ClusterNameParameters.ps1` + `.pester.ps1` | Cluster Name DNS registration parameters |
| `files/Set-ClusterSharedDisks.ps1.stub` | `scripts/Set-ClusterSharedDisks.ps1` + `.pester.ps1` | EBS-identity disk adoption, possible owners, and Online state |
| `files/Set-ClusteredFileServer.ps1.stub` | `scripts/Set-ClusteredFileServer.ps1` + `.pester.ps1` | AZ-a file-server role, home disk, preferred owners, static IPs, and OR dependency |
| `files/Set-ClusteredSmbShare.ps1.stub` | `scripts/Set-ClusteredSmbShare.ps1` + `.pester.ps1` | Protected directory DACL and exact scoped clustered SMB share |

`scripts/materialize-role-scripts.sh` resolves each stub into `files/<Name>.ps1` before the
role is linted or run; the materialized copy is a build artifact and is never committed.
Each script owns its own read → normalized diff → mutate-only-the-drift →
re-acquire-and-verify cycle and reports a deterministic Change/NoChange verdict through
`$Ansible`, so the play recap stays honest and the task file stays declarative. Contract and
repo wiring: [docs/reference/powershell-style-guide.md](../../../docs/reference/powershell-style-guide.md).

## Configuration

Defaults (`defaults/main.yml`, merged by the v3 loader into `fileserver_running`) carry this
single fleet's ratified SMB, cluster topology, disk-owner, role-address, share-property, NTFS,
and share-access policy. Validation treats those maps as exact policy. Secrets and runtime AWS
volume identifiers never enter defaults: the playbook resolves the password once into controller
memory, and the role's cluster scope resolves Function-tagged volumes using IMDSv2 on each declared
disk preparer and DescribeVolumes on localhost, then publishes the resolved map on the former
immediately before cluster mutation.
The baseline role call takes the node execution-scope default; the cluster play passes cluster,
and tasks read only fileserver_running.execution_scope.

The directory DACL is protected and contains exactly SYSTEM and local Administrators
`FullControl` plus Domain Users `Modify`; the share ACL contains exactly local Administrators
`Full` plus Domain Users `Change`. Owner, group, and SACL are preserved.

Not implemented: the witness SMB share and quorum, an AZ-b file-server role, and Storage Replica.
Quorum remains `NodeMajority`; the adopted AZ-b disk is owner-scoped but hosts no role.
