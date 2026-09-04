##############################################################################
# Packer HCL2: ELK Ubuntu 22.04 AMI Builder
# Builds role-specific AMIs for all ELK node types.
# Usage: packer build -var "node_role=es-master" elk-ubuntu.pkr.hcl
##############################################################################

packer {
  required_version = ">= 1.9"
  required_plugins {
    amazon = {
      version = ">= 1.3"
      source  = "github.com/hashicorp/amazon"
    }
    ansible = {
      version = ">= 1.1"
      source  = "github.com/hashicorp/ansible"
    }
  }
}

# ── Variables ─────────────────────────────────────────────────────────────────
variable "aws_region"    { type = string; default = "us-east-2" }
variable "elk_version"   { type = string; default = "8.12.2" }
variable "jdk_version"   { type = string; default = "17" }
variable "node_role"     { type = string; default = "es-master" }
variable "environment"   { type = string; default = "dev" }
variable "instance_type" { type = string; default = "t3.medium" }
variable "subnet_id"     { type = string }
variable "vpc_id"        { type = string }
variable "kms_key_id"    { type = string; default = "" }
variable "os_type"       {
  type    = string
  default = "ubuntu-22.04"
  # Options: ubuntu-22.04 | amazon-linux-2023 | rocky-linux-9
}

locals {
  ami_filters = {
    "ubuntu-22.04"      = {
      filter_name = "ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"
      owners      = ["099720109477"]  # Canonical
    }
    "amazon-linux-2023" = {
      filter_name = "al2023-ami-2023*-kernel-*-x86_64"
      owners      = ["137112412989"]  # Amazon
    }
    "rocky-linux-9"     = {
      filter_name = "Rocky-9-EC2-Base-9.*.x86_64*"
      owners      = ["792107900819"]  # Rocky Linux Foundation
    }
  }

  selected_os     = local.ami_filters[var.os_type]
  timestamp       = formatdate("YYYYMMDDHHmmss", timestamp())
  ami_name        = "elk-${var.os_type}-${var.node_role}-${var.elk_version}-${local.timestamp}"
}

# ── Source AMI ────────────────────────────────────────────────────────────────
source "amazon-ebs" "elk_node" {
  region        = var.aws_region
  instance_type = var.instance_type

  source_ami_filter {
    filters = {
      name                = local.selected_os.filter_name
      "virtualization-type" = "hvm"
      "root-device-type"   = "ebs"
      "state"              = "available"
    }
    owners      = local.selected_os.owners
    most_recent = true
  }

  subnet_id             = var.subnet_id
  vpc_id                = var.vpc_id
  associate_public_ip_address = false

  communicator = "ssh"
  ssh_username = var.os_type == "ubuntu-22.04" ? "ubuntu" : "ec2-user"
  ssh_timeout  = "10m"

  ami_name        = local.ami_name
  ami_description = "ELK ${var.elk_version} ${var.node_role} on ${var.os_type}"

  ami_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
    delete_on_termination = true
  }

  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_type           = "gp3"
    volume_size           = 50
    encrypted             = true
    kms_key_id            = var.kms_key_id != "" ? var.kms_key_id : null
    delete_on_termination = true
  }

  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  # IMDSv2 enforced on final AMI
  imds_support = "v2.0"

  tags = {
    Name        = local.ami_name
    NodeRole    = var.node_role
    ELKVersion  = var.elk_version
    OSType      = var.os_type
    Environment = var.environment
    BuildDate   = local.timestamp
    ManagedBy   = "packer"
  }

  snapshot_tags = {
    Name     = "${local.ami_name}-root"
    NodeRole = var.node_role
  }
}

