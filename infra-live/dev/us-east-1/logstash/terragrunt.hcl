##############################################################################
# infra-live/dev/us-east-1/logstash/terragrunt.hcl
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
dependency "sg"  { config_path = "../security-groups"; mock_outputs = { logstash_sg_id = "sg-00000000" } }
dependency "iam" { config_path = "../iam";  mock_outputs = { logstash_instance_profile_name = "mock-profile" } }

terraform {
  source = "../../../../infra-modules/ec2-asg"
}

inputs = {
  name_prefix           = local.np
  node_role             = "logstash"
  environment           = local.e.environment
  aws_region            = local.e.aws_region
  elk_version           = local.e.elk_version
  cluster_name          = "${local.np}-cluster"
  ssm_path_prefix       = "/elk/${local.e.environment}"

  subnet_ids            = dependency.vpc.outputs.private_subnet_ids
  instance_type         = local.e.logstash_instance_type
  security_group_ids    = [dependency.sg.outputs.logstash_sg_id]
  instance_profile_name = dependency.iam.outputs.logstash_instance_profile_name

  min_size         = 1
  max_size         = 2
  desired_capacity = 1

  root_volume_size_gb         = 50
  data_volume_size_gb         = 100  # PQ + DLQ storage
  data_volume_mount           = "/var/lib/logstash"
  data_volume_iops            = 3000
  data_volume_throughput_mbps = 250

  ami_name_filter = "elk-ubuntu-22.04-logstash-*"
  ami_owner       = "self"
}
