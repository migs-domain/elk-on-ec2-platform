##############################################################################
# infra-live/dev/us-east-1/s3-buckets/terragrunt.hcl
##############################################################################
include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
}

terraform {
  source = "../../../../infra-modules/s3-buckets"
}

# ELB account IDs per region:
# us-east-1:      127311923021
# us-east-2:      033677994240
# us-west-1:      027434742980
# us-west-2:      797873946194
# ap-southeast-1: 114774131450
# eu-west-1:      156460612806
locals {
  elb_account_ids = {
    "us-east-1"      = "127311923021"
    "us-east-2"      = "033677994240"
    "us-west-2"      = "797873946194"
    "eu-west-1"      = "156460612806"
    "ap-southeast-1" = "114774131450"
  }
}

inputs = {
  name_prefix      = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
  environment      = local.e.environment
  enable_cloudtrail = true
  enable_waf        = local.e.environment != "dev"
  elb_account_id   = local.elb_account_ids[local.e.aws_region]
}
