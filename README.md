# windows-fileserver-ha

Target architecture: a four-node Windows Server 2025 WSFC stretch cluster across two
Availability Zones, Storage Replica between per-AZ shared storage, and a workgroup file-share
witness in a third AZ. The implemented service is deliberately narrower: one AZ-a clustered
file-server role and its encrypted continuously available `data` share. This repository is a
data-only consumer of the pinned nwarila-platform Terraform and Ansible frameworks.

## Status

The fleet playbook codifies a four-node cluster, adopts both EBS volumes by runtime identity,
constrains each disk to its declared owner pair, creates `TCNAW-HAFS01` on the AZ-a disk, and
publishes `\\TCNAW-HAFS01\data` with exact protected NTFS and share ACLs. Its ungated final
readback proves that implemented surface on every run. Witness quorum, the AZ-b file-server role,
and Storage Replica remain explicitly deferred with exit criteria in
[docs/explanation/technical-debt.md](docs/explanation/technical-debt.md).

## The PowerShell development model

Complex Windows mutations are **first-class PowerShell scripts**, executed by Ansible through
`ansible.windows.win_powershell` — never embedded `win_shell` blocks — and developed to the
organization's single PowerShell definition,
[NWarila/powershell-template](https://github.com/NWarila/powershell-template):

- every script is three files: `scripts/<Name>.ps1`, its self-contained
  `scripts/<Name>.pester.ps1` spec, and a `files/<Name>.ps1.stub` marker in the consuming
  role that `scripts/materialize-role-scripts.sh` resolves at build time;
- each script owns read → normalized diff → mutate-only-the-drift → re-acquire-and-verify, and
  reports a deterministic **Change/NoChange** verdict through `$Ansible.Changed`, so the play
  recap shows an honest `ok`/`changed` per action;
- scripts run identically standalone (JSON result) and under Ansible, so specs and dev shells
  exercise the exact production path;
- CI is one thin workflow ([powershell.yml](.github/workflows/powershell.yml)) importing the
  org's reusable pester-matrix: one matrix leg per script, house analyzer at zero findings,
  then the spec. It runs only when a PR touches a PowerShell file.

Repo wiring: [docs/reference/powershell-style-guide.md](docs/reference/powershell-style-guide.md).
Task-authoring rules: [docs/reference/ansible-style-guide.md](docs/reference/ansible-style-guide.md).

## Repository layout

| Path | Contents |
|---|---|
| `ansible/applications/fileserver/` | The application role: v3.3.0 framework loader, OS entrypoints, merged-config validation, and per-script `.ps1.stub` markers under `files/`. |
| `ansible/playbooks/fileserver-aws.yml` | Prepares the fleet, applies the Administrator baseline, resolves the cluster credential once, forms the cluster and AZ-a service, performs the final proof, and scrubs the credential variable. |
| `ansible/inventory/` | The tracked EC2 dynamic inventory and its group contract (`fileserver_nodes`, `fileserver_witness`, and overlapping singleton `fileserver_cluster_former`). |
| `.github/workflows/powershell.yml` | Thin caller of the org's standardized PowerShell test matrix. |
| `docs/reference/` | Authoring rules for Ansible tasks and this repo's PowerShell wiring, plus AWS IAM reference documents. |
| `docs/explanation/` | Technical debt with exit criteria. |
| `scripts/` | PowerShell pairs (`.ps1` + `.pester.ps1`) plus the materialization and local-verification entry points. |

## Quality gates

Install Bash, `yamllint`, `pwsh` with Pester v5+, and PSScriptAnalyzer. Replace
`<powershell-template>` below with the absolute path to a complete checkout at the `template-ref`
pinned in `.github/workflows/powershell.yml`. From the repository root, run the resulting command:

```sh
POWERSHELL_TEMPLATE_ROOT=<powershell-template> ./scripts/verify.sh
```

The deployment files have their own static gates:

```sh
terraform fmt -check terraform/aws.tfvars
yamllint -c .yamllint.yml .github/workflows/aws-deploy.yml
actionlint .github/workflows/aws-deploy.yml
```
