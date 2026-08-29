variable "name_prefix"          { type = string }
variable "environment"          { type = string }
variable "vpc_id"               { type = string }
variable "private_subnet_ids"   { type = list(string) }
variable "public_subnet_ids"    { type = list(string) }
variable "alb_sg_id"            { type = string }
variable "alb_logs_bucket_id"   { type = string }
variable "acm_certificate_arn"  { type = string }
variable "create_app_alb"       { type = bool; default = true }
variable "web_acl_arn"          { type = string; default = null }
variable "tags"                 { type = map(string); default = {} }
