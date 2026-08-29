variable "name_prefix"              { type = string }
variable "node_role"                { type = string }
variable "environment"              { type = string }
variable "aws_region"               { type = string }
variable "elk_version"              { type = string; default = "8.12.2" }
variable "cluster_name"             { type = string }
variable "ssm_path_prefix"          { type = string; default = "/elk" }

variable "ami_id"                   { type = string; default = "" }
variable "ami_name_filter"          { type = string; default = "elk-ubuntu-22.04-*" }
variable "ami_owner"                { type = string; default = "self" }

variable "instance_type"            { type = string }
variable "key_pair_name"            { type = string; default = null }
variable "instance_profile_name"    { type = string }
variable "security_group_ids"       { type = list(string) }
variable "subnet_ids"               { type = list(string) }

variable "min_size"                 { type = number; default = 1 }
variable "max_size"                 { type = number; default = 5 }
variable "desired_capacity"         { type = number; default = 1 }
variable "min_healthy_percentage"   { type = number; default = 66 }

variable "alb_target_group_arns"    { type = list(string); default = null }

variable "kms_key_arn"              { type = string; default = null }
variable "root_volume_size_gb"      { type = number; default = 50 }
variable "data_volume_size_gb"      { type = number; default = 0 }
variable "data_volume_iops"         { type = number; default = 3000 }
variable "data_volume_throughput_mbps" { type = number; default = 250 }
variable "data_volume_mount"        { type = string; default = "/var/lib/elasticsearch" }

variable "es_heap_size"             { type = string; default = "4g" }
variable "tls_mode"                 { type = string; default = "full" }
variable "extra_userdata"           { type = string; default = "" }
variable "tags"                     { type = map(string); default = {} }
