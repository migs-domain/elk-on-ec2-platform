##############################################################################
# Packer variables file — dev environment
##############################################################################
aws_region    = "us-east-1"
elk_version   = "8.12.2"
jdk_version   = "17"
environment   = "dev"
instance_type = "t3.medium"
os_type       = "ubuntu-22.04"
# subnet_id and vpc_id must be provided at build time or via env vars
