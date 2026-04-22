---
name: demo-setup-infra
description: Fork the repo, configure GitHub workflows, and deploy MCP Server, Adapter, and Admin UI to AWS ECS
user-invocable: true
---

# Deploy Infrastructure

You are helping an SE deploy the Okta MCP Adapter demo to AWS ECS. This covers forking the repo, setting up GitHub Actions, and deploying 3 services (MCP Server, Adapter, Admin UI).

## Phase 1: Fork and Configure the Repository

### Step 1: Fork the Repo

```bash
# Fork to your GitHub account
gh repo fork joevanhorn/okta-mcp-demo --clone
cd okta-mcp-demo
```

### Step 2: Add the MCP Adapter Zip

The adapter is distributed by Okta PS as a zip file (`okta-agent-mcp-adapter-X.Y.Z.zip`). Get this from your PS contact, then add it to the repo root:

```bash
# Copy the zip into the repo (the .gitignore excludes *.zip from commits)
cp ~/Downloads/okta-agent-mcp-adapter-0.14.0.zip .
```

> **Note:** The zip is NOT committed to git. Each SE must have their own copy. For CI/CD, upload it to S3 and modify the workflow to download it.

### Step 3: Create a GitHub Environment

Go to **Settings > Environments** in your forked repo and create an environment named `mcp-demo`.

### Step 4: Configure AWS OIDC for GitHub Actions

The workflow authenticates via OIDC — no long-lived AWS credentials needed.

1. Create an IAM OIDC identity provider for GitHub Actions (if not already done):
   ```
   Provider URL: https://token.actions.githubusercontent.com
   Audience: sts.amazonaws.com
   ```

2. Create an IAM role with a trust policy scoped to your repo:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": {
         "Federated": "arn:aws:iam::YOUR-ACCOUNT:oidc-provider/token.actions.githubusercontent.com"
       },
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {
         "StringEquals": {
           "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
         },
         "StringLike": {
           "token.actions.githubusercontent.com:sub": "repo:YOUR-ORG/okta-mcp-demo:*"
         }
       }
     }]
   }
   ```

3. Attach these policies to the role:
   - `AmazonECS_FullAccess`
   - `AmazonEC2ContainerRegistryPowerUser`
   - Custom policy for Terraform (S3, RDS, Route53, ACM, IAM, CloudWatch, ALB, VPC)

### Step 5: Add GitHub Environment Secrets

In the `mcp-demo` environment, add:

| Secret | Value |
|--------|-------|
| `AWS_ROLE_ARN` | ARN of the IAM role from Step 4 |

Optionally add a **Repository Variable** (not secret):

| Variable | Value |
|----------|-------|
| `AWS_REGION` | `us-east-2` (or your preferred region) |

### Step 6: Configure Terraform Variables

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your values
```

**Required values:**
- `domain_name` — domain with a Route53 hosted zone (e.g., `mcp-demo.example.com`)
- `hosted_zone_id` — Route53 zone ID
- `vpc_id`, `public_subnet_ids`, `private_subnet_ids` — existing VPC with 2 AZs
- `okta_domain` — your Okta org (e.g., `your-org.okta.com`)
- Salesforce and ServiceNow credentials (from `/demo-setup-data`)
- Okta OIDC app credentials (from `/demo-setup-okta`)

**Backend configuration:** Edit `provider.tf` to configure your Terraform state backend (S3 recommended, local works for single-user).

## Phase 2: Deploy Infrastructure

Deploy in this exact order — later services depend on earlier ones.

### Step 1: Terraform Apply

```bash
gh workflow run deploy.yml -f action=terraform-apply
```

Monitor: `gh run list --workflow=deploy.yml --limit=1`

This creates: ECS cluster, ALB, RDS, ECR repos, ACM certs, Route53 records, security groups, IAM roles.

### Step 2: Deploy MCP Server

```bash
gh workflow run deploy.yml -f action=deploy-mcp-server
```

Verify: `curl https://mcp.YOUR-DOMAIN/health` → `{"status":"ok","tools":14}`

### Step 3: Deploy MCP Adapter

```bash
gh workflow run deploy.yml -f action=deploy-mcp-adapter
```

Verify: `curl https://adapter.YOUR-DOMAIN/.well-known/oauth-protected-resource` → JSON

### Step 4: Deploy Admin UI

```bash
gh workflow run deploy.yml -f action=deploy-mcp-admin-ui
```

Verify: `https://admin.YOUR-DOMAIN` loads the login page

### Step 5: Configure the Adapter

```bash
# Get the adapter admin password from Terraform state
cd terraform && terraform output -raw mcp_adapter_admin_password

# Login
TOKEN=$(curl -s -X POST https://adapter.YOUR-DOMAIN/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"YOUR-PASSWORD"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Create resource — resource_id MUST match auth server ID
curl -s -X POST https://adapter.YOUR-DOMAIN/api/admin/resources \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "mcp-tools",
    "resource_id": "YOUR-AUTH-SERVER-ID",
    "mcp_url": "https://mcp.YOUR-DOMAIN/mcp",
    "description": "Salesforce + ServiceNow MCP tools"
  }'
```

### Step 6: Import AI Agent via Admin UI

1. Navigate to `https://admin.YOUR-DOMAIN` and log in with Okta
2. Go to **Agents** > **Import from Okta**
3. Import your AI agent
4. Click **Sync All** to resolve managed connections
5. Verify resources show as "Linked"

### Step 7: Connect Claude Code

```bash
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN
```

**Do NOT pass --client-id** — the adapter handles CIMD-based registration.

## Tear Down

```bash
gh workflow run deploy.yml -f action=terraform-destroy
```

## Troubleshooting

| Issue | Fix |
|-------|-----|
| Workflow fails on ECR login | Check `AWS_ROLE_ARN` secret is set in the `mcp-demo` environment |
| Terraform state lock | Another workflow is running — wait 60s and retry |
| MCP server 503 | Container restarting — check CloudWatch `/ecs/mcp-server` |
| Adapter 502 | MCP server unreachable — verify health endpoint first |
| Admin UI 504 | Health check must be `/api/test-env`, not `/` |
| 0 tools in Claude Code | Check adapter logs, verify resource is synced in Admin UI |
| `invalid_scope` | Add `mcp:read` scope to your auth server |
| `access_denied` | Set policy client whitelist to `ALL_CLIENTS` |
| Adapter zip not found | Place `okta-agent-mcp-adapter*.zip` in repo root |

## Cost Estimate

| Resource | Monthly |
|----------|---------|
| ECS Fargate (3 services) | ~$30 |
| RDS PostgreSQL (db.t3.micro) | ~$15 |
| ALB | ~$20 |
| Route53 + ACM | ~$2 |
| **Total** | **~$67** |
