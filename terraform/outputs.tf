output "mcp_server_url" {
  description = "MCP Server URL"
  value       = "https://mcp.${var.domain_name}"
}

output "mcp_adapter_url" {
  description = "MCP Adapter gateway URL"
  value       = "https://adapter.${var.domain_name}"
}

output "mcp_admin_ui_url" {
  description = "MCP Admin UI URL"
  value       = "https://admin.${var.domain_name}"
}

output "ecs_cluster" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.app.name
}

output "mcp_adapter_admin_password" {
  description = "Admin password for the MCP Adapter API"
  value       = random_password.adapter_admin_password.result
  sensitive   = true
}

output "rds_endpoint" {
  description = "RDS PostgreSQL endpoint"
  value       = aws_db_instance.app.endpoint
}

output "alb_dns" {
  description = "ALB DNS name (for debugging)"
  value       = aws_lb.app.dns_name
}
