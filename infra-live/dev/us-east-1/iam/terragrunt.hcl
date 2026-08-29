##############################################################################
# infra-live/dev/us-east-1/iam/terragrunt.hcl
##############################################################################
include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
}

dependency "s3_buckets" {
  config_path = "../s3-buckets"
  mock_outputs = {
    snapshot_bucket_arn      = "arn:aws:s3:::mock-snapshot"
    alb_logs_bucket_arn      = "arn:aws:s3:::mock-alb-logs"
    cloudtrail_bucket_arn    = "arn:aws:s3:::mock-cloudtrail"
    vpc_flow_logs_bucket_arn = "arn:aws:s3:::mock-vpc-flow"
    waf_logs_bucket_arn      = "arn:aws:s3:::mock-waf-logs"
    kms_key_arn              = "arn:aws:kms:us-east-1:111111111111:key/mock"
  }
}

terraform {
  source = "../../../../infra-modules/iam"
}

inputs = {
  name_prefix           = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
  ssm_path_prefix       = "/elk/${local.e.environment}"
  kms_key_arn           = dependency.s3_buckets.outputs.kms_key_arn
  snapshot_bucket_arn   = dependency.s3_buckets.outputs.snapshot_bucket_arn
  log_source_bucket_arns = [
    dependency.s3_buckets.outputs.alb_logs_bucket_arn,
    dependency.s3_buckets.outputs.cloudtrail_bucket_arn,
    dependency.s3_buckets.outputs.vpc_flow_logs_bucket_arn,
    dependency.s3_buckets.outputs.waf_logs_bucket_arn,
  ]
}
