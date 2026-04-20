# Okta MCP Adapter Demo — Build & Setup Guide

## For: Okta Solutions Engineers

This guide walks you through setting up the full Okta MCP Adapter demo from scratch, including Salesforce + ServiceNow data, Okta configuration, FGA authorization, and the MCP adapter deployment. Estimated setup time: 2-3 hours (mostly waiting for deployments).

---

## Prerequisites

### Accounts & Access

| Requirement | Details |
|-------------|---------|
| Okta OIE org | With OIG (Identity Governance) and AI Agents feature enabled |
| Salesforce dev org | Free developer org from developer.salesforce.com works fine |
| ServiceNow dev instance | Free PDI from developer.servicenow.com |
| AWS account | For ECS deployment (Fargate). ~$5/day for all services |
| Okta FGA tenant | Free at dashboard.fga.dev |
| GitHub repo | Fork or clone `joevanhorn/ofcto-workforce-taskvantage` |

### Local Tools (on your demo machine)

| Tool | Version | Install |
|------|---------|---------|
| Claude Code CLI | v2.1.30+ | `npm install -g @anthropic-ai/claude-code` |
| Node.js | 18+ | `brew install node` or `nvm install 20` |
| Python | 3.10+ | `brew install python3` |
| AWS CLI | v2 | `brew install awscli` |
| Terraform | 1.9+ | `brew install terraform` |
| gh CLI | latest | `brew install gh` |

---

## Phase 1: Seed Demo Data (30 minutes)

### 1.1 Salesforce Connected App

1. Log into your Salesforce dev org
2. **Setup > App Manager > New Connected App**
   - Name: `MCP Demo Data Seeder`
   - Enable OAuth: Yes
   - Callback URL: `https://login.salesforce.com/services/oauth2/callback`
   - Scopes: `api`, `refresh_token, offline_access`
3. Save, then **Manage > Edit Policies**:
   - Under **Client Credentials Flow**, set **Run As** to your admin user
4. Note the **Client ID** and **Client Secret**

### 1.2 ServiceNow Credentials

1. Go to your ServiceNow developer portal (developer.servicenow.com)
2. Get the **admin username and password** for your PDI
3. Verify API access: `curl -u admin:PASSWORD https://YOUR-INSTANCE.service-now.com/api/now/table/incident?sysparm_limit=1`

### 1.3 Run the Seeding Script

```bash
cd environments/ai-agent-demo/bedrock-agent/scripts

python3 seed_demo_data.py --mode dry-run  # preview first

python3 seed_demo_data.py --mode populate --target both \
  --sf-instance-url https://YOUR-ORG.develop.my.salesforce.com \
  --sf-client-id YOUR_CLIENT_ID \
  --sf-client-secret YOUR_CLIENT_SECRET \
  --snow-instance-url https://YOUR-INSTANCE.service-now.com \
  --snow-user admin \
  --snow-password 'YOUR_PASSWORD'
```

Expected output: 5 Salesforce accounts, 5 opportunities, 5 ServiceNow incidents, 6 enhancement requests.

### 1.4 Verify Data

```bash
# Salesforce
python3 seed_demo_data.py --mode dry-run --target salesforce  # should list 5 accounts

# ServiceNow
curl -s -u admin:PASSWORD \
  'https://YOUR-INSTANCE.service-now.com/api/now/table/incident?sysparm_query=numberSTARTSWITHINC-4&sysparm_limit=5' \
  -H 'Accept: application/json' | python3 -m json.tool | head -20
```

---

## Phase 2: Okta Configuration (30 minutes)

### 2.1 Custom Authorization Server

Deploy via Terraform (recommended) or create manually:

```bash
# Via Terraform
gh workflow run tf-apply.yml -f environment=YOUR-ENV \
  -f targets="okta_auth_server.mcp_adapter,okta_auth_server_scope.sfdc_read,okta_auth_server_scope.sfdc_write,okta_auth_server_scope.snow_read,okta_auth_server_scope.snow_write"
```

Or manually in Admin Console:
1. **Security > API > Authorization Servers > Add Authorization Server**
   - Name: `MCP Adapter Auth Server`
   - Audience: `https://mcp.YOUR-DOMAIN`
2. Add 5 scopes: `sfdc:read`, `sfdc:write`, `snow:read`, `snow:write`, `mcp:read` (all Implicit consent)
   > **Note:** The adapter requests `mcp:read` by default as its agent scope. If this scope is missing, Step 3 of the XAA token exchange fails with `invalid_scope`.