# ── Build ─────────────────────────────────────────────────────────────────────
build {
  name    = "elk-${var.node_role}"
  sources = ["source.amazon-ebs.elk_node"]

  # 1. OS updates and base packages
  provisioner "shell" {
    inline = [
      # Detect OS family
      "if command -v apt-get &>/dev/null; then",
      "  export DEBIAN_FRONTEND=noninteractive",
      "  apt-get update -y",
      "  apt-get upgrade -y",
      "  apt-get install -y curl wget gnupg2 apt-transport-https ca-certificates",
      "  apt-get install -y python3 python3-pip jq unzip awscli htop iotop sysstat",
      "  apt-get install -y lvm2 xfsprogs",
      "elif command -v dnf &>/dev/null; then",
      "  dnf update -y",
      "  dnf install -y curl wget gnupg2 ca-certificates",
      "  dnf install -y python3 python3-pip jq unzip awscli htop iotop sysstat",
      "  dnf install -y lvm2 xfsprogs",
      "fi"
    ]
  }

  # 2. Java 17 (Temurin / OpenJDK)
  provisioner "shell" {
    inline = [
      "if command -v apt-get &>/dev/null; then",
      "  wget -qO - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor -o /usr/share/keyrings/adoptium.gpg",
      "  echo 'deb [signed-by=/usr/share/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb jammy main' > /etc/apt/sources.list.d/adoptium.list",
      "  apt-get update -y",
      "  apt-get install -y temurin-${var.jdk_version}-jdk",
      "else",
      "  dnf install -y java-${var.jdk_version}-amazon-corretto-devel || dnf install -y java-17-openjdk-devel",
      "fi",
      "java -version"
    ]
  }

  # 3. Elastic GPG key and repository
  provisioner "shell" {
    inline = [
      "if command -v apt-get &>/dev/null; then",
      "  wget -qO - https://artifacts.elastic.co/GPG-KEY-elasticsearch | gpg --dearmor -o /usr/share/keyrings/elasticsearch-keyring.gpg",
      "  echo 'deb [signed-by=/usr/share/keyrings/elasticsearch-keyring.gpg] https://artifacts.elastic.co/packages/8.x/apt stable main' > /etc/apt/sources.list.d/elastic-8.x.list",
      "  apt-get update -y",
      "else",
      "  rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch",
      "  cat > /etc/yum.repos.d/elasticsearch.repo << 'EOF'",
      "[elasticsearch]",
      "name=Elasticsearch repository for 8.x packages",
      "baseurl=https://artifacts.elastic.co/packages/8.x/yum",
      "gpgcheck=1",
      "gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch",
      "enabled=1",
      "autorefresh=1",
      "type=rpm-md",
      "EOF",
      "fi"
    ]
  }

  # 4. Install role-specific Elastic packages
  provisioner "shell" {
    environment_vars = [
      "NODE_ROLE=${var.node_role}",
      "ELK_VERSION=${var.elk_version}"
    ]
    script = "${path.root}/scripts/install-elastic-packages.sh"
  }

  # 5. Install Fluentd (td-agent 4.x) on all nodes that need it
  provisioner "shell" {
    script = "${path.root}/scripts/install-fluentd.sh"
  }

  # 6. Role-specific configuration and hardening
  provisioner "ansible" {
    playbook_file   = "${path.root}/ansible/site.yml"
    extra_arguments = [
      "--extra-vars", "node_role=${var.node_role} elk_version=${var.elk_version} environment=${var.environment}",
      "--diff"
    ]
    ansible_env_vars = [
      "ANSIBLE_HOST_KEY_CHECKING=False",
      "ANSIBLE_NOCOLOR=True"
    ]
  }

  # 7. Clean up and prepare for AMI snapshot
  provisioner "shell" {
    inline = [
      "# Clear logs",
      "find /var/log -type f -name '*.log' -delete",
      "find /var/log -type f -name '*.gz' -delete",
      "# Remove SSH host keys (regenerated on first boot)",
      "rm -f /etc/ssh/ssh_host_*",
      "# Clear cloud-init state",
      "cloud-init clean --logs",
      "# Clear history",
      "history -c",
      "rm -f ~/.bash_history /root/.bash_history"
    ]
  }

  # 8. Post-processor: manifest for version tracking
  post-processor "manifest" {
    output     = "manifests/${var.node_role}-${var.os_type}-manifest.json"
    strip_path = true
  }
}
