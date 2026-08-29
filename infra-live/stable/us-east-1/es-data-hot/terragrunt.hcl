##############################################################################
# Stable environment — es-data-hot terragrunt.hcl
# 2 r6i.2xlarge data nodes across 2 AZs
##############################################################################
include "root" { path = find_in_parent_folders() }

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
  np       = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
}

dependency "vpc" { config_path = "../vpc";  mock_outputs = { private_subnet_ids = ["subnet-1","subnet-2","subnet-3"] } }
dependency "sg"  { config_path = "../security-groups"; mock_outputs = { es_data_sg_id = "sg-0", monitoring_sg_id = "sg-1" } }
dependency "iam" { config_path = "../iam";  mock_outputs = { elasticsearch_instance_profile_name = "mock" } }
dependency "s3"  { config_path = "../s3-buckets"; mock_outputs = { kms_key_arn = "arn:aws:kms:us-east-1:222:key/mock" } }

terraform {
  source = "../../../../infra-modules/ec2-asg"
}

inputs = {
  name_prefix           = local.np
  node_role             = "es-data-hot"
  environment           = local.e.environment
  aws_region            = local.e.aws_region
  elk_version           = local.e.elk_version
  cluster_name          = "${local.np}-cluster"
  ssm_path_prefix       = "/elk/${local.e.environment}"

  subnet_ids            = dependency.vpc.outputs.private_subnet_ids
  instance_type         = local.e.es_data_instance_type  # r6i.2xlarge = 64GB RAM
  security_group_ids    = [dependency.sg.outputs.es_data_sg_id, dependency.sg.outputs.monitoring_sg_id]
  instance_profile_name = dependency.iam.outputs.elasticsearch_instance_profile_name

  min_size         = 2
  max_size         = 6
  desired_capacity = 2

  root_volume_size_gb          = 50
  data_volume_size_gb          = 1000
  data_volume_iops             = 6000
  data_volume_throughput_mbps  = 500
  data_volume_mount            = "/var/lib/elasticsearch"
  kms_key_arn                  = dependency.s3.outputs.kms_key_arn

  # r6i.2xlarge = 64GB → heap 31g (cap)
  es_heap_size = "31g"

  ami_name_filter = "elk-ubuntu-22.04-es-data-*"
  ami_owner       = "self"
}
