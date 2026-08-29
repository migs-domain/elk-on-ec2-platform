##############################################################################
# env.hcl — stable environment configuration
##############################################################################
locals {
  org_prefix   = "acme"
  project      = "elk"
  environment  = "stable"

  tf_role_arn  = "arn:aws:iam::222222222222:role/TerraformDeployRole-stable"
  account_id   = "222222222222"

  elk_version  = "8.12.2"
  aws_region   = "us-east-1"

  vpc_cidr     = "10.20.0.0/16"

  # 3 AZs for HA
  availability_zones = ["us-east-1a", "us-east-1b", "us-east-1c"]

  # Sizing — stable
  es_master_instance_type  = "m6i.large"
  es_data_instance_type    = "r6i.2xlarge"
  es_ingest_instance_type  = "c6i.xlarge"
  kibana_instance_type     = "t3.large"
  logstash_instance_type   = "c6i.xlarge"

  # Replica count: stable = 1
  es_replica_count = 1

  ilm_policy = "logs-stable-ilm-policy"

  bastion_allowed_cidrs = ["10.0.0.0/8"]
}
