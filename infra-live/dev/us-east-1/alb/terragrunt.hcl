##############################################################################
# infra-live/dev/us-east-1/alb/terragrunt.hcl
##############################################################################
include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
  np       = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
}

dependency "vpc" {
  config_path  = "../vpc"
  mock_outputs = {
    vpc_id             = "vpc-00000000"
    private_subnet_ids = ["subnet-00000000"]
    public_subnet_ids  = ["subnet-00000001"]
  }
}
dependency "sg" {
  config_path  = "../security-groups"
  mock_outputs = { alb_sg_id = "sg-00000000" }
}
dependency "s3" {
  config_path  = "../s3-buckets"
  mock_outputs = { alb_logs_bucket_id = "mock-alb-logs" }
}

terraform {
  source = "../../../../infra-modules/alb"
}

inputs = {
  name_prefix         = local.np
  environment         = local.e.environment
  vpc_id              = dependency.vpc.outputs.vpc_id
  private_subnet_ids  = dependency.vpc.outputs.private_subnet_ids
  public_subnet_ids   = dependency.vpc.outputs.public_subnet_ids
  alb_sg_id           = dependency.sg.outputs.alb_sg_id
  alb_logs_bucket_id  = dependency.s3.outputs.alb_logs_bucket_id
  # ACM cert ARN — must be pre-provisioned and matched to your domain
  acm_certificate_arn = "arn:aws:acm:us-east-1:111111111111:certificate/REPLACE-ME"
  create_app_alb      = true
  web_acl_arn         = null  # no WAF in dev
}
