# MCP Adapter Setup — Lessons Learned & Gotchas

## For: SEs setting up the Okta MCP Adapter demo

These are hard-won learnings from the initial deployment. Read this before starting your setup to avoid hours of debugging.

---

## Okta Configuration Gotchas

### 1. Auth Server Access Policies Must Include All Client Apps

The custom auth server (`MCP Adapter Auth Server`) needs an access policy that whitelists **every OIDC app** that will authenticate through it. If you create a new app for a new AI agent, you must add its client ID to the policy.

```
Auth Server → Policies → MCP Adapter Access → Client Whitelist
Must include: MCP Adapter app, Claude Code Agent app, any future agent apps
```

**Symptom if missing:** `access_denied: Policy evaluation failed for this request`

### 2. Each AI Agent Needs Its Own OIDC App

Don't share OIDC apps between AI agents. Each agent in Okta (Directory > AI Agents) should have a **dedicated** OIDC app linked to it.

| Agent | OIDC App | Purpose |
|-------|----------|---------|
| Product Intelligence Agent | Custom OIDC app (first-party) | Bedrock dashboard SSO |
| Claude Code Agent | Claude Code Agent - MCP Client | Third-party MCP adapter auth |

**Why:** The adapter uses the agent's linked app for credential relay. If two agents share an app, the adapter can't distinguish which agent is connecting.

### 3. Redirect URIs for the Adapter BFF Pattern

The adapter uses a Backend-for-Frontend (BFF) OAuth pattern. Claude Code connects to the adapter, the adapter redirects to Okta, and Okta callbacks go to the **adapter's** callback URL (not Claude Code's localhost).

Required redirect URI on the agent's OIDC app:
```
https://adapter.YOUR-DOMAIN/oauth/callback
```

**Symptom if missing:** `400 Bad Request: redirect_uri parameter must be a Login redirect URI`

### 4. Wildcard Redirect URIs Don't Work for Ports

Okta's `wildcard_redirect: SUBDOMAIN` feature is for subdomain wildcards (e.g., `*.example.com`), NOT port wildcards. `http://localhost:*/callback` does NOT match dynamic ports.

**Solution:** Use the adapter's BFF pattern (callback goes to the adapter URL, not localhost). This is the correct architecture anyway.

### 5. Native App Type for Direct Claude Code Connection (Fallback)

If you need Claude Code to connect directly to Okta (without the adapter), create a **native** app type. Okta automatically allows any `http://localhost:{port}/callback` for native apps.

```bash
# Only needed as a fallback — prefer the adapter BFF pattern
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN
```

---

## Adapter Configuration Gotchas

### 6. CIMD Trust Policy for Claude Code

Claude Code identifies itself via CIMD (Client Instance Metadata Document) from `claude.ai`. The adapter must be configured to trust this domain and accept its redirect URI patterns.

Required env vars:
```
CIMD_ENABLED=true
CIMD_ALLOW_LOCALHOST=true
CIMD_REQUIRE_HTTPS=false
CIMD_TRUSTED_DOMAINS=claude.ai,anthropic.com
CIMD_ALLOWED_REDIRECT_PATTERNS=http://localhost/callback,http://127.0.0.1/callback,http://localhost:*/callback,http://127.0.0.1:*/callback
CIMD_TRUSTED_BACKEND_ACCESS=xaa-salesforce,xaa-servicenow,taskvantage-tools
CIMD_UNKNOWN_BACKEND_ACCESS=xaa-salesforce,xaa-servicenow,taskvantage-tools
```

**Symptom if missing:** `invalid_client: CIMD client rejected by trust policy`

The specific rejection reasons in the adapter logs tell you what to fix:
- `"no redirect_uris match allowed patterns"` → update `CIMD_ALLOWED_REDIRECT_PATTERNS`
- `"domain not trusted"` → update `CIMD_TRUSTED_DOMAINS`

### 7. OKTA_ISSUER Must Include Auth Server ID

The adapter needs `OKTA_ISSUER` pointing to the **custom auth server**, not just the org URL.

```
# Wrong:
OKTA_ISSUER=https://YOUR-ORG.okta.com

# Correct:
OKTA_ISSUER=https://YOUR-ORG.okta.com/oauth2/YOUR-AUTH-SERVER-ID
```

