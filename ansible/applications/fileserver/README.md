# `fileserver` role

Windows Server 2025 highly available file service (WSFC stretch cluster) — the cluster/file-service
application role; directory prestaging is owned by the sibling `fileserver_ad_config` supporting role.

## Implemented scope

The role's node phase converges the SMB server baseline, Failover Clustering and File Services
prerequisites, AWS NVMe reservation support, and cluster-service-account membership in local
Administrators under the caller-selected domain automation identity. A preceding fleet play then
resolves the cluster service account on all four nodes and the witness and publishes their connection
facts. The inventory-proven singleton formation play consumes those facts, and the role’s cluster
scope performs the whole cluster convergence: it
forms the caller-declared cluster, converges its name parameters, adopts both declared disks by EBS
identity, creates the caller-declared file-server name as the implemented AZ role, and publishes every
caller-declared clustered share and folder tree under the role's encryption and access policy. The
cluster play only invokes that scope. The final controller play clears the localhost source
credential; host-scoped connection and role-input copies remain only in process memory until the
immediately following playbook exit.

## How this role does complex work

Every mutation too complex for a native `ansible.windows` module is a **first-class PowerShell
script** executed through `ansible.windows.win_powershell`. The role carries only a stub
marker per script (the org three-file convention); the script itself lives once, with its
spec, under `scripts/`:

| Stub in this role | Source pair | Converges |
|---|---|---|
| `files/Get-ClusteredFileServerOwner.ps1.stub` | `scripts/Get-ClusteredFileServerOwner.ps1` + `.pester.ps1` | Exact Online clustered file-server role owner for node-local delegation |
| `files/Set-DomainControllerNamespace.ps1.stub` | `scripts/Set-DomainControllerNamespace.ps1` + `.pester.ps1` | Exact domain-controller NRPT rule (realm forward zone and DC reverse zone) with failure-honest readback |
| `files/Set-PrestagedClusterNameObject.ps1.stub` | `scripts/Set-PrestagedClusterNameObject.ps1` + `.pester.ps1` | Prestaged cluster name object release with explicit directory binding and two-controller readback |
| `files/Set-SmbServerHardening.ps1.stub` | `scripts/Set-SmbServerHardening.ps1` + `.pester.ps1` | SMB server configuration against the declared baseline (`fileserver.smb.settings`) |
| `files/Set-FileServerCluster.ps1.stub` | `scripts/Set-FileServerCluster.ps1` + `.pester.ps1` | Exact caller-declared cluster membership and static addresses |
| `files/Set-ClusterNameParameters.ps1.stub` | `scripts/Set-ClusterNameParameters.ps1` + `.pester.ps1` | Network Name DNS registration parameters (Cluster Name and file-server access point) |
| `files/Set-ClusterSharedDisks.ps1.stub` | `scripts/Set-ClusterSharedDisks.ps1` + `.pester.ps1` | EBS-identity disk adoption, possible owners, and Online state |
| `files/Set-ClusteredFileServer.ps1.stub` | `scripts/Set-ClusteredFileServer.ps1` + `.pester.ps1` | Caller-declared file-server role converged by the role's cluster scope: home disk, preferred owners, static IPs, and OR dependency |
| `files/Set-ClusteredFolderTree.ps1.stub` | `scripts/Set-ClusteredFolderTree.ps1` + `.pester.ps1` | Declared folders, inheritance boundaries, and exact explicit access entries without recursion |
| `files/Set-ClusteredSmbShare.ps1.stub` | `scripts/Set-ClusteredSmbShare.ps1` + `.pester.ps1` | Protected directory DACL and exact scoped clustered SMB share |
| `files/Set-ClusterFileShareWitness.ps1.stub` | `scripts/Set-ClusterFileShareWitness.ps1` + `.pester.ps1` | Dedicated directory, exact protected CNO DACL, and exact standalone witness share |
| `files/Set-ClusterFileShareWitnessQuorum.ps1.stub` | `scripts/Set-ClusterFileShareWitnessQuorum.ps1` + `.pester.ps1` | Exact Online file-share witness resource and Node and File Share Majority quorum |

`scripts/materialize-role-scripts.sh` resolves each stub into `files/<Name>.ps1` before the
role is linted or run; the materialized copy is a build artifact and is never committed.
Each script owns its own read → normalized diff → mutate-only-the-drift →
re-acquire-and-verify cycle and reports a deterministic Change/NoChange verdict through
`$Ansible`, so the play recap stays honest and the task file stays declarative. Contract and
repo wiring: [docs/reference/powershell-style-guide.md](../../../docs/reference/powershell-style-guide.md).