### 2.2 Groups

Create 4 groups (Terraform or Admin Console):
- `Cowork-CRM-Read` — Salesforce read-only tool access
- `Cowork-CRM-Write` — Salesforce read + write tool access
- `Cowork-ITSM-Read` — ServiceNow read-only tool access
- `Cowork-ITSM-Write` — ServiceNow read + write tool access

### 2.3 Access Policies

On the auth server, create two policies:

**CRM Access** (client whitelist: `ALL_CLIENTS`):
- Rule 1 (priority 1): If user in `Cowork-CRM-Write` → grant `sfdc:read sfdc:write mcp:read`
- Rule 2 (priority 2): If user in `Cowork-CRM-Read` → grant `sfdc:read mcp:read`

**ITSM Access** (client whitelist: `ALL_CLIENTS`):
- Rule 1 (priority 1): If user in `Cowork-ITSM-Write` → grant `snow:read snow:write mcp:read`
- Rule 2 (priority 2): If user in `Cowork-ITSM-Read` → grant `snow:read mcp:read`

> **Important:** Most-permissive rules must have lower priority numbers. Okta stops at the first match.

> **Critical:** The access policy's client whitelist MUST be set to `ALL_CLIENTS`, not specific client IDs. The jwt-bearer grant type used in Step 3 of the XAA token exchange may use a different client_id than the authorization_code grant. Setting specific client IDs causes `access_denied: Policy evaluation failed` errors.

> **Grant types required:** Each policy rule must allow both `authorization_code` and `jwt-bearer` grant types to support the full XAA flow.

### 2.4 OIDC Applications

Create two OIDC apps:

**MCP Adapter App** (for agent auth):
- Type: Web
- Grant types: Authorization Code, jwt-bearer
- Redirect URI: `https://adapter.YOUR-DOMAIN/oauth/callback`
- Auth method: client_secret_basic
- Assign to: Everyone group

**Admin UI App** (for admin console):
- Type: Web
- Grant types: Authorization Code, Refresh Token
- Redirect URI: `https://admin.YOUR-DOMAIN/api/auth/callback/okta`
- Logout URI: `https://admin.YOUR-DOMAIN/login`
- Okta API Scopes: `okta.aiAgents.read`, `okta.aiAgents.manage`, `okta.apps.read`, `okta.apps.manage`, `okta.groups.read`, `okta.authorizationServers.read`

### 2.5 OIG Access Request Catalog Items

Create request types for each entitlement:

| Request Type | Grants Group | Approval | Time-Bound |
|---|---|---|---|
| Cowork: CRM Read Access | Cowork-CRM-Read | Manager | No (persistent) |
| Cowork: CRM Write Access | Cowork-CRM-Write | Manager + App Owner | Yes (default 8h) |
| Cowork: ITSM Read Access | Cowork-ITSM-Read | Manager | No (persistent) |
| Cowork: ITSM Write Access | Cowork-ITSM-Write | Manager + App Owner | Yes (default 8h) |

---

## Phase 2.5: Okta AI Agent Setup (15 minutes)

### 2.5.1 Create AI Agent

1. In Okta Admin Console, go to **Directory > AI Agents**
2. Click **Create AI Agent**
3. Name it (e.g., "Claude Code Agent")

### 2.5.2 Create Dedicated OIDC App for the Agent

Each AI agent needs its own dedicated OIDC app — do NOT share OIDC apps between agents. The adapter uses the agent's linked app for credential relay, so sharing apps prevents the adapter from distinguishing which agent is connecting.

1. Create a new OIDC app (see Section 2.4 "MCP Adapter App" above for settings)
2. Ensure the redirect URI includes `https://adapter.YOUR-DOMAIN/oauth/callback`

### 2.5.3 Link the OIDC App to the AI Agent

1. Go back to **Directory > AI Agents**, select your agent
2. Under **Credentials**, link the OIDC app you created
3. Register the agent's public key as credentials (if using jwt-bearer grant)

### 2.5.4 Add Managed Connection

1. On the AI Agent page, add a **Managed Connection**
2. Point it to the **MCP Adapter Auth Server** (the custom auth server from Phase 2.1)
3. This gives the adapter a single resource to exchange tokens for and discover tools from
4. Do NOT create separate managed connections for each backend system (Salesforce, ServiceNow) — create ONE pointing to the adapter auth server

---

