# ansible/inventory/

## There is no static inventory, and that is deliberate

The AWS deploy is **ephemeral**: every run creates the five instances, converges them, and
destroys them. An instance id written into a file here would be wrong the moment the run that
produced it ended.

The inventory is generated **per run from Terraform output** and verified against live EC2 tags
before Ansible is allowed to touch a host. That machinery (the deploy workflow, the dynamic
`aws_ec2.yml` discovery aid, and the runtime JSON inventory) lands with the deploy scaffold;
this file records the contract it must satisfy.

## The ratified shape the inventory must carry

Two groups, five hosts, always exact:

| Group | Hosts | Why a separate group |
|---|---|---|
| `fileserver_nodes` | `fs-node-a1`, `fs-node-a2`, `fs-node-b1`, `fs-node-b2` | The WSFC cluster nodes (two per AZ). EP3 node-only work (domain join, cluster bootstrap) targets this group alone. |
| `fileserver_witness` | `fs-witness-01` | Non-domain-joined file-share witness in a third AZ. Must never be swept into node-only plays. |

`ansible/playbooks/fileserver-aws.yml` asserts exactly 4 + 1 before any role runs, so a stale
or half-provisioned inventory fails closed rather than converging the wrong fleet.

## Running the playbook by hand

Point `-i` at a run's generated inventory while those instances still exist, and pass `-e env=<ENV>`.
The playbook re-asserts the shape itself; a stale file fails closed.
