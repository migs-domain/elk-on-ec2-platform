variable "name_prefix"          { type = string }
variable "vpc_id"               { type = string }
variable "vpc_cidr"             { type = string }
variable "bastion_allowed_cidrs" { type = list(string); default = [] }
variable "alb_ingress_cidrs"    { type = list(string); default = ["0.0.0.0/0"] }
variable "tags"                 { type = map(string); default = {} }
