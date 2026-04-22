# =============================================================================
# Okta MCP Demo — Core Infrastructure
# =============================================================================
# Shared resources used by MCP Server, Adapter, and Admin UI:
#   - ALB (load balancer + HTTPS termination)
#   - ECS Fargate cluster
#   - RDS PostgreSQL (for MCP Adapter)
#   - Security groups
#   - IAM roles
# =============================================================================

# ---------------------------------------------------------------------------
# Random Passwords
# ---------------------------------------------------------------------------
resource "random_password" "db" {
  length  = 24
  special = false
}

# ---------------------------------------------------------------------------
# ACM Certificate (root domain)
# ---------------------------------------------------------------------------
resource "aws_acm_certificate" "app" {
  domain_name       = var.domain_name
  validation_method = "DNS"
  lifecycle { create_before_destroy = true }
}

resource "aws_route53_record" "cert_validation" {
  for_each = {
    for dvo in aws_acm_certificate.app.domain_validation_options : dvo.domain_name => {
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

resource "aws_acm_certificate_validation" "app" {
  certificate_arn         = aws_acm_certificate.app.arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

# ---------------------------------------------------------------------------
# Security Groups
# ---------------------------------------------------------------------------

# ALB: accepts HTTPS from the internet
resource "aws_security_group" "alb" {
  name        = "okta-mcp-demo-alb"
  description = "ALB for Okta MCP Demo"
  vpc_id      = var.vpc_id

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTP (redirect to HTTPS)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Fargate: accepts traffic from ALB on service ports
# IMPORTANT: All ingress rules MUST be inline here. Standalone
# aws_vpc_security_group_ingress_rule resources conflict with inline
# rules and get deleted on every apply.
resource "aws_security_group" "fargate" {
  name        = "okta-mcp-demo-fargate"
  description = "Fargate tasks for Okta MCP Demo"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MCP Adapter from ALB (port 8000)"
    from_port       = 8000
    to_port         = 8000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "MCP Server from ALB (port 3000)"
    from_port       = 3000
    to_port         = 3000
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  ingress {
    description     = "Admin UI from ALB (port 3001)"
    from_port       = 3001
    to_port         = 3001
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# RDS: accepts traffic only from Fargate
resource "aws_security_group" "rds" {
  name        = "okta-mcp-demo-rds"
  description = "RDS PostgreSQL for MCP Adapter"
  vpc_id      = var.vpc_id

  ingress {
    description     = "PostgreSQL from Fargate"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.fargate.id]
  }
}

# ---------------------------------------------------------------------------
# RDS PostgreSQL (for MCP Adapter state)
# ---------------------------------------------------------------------------
resource "aws_db_subnet_group" "app" {
  name       = "okta-mcp-demo"
  subnet_ids = var.private_subnet_ids
}

resource "aws_db_instance" "app" {
  identifier     = "okta-mcp-demo"
  engine         = "postgres"
  engine_version = "16"
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = "mcpadapter"
  username = "mcpadapter"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.app.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  skip_final_snapshot = true
  publicly_accessible = false
  backup_retention_period = 1
}

# ---------------------------------------------------------------------------
# ALB
# ---------------------------------------------------------------------------
resource "aws_lb" "app" {
  name               = "okta-mcp-demo"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.app.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.app.certificate_arn

  # Default action returns 404 — each service has its own listener rule
  default_action {
    type = "fixed-response"
    fixed_response {
      content_type = "text/plain"
      message_body = "Not Found"
      status_code  = "404"
    }
  }
}

resource "aws_lb_listener" "http_redirect" {
  load_balancer_arn = aws_lb.app.arn
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

# ---------------------------------------------------------------------------
# ECS Cluster + IAM Roles
# ---------------------------------------------------------------------------
resource "aws_ecs_cluster" "app" {
  name = "okta-mcp-demo"
}

resource "aws_iam_role" "ecs_execution" {
  name = "okta-mcp-demo-ecs-execution"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_execution" {
  role       = aws_iam_role.ecs_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name = "okta-mcp-demo-ecs-task"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
}

# ---------------------------------------------------------------------------
# Route53 — root domain points to ALB
# ---------------------------------------------------------------------------
resource "aws_route53_record" "app" {
  zone_id = var.hosted_zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.app.dns_name
    zone_id                = aws_lb.app.zone_id
    evaluate_target_health = true
  }
}
