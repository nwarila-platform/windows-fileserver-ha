# ansible/inventory/

## There is no static inventory, and that is deliberate

The AWS deploy is **ephemeral**: every run creates the five instances, converges them, and
destroys them. An instance id written into a file here would be wrong the moment the run that
produced it ended.

The tracked `aws_ec2.yml` dynamic plugin is the inventory. Its live EC2 tag filters use values
GitHub exports to select one repository and run, then it assigns matching instances to groups by
their EC2 `Function` tag. Cluster nodes must carry `Windows HA FileServer`; the
witness must carry `Windows FS Witness`. The Terraform region that must stamp those
tags has not landed yet.

## The ratified shape the inventory must carry

Two groups, five hosts, always exact:

| Group | Hosts | Why a separate group |
|---|---|---|
| `fileserver_nodes` | `fs-node-a1`, `fs-node-a2`, `fs-node-b1`, `fs-node-b2` | The WSFC cluster nodes (two per AZ). EP3 node-only work (domain join, cluster bootstrap) targets this group alone. |
| `fileserver_witness` | `fs-witness-01` | Non-domain-joined file-share witness in a third AZ. Must never be swept into node-only plays. |

`ansible/playbooks/fileserver-aws.yml` asserts exactly 4 + 1 before any role runs when either
group contains a host. Such a half-provisioned inventory fails the assertion, but if both groups
are empty Ansible skips the play and the assertion never executes.

## Running the playbook by hand

While a run's instances still exist, export that run's required environment variables, point
`-i` at the tracked `ansible/inventory/aws_ec2.yml`, and pass `-e env=<ENV>`.