## Phase 3: Deploy Infrastructure (45 minutes)

### 3.1 MCP Server

The MCP server provides 14 tools (7 Salesforce, 7 ServiceNow) with scope-based filtering and FGA checks.

```bash
# Deploy ECS infrastructure
gh workflow run supersafe-ai-webapp-deploy.yml -f action=terraform-apply

# Build and deploy MCP server container
gh workflow run supersafe-ai-webapp-deploy.yml -f action=deploy-mcp-server
```

Verify: `curl https://mcp.YOUR-DOMAIN/health` should return `{"status":"ok","tools":14}`

### 3.2 MCP Adapter

The adapter is the Okta-delivered OAuth gateway (v0.14.0).

```bash
# Deploy adapter container
gh workflow run supersafe-ai-webapp-deploy.yml -f action=deploy-mcp-adapter
```

Verify: `curl https://adapter.YOUR-DOMAIN/.well-known/oauth-protected-resource` should return JSON.

### 3.3 Admin UI

```bash
# Deploy admin UI container
gh workflow run supersafe-ai-webapp-deploy.yml -f action=deploy-mcp-admin-ui
```

Verify: `https://admin.YOUR-DOMAIN` loads the login page. The ALB health check must target `/api/test-env` (not `/`, which triggers NextAuth session validation and times out).

### 3.4 Configure the Adapter

```bash
# Login to the Admin API
TOKEN=$(curl -s -X POST https://adapter.YOUR-DOMAIN/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"YOUR-ADMIN-PASSWORD"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# Add MCP server as a resource
# CRITICAL: resource_id MUST match your Okta auth server ID — the managed connections
# syncer resolves connections to resource_id values derived from the auth server ID.
curl -s -X POST https://adapter.YOUR-DOMAIN/api/admin/resources \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "name": "taskvantage-tools",
    "resource_id": "YOUR-AUTH-SERVER-ID",
    "mcp_url": "https://mcp.YOUR-DOMAIN/mcp",
    "paths": ["/taskvantage"],
    "auth_method": "bearer-passthrough",
    "auth_config": {},
    "description": "Salesforce + ServiceNow MCP tools"
  }'

# Add Claude Code as an agent
curl -s -X POST https://adapter.YOUR-DOMAIN/api/admin/agents \
  -H "Authorization: Bearer $TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "agent_id": "claude-code",
    "client_id": "YOUR-OIDC-APP-CLIENT-ID",
    "client_secret": "ACTUAL-SECRET",
    "private_key": "{}",
    "resource_access": ["taskvantage-tools"],
    "enabled": true
  }'
```

### 3.5 Import AI Agents and Sync Connections

