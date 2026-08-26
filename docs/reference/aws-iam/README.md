# AWS IAM reference

**Type**: Reference (Diátaxis). These documents record the IAM used by this repository's
ephemeral AWS deployment. An operator provisions the roles and policies; Terraform does not manage
them.

## Materializing and adapting the documents

The policy files use only `<account-id>` as a placeholder. The trust files use `<account-id>`, and
the CI trust also uses `<owner-id>` and `<repository-id>`. Other repository, region, resource and
tag values are literals or wildcards. In particular, `RepositoryId` is the literal `1329889926` in
five runner policies, the region is `us-east-1`, and the VPC, subnet, key-pair and KMS resources
are not repository-specific placeholders.

Before applying the documents, review them together and change:

- the account ID;
- the owner ID and repository ID; and
- the VPC, subnet, key-pair and EBS KMS references if the policy is narrowed from the current
  wildcards.

## Roles and policy attachments

Trust-document file names follow the upstream naming scheme; role names follow
`<owner>_<repo>_<runner|admin>` and are the values in the `Role` column.

| Role | Trust document | Attached permissions | Purpose |
|---|---|---|---|
| `nwarila-platform_windows-fileserver-ha_runner` | `roles/github_nwarila-platform_windows-fileserver-ha.trust.json` | All eight `runner_*.json` policies below | Repository deployment access |
| `nwarila-platform_windows-fileserver-ha_admin` | `roles/github_nwarila-platform_windows-fileserver-ha-admin.trust.json` | All eight `runner_*.json` policies below | Operator deployment access |
| `nwarila-ec2-role` | `roles/nwarila-ec2-role.trust.json` | `AmazonSSMManagedInstanceCore` only | EC2 instance profile `nwarila-ec2-profile` |

No workflow currently shipped by this repository assumes the runner role.

| Policy document | Grant |
|---|---|
| `nwarila-platform_windows-fileserver-ha_runner_iam.json` | Read `nwarila-ec2-profile`; pass only `nwarila-ec2-role` and only to EC2 |
| `nwarila-platform_windows-fileserver-ha_runner_eni.json` | Describe ENIs and addresses; create tagged ENIs; manage owned ENIs and attach them to owned instances |
| `nwarila-platform_windows-fileserver-ha_runner_sg.json` | Describe security groups; create tagged groups; manage owned groups and their rule resources |
| `nwarila-platform_windows-fileserver-ha_runner_ec2.json` | Read deployment metadata; launch tagged instances and volumes; manage and tag owned instances and volumes |
| `nwarila-platform_windows-fileserver-ha_runner_ssm.json` | Read the AMI parameter hierarchy; start SSH sessions and PowerShell commands on repository-tagged instances; read results and tear down the runner's sessions |
| `nwarila-platform_windows-fileserver-ha_runner_kms.json` | Resolve KMS aliases and keys; use KMS cryptographic and grant operations through EC2 in `us-east-1` |
| `nwarila-platform_windows-fileserver-ha_runner_s3.json` | Manage the two Terraform state objects and list only those two keys; read the OpenVPN and directory-join artifacts |
| `nwarila-platform_windows-fileserver-ha_runner_ebs.json` | Describe volumes; create tagged volumes; attach, detach and delete owned volumes |

## Boundaries present in the documents

- Every statement is `Allow`; none is `Deny`.
- EC2, ENI, security-group and EBS creation requires the repository, repository ID and `ManagedBy`
  request-tag values, plus the presence of commit, run and environment tags. Lifecycle operations
  on instances, ENIs, security groups and volumes require the corresponding ownership tags.
- The CI trust uses only `StringEquals`: it requires audience `sts.amazonaws.com` and the
  repository ID, and pins `ref`, both recorded `sub` forms and `job_workflow_ref` to
  `refs/heads/main`; no other branch, tag, pull request or environment can assume the role.
- The operator trust accepts only the `github_nwarila-platform` IAM Identity Center role name with
  a 16-character generated suffix: each `?` in its `ArnLike` pattern matches one character.
- The runner can pass only `nwarila-ec2-role` to EC2. KMS use is conditioned on the EC2 service in
  `us-east-1`.
- S3 access can manage the two Terraform state objects and list their exact keys; additional
  read-only access is limited to the OpenVPN and directory-join artifact paths in this account.

The instance profile carries `AmazonSSMManagedInstanceCore` only and has no S3 policy.

## Broker permission set

The operator trust names the account principal and then limits `aws:PrincipalArn` to the generated
IAM Identity Center role. The `github_nwarila-platform` permission set must therefore also allow
`sts:AssumeRole` on this repository's operator role. That permission is managed outside this
repository.

Add the operator-role ARN to the permission set's inline policy, then provision the updated
permission set to the account. Do not edit the generated `AWSReservedSSO_*` role directly; IAM
Identity Center manages that role. See AWS's documentation for
[account-principal role delegation](https://docs.aws.amazon.com/STS/latest/APIReference/API_AssumeRole.html)
and [permission-set inline policies](https://docs.aws.amazon.com/singlesignon/latest/userguide/permissionsetcustom.html).

## Accepted IAM residuals

- Launch references allow any image, subnet, security group, key pair and placement group matching
  the regional ARN patterns. There is no subnet or image-owner condition.
- IAM does not require EBS encryption or cap instance type, volume size, IOPS, throughput, instance
  count or spend.
- IAM does not restrict the security-group rule ports. The rule-resource grants are regional
  wildcards; the corresponding group grants require the repository ownership tags.
- IAM does not prevent a public IPv4 at launch. The runner has no Elastic IP, internet-gateway or
  route-table actions.
- KMS cryptographic access uses `Resource: "*"`, bounded by `kms:ViaService` for EC2 in `us-east-1`.
- The OpenVPN installer grant accepts any version directory under `OpenVPN.net/OpenVPN Community/`
  but only the `OpenVPN_Community_amd64.msi` file name within it.
