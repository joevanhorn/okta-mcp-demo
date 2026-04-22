# =============================================================================
# MCP Server — Salesforce + ServiceNow tools for AI agents
# =============================================================================

# ---------------------------------------------------------------------------
# ECR Repository
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "mcp_server" {
  name                 = "mcp-server"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }
}

# ---------------------------------------------------------------------------
# CloudWatch Logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "mcp_server" {
  name              = "/ecs/mcp-server"
  retention_in_days = 14
}

# ---------------------------------------------------------------------------
# ACM Certificate (mcp.DOMAIN)
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "mcp" {
  domain_name       = "mcp.${var.domain_name}"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "mcp_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.mcp.domain_validation_options : dvo.domain_name => {
      name   = dvo.resource_record_name
      record = dvo.resource_record_value
      type   = dvo.resource_record_type
    }
  }
  zone_id = var.hosted_zone_id
  name    = each.value.name
  type    = each.value.type
  ttl     = 300
  records = [each.value.record]
}

resource "aws_acm_certificate_validation" "mcp" {
  certificate_arn         = aws_acm_certificate.mcp.arn
  validation_record_fqdns = [for r in aws_route53_record.mcp_cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# ALB — Target Group + Listener Rule + DNS
# ---------------------------------------------------------------------------
resource "aws_lb_listener_certificate" "mcp" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate_validation.mcp.certificate_arn
}

resource "aws_lb_target_group" "mcp_server" {
  name        = "mcp-server"
  port        = 3000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/health"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

resource "aws_lb_listener_rule" "mcp_server" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mcp_server.arn
  }

  condition {
    host_header {
      values = ["mcp.${var.domain_name}"]
    }
  }
}

resource "aws_route53_record" "mcp_server" {
  zone_id = var.hosted_zone_id
  name    = "mcp.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# ECS Task Definition
# ---------------------------------------------------------------------------
resource "random_password" "mcp_api_key" {
  length  = 32
  special = false
}

resource "aws_ecs_task_definition" "mcp_server" {
  family                   = "mcp-server"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "mcp-server"
    image = "${aws_ecr_repository.mcp_server.repository_url}:latest"

    portMappings = [{
      containerPort = 3000
      protocol      = "tcp"
    }]

    environment = [
      { name = "TRANSPORT", value = "http" },
      { name = "PORT", value = "3000" },
      { name = "SFDC_CLIENT_ID", value = var.sfdc_client_id },
      { name = "SFDC_CLIENT_SECRET", value = var.sfdc_client_secret },
      { name = "SFDC_INSTANCE_URL", value = var.sfdc_instance_url },
      { name = "SNOW_INSTANCE_URL", value = var.snow_instance_url },
      { name = "SNOW_USERNAME", value = var.snow_username },
      { name = "SNOW_PASSWORD", value = var.snow_password },
      { name = "SERVICE_API_KEY", value = random_password.mcp_api_key.result },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mcp_server.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

# ---------------------------------------------------------------------------
# ECS Service
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "mcp_server" {
  name            = "mcp-server"
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.mcp_server.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.fargate.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.mcp_server.arn
    container_name   = "mcp-server"
    container_port   = 3000
  }

  depends_on = [aws_lb_listener_rule.mcp_server]
}
