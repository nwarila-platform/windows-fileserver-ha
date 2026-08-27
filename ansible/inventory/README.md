# ansible/inventory/

## There is no static inventory, and that is deliberate

The AWS deploy is **ephemeral**: every run creates the five instances, converges them, and
destroys them. An instance id written into a file here would be wrong the moment the run that
produced it ended.

The tracked `aws_ec2.yml` dynamic plugin is the inventory. Its live EC2 tag filters use values
GitHub exports to select one repository and run, then it assigns matching instances to groups by
their EC2 `Function` tag. Cluster nodes must carry `Windows HA FileServer`; the
witness must carry `Windows FS Witness`. The Terraform region that must stamp those
tags is `terraform/aws.tfvars`.

## The ratified shape the inventory must carry

Two groups, five hosts, always exact:

| Group | Hosts | Why a separate group |
|---|---|---|
| `fileserver_nodes` | `tcnaw-hafs01a`, `tcnaw-hafs02a`, `tcnaw-hafs01b`, `tcnaw-hafs02b` | The WSFC cluster nodes (two per AZ). EP3 node-only work (domain join, cluster bootstrap) targets this group alone. |
| `fileserver_witness` | `tcnaw-witnes01c` | Non-domain-joined file-share witness in a third AZ. Must never be swept into node-only plays. |

`ansible/playbooks/fileserver-aws.yml` runs its contract on implicit localhost before any role.
It rejects an empty or partial result, any host outside the two known groups, and any shape other
than exactly four cluster nodes plus one witness.

## Running the playbook by hand

While a run's instances still exist, export that run's required environment variables, point
`-i` at the tracked `ansible/inventory/aws_ec2.yml`, and pass `aws_account_id` and `aws_region`
as extra-vars. The inventory composes uppercase `ENV` directly from each instance's Environment
tag; lowercase `env` is not a playbook input.
