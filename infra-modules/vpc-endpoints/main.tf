##############################################################################
# Module: vpc-endpoints
# Creates VPC Interface and Gateway endpoints to eliminate NAT data charges
# for S3, SSM, Secrets Manager, KMS, CloudWatch, EC2 API, etc.
##############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

# ── S3 Gateway Endpoint (free; no ENI) ────────────────────────────────────────
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = var.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = var.private_route_table_ids

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-s3" })
}

# ── Interface Endpoints ───────────────────────────────────────────────────────
locals {
  interface_services = {
    ssm            = "com.amazonaws.${var.aws_region}.ssm"
    ssmmessages    = "com.amazonaws.${var.aws_region}.ssmmessages"
    ec2messages    = "com.amazonaws.${var.aws_region}.ec2messages"
    secretsmanager = "com.amazonaws.${var.aws_region}.secretsmanager"
    kms            = "com.amazonaws.${var.aws_region}.kms"
    logs           = "com.amazonaws.${var.aws_region}.logs"
    monitoring     = "com.amazonaws.${var.aws_region}.monitoring"
    ec2            = "com.amazonaws.${var.aws_region}.ec2"
    elasticloadbalancing = "com.amazonaws.${var.aws_region}.elasticloadbalancing"
    sts            = "com.amazonaws.${var.aws_region}.sts"
  }
}

resource "aws_security_group" "endpoints" {
  name        = "${var.name_prefix}-vpce-sg"
  description = "Allow HTTPS from within VPC to interface endpoints"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS from VPC"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-sg" })
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_services

  vpc_id              = var.vpc_id
  service_name        = each.value
  vpc_endpoint_type   = "Interface"
  subnet_ids          = var.private_subnet_ids
  security_group_ids  = [aws_security_group.endpoints.id]
  private_dns_enabled = true

  tags = merge(var.tags, { Name = "${var.name_prefix}-vpce-${each.key}" })
}
