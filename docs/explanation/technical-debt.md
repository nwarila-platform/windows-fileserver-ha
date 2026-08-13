# Technical debt

Every known gap, its containment, and its exit criteria. Entries close when the exit criteria
are met, not when they stop being inconvenient.

## TD-001 — The deploy scaffold has not landed

**Gap:** The workflows, Terraform data, IAM documents, framework pins, composition tooling, and
the `verify.sh` entry point (the windows-wsus-derived deploy surface) are not yet in this
repository, so the deploy lifecycle cannot run at all and the quality gates that do exist
(`scripts/check-powershell.sh`, `scripts/check-winshell-splitargs.py`) are invoked directly
rather than from one verification entry point.
**Containment:** The Ansible/PowerShell tree is authored to the composed-framework contract
(v3.3.0 loader, `roles_path` by bare name) so the scaffold lands around it without rework; the
gates run standalone in the meantime.
**Exit:** The scaffold lands with both gates wired into `verify.sh`, framework pins recorded
under `.github/`, and the five-instance assertions at every ratified site.

## TD-002 — No domain, and the cluster cannot converge without one

**Gap:** Active Directory is mandatory for Storage Replica and clustered file roles, and the
domain controllers are owner-supplied and out of scope. Until the owner provides the domain
FQDN, DNS addresses, a join-credential path, and reachability from the four node subnets,
EP3/EP4 cannot be implemented and no deploy can reach a green cluster.
**Containment:** The fileserver role fails closed (`END` guard in
`tasks/present_windows.yml`) rather than reporting a host converged into an undefined state;
no domain-join or AD egress configuration exists anywhere in the repo, so nothing points at a
guessed destination.
**Exit:** Owner supplies the domain inputs; EP3 lands domain join and WSFC bootstrap and
removes the fail-closed guard.

## TD-003 — Per-node and shared storage is unmodeled

**Gap:** The per-AZ io2 Multi-Attach shared volumes and per-node data-disk layouts are absent:
the pinned Terraform framework cannot express shared volumes, and a disk layout declared before
EP4's storage design would be a fiction. The playbook therefore composes no
`windows_disk_manager` entry yet.
**Containment:** Noted in the playbook header; the role's storage-dependent surface is behind
the TD-002 fail-closed guard anyway.
**Exit:** EP4 lands the storage design on a framework pin that carries `all_volumes`, and the
playbook declares the disk layout through `windows_disk_manager`.
