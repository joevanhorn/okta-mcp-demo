# =============================================================================
# MCP Adapter + Admin UI — ECS Deployment
# =============================================================================
# Deploys the Okta Agent MCP Adapter (OAuth gateway) and its Admin UI.
#
# Endpoints:
#   adapter.YOUR-DOMAIN — MCP gateway (port 8000)
#   admin.YOUR-DOMAIN   — Admin console (port 3001)
# =============================================================================

# ---------------------------------------------------------------------------
# Random Secrets
# ---------------------------------------------------------------------------
resource "random_password" "adapter_encryption_key" {
  length  = 32
  special = false
}

resource "random_password" "adapter_admin_password" {
  length  = 16
  special = false
}

resource "random_password" "admin_ui_nextauth_secret" {
  length  = 32
  special = false
}

# ---------------------------------------------------------------------------
# ECR Repositories
# ---------------------------------------------------------------------------
resource "aws_ecr_repository" "mcp_adapter" {
  name                 = "mcp-adapter"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = false }
}

resource "aws_ecr_repository" "mcp_admin_ui" {
  name                 = "mcp-admin-ui"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration { scan_on_push = false }
}

# ---------------------------------------------------------------------------
# CloudWatch Logs
# ---------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "mcp_adapter" {
  name              = "/ecs/mcp-adapter"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "mcp_admin_ui" {
  name              = "/ecs/mcp-admin-ui"
  retention_in_days = 14
}

# ---------------------------------------------------------------------------
# ACM Certificates
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "adapter" {
  domain_name       = "adapter.${var.domain_name}"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "adapter_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.adapter.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "adapter" {
  certificate_arn         = aws_acm_certificate.adapter.arn
  validation_record_fqdns = [for r in aws_route53_record.adapter_cert_validation : r.fqdn]
}

resource "aws_acm_certificate" "admin_ui" {
  domain_name       = "admin.${var.domain_name}"
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "admin_ui_cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.admin_ui.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "admin_ui" {
  certificate_arn         = aws_acm_certificate.admin_ui.arn
  validation_record_fqdns = [for r in aws_route53_record.admin_ui_cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# Route53 Records
# ---------------------------------------------------------------------------
resource "aws_route53_record" "adapter" {
  zone_id = var.hosted_zone_id
  name    = "adapter.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "admin_ui" {
  zone_id = var.hosted_zone_id
  name    = "admin.${var.domain_name}"
  type    = "A"
  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}

# ---------------------------------------------------------------------------
# ALB — Target Groups + Listener Rules
# ---------------------------------------------------------------------------
resource "aws_lb_listener_certificate" "adapter" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate_validation.adapter.certificate_arn
}

resource "aws_lb_listener_certificate" "admin_ui" {
  listener_arn    = aws_lb_listener.https.arn
  certificate_arn = aws_acm_certificate_validation.admin_ui.certificate_arn
}

resource "aws_lb_target_group" "mcp_adapter" {
  name        = "mcp-adapter"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/.well-known/oauth-protected-resource"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200"
  }
}

resource "aws_lb_target_group" "mcp_admin_ui" {
  name        = "mcp-admin-ui"
  port        = 3001
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    path                = "/api/test-env"
    interval            = 30
    timeout             = 10
    healthy_threshold   = 2
    unhealthy_threshold = 5
    matcher             = "200"
  }
}

resource "aws_lb_listener_rule" "mcp_adapter" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 20

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mcp_adapter.arn
  }

  condition {
    host_header {
      values = ["adapter.${var.domain_name}"]
    }
  }
}

resource "aws_lb_listener_rule" "mcp_admin_ui" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 30

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.mcp_admin_ui.arn
  }

  condition {
    host_header {
      values = ["admin.${var.domain_name}"]
    }
  }
}

