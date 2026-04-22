# =============================================================================
# Required Variables — you MUST set these
# =============================================================================

variable "domain_name" {
  description = "Domain for the demo (e.g., mcp-demo.example.com)"
  type        = string
}

variable "hosted_zone_id" {
  description = "Route53 hosted zone ID for the domain"
  type        = string
}

variable "vpc_id" {
  description = "VPC to deploy into (must have public + private subnets)"
  type        = string
}

variable "public_subnet_ids" {
  description = "Public subnets for the ALB (need 2 in different AZs)"
  type        = list(string)
}

variable "private_subnet_ids" {
  description = "Private subnets for Fargate tasks and RDS (need 2 in different AZs)"
  type        = list(string)
}

# =============================================================================
# Okta Configuration
# =============================================================================

variable "okta_domain" {
  description = "Okta org domain (e.g., your-org.okta.com)"
  type        = string
}

variable "okta_auth_server_id" {
  description = "Okta auth server ID for MCP Adapter (use 'org' for org auth server)"
  type        = string
  default     = "org"
}

variable "okta_ai_agent_id" {
  description = "Okta AI Agent ID (wlp...)"
  type        = string
  default     = ""
}

variable "okta_ai_agent_client_id" {
  description = "OIDC app client ID linked to the AI Agent"
  type        = string
  default     = ""
}

variable "admin_ui_okta_client_id" {
  description = "Admin UI OIDC app client ID"
  type        = string
  default     = ""
}

variable "admin_ui_okta_client_secret" {
  description = "Admin UI OIDC app client secret"
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# MCP Server — Backend Credentials
# =============================================================================

variable "sfdc_client_id" {
  description = "Salesforce connected app client ID"
  type        = string
  default     = ""
}

variable "sfdc_client_secret" {
  description = "Salesforce connected app client secret"
  type        = string
  sensitive   = true
  default     = ""
}

variable "sfdc_instance_url" {
  description = "Salesforce instance URL (e.g., https://your-org.develop.my.salesforce.com)"
  type        = string
  default     = ""
}

variable "snow_instance_url" {
  description = "ServiceNow instance URL (e.g., https://devXXXXX.service-now.com)"
  type        = string
  default     = ""
}

variable "snow_username" {
  description = "ServiceNow admin username"
  type        = string
  default     = "admin"
}

variable "snow_password" {
  description = "ServiceNow admin password"
  type        = string
  sensitive   = true
  default     = ""
}

# =============================================================================
# Optional / Tunable
# =============================================================================

variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-2"
}

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}
