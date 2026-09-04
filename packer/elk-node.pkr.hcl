##############################################################################
# Packer: ELK Ubuntu 22.04 AMI Builder
# Builds role-specific AMIs: es-master, es-data, es-ingest, es-coord,
# kibana, logstash, app-host
# Usage: packer build -var="node_role=es-master" elk-node.pkr.hcl
##############################################################################

packer {
  required_version = ">= 1.10"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3"
    }
    ansible = {
      source  = "github.com/hashicorp/ansible"
      version = ">= 1.1"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "node_role" {
  type        = string
  description = "es-master | es-data | es-ingest | es-coord | kibana | logstash | app-host"
}

variable "elk_version" {
  type    = string
  default = "8.12.2"
}

variable "jdk_version" {
  type    = string
  default = "17"
}

variable "aws_region" {
  type    = string
  default = "us-east-2"
}

variable "vpc_id" {
  type        = string
  description = "VPC for Packer builder instance (needs internet access)"
}

variable "subnet_id" {
  type        = string
  description = "Public subnet for the Packer builder instance"
}

variable "instance_type" {
  type    = string
  default = "t3.medium"
}

variable "ami_regions" {
  type    = list(string)
  default = ["us-east-2"]
}

variable "encrypt_boot" {
  type    = bool
  default = true
}

variable "kms_key_id" {
  type    = string
  default = null
}

# ── Base Ubuntu 22.04 AMI ─────────────────────────────────────────────────────
data "amazon-ami" "ubuntu_2204" {
  region = var.aws_region
  owners = ["099720109477"]  # Canonical

  filters = {
    name                = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
    virtualization-type = "hvm"
    root-device-type    = "ebs"
  }

  most_recent = true
}

# ── Source: AWS EC2 builder ───────────────────────────────────────────────────
source "amazon-ebs" "elk_node" {
  region        = var.aws_region
  instance_type = var.instance_type
  source_ami    = data.amazon-ami.ubuntu_2204.id

  ssh_username        = "ubuntu"
  ssh_timeout         = "10m"
  ssh_agent_auth      = false

  vpc_id    = var.vpc_id
  subnet_id = var.subnet_id

  associate_public_ip_address = true

  # IMDSv2
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  encrypt_boot = var.encrypt_boot
  kms_key_id   = var.kms_key_id

  ami_name        = "elk-ubuntu-22.04-${var.node_role}-${var.elk_version}-{{timestamp}}"
  ami_description = "ELK ${var.node_role} node, Elastic ${var.elk_version}, Ubuntu 22.04"

  ami_regions = var.ami_regions

  tags = {
    Name        = "elk-ubuntu-22.04-${var.node_role}-${var.elk_version}"
    NodeRole    = var.node_role
    ELKVersion  = var.elk_version
    BaseOS      = "ubuntu-22.04"
    BuildDate   = "{{isotime \"2006-01-02\"}}"
    ManagedBy   = "Packer"
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 50
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }
}

# ── Build ─────────────────────────────────────────────────────────────────────
build {
  name    = "elk-${var.node_role}"
  sources = ["source.amazon-ebs.elk_node"]

  # 1. System updates and base packages
  provisioner "shell" {
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      "echo 'Waiting for cloud-init...'",
      "cloud-init status --wait",
      "sudo apt-get update -qq",
      "sudo apt-get upgrade -y -qq",
      "sudo apt-get install -y -qq",
      "  curl wget gnupg2 ca-certificates apt-transport-https",
      "  software-properties-common unzip jq awscli",
      "  sysstat iotop htop lsof net-tools nload",
      "  python3-pip openssl",
    ]
  }

  # 2. Install OpenJDK 17 (only for ES/Logstash nodes)
  provisioner "shell" {
    only   = ["amazon-ebs.elk_node"]
    inline = [
      "export DEBIAN_FRONTEND=noninteractive",
      # OpenJDK 17 ships with ES 8.x bundled; we also install system JDK
      "sudo apt-get install -y -qq openjdk-17-jdk-headless",
      "sudo update-alternatives --set java /usr/lib/jvm/java-17-openjdk-amd64/bin/java",
      "java -version",
    ]
  }

  # 3. Install Elastic Stack components based on role
  provisioner "shell" {
    environment_vars = [
      "ELK_VERSION=${var.elk_version}",
      "NODE_ROLE=${var.node_role}",
    ]
    script = "${path.root}/scripts/install-elastic.sh"
  }

  # 4. Install monitoring agents (all nodes)
  provisioner "shell" {
    environment_vars = ["ELK_VERSION=${var.elk_version}"]
    script           = "${path.root}/scripts/install-monitoring-agents.sh"
  }

  # 5. Install role-specific extras
  provisioner "shell" {
    environment_vars = [
      "NODE_ROLE=${var.node_role}",
      "ELK_VERSION=${var.elk_version}",
    ]
    script = "${path.root}/scripts/install-role-extras.sh"
  }

  # 6. OS hardening
  provisioner "shell" {
    script = "${path.root}/scripts/os-hardening.sh"
  }

  # 7. Upload static config templates (no secrets; runtime values filled by userdata)
  provisioner "file" {
    source      = "${path.root}/configs/${var.node_role}/"
    destination = "/tmp/elk-configs/"
  }

  provisioner "shell" {
    inline = [
      "sudo mkdir -p /etc/elk-templates",
      "sudo cp -r /tmp/elk-configs/* /etc/elk-templates/ 2>/dev/null || true",
      "sudo chmod 640 /etc/elk-templates/*",
    ]
  }

  # 8. Systemd unit file installation
  provisioner "shell" {
    environment_vars = ["NODE_ROLE=${var.node_role}"]
    script           = "${path.root}/scripts/configure-systemd.sh"
  }

  # 9. Final cleanup
  provisioner "shell" {
    inline = [
      "sudo apt-get autoremove -y -qq",
      "sudo apt-get clean",
      "sudo rm -rf /var/lib/apt/lists/*",
      "sudo rm -rf /tmp/elk-configs /tmp/*.deb",
      "sudo truncate -s 0 /etc/machine-id",
      "sudo rm -f /var/lib/dbus/machine-id",
      # Sanitize SSH host keys (regenerated on first boot)
      "sudo rm -f /etc/ssh/ssh_host_*",
      # Clear cloud-init state
      "sudo cloud-init clean --logs",
      "echo 'AMI build complete'",
    ]
  }

  post-processor "manifest" {
    output     = "packer-manifest.json"
    strip_path = true
  }
}
