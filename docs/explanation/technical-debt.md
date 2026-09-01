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

## TD-002 — Witness quorum is deferred

**Gap:** The implemented cluster remains `NodeMajority`. The intended witness is workgroup-joined
and its security group has no inbound SMB path from the nodes; this implementation is forbidden
from changing the witness security group or ENI.
**Containment:** The final proof requires `NodeMajority` and reports workgroup file-share
witness/quorum as NOT DONE. No witness credential, share, networking, or quorum mutation occurs.
**Exit:** An authorized plan supplies a dedicated local credential, an exclusive SMB2+ witness
share with exact filesystem/share rights, TCP/445 authorization, sensitive credential transport,
and fresh quorum validation before changing the quorum model.

## TD-003 — Cross-AZ data service is deferred

**Gap:** Both per-AZ disks are adopted into the cluster and constrained to their declared owner
pairs, but only the AZ-a disk hosts a file-server role and encrypted CA `data` share. There is no
AZ-b file-server role or Storage Replica relationship.
**Containment:** The final proof requires the AZ-b disk to remain Online in `Available Storage`,
absent from the AZ-a role, and reports both the AZ-b role and Storage Replica as NOT DONE. The
implemented data service is not described as cross-AZ.
**Exit:** An authorized plan creates the AZ-b role, configures Storage Replica between the exact
volumes, and passes full planned and unplanned failover proof without weakening owner or access
policy.
