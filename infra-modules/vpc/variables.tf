variable "name_prefix" {
  description = "Prefix applied to all resource names"
  type        = string
}

variable "environment" {
  description = "Deployment environment: dev | stable | prod"
  type        = string
  validation {
    condition     = contains(["dev", "stable", "prod"], var.environment)
    error_message = "environment must be dev, stable, or prod."
  }
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC (e.g. 10.10.0.0/16)"
  type        = string
  default     = "10.10.0.0/16"
}

variable "availability_zones" {
  description = "List of AZs to use (at least 3 for stable/prod)"
  type        = list(string)
}

variable "enable_vpc_flow_logs" {
  description = "Enable VPC Flow Logs to CloudWatch"
  type        = bool
  default     = true
}

variable "flow_log_retention_days" {
  description = "CloudWatch log group retention for flow logs"
  type        = number
  default     = 30
}

variable "kms_key_arn" {
  description = "KMS key ARN for log group encryption"
  type        = string
  default     = null
}

variable "tags" {
  description = "Common tags applied to all resources"
  type        = map(string)
  default     = {}
}
