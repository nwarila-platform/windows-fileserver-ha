# =========================================================================================== #
# File: 'terraform/aws.tfvars'
# --- [ Description ] ----------------------------------------------------------------------- #
#
# Variable input for the pinned aws-terraform-framework (SHA in .github/terraform-framework-pin).
# Plain tfvars — the workflow passes this file to terraform verbatim. This repository declares
# NO .tf files of its own: resources live in the pinned framework, configuration in the pinned
# ansible-framework plus this repository's role.
#
# REACHABILITY — DIRECT SSH OVER A PUBLIC IPv4. The workflow discovers the runner's public IPv4
# and passes it as the framework's runtime-only runner_ip variable. When an operator hostname is
# configured it resolves that too and passes debug_ip, which adds RDP for a person working on the
# held systems. The framework attaches one security group carrying both to every interface. The
# instances receive public IPv4 addresses at launch; no Elastic IP is involved. The account has
# no NAT and no VPC endpoints.
#
# The dependency worth knowing: MapPublicIpOnLaunch is an attribute of shared subnets no
# repository owns. Direct SSH requires each instance's launch-time public address as well as the
# runner-scoped security group.
#
# readiness_gate is FALSE by design: the composed playbook owns the bounded direct-SSH readiness
# check and the framework bootstrap repairs the Windows OpenSSH shell on first contact.
#
# =========================================================================================== #

# environment and the deployment identity (repository, repository_id, commit_sha, run_id) are
# deliberately NOT in this file: the workflow passes them as -var flags placed AFTER this file on
# the command line. Terraform resolves repeated command-line assignments in the order given, so it
# is that ordering, not the kind of flag, that keeps this file from renaming the deployment.

