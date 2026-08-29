output "kibana_alb_arn"          { value = aws_lb.kibana.arn }
output "kibana_alb_dns_name"     { value = aws_lb.kibana.dns_name }
output "kibana_target_group_arn" { value = aws_lb_target_group.kibana.arn }
output "app_alb_arn"             { value = var.create_app_alb ? aws_lb.app[0].arn : null }
output "app_alb_dns_name"        { value = var.create_app_alb ? aws_lb.app[0].dns_name : null }
output "app_target_group_arn"    { value = var.create_app_alb ? aws_lb_target_group.app[0].arn : null }
