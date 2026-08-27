# Technical debt

Every known gap, its containment, and its exit criteria. Entries close when the exit criteria
are met, not when they stop being inconvenient.

## TD-001 — Deploy checks are outside the contributor-local verifier

**Gap:** `scripts/verify.sh` runs the three existing contributor-local gates (`yamllint`, the org
PowerShell pair suite, and `scripts/materialize-role-scripts.sh --check`) through one entry point,
but it does not run the deploy workflow's Terraform-format, workflow-lint, or IAM checks.
**Containment:** The deploy files are checked directly with `terraform fmt -check`, `yamllint`,
and `actionlint`; the IAM reference documents remain reviewable in their tracked form.
**Exit:** `scripts/verify.sh` gains the deploy-workflow checks and IAM checks.

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

## TD-003 — Shared storage is not adopted in the guest

**Gap:** Terraform provisions one io2 Multi-Attach volume per node pair, but the playbook has no
guest disk layout and the role does not yet enable NVMe persistent reservations or adopt the
shared volumes. The playbook therefore composes no `windows_disk_manager` entry yet.
**Containment:** Noted in the playbook header; the role's storage-dependent surface is behind
the TD-002 fail-closed guard anyway.
**Exit:** EP4 enables persistent reservations, adopts the shared volumes without reformatting,
and declares the disk layout through `windows_disk_manager`.