Also set `RELAY_OKTA_AUTH_SERVER_ID` to just the auth server ID:
```
RELAY_OKTA_AUTH_SERVER_ID=YOUR-AUTH-SERVER-ID
```

**Symptom if wrong:** Claude Code hits `/v1/authorize` (404) instead of `/oauth2/{serverId}/v1/authorize`

### 8. Agent Needs client_id and client_secret for Relay

The adapter's confidential relay pattern requires the agent's OIDC app credentials in the database. When you create an agent via the Admin API:

```json
{
  "agent_id": "claude-code",
  "client_id": "0oaXXXXXX",
  "client_secret": "ACTUAL_SECRET_HERE",
  "cimd_client_id": "https://claude.ai/oauth/claude-code-client-metadata",
  "enabled": true
}
```

**Symptom if missing:** `No relay credentials: agent must have client_id and client_secret configured in the database`

### 9. Don't Pass --client-id to Claude Code MCP Add

When using the adapter, let it handle OAuth via CIMD/DCR. Don't pass `--client-id`:

```bash
# Correct — adapter handles everything:
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN

# Wrong — bypasses adapter's BFF, goes directly to Okta:
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN --client-id 0oaXXX
```

Passing `--client-id` causes Claude Code to construct its own Okta authorize URL and go directly to Okta, bypassing the adapter entirely.

---

## Resource Syncer Gotchas

### 10. Resource IDs Must Match Auth Server IDs

The Okta Managed Connections syncer resolves connections to `resource_id` values derived from the auth server ID. Resources in the adapter must have `resource_id` matching the Okta auth server ID, not auto-generated UUIDs.

```bash
# When creating resources via Admin API, set resource_id explicitly:
curl -X POST /api/admin/resources -d '{
  "name": "xaa-salesforce",
  "resource_id": "YOUR-SF-AUTH-SERVER-ID",    # ← auth server ID!
  "mcp_url": "https://mcp.YOUR-DOMAIN/sse",
  "description": "Salesforce CRM tools"
}'
```

**Symptom if wrong:** `Resource ausXXXX not in Resources — unresolved` in adapter logs

### 11. Resources Show "Linked" But 0 Tools

If the Admin UI shows resources as "Linked" but Claude Code sees 0 tools:
1. Check that the **agent** (not just the resource) has `okta_ai_agent_id` set
2. Check that the agent's Okta AI agent has managed connections to the auth servers
3. Run "Sync All" from the Admin UI after any changes
4. Reconnect Claude Code after syncing

### 12. "Cannot hydrate resource — unknown connection type"

This means the syncer found the resource but doesn't know how to authenticate to it. Resources created via the Admin API without Okta managed connections show `source: resource-map-only` and can't be hydrated.

**Fix:** Import the AI agent from Okta via the Admin UI. The import brings in the managed connections which the syncer uses to resolve and hydrate resources.

### 13. Admin UI Import vs. API Import

The Admin UI's "Import from Okta" button uses the admin user's Okta OIDC token to call the Okta Management API. The adapter's own admin JWT (`/api/admin/login`) does NOT work for Okta imports.

**You must use the Admin UI** for imports — the API endpoint returns `okta_auth_required` with a plain admin JWT.

---

## Admin UI Gotchas

### 14. NEXT_PUBLIC_API_URL Must Be Set at Build Time

Next.js bakes `NEXT_PUBLIC_*` environment variables into the JavaScript bundle at build time. Setting them as ECS environment variables has no effect — they must be Docker build args.

```dockerfile
ARG NEXT_PUBLIC_API_URL=http://okta-agent-mcp-adapter:8000
ENV NEXT_PUBLIC_API_URL=${NEXT_PUBLIC_API_URL}
RUN npm run build
```

```bash
docker build --build-arg NEXT_PUBLIC_API_URL=https://adapter.YOUR-DOMAIN -t mcp-admin-ui .
```

**Symptom if wrong:** Admin UI returns 504 because API calls go to `okta-agent-mcp-adapter:8000` (Docker Compose hostname) which doesn't resolve in ECS.

### 15. Admin UI OIDC App Needs Okta API Scopes

