##############################################################################
# infra-live/dev/us-east-1/es-data-hot/terragrunt.hcl
# 1 data-hot node (dev single-AZ)
##############################################################################
include "root" {
  path = find_in_parent_folders()
}

locals {
  env_vars = read_terragrunt_config(find_in_parent_folders("env.hcl"))
  e        = local.env_vars.locals
  np       = "${local.e.org_prefix}-${local.e.project}-${local.e.environment}"
}

dependency "vpc" { config_path = "../vpc";  mock_outputs = { private_subnet_ids = ["subnet-00000000"] } }
dependency "sg"  { config_path = "../security-groups"; mock_outputs = { es_data_sg_id = "sg-00000000", monitoring_sg_id = "sg-00000001" } }
dependency "iam" { config_path = "../iam";  mock_outputs = { elasticsearch_instance_profile_name = "mock-profile" } }
dependency "s3"  { config_path = "../s3-buckets"; mock_outputs = { kms_key_arn = "arn:aws:kms:us-east-1:111:key/mock" } }

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
  instance_type         = local.e.es_data_instance_type
  security_group_ids    = [dependency.sg.outputs.es_data_sg_id, dependency.sg.outputs.monitoring_sg_id]
  instance_profile_name = dependency.iam.outputs.elasticsearch_instance_profile_name

  min_size         = 1
  max_size         = 3
  desired_capacity = 1

  root_volume_size_gb          = 50
  data_volume_size_gb          = 500   # 500 GB hot data volume
  data_volume_iops             = 3000
  data_volume_throughput_mbps  = 250
  data_volume_mount            = "/var/lib/elasticsearch"
  kms_key_arn                  = dependency.s3.outputs.kms_key_arn

  # r6i.xlarge = 32 GB RAM → 16g heap (capped at 31g)
  es_heap_size = "16g"

  ami_name_filter = "elk-ubuntu-22.04-es-data-*"
  ami_owner       = "self"
}
