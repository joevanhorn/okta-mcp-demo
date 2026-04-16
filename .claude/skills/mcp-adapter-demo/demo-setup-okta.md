---
name: demo-setup-okta
description: Configure Okta auth server, groups, policies, and AI agents for the MCP Adapter demo
user-invocable: true
---

# Okta Configuration for MCP Adapter Demo

You are helping an SE configure their Okta org for the MCP Adapter demo. This creates the auth server, groups, access policies, OIDC apps, and AI agent configuration.

## What You Need From the User

1. **Okta org domain** (e.g., `myorg.okta.com`)
2. **Okta API token** (SSWS format)
3. **Terraform environment name** in the repo (e.g., `YOUR-ENV`)
4. Whether they want to use **Terraform** (recommended) or **manual API calls**

## Steps

### Step 1: Create Auth Server + Scopes

The Terraform file `environments/{env}/terraform/mcp_cowork.tf` creates everything. If deploying via Terraform:

```bash
gh workflow run tf-apply.yml -f environment=YOUR-ENV
```

If doing manually via API, create:
- Custom auth server named "MCP Adapter Auth Server"
- 5 scopes: `sfdc:read`, `sfdc:write`, `snow:read`, `snow:write`, `mcp:read`
  - **Critical**: `mcp:read` is required — the adapter requests it by default

### Step 2: Create Groups

Create 4 groups:
- `Cowork-CRM-Read`
- `Cowork-CRM-Write`
- `Cowork-ITSM-Read`
- `Cowork-ITSM-Write`

### Step 3: Create Access Policies

**Critical rules:**
- Client whitelist MUST be `ALL_CLIENTS` (not specific client IDs)
- Must allow both `authorization_code` and `urn:ietf:params:oauth:grant-type:jwt-bearer` grant types
- Include `mcp:read` in all scope grants
- Most-permissive rules first (lower priority number)

### Step 4: Create OIDC Apps

Create two apps:
1. **MCP Adapter App** — for agent auth relay
   - Grant types: authorization_code, jwt-bearer
   - Redirect URI: `https://adapter.YOUR-DOMAIN/oauth/callback`
   - Assign to Everyone group

2. **Admin UI App** — for admin console SSO
   - Grant types: authorization_code, refresh_token
   - Redirect URI: `https://admin.YOUR-DOMAIN/api/auth/callback/okta`
   - API scopes: `okta.aiAgents.read`, `okta.aiAgents.manage`, `okta.apps.read`, `okta.apps.manage`, `okta.groups.read`, `okta.authorizationServers.read`

### Step 5: Create AI Agent

1. Go to **Directory > AI Agents > Create AI Agent**
2. Create a **dedicated OIDC app** for the agent (do NOT share with other agents)
3. Link the OIDC app to the AI agent
4. Register the agent's public key as credentials
5. Add ONE managed connection pointing to the **MCP Adapter Auth Server**
   - Do NOT create separate connections for each backend system

### Step 6: Create OIG Access Request Catalog Items

| Request Type | Grants Group | Approval | Duration |
|---|---|---|---|
| Cowork: CRM Read Access | Cowork-CRM-Read | Manager | Persistent |
| Cowork: CRM Write Access | Cowork-CRM-Write | Manager + App Owner | 8 hours |
| Cowork: ITSM Read Access | Cowork-ITSM-Read | Manager | Persistent |
| Cowork: ITSM Write Access | Cowork-ITSM-Write | Manager + App Owner | 8 hours |

## Critical Gotchas

- **ALL_CLIENTS policy**: The jwt-bearer grant in XAA Step 3 uses a different client_id. Specific client IDs cause `access_denied`.
- **mcp:read scope**: Missing this causes `invalid_scope` during token exchange.
- **One managed connection**: Multiple connections to the same MCP server cause unresolved resources.
- **Dedicated OIDC app per agent**: Shared apps prevent the adapter from distinguishing agents.
- **Redirect URI**: Must include `https://adapter.YOUR-DOMAIN/oauth/callback` on the agent's OIDC app.

## Verification

```bash
# Check auth server
curl -s "https://YOUR-ORG.okta.com/api/v1/authorizationServers" \
  -H "Authorization: SSWS TOKEN" | python3 -c "import sys,json; [print(f'{s[\"name\"]}: {s[\"id\"]}') for s in json.load(sys.stdin)]"

# Check groups
curl -s "https://YOUR-ORG.okta.com/api/v1/groups?q=Cowork" \
  -H "Authorization: SSWS TOKEN" | python3 -c "import sys,json; [print(g['profile']['name']) for g in json.load(sys.stdin)]"
```
