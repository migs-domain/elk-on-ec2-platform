##############################################################################
# Module: s3-buckets
# Creates per-environment S3 buckets: snapshot, ALB logs, CloudTrail,
# VPC flow logs, WAF logs, S3 access logs. All KMS-encrypted.
##############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

locals {
  account_id = data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}

# ── KMS Key ───────────────────────────────────────────────────────────────────
resource "aws_kms_key" "buckets" {
  description             = "${var.name_prefix} S3 bucket encryption key"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "Enable IAM User Permissions"
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${local.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid    = "Allow S3 Service"
        Effect = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = "*"
      },
      {
        Sid    = "Allow Delivery Services"
        Effect = "Allow"
        Principal = {
          Service = [
            "delivery.logs.amazonaws.com",
            "cloudtrail.amazonaws.com",
            "firehose.amazonaws.com"
          ]
        }
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = "*"
      }
    ]
  })

  tags = merge(var.tags, { Name = "${var.name_prefix}-s3-kms" })
}

resource "aws_kms_alias" "buckets" {
  name          = "alias/${var.name_prefix}-s3"
  target_key_id = aws_kms_key.buckets.id
}

# ── Helper: private, versioned, encrypted bucket ──────────────────────────────
module "bucket" {
  source   = "./bucket-submodule"
  for_each = local.bucket_configs

  name_prefix = var.name_prefix
  bucket_name = "${var.name_prefix}-${each.key}-${local.account_id}"
  kms_key_arn = aws_kms_key.buckets.arn
  tags        = merge(var.tags, { BucketPurpose = each.key })

  depends_on = [aws_kms_key.buckets]
}

locals {
  bucket_configs = {
    snapshots      = {}
    alb-logs       = {}
    cloudtrail     = {}
    vpc-flow-logs  = {}
    waf-logs       = {}
    s3-access-logs = {}
    cloudfront-logs = {}
  }
}

# ALB requires specific bucket policy for log delivery
resource "aws_s3_bucket_policy" "alb_logs" {
  bucket = "${var.name_prefix}-alb-logs-${local.account_id}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "ALBLogDelivery"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${var.elb_account_id}:root"
        }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.name_prefix}-alb-logs-${local.account_id}/alb/*"
      },
      {
        Sid    = "AWSLogDeliveryWrite"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.name_prefix}-alb-logs-${local.account_id}/alb/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      },
      {
        Sid    = "AWSLogDeliveryAclCheck"
        Effect = "Allow"
        Principal = { Service = "delivery.logs.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::${var.name_prefix}-alb-logs-${local.account_id}"
      }
    ]
  })

  depends_on = [module.bucket]
}

# CloudTrail bucket policy
resource "aws_s3_bucket_policy" "cloudtrail" {
  bucket = "${var.name_prefix}-cloudtrail-${local.account_id}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AWSCloudTrailAclCheck"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:GetBucketAcl"
        Resource = "arn:aws:s3:::${var.name_prefix}-cloudtrail-${local.account_id}"
      },
      {
        Sid    = "AWSCloudTrailWrite"
        Effect = "Allow"
        Principal = { Service = "cloudtrail.amazonaws.com" }
        Action   = "s3:PutObject"
        Resource = "arn:aws:s3:::${var.name_prefix}-cloudtrail-${local.account_id}/cloudtrail/AWSLogs/${local.account_id}/*"
        Condition = {
          StringEquals = { "s3:x-amz-acl" = "bucket-owner-full-control" }
        }
      }
    ]
  })

  depends_on = [module.bucket]
}

# WAF / Firehose bucket policy
resource "aws_s3_bucket_policy" "waf_logs" {
  bucket = "${var.name_prefix}-waf-logs-${local.account_id}"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "FirehoseDelivery"
        Effect = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action   = ["s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject"]
        Resource = ["arn:aws:s3:::${var.name_prefix}-waf-logs-${local.account_id}", "arn:aws:s3:::${var.name_prefix}-waf-logs-${local.account_id}/*"]
      }
    ]
  })

  depends_on = [module.bucket]
}

# ── CloudTrail ────────────────────────────────────────────────────────────────
resource "aws_cloudtrail" "this" {
  count                         = var.enable_cloudtrail ? 1 : 0
  name                          = "${var.name_prefix}-trail"
  s3_bucket_name                = "${var.name_prefix}-cloudtrail-${local.account_id}"
  include_global_service_events = true
  is_multi_region_trail         = var.environment == "prod"
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.buckets.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::"]
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-cloudtrail" })

  depends_on = [aws_s3_bucket_policy.cloudtrail]
}

# ── Kinesis Firehose for WAF ──────────────────────────────────────────────────
resource "aws_iam_role" "firehose" {
  name               = "${var.name_prefix}-firehose-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
  tags = var.tags
}

resource "aws_iam_role_policy" "firehose_s3" {
  name = "${var.name_prefix}-firehose-s3"
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:AbortMultipartUpload", "s3:GetBucketLocation", "s3:GetObject",
        "s3:ListBucket", "s3:ListBucketMultipartUploads", "s3:PutObject",
        "kms:GenerateDataKey", "kms:Decrypt"
      ]
      Resource = [
        aws_kms_key.buckets.arn,
        "arn:aws:s3:::${var.name_prefix}-waf-logs-${local.account_id}",
        "arn:aws:s3:::${var.name_prefix}-waf-logs-${local.account_id}/*"
      ]
    }]
  })
}

resource "aws_kinesis_firehose_delivery_stream" "waf" {
  count       = var.enable_waf ? 1 : 0
  # WAF logging requires the stream name to start with "aws-waf-logs-"
  name        = "aws-waf-logs-${var.name_prefix}"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = "arn:aws:s3:::${var.name_prefix}-waf-logs-${local.account_id}"
    prefix              = "waf/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "waf-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/"
    buffering_size      = 64
    buffering_interval  = 300

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = "/aws/kinesisfirehose/${var.name_prefix}-waf"
      log_stream_name = "S3Delivery"
    }
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-waf-firehose" })

  depends_on = [aws_s3_bucket_policy.waf_logs]
}

# ── WAF Web ACL ───────────────────────────────────────────────────────────────
resource "aws_wafv2_web_acl" "this" {
  count = var.enable_waf ? 1 : 0
  name  = "${var.name_prefix}-web-acl"
  scope = "REGIONAL"

  default_action { allow {} }

  rule {
    name     = "AWSManagedRulesCommonRuleSet"
    priority = 1

    override_action { none {} }

    statement {
      managed_rule_group_statement {
        name        = "AWSManagedRulesCommonRuleSet"
        vendor_name = "AWS"
      }
    }

    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${var.name_prefix}-common-rules"
      sampled_requests_enabled   = true
    }
  }
  
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${var.name_prefix}-web-acl"
    sampled_requests_enabled   = true
  }

  tags = var.tags
}

resource "aws_wafv2_web_acl_logging_configuration" "this" {
  count                   = var.enable_waf ? 1 : 0
  log_destination_configs = [aws_kinesis_firehose_delivery_stream.waf[0].arn]
  resource_arn            = aws_wafv2_web_acl.this[0].arn
}
