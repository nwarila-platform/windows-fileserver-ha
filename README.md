# windows-fileserver-ha

Highly available Windows Server 2025 file service: a four-node WSFC stretch cluster across two
Availability Zones (two nodes per AZ on per-AZ shared storage), Storage Replica between the
pairs, a non-domain-joined file-share witness in a third AZ, and an ephemeral AWS proof
environment. Data-only consumer of the pinned nwarila-platform Terraform and Ansible
frameworks.

## Status

Scaffold in progress. The Ansible tree, the PowerShell development model, and their quality
gates are in place; the deploy surface (workflows and Terraform data) and the
cluster implementation (EP3/EP4) are not — the application role **fails closed**
until they land. The domain is owner-supplied and currently absent, which blocks any green
cluster. Every gap is recorded with exit criteria in
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
| `ansible/playbooks/fileserver-aws.yml` | Applies the role to the ratified five-instance shape (4 nodes + 1 witness) and asserts it exactly. |
| `ansible/inventory/` | Why there is no static inventory, and the group contract (`fileserver_nodes`, `fileserver_witness`) a generated one must satisfy. |
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

The deploy-workflow checks and IAM checks remain pending with the
deploy scaffold.
