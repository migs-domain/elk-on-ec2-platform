##############################################################################
# Module: alb
# Application Load Balancer for Kibana (internal) and app hosts (public).
##############################################################################

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 5.0" }
  }
}

# ── Kibana Internal ALB ───────────────────────────────────────────────────────
resource "aws_lb" "kibana" {
  name               = "${var.name_prefix}-kibana-alb"
  internal           = true
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.private_subnet_ids

  enable_deletion_protection = var.environment == "prod"

  access_logs {
    bucket  = var.alb_logs_bucket_id
    prefix  = "alb/kibana"
    enabled = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-kibana-alb" })
}

resource "aws_lb_target_group" "kibana" {
  name        = "${var.name_prefix}-kibana-tg"
  port        = 5601
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/api/status"
    protocol            = "HTTP"
    port                = "5601"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-kibana-tg" })
}

resource "aws_lb_listener" "kibana_https" {
  load_balancer_arn = aws_lb.kibana.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.kibana.arn
  }
}

# HTTP → HTTPS redirect
resource "aws_lb_listener" "kibana_http_redirect" {
  load_balancer_arn = aws_lb.kibana.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# ── App/Nginx ALB (public-facing, optional) ───────────────────────────────────
resource "aws_lb" "app" {
  count              = var.create_app_alb ? 1 : 0
  name               = "${var.name_prefix}-app-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [var.alb_sg_id]
  subnets            = var.public_subnet_ids

  enable_deletion_protection = var.environment == "prod"

  access_logs {
    bucket  = var.alb_logs_bucket_id
    prefix  = "alb/app"
    enabled = true
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-alb" })
}

resource "aws_lb_target_group" "app" {
  count       = var.create_app_alb ? 1 : 0
  name        = "${var.name_prefix}-app-tg"
  port        = 80
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    path                = "/health"
    protocol            = "HTTP"
    port                = "traffic-port"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-299"
  }

  tags = merge(var.tags, { Name = "${var.name_prefix}-app-tg" })
}

resource "aws_lb_listener" "app_https" {
  count             = var.create_app_alb ? 1 : 0
  load_balancer_arn = aws_lb.app[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.acm_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app[0].arn
  }
}

# Associate WAF Web ACL with app ALB
resource "aws_wafv2_web_acl_association" "app_alb" {
  count        = var.create_app_alb && var.web_acl_arn != null ? 1 : 0
  resource_arn = aws_lb.app[0].arn
  web_acl_arn  = var.web_acl_arn
}