## What the caller supplies

For `state=present`, the playbook supplies these environment-specific input values:

| Key | Contract |
|---|---|
| `cluster.service_account` | Account that forms and administers the cluster nodes. |
| `cluster.service_account_password` | Password supplied explicitly for the service account's delegation-capable batch logons. |
| `cluster.name` | Cluster identity. |
| `cluster.nodes` | Exact four-node list. |
| `cluster.static_addresses` | Four distinct core cluster addresses. |
| `cluster.shared_disks[]` | Exactly two `function`, `owners`, and `fileserver_home` declarations. |
| `cluster.file_server.name` | Clustered file-server role identity. |
| `cluster.file_server.static_addresses` | Two distinct role addresses. |
| `cluster.file_server.ignored_network_addresses` | Two distinct ignored network addresses. |
| `cluster.witness.host` | Dedicated non-cluster domain member that hosts the witness share. |
| `cluster.witness.cluster_principal` | Down-level CNO principal granted exact witness rights. |
| `cluster.witness.node_addresses` | Four node addresses admitted through the witness host firewall. |
| `cluster.witness.share.path` | Drive-rooted local witness directory path. |
| `cluster.shares[]` | Ordered share declarations; the preserved `data` share is first. |
| `cluster.shares[].path` | Unique, non-nested, drive-rooted clustered-share path. |
| `cluster.shares[].access` | Compact caller grants as `{ principal, rights, share }`; the role emits the complete protected NTFS and share ACLs. |
| `cluster.shares[].folders[]` | Optional ordered relative folders with compact `{ principal, rights }` grants; `inherit` defaults to `true`. |

The inventory contract supplies the four-node group, the invocation supplies the AWS region, and a
preceding fleet play resolves the cluster-service-account connection on all four nodes and the witness.
The singleton formation play consumes those published connection facts and supplies that account's
password explicitly to the role. `tasks/validate.yml` rejects a malformed merged map before any role
mutation.

## Configuration

Defaults (`defaults/main.yml`, merged by the v3 loader into `fileserver_running`) carry product
opinion and an empty required-input contract: the node execution-scope default, SMB hardening,
the cluster service account password contract, fixed Windows resource labels,
Network Name resource parameters, share property defaults, and protected principal grants. The
playbook supplies every deployment-specific value through its anchored cluster declaration and the
shared `ansible/playbooks/vars/fileserver-shares.yml` declaration: the
service account; cluster, file-server, and witness identities; node and disk ownership; addresses;
share names, paths, descriptions, folder trees; and site principals. The shared file is compact:
the role supplies SYSTEM and Administrators, `Allow`, inheritance and propagation flags, share
property defaults, and the default `inherit: true` before a value crosses a module boundary.
Callers are refused if they attempt to write any of those role-owned access fields or principals.
Validation treats the merged maps as exact policy. Runtime volume identifiers and the cluster
credential value never enter defaults; the playbook resolves the credential once and supplies it at
the cluster role invocation, and the role's cluster scope resolves the Function-tagged declared
volumes immediately before cluster mutation.
The baseline role call takes the node execution-scope default; the cluster play passes cluster,
and tasks read only fileserver_running.execution_scope.

The first `data` share preserves the historical exact root policy: SYSTEM and local Administrators
`FullControl` plus one case-identical site principal with `Modify`, and local Administrators `Full`
plus that site principal with `Change` on the share. Later roots retain the protected entries and
may add unique supported Allow grants. Folder DACLs keep explicit SYSTEM and local Administrators
`FullControl`, honor the declared inheritance boundary, and contain exactly the remaining declared
entries. Owner, group, SACL, files, and undeclared folders are untouched.

Managed principals follow `DOMAIN\DOMAIN_GS-FileShare_Share[-Folder...]-Modify|Read`. The two
domain tokens must match, and Title-Case share and folder segments match the declaration
case-insensitively. `Read` grants `ReadAndExecute` (and SMB `Read` at a root), while `Modify`
grants `Modify` (and SMB `Change` at a root). Explicitly unmanaged non-group principals are exempt.

Not implemented: a second file-server role and Storage Replica. The second adopted disk is
owner-scoped but hosts no role.

## State

- `present` (default) — converge the role's declared state.
- `absent` — not implemented; the framework loader fails before role work because no
  `absent_windows.yml` exists.
- `clean` — supported no-op; neither role leaves a persistent cache to remove.
