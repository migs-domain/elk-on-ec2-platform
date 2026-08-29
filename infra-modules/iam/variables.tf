variable "name_prefix"          { type = string }
variable "ssm_path_prefix"      { type = string; default = "/elk" }
variable "kms_key_arn"          { type = string; default = null }
variable "snapshot_bucket_arn"  { type = string }
variable "log_source_bucket_arns" { type = list(string); default = [] }
variable "sqs_queue_arns"       { type = list(string); default = ["*"] }
variable "kinesis_stream_arns"  { type = list(string); default = ["*"] }
variable "tags"                 { type = map(string); default = {} }
