##############################################################################
# infra-live/dev/us-east-1/es-masters/terragrunt.hcl
# 3 dedicated master nodes (quorum)
##############################################################################
include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
  np       = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
}

dependency "vpc"  { config_path = "../vpc";  mock_outputs = { private_subnet_ids = ["subnet-00000000"] } }
dependency "sg"   { config_path = "../security-groups"; mock_outputs = { es_master_sg_id = "sg-00000000", monitoring_sg_id = "sg-00000001" } }
dependency "iam"  { config_path = "../iam";  mock_outputs = { elasticsearch_instance_profile_name = "mock-profile" } }

terraform {
  source = "../../../../infra-modules/ec2-asg"
}

inputs = {
  name_prefix           = local.np
  node_role             = "es-master"
  environment           = local.e.environment
  aws_region            = local.e.aws_region
  elk_version           = local.e.elk_version
  cluster_name          = "${local.np}-cluster"
  ssm_path_prefix       = "/elk/${local.e.environment}"

  # dev: 3 masters in single AZ (quorum requires 3 regardless)
  subnet_ids            = dependency.vpc.outputs.private_subnet_ids
  instance_type         = local.e.es_master_instance_type
  security_group_ids    = [dependency.sg.outputs.es_master_sg_id, dependency.sg.outputs.monitoring_sg_id]
  instance_profile_name = dependency.iam.outputs.elasticsearch_instance_profile_name

  min_size         = 3
  max_size         = 3
  desired_capacity = 3

  # Masters hold no data; root vol only
  root_volume_size_gb  = 50
  data_volume_size_gb  = 0

  # 50% heap of instance RAM (m6i.large = 8 GB RAM → 4g)
  es_heap_size = "4g"

  ami_name_filter = "elk-ubuntu-22.04-es-master-*"
  ami_owner       = "self"
}
