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

**Gap:** The implemented cluster remains `NodeMajority`. The domain-joined witness interface still
declares `security_groups = []` and `ingress = []`, so the four cluster nodes have no inbound SMB
path to it.
**Containment:** The final proof requires `NodeMajority` and reports file-share witness/quorum as
NOT DONE. The witness receives domain membership, but no SMB share,
inbound access, or quorum mutation occurs.
**Exit:** An authorized plan permits TCP/445 only from the four cluster nodes, creates an exclusive
SMB2+ witness share with exact filesystem/share rights, configures quorum with domain credentials
and Kerberos, and passes fresh quorum validation before changing the quorum model.

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

## TD-004 — Cluster directory identities have no release path

**Gap:** The CNO and VCO are correctly prestaged: `svc-fscluster-mgr` has an explicit `GenericAll`
ACE on `TCNAW-FSCL01`, and `TCNAW-FSCL01$` has one on `TCNAW-HAFS01`. Teardown destroys the
infrastructure without removing the cluster, leaving both objects enabled. The enabled state is the
[vendor-documented safety interlock](https://learn.microsoft.com/en-us/windows-server/failover-clustering/prestage-cluster-adds)
that prevents a new cluster from adopting an account already in use.
**Containment:** The objects are disabled by hand before each ephemeral deployment. The directory
role's `fresh_deployment` defaults to false, and the deploy workflow never runs
`ansible/playbooks/fileserver-ad-config-local.yml`, so cancelled or timed-out runs leave enabled
orphans. A green run silently depends on an undocumented manual step and is not third-party
reproducible.
**Exit:** An authorized plan adds client-side release on cluster teardown and reconciliation on
formation for cancelled runs, gated on an explicit `fresh_deployment` declaration so a live
cluster's identity cannot be disabled. This needs no new directory rights, domain controller in the
CI inventory, or RSAT AD tooling: every node has `System.DirectoryServices` and LDAP reachability
over the tunnel.