The Admin UI app requires these Okta API scopes to manage AI agents:
- `okta.aiAgents.read`
- `okta.aiAgents.manage`
- `okta.apps.read`
- `okta.apps.manage`
- `okta.groups.read`
- `okta.authorizationServers.read`

Without these, the import and sync operations fail silently.

---

## FGA Gotchas

### 16. FGA Dashboard Tour Mode Overwrites Your Model

When you open the FGA Dashboard's Model Explorer for a **new store** for the first time, it forces a mandatory interactive tour that creates a sample `doc/folder` model. **This becomes the latest model.**

**Impact:** The MCP server uses an explicit `FGA_MODEL_ID` so existing checks still work. But the Dashboard UI shows the tour model as "latest."

**Recovery:** Re-run `python3 scripts/setup_fga.py` and update `FGA_MODEL_ID` in `src/fga.ts`.

---

## MCP Server & Protocol Gotchas

### 17. MCP Server Must Support JSON-RPC POST

The adapter POSTs standard MCP JSON-RPC messages to the `mcp_url`. It does NOT use SSE transport to communicate with the backend. The backend MCP server needs a `POST /mcp` endpoint that handles `initialize`, `tools/list`, and `tools/call` as plain JSON-RPC over HTTP.

**Symptom if wrong:** Adapter logs show connection errors or empty tool lists. If your backend only exposes `/sse`, the adapter cannot communicate with it.

### 18. Tool Schemas Must Be JSON Schema Format

The adapter (and Claude Code) expect `inputSchema` on each tool to be standard JSON Schema (`{type: "object", properties: {...}, required: [...]}`). If your MCP server uses Zod and serializes internal Zod structures instead of calling `.jsonSchema()`, the tools won't be recognized by Claude Code.

**Symptom if wrong:** Tools appear in the adapter but Claude Code reports 0 tools or fails to invoke them.

---

## Resource & Connection Gotchas (Continued)

### 19. Resource ID Must Match Auth Server ID

The Okta Managed Connections syncer resolves connections to `resource_id` values derived from the auth server ID. Resources created via the Admin API must have `resource_id` set to the Okta auth server ID (e.g., `YOUR-AUTH-SERVER-ID`), not auto-generated UUIDs.

**Symptom if wrong:** `Resource ausXXXX not in Resources — unresolved` in adapter logs during sync.

### 20. One Managed Connection Per MCP Server

Don't create separate managed connections for Salesforce and ServiceNow auth servers if they point to the same MCP server. Create ONE managed connection pointing to the MCP Adapter Auth Server. This gives the adapter a single resource to exchange tokens for and discover tools from. The backend MCP server handles routing to Salesforce and ServiceNow internally.

**Symptom if wrong:** Multiple unresolved resources in the syncer, confusing resource-to-tool mappings.

### 21. Auth Server Policy Must Allow ALL_CLIENTS

The jwt-bearer grant type in Step 3 of the XAA token exchange may use a different client_id than the authorization_code grant. Set the access policy's client whitelist to `ALL_CLIENTS` to avoid policy evaluation failures.

**Symptom if wrong:** `access_denied: Policy evaluation failed for this request` during Step 3 of XAA.

### 22. Add mcp:read Scope to Auth Server

The adapter's default agent scope is `mcp:read`. If your auth server doesn't have this scope, Step 3 of the XAA exchange fails. Create the scope on the auth server before deploying.

**Symptom if wrong:** `invalid_scope` error during token exchange.

### 23. ServiceNow Dev Instances Hibernate

ServiceNow PDIs (Personal Developer Instances) hibernate after a period of inactivity. Before any demo, wake the instance at developer.servicenow.com by clicking on it. If you see HTML responses instead of JSON from ServiceNow APIs, the instance is hibernating and needs to be woken up.

**Symptom:** ServiceNow tool calls return HTML login pages or 503 errors instead of JSON data.

### 24. Admin UI Health Check Must Avoid NextAuth

The ALB health check for the Admin UI must NOT hit `/` (which triggers NextAuth session validation and times out). Use `/api/test-env` instead.

**Symptom if wrong:** ALB marks the Admin UI target as unhealthy, returning 502/503 to users even though the app is running.

### 25. Don't Pass --client-id to Claude Code

