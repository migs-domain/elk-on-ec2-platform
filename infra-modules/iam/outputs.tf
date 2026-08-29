output "elasticsearch_instance_profile_name" { value = aws_iam_instance_profile.elasticsearch.name }
output "elasticsearch_role_arn"             { value = aws_iam_role.elasticsearch.arn }
output "logstash_instance_profile_name"     { value = aws_iam_instance_profile.logstash.name }
output "logstash_role_arn"                  { value = aws_iam_role.logstash.arn }
output "kibana_instance_profile_name"       { value = aws_iam_instance_profile.kibana.name }
output "app_host_instance_profile_name"     { value = aws_iam_instance_profile.app_host.name }
output "snapshot_role_arn"                  { value = aws_iam_role.snapshot.arn }
