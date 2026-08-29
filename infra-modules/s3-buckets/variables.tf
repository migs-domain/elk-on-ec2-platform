variable "name_prefix"      { type = string }
variable "environment"      { type = string }
variable "enable_cloudtrail" {
  type = bool
  default = true
}
variable "enable_waf"       {
  type = bool
  default = true
}
variable "elb_account_id"   {
  type        = string
  description = "AWS ELB service account ID for the region (see: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/enable-access-logging.html)"
  default     = "127311923021"  # us-east-1; override per region
}
variable "kms_key_arn"      {
  type = string
  default = null
}
variable "tags"             {
  type = map(string)
  default = {}
}
