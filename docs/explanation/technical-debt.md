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

## TD-002 — Domain convergence and cluster bootstrap are not proven

**Gap:** Active Directory is mandatory for Storage Replica and clustered file roles. The
playbook now declares the private-network and domain-member contracts for the four nodes, but
their live convergence is not yet proven and the WSFC bootstrap is not implemented.
**Containment:** The fileserver role fails closed (`END` guard in
`tasks/present_windows.yml`) rather than reporting a host converged into an undefined state; the
non-domain-joined witness is excluded from the domain-side play by its `hosts:` boundary.
**Exit:** The tunnel and domain join converge on all four nodes, WSFC bootstrap lands, and the
fail-closed guard advances to the next unimplemented cluster region.

## TD-003 — Shared storage is not cluster-ready

**Gap:** The playbook prepares each io2 Multi-Attach volume as `D:` on exactly one node per pair,
but the role does not yet enable NVMe persistent reservations or place the volumes under cluster
ownership.
**Containment:** Only the designated first node in each Availability Zone can initialize,
partition, or format its pair's shared volume; the storage-dependent application surface remains
behind the TD-002 fail-closed guard.
**Exit:** A later region enables persistent reservations, reboots as required, validates the
storage, and places the prepared volumes under cluster ownership without reformatting them.
