##############################################################################
# infra-live/dev/us-east-1/vpc/terragrunt.hcl
##############################################################################
include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
}

terraform {
  source = "../../../../infra-modules/vpc"
}

inputs = {
  name_prefix            = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
  environment            = local.e.environment
  vpc_cidr               = local.e.vpc_cidr
  availability_zones     = local.e.availability_zones
  enable_vpc_flow_logs   = true
  flow_log_retention_days = 30
}