1. Log into the Admin UI at `https://admin.YOUR-DOMAIN` using your Okta credentials
2. Navigate to **Agents** and click **Import from Okta** — this uses your Okta OIDC token to call the Management API (the adapter's admin JWT does NOT work for imports)
3. Select the AI agents to import — the import brings in managed connections which the syncer uses to resolve and hydrate resources
4. Click **Sync All** to resolve connections to resources
5. Verify resources show as "Linked" with the correct tool count

> **Note:** Create ONE managed connection pointing to the MCP Adapter Auth Server. Do not create separate managed connections for each backend system (Salesforce, ServiceNow) if they all point to the same MCP server.

---

## Phase 4: Okta FGA Setup (15 minutes)

### 4.1 Create FGA Store

1. Go to https://dashboard.fga.dev
2. Create a new store (or use existing)
3. Note the **Store ID**, **Client ID**, and **Client Secret**

> **WARNING:** When you open the Model Explorer for the first time, FGA forces a mandatory tour that creates a sample doc/folder model. This overwrites your active model. Always re-run the setup script after the tour.

### 4.2 Write Model and Tuples

```bash
cd environments/ai-agent-demo/mcp-server

# Update the FGA credentials in scripts/setup_fga.py with your store details

python3 scripts/setup_fga.py
```

Expected output: model created, 67 tuples written, 7/7 verification checks passing.

### 4.3 Update MCP Server

Update `src/fga.ts` with your FGA credentials and model ID, then redeploy:

```bash
gh workflow run supersafe-ai-webapp-deploy.yml -f action=deploy-mcp-server
```

---

## Phase 5: Demo Machine Setup (15 minutes)

### 5.1 Install Claude Code

```bash
# macOS
npm install -g @anthropic-ai/claude-code

# Verify
claude --version
```

### 5.2 Connect to the Adapter

```bash
# Add the adapter as an MCP server — NO --client-id flag!
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN
```

> **Critical:** Do NOT pass `--client-id` to `claude mcp add`. The adapter handles client registration automatically via CIMD (Client Instance Metadata Document). Passing a client_id causes Claude Code to bypass the adapter's BFF pattern and go directly to Okta, which fails.

When you run `claude`, it will:
1. Connect to the adapter via HTTP transport
2. The adapter handles CIMD-based client registration automatically
3. Adapter initiates PKCE auth → your browser opens Okta login
4. Authenticate with MFA
5. Token returned to adapter → tools appear based on your scopes

### 5.3 Local Fallback (if adapter connection fails)

The repo includes `.mcp.json` for direct MCP server access:

```bash
cd /path/to/ofcto-workforce-taskvantage
claude  # auto-detects .mcp.json, connects via stdio
```

This bypasses the adapter (no OAuth flow) but gives you all 14 tools for demonstrating the data and FGA.

### 5.4 Pre-Demo Verification

```bash
# Wake ServiceNow dev instance (they hibernate after inactivity!)
# Go to developer.servicenow.com and click your instance to wake it

# Verify MCP server health
curl https://mcp.YOUR-DOMAIN/health
# Expected: {"status":"ok","tools":14}

# Verify adapter health
curl https://adapter.YOUR-DOMAIN/.well-known/oauth-protected-resource
# Expected: JSON document

# Verify Admin UI
# Open https://admin.YOUR-DOMAIN in a browser

# In Claude Code, verify tools are available:
# Type: "What tools do you have available?"
# Expected: list of search_accounts, get_account_details, etc.

# Test a real query:
# Type: "Search for Acme Corp in Salesforce"
# Expected: real Salesforce data with account details

# Test FGA (if connected as a read-only user):
# Type: "Create a new opportunity for Acme Corp"
# Expected: tool not available or FGA denial
```

---

## Customization Guide

### Using Your Own Data

Edit `environments/ai-agent-demo/bedrock-agent/config/demo_data_seed.yaml`:
- Change company names, industries, revenue figures
- Adjust incident descriptions and priorities
- Modify enhancement requests to match your prospect's product interests
- Re-run the seeding script

### Adding New Tools

Edit `environments/ai-agent-demo/mcp-server/src/tools/`:
- Create a new directory for the system (e.g., `jira/`)
- Add `client.ts` (API client) and `index.ts` (tool registrations)
- Import in `src/index.ts`
- Add corresponding FGA tuples in `scripts/setup_fga.py`

### Changing the FGA Model

Edit `scripts/setup_fga.py`:
- Add new types (e.g., `jira_project`)
- Add new relations (e.g., `contributor`, `admin`)
- Add new tuples for your demo users
- Re-run the script (creates a new model version)

---

## Troubleshooting

| Issue | Fix |
|-------|-----|
| MCP server returns 0 tools | Check that the user has Cowork group membership in Okta |
| FGA checks fail | Re-run `setup_fga.py` — tour mode may have overwritten the model |
| Adapter returns 503 | ECS task may be starting — check CloudWatch logs `/ecs/mcp-adapter` |
| Salesforce auth fails | Verify connected app has client credentials flow enabled with a Run As user |
| ServiceNow returns 401 | Verify local admin credentials (not federated Okta user) |
| ServiceNow returns HTML instead of JSON | Dev instance is hibernating — wake it at developer.servicenow.com before the demo |
| State lock errors in Terraform | Wait 60s and retry — another workflow may be running |
| Claude Code shows no tools | Restart Claude Code, verify `.mcp.json` exists in the repo root |
| MCP Server 504 after TF apply | SG rule for port 3000 deleted — must be inline in main.tf, not standalone |
| Admin UI restart loop | Increase memory to 1024 MB in task definition |
| Services seesaw during deploy | Add deployment_minimum_healthy_percent=100 to ECS services |

---

## Cost Estimate

| Resource | Monthly Cost |
|----------|-------------|
| ECS Fargate (5 services × 0.25 vCPU) | ~$45 |
| RDS PostgreSQL (db.t3.micro) | ~$15 |
| ALB | ~$20 |
| Route53 + ACM | ~$2 |
| ECR storage | ~$1 |
| **Total** | **~$83/month** |

Tear down with: `gh workflow run supersafe-ai-webapp-deploy.yml -f action=terraform-destroy`
