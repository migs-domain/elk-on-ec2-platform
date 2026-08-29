##############################################################################
# Module: iam
# Creates IAM roles and instance profiles for all ELK node types.
# Follows least-privilege: each role only gets what it needs.
##############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
  }
}

# ── Shared SSM base policy ────────────────────────────────────────────────────
resource "aws_iam_policy" "ssm_base" {
  name        = "${var.name_prefix}-ssm-base"
  description = "Allow nodes to pull configs/certs from SSM and Secrets Manager"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SSMGetParameters"
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters",
          "ssm:GetParametersByPath"
        ]
        Resource = "arn:aws:ssm:*:*:parameter/${var.ssm_path_prefix}/*"
      },
      {
        Sid    = "SecretsManagerGet"
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue",
          "secretsmanager:DescribeSecret"
        ]
        Resource = "arn:aws:secretsmanager:*:*:secret:${var.name_prefix}/*"
      },
      {
        Sid    = "KMSDecrypt"
        Effect = "Allow"
        Action = ["kms:Decrypt", "kms:GenerateDataKey"]
        Resource = var.kms_key_arn != null ? [var.kms_key_arn] : ["*"]
      },
      {
        Sid    = "EC2MetadataTokenRequired"
        Effect = "Allow"
        Action = ["ec2:DescribeInstances", "ec2:DescribeTags"]
        Resource = "*"
      }
    ]
  })
}

# ── Elasticsearch nodes ───────────────────────────────────────────────────────
resource "aws_iam_role" "elasticsearch" {
  name               = "${var.name_prefix}-es-node-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "es_ssm" {
  role       = aws_iam_role.elasticsearch.name
  policy_arn = aws_iam_policy.ssm_base.arn
}

resource "aws_iam_role_policy" "es_snapshot" {
  name = "${var.name_prefix}-es-snapshot"
  role = aws_iam_role.elasticsearch.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "SnapshotBucketAccess"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket",
          "s3:DeleteObject",
          "s3:GetBucketLocation"
        ]
        Resource = [
          "${var.snapshot_bucket_arn}",
          "${var.snapshot_bucket_arn}/*"
        ]
      }
    ]
  })
}

# CloudWatch metrics for node health
resource "aws_iam_role_policy_attachment" "es_cloudwatch" {
  role       = aws_iam_role.elasticsearch.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "elasticsearch" {
  name = "${var.name_prefix}-es-node-profile"
  role = aws_iam_role.elasticsearch.name
}

# ── Logstash ──────────────────────────────────────────────────────────────────
resource "aws_iam_role" "logstash" {
  name               = "${var.name_prefix}-logstash-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "logstash_ssm" {
  role       = aws_iam_role.logstash.name
  policy_arn = aws_iam_policy.ssm_base.arn
}

resource "aws_iam_role_policy" "logstash_s3_read" {
  name = "${var.name_prefix}-logstash-s3-read"
  role = aws_iam_role.logstash.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "S3LogsRead"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:ListBucket", "s3:GetBucketLocation"]
        Resource = concat(
          [for b in var.log_source_bucket_arns : b],
          [for b in var.log_source_bucket_arns : "${b}/*"]
        )
      },
      {
        Sid    = "SQSLogstashInputs"
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:GetQueueUrl",
          "sqs:ListQueues"
        ]
        Resource = var.sqs_queue_arns
      },
      {
        Sid    = "KinesisFirehoseRead"
        Effect = "Allow"
        Action = [
          "kinesis:GetRecords",
          "kinesis:GetShardIterator",
          "kinesis:DescribeStream",
          "kinesis:ListStreams"
        ]
        Resource = var.kinesis_stream_arns
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "logstash_cloudwatch" {
  role       = aws_iam_role.logstash.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "logstash" {
  name = "${var.name_prefix}-logstash-profile"
  role = aws_iam_role.logstash.name
}

# ── Kibana ────────────────────────────────────────────────────────────────────
resource "aws_iam_role" "kibana" {
  name               = "${var.name_prefix}-kibana-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "kibana_ssm" {
  role       = aws_iam_role.kibana.name
  policy_arn = aws_iam_policy.ssm_base.arn
}

resource "aws_iam_instance_profile" "kibana" {
  name = "${var.name_prefix}-kibana-profile"
  role = aws_iam_role.kibana.name
}

# ── App EC2 hosts (Filebeat + Nginx + Fluentd) ────────────────────────────────
resource "aws_iam_role" "app_host" {
  name               = "${var.name_prefix}-app-host-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy_attachment" "app_ssm" {
  role       = aws_iam_role.app_host.name
  policy_arn = aws_iam_policy.ssm_base.arn
}

resource "aws_iam_role_policy_attachment" "app_ssm_managed" {
  role       = aws_iam_role.app_host.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "app_host" {
  name = "${var.name_prefix}-app-host-profile"
  role = aws_iam_role.app_host.name
}

# ── Snapshot-specific IAM role (used by Elasticsearch SLM) ───────────────────
resource "aws_iam_role" "snapshot" {
  name               = "${var.name_prefix}-es-snapshot-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "snapshot_s3" {
  name = "${var.name_prefix}-snapshot-s3"
  role = aws_iam_role.snapshot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:PutObject", "s3:GetObject", "s3:ListBucket",
        "s3:DeleteObject", "s3:GetBucketLocation", "s3:ListBucketMultipartUploads",
        "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"
      ]
      Resource = [var.snapshot_bucket_arn, "${var.snapshot_bucket_arn}/*"]
    }]
  })
}

resource "aws_iam_instance_profile" "snapshot" {
  name = "${var.name_prefix}-snapshot-profile"
  role = aws_iam_role.snapshot.name
}
