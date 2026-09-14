# `fileserver` role

Windows Server 2025 highly available file service (WSFC stretch cluster) — the cluster/file-service
application role; directory prestaging is owned by the sibling `fileserver_ad_config` supporting role.

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
| `files/Set-FileServerCluster.ps1.stub` | `scripts/Set-FileServerCluster.ps1` + `.pester.ps1` | Exact caller-declared cluster membership and static addresses |
| `files/Set-ClusterNameParameters.ps1.stub` | `scripts/Set-ClusterNameParameters.ps1` + `.pester.ps1` | Cluster Name DNS registration parameters |
| `files/Set-ClusterSharedDisks.ps1.stub` | `scripts/Set-ClusterSharedDisks.ps1` + `.pester.ps1` | EBS-identity disk adoption, possible owners, and Online state |
| `files/Set-ClusteredFileServer.ps1.stub` | `scripts/Set-ClusteredFileServer.ps1` + `.pester.ps1` | Caller-declared file-server role converged by the role's cluster scope: home disk, preferred owners, static IPs, and OR dependency |
| `files/Set-ClusteredSmbShare.ps1.stub` | `scripts/Set-ClusteredSmbShare.ps1` + `.pester.ps1` | Protected directory DACL and exact scoped clustered SMB share |

`scripts/materialize-role-scripts.sh` resolves each stub into `files/<Name>.ps1` before the
role is linted or run; the materialized copy is a build artifact and is never committed.
Each script owns its own read → normalized diff → mutate-only-the-drift →
re-acquire-and-verify cycle and reports a deterministic Change/NoChange verdict through
`$Ansible`, so the play recap stays honest and the task file stays declarative. Contract and
repo wiring: [docs/reference/powershell-style-guide.md](../../../docs/reference/powershell-style-guide.md).

## What the caller supplies

For `state=present`, the playbook supplies the environment-specific leaves omitted from defaults:

| Key | Contract |
|---|---|
| `cluster.service_account` | Account that forms and administers the cluster nodes. |
| `cluster.name` | Cluster identity. |
| `cluster.nodes` | Exact four-node list. |
| `cluster.static_addresses` | Four distinct core cluster addresses. |
| `cluster.shared_disks[]` | Exactly two `function`, `owners`, and `fileserver_home` declarations. |
| `cluster.file_server.name` | Clustered file-server role identity. |
| `cluster.file_server.static_addresses` | Two distinct role addresses. |
| `cluster.file_server.ignored_network_addresses` | Two distinct ignored network addresses. |
| `cluster.share.path` | Drive-rooted clustered-share path. |
| `cluster.share.ntfs_access` | Complete three-entry protected DACL, including the site principal. |
| `cluster.share.share_access` | Complete two-entry share ACL, including the same site principal. |

The inventory contract supplies the four-node group, the invocation supplies the AWS region, and the
cluster play supplies its ambient cluster-service-account connection context. `tasks/validate.yml`
rejects a malformed merged map before any role mutation.

## Configuration

Defaults (`defaults/main.yml`, merged by the v3 loader into `fileserver_running`) carry product
opinion only: the node execution-scope default, SMB hardening, fixed Windows resource and share
labels, Cluster Name resource parameters, share properties, and built-in principal grants. The
playbook supplies every deployment-specific value through its anchored `fileserver` map: the
service account; cluster and file-server identities; node and disk ownership; addresses; share path;
and site principal. Caller-supplied access lists replace the defaults whole. Validation treats the
merged maps as exact policy. Runtime volume identifiers and the cluster credential never enter
defaults; the playbook resolves the credential once, and the role's cluster scope resolves the
Function-tagged declared volumes immediately before cluster mutation.
The baseline role call takes the node execution-scope default; the cluster play passes cluster,
and tasks read only fileserver_running.execution_scope.

The directory DACL is protected and contains exactly SYSTEM and local Administrators
`FullControl` plus Domain Users `Modify`; the share ACL contains exactly local Administrators
`Full` plus Domain Users `Change`. Owner, group, and SACL are preserved.

Not implemented: the witness SMB share and quorum, an AZ-b file-server role, and Storage Replica.
Quorum remains `NodeMajority`; the adopted AZ-b disk is owner-scoped but hosts no role.

## State

- `present` (default) — converge the role's declared state.
- `absent` — not implemented; the framework loader fails before role work because no
  `absent_windows.yml` exists.
- `clean` — supported no-op; neither role leaves a persistent cache to remove.
