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

## TD-005 — Managed-host identity is not authenticated before contact

**Gap:** `ansible/inventory/aws_ec2.yml` sets `StrictHostKeyChecking=no` and
`UserKnownHostsFile=/dev/null`, so direct SSH accepts every host key and records none.
**Why debt, not a defect:** All six declared connections are direct SSH; there is no Session
Manager or WinRM leg. Short-lived hosts and run-scoped security-group paths narrow exposure without
authenticating the endpoint, so the deployment works while retaining that trust gap.
**Correction:** Before the first `credential_resolver` attempt, acquire each host's public SSH keys
through a platform-authenticated channel, write them to a run-scoped known-hosts file, and require
`StrictHostKeyChecking=yes`.
**Exit:** Every host's keys are acquired before its first connection; a rebuilt host needs no manual
known-hosts edit; a mismatched key is refused before authentication; and the inventory uses the
run-scoped file with `StrictHostKeyChecking=yes`, never `no`, `accept-new`, or `/dev/null`.
