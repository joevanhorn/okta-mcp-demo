---
name: demo-setup-infra
description: Deploy MCP Server, Adapter, and Admin UI to AWS ECS for the MCP Adapter demo
user-invocable: true
---

# Deploy Infrastructure

You are helping an SE deploy the MCP Adapter demo infrastructure to AWS ECS. This deploys 3 services on the existing supersafe-ai ECS cluster.

## What You Need From the User

1. **AWS access** — the GitHub Actions workflows handle deployment via OIDC. The user needs the repo with workflows configured.
2. **Domain** — a domain with Route53 hosted zone (e.g., `YOUR-DOMAIN`)
3. **Okta configuration** from the previous step (auth server ID, OIDC app credentials)

## Deployment Order

Deploy in this exact order — later services depend on earlier ones.

### Step 1: Terraform Apply (creates all AWS resources)

```bash
gh workflow run supersafe-ai-webapp-deploy.yml -f action=terraform-apply
```

This creates:
- ECR repos (mcp-server, mcp-adapter, mcp-admin-ui)
- ECS task definitions + services
- ALB listener rules for mcp.DOMAIN, adapter.DOMAIN, admin.DOMAIN
- ACM certificates + Route53 records
- Security group rules
- CloudWatch log groups

### Step 2: Deploy MCP Server

```bash
gh workflow run supersafe-ai-webapp-deploy.yml -f action=deploy-mcp-server
```

Verify: `curl https://mcp.YOUR-DOMAIN/health` → `{"status":"ok","tools":14}`

### Step 3: Deploy MCP Adapter

```bash
gh workflow run supersafe-ai-webapp-deploy.yml -f action=deploy-mcp-adapter
```

Verify: `curl https://adapter.YOUR-DOMAIN/.well-known/oauth-protected-resource` → JSON

### Step 4: Deploy Admin UI

```bash
gh workflow run supersafe-ai-webapp-deploy.yml -f action=deploy-mcp-admin-ui
```

Verify: `https://admin.YOUR-DOMAIN` loads the login page

**Note**: The Admin UI health check must target `/api/test-env`, not `/` (NextAuth session validation times out on `/`).

### Step 5: Configure the Adapter

```bash
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

### Step 6: Import AI Agents via Admin UI

1. Log into `https://admin.YOUR-DOMAIN` with Okta
2. Go to **Agents** → **Import from Okta**
3. Import your AI agent
4. Click **Sync All** to resolve managed connections
5. Verify resources show as "Linked"

### Step 7: Connect Claude Code

On the demo machine:
```bash
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN
```

**Do NOT pass --client-id** — the adapter handles CIMD-based registration.

## Troubleshooting

| Issue | Fix |
|-------|-----|
| MCP server 503 | Container restarting — wait 60s, check CloudWatch `/ecs/mcp-server` |
| Adapter 502 | MCP server unreachable — verify health endpoint first |
| Admin UI 504 | Health check hitting `/` — must be `/api/test-env` |
| 0 tools in Claude Code | Check adapter logs for XAA errors, verify resource is synced |
| `subject_token is invalid` | Auth server issuer mismatch — use org auth server |
| `invalid_scope` | Add `mcp:read` scope to auth server |
| `access_denied: Policy evaluation failed` | Set policy client whitelist to `ALL_CLIENTS` |
| State lock errors | Wait 60s and retry — another TF workflow is running |

## Key Env Vars (Adapter ECS Task)

```
OKTA_DOMAIN=your-org.okta.com
OKTA_ISSUER=https://your-org.okta.com
RELAY_OKTA_AUTH_SERVER_ID=org
GATEWAY_BASE_URL=https://adapter.YOUR-DOMAIN
CACHE_PROVIDER=memory
CIMD_ENABLED=true
CIMD_TRUSTED_DOMAINS=claude.ai,anthropic.com
CIMD_ALLOWED_REDIRECT_PATTERNS=http://localhost/callback,http://127.0.0.1/callback,http://localhost:*/callback
```
