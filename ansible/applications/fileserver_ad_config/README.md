# `fileserver_ad_config`

Creates and maintains the directory objects a Windows failover cluster is formed with: the service
account, the cluster name object, the file server's client access point, and the rights that tie
them together.

## Why this is a separate role

The everyday converge joins machines to a directory with the least credential that can do it.
Forming a cluster needs a different principal -- one that is a local administrator on every node
and owns the cluster's computer object. Keeping that in its own role and playbook means the
everyday path never carries rights it does not need.

## Where it runs

Against a **domain controller**, never against a cluster node. The inventory for this role is
static, because a domain controller is not part of the ephemeral fleet the deploy workflow builds
and destroys.

## How it is run

Manually, and only manually -- there is no workflow that runs it, by design: the CI runner has no
route to a domain controller. An operator runs it from a workstation that does:

```
COMPOSE_PLAYBOOK=fileserver-ad-config-local.yml \
COMPOSE_INVENTORY=ansible/inventory/domain_controllers.yml \
  scripts/compose-and-run.sh -e aws_account_id=<account-id>
```

The key that reaches the domain controller is deliberately not stored; it is supplied for the run
that needs it. The service account's password is read from S3 by the `secret` lookup and never
written to disk by this repository.

## The privilege model

Both computer objects are **prestaged disabled**, so no principal is ever granted the right to
create computer objects:

| principal | right | object |
|---|---|---|
| the service account | Full Control | the cluster name object |
| the cluster name object | Full Control | the file server access point |

The cluster takes over objects that already exist. It cannot create others, and it holds nothing
at the OU level.