# ---------------------------------------------------------------------------
# ECS Task Definition — MCP Adapter
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "mcp_adapter" {
  family                   = "mcp-adapter"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "mcp-adapter"
    image = "${aws_ecr_repository.mcp_adapter.repository_url}:latest"

    portMappings = [{
      containerPort = 8000
      protocol      = "tcp"
    }]

    environment = [
      { name = "OKTA_DOMAIN", value = var.okta_domain },
      { name = "OKTA_ISSUER", value = "https://${var.okta_domain}" },
      { name = "RELAY_OKTA_AUTH_SERVER_ID", value = var.okta_auth_server_id },
      { name = "GATEWAY_BASE_URL", value = "https://adapter.${var.domain_name}" },
      { name = "GATEWAY_PORT", value = "8000" },
      { name = "DATABASE_URL", value = "postgresql://${aws_db_instance.app.username}:${random_password.db.result}@${aws_db_instance.app.endpoint}/${aws_db_instance.app.db_name}" },
      { name = "ENCRYPTION_KEY", value = base64encode(random_password.adapter_encryption_key.result) },
      { name = "ADMIN_USERNAME", value = "admin" },
      { name = "ADMIN_PASSWORD", value = random_password.adapter_admin_password.result },
      { name = "CACHE_PROVIDER", value = "memory" },
      { name = "LOG_LEVEL", value = "INFO" },
      { name = "PYTHONUNBUFFERED", value = "1" },
      # Okta AI Agent
      { name = "OKTA_AI_AGENT_ID", value = var.okta_ai_agent_id },
      { name = "OKTA_AI_AGENT_CLIENT_ID", value = var.okta_ai_agent_client_id },
      # DCR config
      { name = "DCR_ENABLED", value = "true" },
      { name = "DCR_PROVISION_OKTA_APP", value = "false" },
      { name = "DCR_AUTO_ENABLE_AGENT", value = "true" },
      # CIMD config — relaxed for demo
      { name = "CIMD_ENABLED", value = "true" },
      { name = "CIMD_ALLOW_LOCALHOST", value = "true" },
      { name = "CIMD_REQUIRE_HTTPS", value = "false" },
      { name = "CIMD_ALLOW_PRIVATE_NETWORKS", value = "true" },
      { name = "CIMD_TLS_VERIFY", value = "false" },
      { name = "CIMD_TRUSTED_DOMAINS", value = "claude.ai,anthropic.com" },
      { name = "CIMD_ALLOWED_REDIRECT_PATTERNS", value = "http://localhost/callback,http://127.0.0.1/callback,http://localhost:*/callback,http://127.0.0.1:*/callback" },
      { name = "CIMD_UNKNOWN_BACKEND_ACCESS", value = "mcp-tools" },
      { name = "CIMD_TRUSTED_BACKEND_ACCESS", value = "mcp-tools" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mcp_adapter.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }

    linuxParameters = {
      initProcessEnabled = true
    }
  }])
}

# ---------------------------------------------------------------------------
# ECS Task Definition — Admin UI
# ---------------------------------------------------------------------------
resource "aws_ecs_task_definition" "mcp_admin_ui" {
  family                   = "mcp-admin-ui"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 512
  memory                   = 1024
  execution_role_arn       = aws_iam_role.ecs_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  container_definitions = jsonencode([{
    name  = "mcp-admin-ui"
    image = "${aws_ecr_repository.mcp_admin_ui.repository_url}:latest"

    portMappings = [{
      containerPort = 3001
      protocol      = "tcp"
    }]

    environment = [
      { name = "NEXT_PUBLIC_API_URL", value = "https://adapter.${var.domain_name}" },
      { name = "API_URL", value = "https://adapter.${var.domain_name}" },
      { name = "NEXT_PUBLIC_APP_NAME", value = "Okta MCP Adapter Admin" },
      { name = "NODE_ENV", value = "production" },
      { name = "PORT", value = "3001" },
      { name = "HOSTNAME", value = "0.0.0.0" },
      { name = "NEXTAUTH_URL", value = "https://admin.${var.domain_name}" },
      { name = "NEXTAUTH_SECRET", value = random_password.admin_ui_nextauth_secret.result },
      { name = "OKTA_DOMAIN", value = var.okta_domain },
      { name = "OKTA_CLIENT_ID", value = var.admin_ui_okta_client_id },
      { name = "OKTA_CLIENT_SECRET", value = var.admin_ui_okta_client_secret },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.mcp_admin_ui.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "ecs"
      }
    }
  }])
}

# ---------------------------------------------------------------------------
# ECS Services
# ---------------------------------------------------------------------------
resource "aws_ecs_service" "mcp_adapter" {
  name            = "mcp-adapter"
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.mcp_adapter.arn
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
    target_group_arn = aws_lb_target_group.mcp_adapter.arn
    container_name   = "mcp-adapter"
    container_port   = 8000
  }

  depends_on = [aws_lb_listener_rule.mcp_adapter]
}

resource "aws_ecs_service" "mcp_admin_ui" {
  name            = "mcp-admin-ui"
  cluster         = aws_ecs_cluster.app.id
  task_definition = aws_ecs_task_definition.mcp_admin_ui.arn
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
    target_group_arn = aws_lb_target_group.mcp_admin_ui.arn
    container_name   = "mcp-admin-ui"
    container_port   = 3001
  }

  depends_on = [aws_lb_listener_rule.mcp_admin_ui]
}
