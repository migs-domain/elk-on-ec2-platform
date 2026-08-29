##############################################################################
# infra-live/root terragrunt.hcl
# Defines remote state, provider generation, and shared inputs.
##############################################################################

locals {
  # Parse path: infra-live/<environment>/<region>/<module>
  path_parts  = split("/", path_relative_to_include())
  environment = local.path_parts[0]
  aws_region  = local.path_parts[1]

  # Load environment-specific vars
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))

  # Shared config
  org_prefix    = local.env_vars.locals.org_prefix
  project       = local.env_vars.locals.project
  name_prefix   = "${local.org_prefix}-${local.project}-${local.environment}"
  tf_state_key  = "${local.environment}/${local.aws_region}/${local.path_parts[2]}/terraform.tfstate"
}

# ── Remote State — S3 + DynamoDB ─────────────────────────────────────────────
remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    bucket         = "${local.org_prefix}-${local.project}-tfstate-${local.aws_region}"
    key            = local.tf_state_key
    region         = local.aws_region
    encrypt        = true
    dynamodb_table = "${local.org_prefix}-${local.project}-tf-locks"
    # KMS encryption on state bucket (set KMS key ARN or use aws:kms default)
  }
}

# ── AWS Provider Generation ───────────────────────────────────────────────────
generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite_terragrunt"

  contents = <<EOF
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0, < 6.0"
    }
  }
}

provider "aws" {
  region = "${local.aws_region}"

  assume_role {
    role_arn = "${local.env_vars.locals.tf_role_arn}"
  }

  default_tags {
    tags = {
      Environment = "${local.environment}"
      ManagedBy   = "terragrunt"
      Project     = "${local.project}"
      OrgPrefix   = "${local.org_prefix}"
    }
  }
}
EOF
}

# ── Shared inputs ─────────────────────────────────────────────────────────────
inputs = {
  environment  = local.environment
  aws_region   = local.aws_region
  name_prefix  = local.name_prefix
  tags = {
    Environment = local.environment
    Project     = local.project
    ManagedBy   = "terragrunt"
  }
}