When connecting Claude Code to the adapter, do NOT pass `--client-id`. The adapter handles client registration via CIMD (Client Instance Metadata Document). Passing a client_id causes Claude Code to bypass the adapter's BFF pattern and go directly to Okta, which fails.

```bash
# Correct:
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN

# Wrong:
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN --client-id 0oaXXX
```

**Symptom if wrong:** Claude Code constructs its own Okta authorize URL, bypassing the adapter entirely. Authentication fails or succeeds but tools are empty.

---

## ECS Infrastructure Stability

### 26. Inline SG Rules, Not Standalone

When a security group has inline `ingress` blocks in Terraform, do NOT add standalone `aws_vpc_security_group_ingress_rule` resources for the same SG. Terraform treats inline rules as authoritative and silently deletes standalone rules on every apply. All ports (8000, 8080, 3000, 3001) must be inline in the fargate SG definition in `main.tf`.

**Symptom:** MCP Server 504s after every Terraform apply. Port 3000 SG rule is deleted.

### 27. Blue/Green Deployment for ECS

Set `deployment_minimum_healthy_percent = 100` and `deployment_maximum_percent = 200` on all ECS services. With `desired_count = 1` and the defaults (min=100, max=200 isn't set by default on Fargate), ECS drains the old task before the new one is healthy, causing a gap with zero targets. The explicit settings ensure the new task starts alongside the old one.

**Symptom:** Services alternate between healthy and unhealthy during deploys (seesaw pattern).

### 28. Admin UI Needs 1024 MB Memory

The Next.js Admin UI with NextAuth and server-side rendering needs at least 1024 MB to avoid OOM kills. At 512 MB, the container gets killed by the OOM killer before health checks can pass, causing a restart loop.

**Symptom:** Admin UI container starts ("Ready in 500ms") but never passes health checks and keeps cycling.

### 29. CloudWatch Dashboard for Demo Health

A CloudWatch dashboard (`MCP-Demo-Health`) monitors all services. Alarms fire to SNS → ntfy when any service goes unhealthy. Dashboard URL: `https://us-east-2.console.aws.amazon.com/cloudwatch/home?region=us-east-2#dashboards:name=MCP-Demo-Health`

---

## Deployment Order

When setting up from scratch, deploy in this order to avoid dependency issues:

1. **Okta config** — auth server, scopes, groups, policies, OIDC apps, AI agents, managed connections
2. **MCP Server** — deploy to ECS, verify `/health` returns 14 tools
3. **MCP Adapter** — deploy to ECS, verify `/.well-known/oauth-protected-resource` returns JSON
4. **Admin UI** — deploy with correct `NEXT_PUBLIC_API_URL` build arg
5. **Admin UI: Import agents** — import AI agents from Okta, sync connections
6. **Admin UI: Create resources** — with `resource_id` matching auth server IDs
7. **Admin UI: Sync All** — resolve connections to resources
8. **Claude Code** — `claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN`

---

## Quick Diagnostic Commands

```bash
# Check adapter health
curl https://adapter.YOUR-DOMAIN/.well-known/oauth-protected-resource

# Check adapter discovery doc (issuer should include auth server ID)
curl https://adapter.YOUR-DOMAIN/.well-known/oauth-authorization-server | python3 -m json.tool

# Check MCP server health
curl https://mcp.YOUR-DOMAIN/health

# Login to adapter admin API
TOKEN=$(curl -s -X POST https://adapter.YOUR-DOMAIN/api/admin/login \
  -H "Content-Type: application/json" \
  -d '{"username":"admin","password":"YOUR-PASSWORD"}' \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")

# List agents
curl -s https://adapter.YOUR-DOMAIN/api/admin/agents -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

# List resources
curl -s https://adapter.YOUR-DOMAIN/api/admin/resources -H "Authorization: Bearer $TOKEN" | python3 -m json.tool

# Check adapter logs for errors (AWS)
aws logs filter-log-events --log-group-name /ecs/mcp-adapter --region us-east-2 \
  --start-time $(python3 -c "import time; print(int((time.time()-300)*1000))") \
  --query 'events[*].message' --output text | tr '\t' '\n' | grep -i "error\|reject\|denied\|unresolved"
```
