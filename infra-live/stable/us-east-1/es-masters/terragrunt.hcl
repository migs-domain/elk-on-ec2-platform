##############################################################################
# Stable environment — es-masters terragrunt.hcl
# 3 dedicated masters across 3 AZs
##############################################################################
include "root" { path = find_in_parent_folders() }

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
  np       = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
}

dependency "vpc" { config_path = "../vpc";  mock_outputs = { private_subnet_ids = ["subnet-1","subnet-2","subnet-3"] } }
dependency "sg"  { config_path = "../security-groups"; mock_outputs = { es_master_sg_id = "sg-0", monitoring_sg_id = "sg-1" } }
dependency "iam" { config_path = "../iam";  mock_outputs = { elasticsearch_instance_profile_name = "mock" } }

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

  # 3 AZs → 3 subnets, one master per AZ
  subnet_ids            = dependency.vpc.outputs.private_subnet_ids
  instance_type         = local.e.es_master_instance_type
  security_group_ids    = [dependency.sg.outputs.es_master_sg_id, dependency.sg.outputs.monitoring_sg_id]
  instance_profile_name = dependency.iam.outputs.elasticsearch_instance_profile_name

  min_size                = 3
  max_size                = 3
  desired_capacity        = 3
  min_healthy_percentage  = 66  # tolerate 1 master down during rolling update

  root_volume_size_gb = 50
  data_volume_size_gb = 0
  es_heap_size        = "4g"

  ami_name_filter = "elk-ubuntu-22.04-es-master-*"
  ami_owner       = "self"
}
