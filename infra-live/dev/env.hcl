##############################################################################
# env.hcl — dev environment configuration
# Referenced by root terragrunt.hcl via find_in_parent_folders
##############################################################################
locals {
  org_prefix   = "acme"
  project      = "elk"
  environment  = "dev"

  # IAM role Terraform assumes for dev
  tf_role_arn  = "arn:aws:iam::111111111111:role/TerraformDeployRole-dev"

  # AWS account ID for this environment
  account_id   = "111111111111"

  # ELK settings
  elk_version  = "8.12.2"
  aws_region   = "us-east-1"

  # VPC CIDR
  vpc_cidr     = "10.10.0.0/16"

  # AZs (dev: single AZ)
  availability_zones = ["us-east-1a"]

  # Sizing
  es_master_instance_type  = "m6i.large"
  es_data_instance_type    = "r6i.xlarge"
  es_ingest_instance_type  = "c6i.large"
  kibana_instance_type     = "t3.large"
  logstash_instance_type   = "c6i.large"

  # Replica count: dev = 0
  es_replica_count = 0

  # ILM policy name
  ilm_policy = "logs-dev-ilm-policy"

  # Bastion CIDR (restrict to your corporate IP)
  bastion_allowed_cidrs = ["10.0.0.0/8"]
}
