##############################################################################
# infra-live/dev/us-east-1/vpc-endpoints/terragrunt.hcl
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
    vpc_id                  = "vpc-00000000"
    vpc_cidr                = "10.10.0.0/16"
    private_subnet_ids      = ["subnet-00000000"]
    private_route_table_ids = ["rtb-00000000"]
  }
}

terraform {
  source = "../../../../infra-modules/vpc-endpoints"
}

inputs = {
  name_prefix             = local.np
  vpc_id                  = dependency.vpc.outputs.vpc_id
  vpc_cidr                = dependency.vpc.outputs.vpc_cidr
  aws_region              = local.e.aws_region
  private_subnet_ids      = dependency.vpc.outputs.private_subnet_ids
  private_route_table_ids = dependency.vpc.outputs.private_route_table_ids
}
