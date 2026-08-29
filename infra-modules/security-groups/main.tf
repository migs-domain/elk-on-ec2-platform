##############################################################################
# Module: security-groups
# Creates all security groups for the ELK platform with least-privilege rules.
##############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

locals {
  es_transport_port = 9300
  es_http_port      = 9200
  es_metrics_port   = 9114  # elasticsearch_exporter (Prometheus)
  kibana_port       = 5601
  logstash_beats    = 5044
  logstash_http     = 8080  # monitoring API
  fluentd_forward   = 24224
  fluentd_metrics   = 24231 # Prometheus metrics
  ssh_port          = 22
}

# ── Bastion ───────────────────────────────────────────────────────────────────
resource "aws_security_group" "bastion" {
  name        = "${var.name_prefix}-sg-bastion"
  description = "SSH access from allowed CIDRs only"
  vpc_id      = var.vpc_id

  ingress {
    description = "SSH"
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    protocol    = "tcp"
    cidr_blocks = var.bastion_allowed_cidrs
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-bastion" })
}

# ── Elasticsearch Masters ─────────────────────────────────────────────────────
resource "aws_security_group" "es_master" {
  name        = "${var.name_prefix}-sg-es-master"
  description = "ES master nodes: transport inter-node only"
  vpc_id      = var.vpc_id

  ingress {
    description = "Transport from ES nodes"
    from_port   = local.es_transport_port
    to_port     = local.es_transport_port
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description     = "Transport from data nodes"
    from_port       = local.es_transport_port
    to_port         = local.es_transport_port
    protocol        = "tcp"
    security_groups = [aws_security_group.es_data.id, aws_security_group.es_ingest.id]
  }

  ingress {
    description = "SSH from bastion"
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description     = "Metricbeat / monitoring"
    from_port       = local.es_http_port
    to_port         = local.es_http_port
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-es-master" })
}

# ── Elasticsearch Data Nodes ──────────────────────────────────────────────────
resource "aws_security_group" "es_data" {
  name        = "${var.name_prefix}-sg-es-data"
  description = "ES data nodes"
  vpc_id      = var.vpc_id

  ingress {
    description = "Transport (inter-node)"
    from_port   = local.es_transport_port
    to_port     = local.es_transport_port
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description     = "Transport from masters"
    from_port       = local.es_transport_port
    to_port         = local.es_transport_port
    protocol        = "tcp"
    security_groups = [aws_security_group.es_master.id]
  }

  ingress {
    description     = "Transport from ingest"
    from_port       = local.es_transport_port
    to_port         = local.es_transport_port
    protocol        = "tcp"
    security_groups = [aws_security_group.es_ingest.id]
  }

  ingress {
    description = "SSH from bastion"
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description     = "HTTP API from ingest/coord/monitoring"
    from_port       = local.es_http_port
    to_port         = local.es_http_port
    protocol        = "tcp"
    security_groups = [aws_security_group.es_ingest.id, aws_security_group.monitoring.id]
  }

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-es-data" })
}

# ── Elasticsearch Ingest / Coordinating ──────────────────────────────────────
resource "aws_security_group" "es_ingest" {
  name        = "${var.name_prefix}-sg-es-ingest"
  description = "ES ingest nodes: receive Beats/Fluentd/Logstash"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Logstash → ES HTTP"
    from_port       = local.es_http_port
    to_port         = local.es_http_port
    protocol        = "tcp"
    security_groups = [aws_security_group.logstash.id]
  }

  ingress {
    description     = "Fluentd → ES HTTP"
    from_port       = local.es_http_port
    to_port         = local.es_http_port
    protocol        = "tcp"
    security_groups = [aws_security_group.fluentd.id]
  }

  ingress {
    description     = "Filebeat → ES HTTP"
    from_port       = local.es_http_port
    to_port         = local.es_http_port
    protocol        = "tcp"
    security_groups = [aws_security_group.filebeat_host.id]
  }

  ingress {
    description = "Transport (inter-node)"
    from_port   = local.es_transport_port
    to_port     = local.es_transport_port
    protocol    = "tcp"
    self        = true
  }

  ingress {
    description     = "Transport to/from masters and data"
    from_port       = local.es_transport_port
    to_port         = local.es_transport_port
    protocol        = "tcp"
    security_groups = [aws_security_group.es_master.id, aws_security_group.es_data.id]
  }

  ingress {
    description = "SSH from bastion"
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-es-ingest" })
}

# ── Kibana ────────────────────────────────────────────────────────────────────
resource "aws_security_group" "kibana" {
  name        = "${var.name_prefix}-sg-kibana"
  description = "Kibana: HTTPS from ALB only"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Kibana from ALB"
    from_port       = local.kibana_port
    to_port         = local.kibana_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from bastion"
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-kibana" })
}

# ── Logstash ──────────────────────────────────────────────────────────────────
resource "aws_security_group" "logstash" {
  name        = "${var.name_prefix}-sg-logstash"
  description = "Logstash: Beats input and HTTP monitoring"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Beats input"
    from_port       = local.logstash_beats
    to_port         = local.logstash_beats
    protocol        = "tcp"
    security_groups = [aws_security_group.filebeat_host.id]
  }

  ingress {
    description = "SSH from bastion"
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  ingress {
    description     = "Logstash HTTP monitoring"
    from_port       = local.logstash_http
    to_port         = local.logstash_http
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-logstash" })
}

# ── Fluentd ───────────────────────────────────────────────────────────────────
resource "aws_security_group" "fluentd" {
  name        = "${var.name_prefix}-sg-fluentd"
  description = "Fluentd app log forwarder"
  vpc_id      = var.vpc_id

  ingress {
    description = "Forward input (internal)"
    from_port   = local.fluentd_forward
    to_port     = local.fluentd_forward
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  ingress {
    description     = "Prometheus metrics scrape"
    from_port       = local.fluentd_metrics
    to_port         = local.fluentd_metrics
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  ingress {
    description = "SSH from bastion"
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-fluentd" })
}

# ── Filebeat hosts (app/Nginx EC2) ────────────────────────────────────────────
resource "aws_security_group" "filebeat_host" {
  name        = "${var.name_prefix}-sg-filebeat-host"
  description = "App EC2 hosts running Filebeat and Nginx"
  vpc_id      = var.vpc_id

  ingress {
    description     = "HTTP/S from ALB"
    from_port       = 80
    to_port         = 443
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description = "SSH from bastion"
    from_port   = local.ssh_port
    to_port     = local.ssh_port
    protocol    = "tcp"
    security_groups = [aws_security_group.bastion.id]
  }

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-filebeat-host" })
}

# ── ALB ───────────────────────────────────────────────────────────────────────
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-sg-alb"
  description = "ALB: HTTPS from internet or internal CIDRs"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = var.alb_ingress_cidrs
  }

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-alb" })
}

# ── Monitoring (Metricbeat collector) ─────────────────────────────────────────
resource "aws_security_group" "monitoring" {
  name        = "${var.name_prefix}-sg-monitoring"
  description = "Monitoring scraper: can reach ES, Logstash, Fluentd metrics"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-sg-monitoring" })
}
