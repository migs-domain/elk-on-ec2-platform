##############################################################################
# infra-live/dev/us-east-1/security-groups/terragrunt.hcl
##############################################################################
include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
}

dependency "vpc" {
  config_path = "../vpc"
  mock_outputs = {
    vpc_id   = "vpc-00000000000000000"
    vpc_cidr = "10.10.0.0/16"
  }
}

terraform {
  source = "../../../../infra-modules/security-groups"
}

inputs = {
  name_prefix           = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
  vpc_id                = dependency.vpc.outputs.vpc_id
  vpc_cidr              = dependency.vpc.outputs.vpc_cidr
  bastion_allowed_cidrs = local.e.bastion_allowed_cidrs
  # Kibana ALB internal only; not public in dev
  alb_ingress_cidrs     = [dependency.vpc.outputs.vpc_cidr]
}