all_systems = [
  # Cluster pair A: two nodes in one subnet and Availability Zone.
  {
    region            = "us_east_1"
    hostname          = "fs-node-a1"
    availability_zone = "us-east-1a"
    subnet_id         = "subnet-0dbb7770d19f253ad"
    # The framework CONSUMES key pairs and never creates them. The private half exists only in
    # the AWS_EC2_SSH_PRIVATE_KEY organization secret and the runner's temporary directory.
    key_name = "nwarila-ec2-key"
    # The framework consumes this standing profile and does not create or modify it.
    iam_instance_profile = "nwarila-ec2-profile"
    aws_kms_alias        = "aws/ebs"
    # Windows_Server-2025-English-STIG-Full, accepted from the framework's vendor allowlist.
    ami = "ami-04807a1de3f592cc5"
    # This lifecycle never changes refresh_serial, so marking the OS replaceable is inert here.
    refresh       = true
    instance_type = "t3.large"
    # Direct SSH reaches the launch-time public IPv4 through the runner-scoped framework SG.
    connection_type = "ssh"
    readiness_user  = null

    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null

    # These exact Function values are the dynamic inventory's group contract.
    tags = {
      Function = "Windows HA FileServer"
      Backup   = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      # The AMI's native size; all persistent service data belongs on shared storage.
      volume_size = "30"
    }

    # Shared disks are declared once in shared_ebs_volumes below, never duplicated per node.
    ebs_block_devices          = []
    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "fs-node-a1 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress         = []
        egress = [
          {
            description                  = "HTTPS out"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          # The VPN tunnel that carries the host onto the private network. Scoped by port rather
          # than by address: the profile names its endpoint by DNS, and that address changes.
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]

    # No Elastic IP: the subnet auto-assigns the launch-time public IPv4 used for direct SSH.
    associate_public_ip = false
  },
  # The second local node shares pair A's subnet and Multi-Attach volume.
  {
    region                     = "us_east_1"
    hostname                   = "fs-node-a2"
    availability_zone          = "us-east-1a"
    subnet_id                  = "subnet-0dbb7770d19f253ad"
    key_name                   = "nwarila-ec2-key"
    iam_instance_profile       = "nwarila-ec2-profile"
    aws_kms_alias              = "aws/ebs"
    ami                        = "ami-04807a1de3f592cc5"
    refresh                    = true
    instance_type              = "t3.large"
    connection_type            = "ssh"
    readiness_user             = null
    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null

    tags = {
      Function = "Windows HA FileServer"
      Backup   = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "30"
    }

    ebs_block_devices          = []
    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "fs-node-a2 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress         = []
        egress = [
          {
            description                  = "HTTPS out"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          # The VPN tunnel that carries the host onto the private network. Scoped by port rather
          # than by address: the profile names its endpoint by DNS, and that address changes.
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]

    associate_public_ip = false
  },
  # Cluster pair B: two nodes in one subnet and a second Availability Zone.
  {
    region                     = "us_east_1"
    hostname                   = "fs-node-b1"
    availability_zone          = "us-east-1b"
    subnet_id                  = "subnet-04260d6f543906b6b"
    key_name                   = "nwarila-ec2-key"
    iam_instance_profile       = "nwarila-ec2-profile"
    aws_kms_alias              = "aws/ebs"
    ami                        = "ami-04807a1de3f592cc5"
    refresh                    = true
    instance_type              = "t3.large"
    connection_type            = "ssh"
    readiness_user             = null
    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null

    tags = {
      Function = "Windows HA FileServer"
      Backup   = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "30"
    }

    ebs_block_devices          = []
    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "fs-node-b1 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress         = []
        egress = [
          {
            description                  = "HTTPS out"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          # The VPN tunnel that carries the host onto the private network. Scoped by port rather
          # than by address: the profile names its endpoint by DNS, and that address changes.
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]

    associate_public_ip = false
  },
  # The second local node shares pair B's subnet and Multi-Attach volume.
  {
    region                     = "us_east_1"
    hostname                   = "fs-node-b2"
    availability_zone          = "us-east-1b"
    subnet_id                  = "subnet-04260d6f543906b6b"
    key_name                   = "nwarila-ec2-key"
    iam_instance_profile       = "nwarila-ec2-profile"
    aws_kms_alias              = "aws/ebs"
    ami                        = "ami-04807a1de3f592cc5"
    refresh                    = true
    instance_type              = "t3.large"
    connection_type            = "ssh"
    readiness_user             = null
    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null

    tags = {
      Function = "Windows HA FileServer"
      Backup   = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "30"
    }

    ebs_block_devices          = []
    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "fs-node-b2 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress         = []
        egress = [
          {
            description                  = "HTTPS out"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          },
          # The VPN tunnel that carries the host onto the private network. Scoped by port rather
          # than by address: the profile names its endpoint by DNS, and that address changes.
          {
            description                  = "OpenVPN tunnel out"
            ip_protocol                  = "udp"
            from_port                    = 1194
            to_port                      = 1194
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]

    associate_public_ip = false
  },
  # The workgroup witness stands alone in the third Availability Zone.
  {
    region                     = "us_east_1"
    hostname                   = "fs-witness-01"
    availability_zone          = "us-east-1c"
    subnet_id                  = "subnet-03a855e712be7b399"
    key_name                   = "nwarila-ec2-key"
    iam_instance_profile       = "nwarila-ec2-profile"
    aws_kms_alias              = "aws/ebs"
    ami                        = "ami-04807a1de3f592cc5"
    refresh                    = true
    instance_type              = "t3.small"
    connection_type            = "ssh"
    readiness_user             = null
    readiness_gate             = false
    readiness_command          = null
    readiness_script_dir       = null
    readiness_private_key_path = null
    imds_hop_limit             = 1
    set_state                  = null

    tags = {
      Function = "Windows FS Witness"
      Backup   = false
    }

    root_block_device = {
      delete_on_termination = true
      iops                  = null
      tags                  = {}
      throughput            = null
      volume_type           = "gp3"
      volume_size           = "30"
    }

    ebs_block_devices          = []
    ami_block_device_overrides = []

    network_interfaces = [
      {
        description     = "fs-witness-01 CI firewall"
        interface_type  = null
        private_ip      = null
        security_groups = []
        ingress         = []
        # No OpenVPN egress: this workgroup witness is deliberately not domain-joined and needs
        # no route to a domain controller.
        egress = [
          {
            description                  = "HTTPS out"
            ip_protocol                  = "tcp"
            from_port                    = 443
            to_port                      = 443
            cidr_ipv4                    = "0.0.0.0/0"
            prefix_list_id               = null
            referenced_security_group_id = null
          }
        ]
        tags = {}
      }
    ]

    associate_public_ip = false
  }
]

# One encrypted io2 Multi-Attach volume per cluster pair. Device index 0 renders xvdd on the
# Windows nodes, and each volume remains in the same Availability Zone as both attachments.
shared_ebs_volumes = {
  cluster-data-a = {
    region            = "us_east_1"
    availability_zone = "us-east-1a"
    aws_kms_alias     = "aws/ebs"
    iops              = "3000"
    volume_size       = "100"
    tags = {
      Function = "Cluster Shared Volume (AZ A)"
    }
    attachments = [
      { hostname = "fs-node-a1", device_index = 0 },
      { hostname = "fs-node-a2", device_index = 0 }
    ]
  }
  cluster-data-b = {
    region            = "us_east_1"
    availability_zone = "us-east-1b"
    aws_kms_alias     = "aws/ebs"
    iops              = "3000"
    volume_size       = "100"
    tags = {
      Function = "Cluster Shared Volume (AZ B)"
    }
    attachments = [
      { hostname = "fs-node-b1", device_index = 0 },
      { hostname = "fs-node-b2", device_index = 0 }
    ]
  }
}

all_databases      = []
all_load_balancers = []
