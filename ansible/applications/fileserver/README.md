# fileserver

Windows Server 2025 highly available file service (WSFC stretch cluster) — the single
application role this repository carries.

## Current scope

The role converges the **SMB server hardening baseline** and then **fails closed**: WSFC
bootstrap (EP3) and shared disks, Storage Replica, and clustered file roles (EP4) are not
implemented, and a host must not be reported converged into an undefined state. The END guard
in `tasks/present_windows.yml` is removed only when that surface lands.

## How this role does complex work

Every mutation too complex for a native `ansible.windows` module is a **first-class PowerShell
script** executed through `ansible.windows.win_powershell`. The role carries only a stub
marker per script (the org three-file convention); the script itself lives once, with its
spec, under `scripts/`:

| Stub in this role | Source pair | Converges |
|---|---|---|
| `files/Set-SmbServerHardening.ps1.stub` | `scripts/Set-SmbServerHardening.ps1` + `.pester.ps1` | SMB server configuration against the declared baseline (`fileserver.smb.settings`) |

`scripts/materialize-role-scripts.sh` resolves each stub into `files/<Name>.ps1` before the
role is linted or run; the materialized copy is a build artifact and is never committed.
Each script owns its own read → normalized diff → mutate-only-the-drift →
re-acquire-and-verify cycle and reports a deterministic Change/NoChange verdict through
`$Ansible`, so the play recap stays honest and the task file stays declarative. Contract and
repo wiring: [docs/reference/powershell-style-guide.md](../../../docs/reference/powershell-style-guide.md).

## Configuration

Defaults (`defaults/main.yml`, merged by the v3 loader into `fileserver_running`) carry only
universally safe values — currently the SMB baseline, which is this repository's declared
security posture. Deployment-specific inputs (domain identity, DNS, witness path, disk
identities) arrive with EP3/EP4 as playbook-supplied keys in the `fileserver:` override dict,
documented in `meta/main.yml` and enforced in `tasks/validate.yml`.
