##############################################################################
# Module: ec2-asg
# Creates an Auto Scaling Group with Launch Template for any ELK node role.
# Used for: ES masters, ES data-hot, ES data-warm, ES ingest, ES coord,
#           Kibana, Logstash, app-hosts (Nginx+Fluentd+Filebeat)
##############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

data "aws_ami" "node" {
  most_recent = true
  owners      = [var.ami_owner]

  filter {
    name   = "name"
    values = [var.ami_name_filter]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

locals {
  ami_id = var.ami_id != "" ? var.ami_id : data.aws_ami.node.id
}

# ── EBS data volume template ──────────────────────────────────────────────────
resource "aws_ebs_volume" "data" {
  count             = 0  # managed via launch template
  availability_zone = ""
  size              = var.data_volume_size_gb
  type              = "gp3"
  iops              = var.data_volume_iops
  throughput        = var.data_volume_throughput_mbps
  encrypted         = true
  kms_key_id        = var.kms_key_arn
  tags              = var.tags
}

# ── Launch Template ───────────────────────────────────────────────────────────
resource "aws_launch_template" "this" {
  name_prefix   = "${var.name_prefix}-${var.node_role}-lt-"
  image_id      = local.ami_id
  instance_type = var.instance_type
  key_name      = var.key_pair_name

  iam_instance_profile {
    name = var.instance_profile_name
  }

  network_interfaces {
    associate_public_ip_address = false
    security_groups             = var.security_group_ids
    delete_on_termination       = true
  }

  metadata_options {
    http_tokens                 = "required"  # IMDSv2
    http_put_response_hop_limit = 2
    http_endpoint               = "enabled"
  }

  monitoring { enabled = true }

  # Root volume (OS)
  block_device_mappings {
    device_name = "/dev/sda1"

    ebs {
      volume_type           = "gp3"
      volume_size           = var.root_volume_size_gb
      encrypted             = true
      kms_key_id            = var.kms_key_arn
      delete_on_termination = true
    }
  }

  # Data volume (Elasticsearch data path, Logstash PQ, etc.)
  dynamic "block_device_mappings" {
    for_each = var.data_volume_size_gb > 0 ? [1] : []

    content {
      device_name = "/dev/xvdf"

      ebs {
        volume_type           = "gp3"
        volume_size           = var.data_volume_size_gb
        iops                  = var.data_volume_iops
        throughput            = var.data_volume_throughput_mbps
        encrypted             = true
        kms_key_id            = var.kms_key_arn
        delete_on_termination = false  # preserve data on ASG replacement
      }
    }
  }

  user_data = base64encode(templatefile("${path.module}/templates/userdata.sh.tpl", {
    node_role           = var.node_role
    environment         = var.environment
    elk_version         = var.elk_version
    ssm_path_prefix     = var.ssm_path_prefix
    cluster_name        = var.cluster_name
    node_name_prefix    = "${var.name_prefix}-${var.node_role}"
    es_heap_size        = var.es_heap_size
    data_volume_device  = "/dev/xvdf"
    data_volume_mount   = var.data_volume_mount
    aws_region          = var.aws_region
    tls_mode            = var.tls_mode
    extra_userdata      = var.extra_userdata
  }))

  tag_specifications {
    resource_type = "instance"
    tags = merge(var.tags, {
      Name        = "${var.name_prefix}-${var.node_role}"
      NodeRole    = var.node_role
      Environment = var.environment
      ELKVersion  = var.elk_version
    })
  }

  tag_specifications {
    resource_type = "volume"
    tags = merge(var.tags, {
      Name     = "${var.name_prefix}-${var.node_role}-vol"
      NodeRole = var.node_role
    })
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ── Auto Scaling Group ────────────────────────────────────────────────────────
resource "aws_autoscaling_group" "this" {
  name_prefix         = "${var.name_prefix}-${var.node_role}-asg-"
  vpc_zone_identifier = var.subnet_ids
  min_size            = var.min_size
  max_size            = var.max_size
  desired_capacity    = var.desired_capacity

  health_check_type         = var.alb_target_group_arns != null ? "ELB" : "EC2"
  health_check_grace_period = 300

  target_group_arns = var.alb_target_group_arns

  launch_template {
    id      = aws_launch_template.this.id
    version = "$Latest"
  }

  # Rolling updates: max-batch = 1 for master quorum safety
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = var.min_healthy_percentage
      instance_warmup        = 300
    }
  }

  dynamic "tag" {
    for_each = merge(var.tags, {
      Name        = "${var.name_prefix}-${var.node_role}"
      NodeRole    = var.node_role
      Environment = var.environment
    })
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    create_before_destroy = true
    ignore_changes        = [desired_capacity]
  }
}
