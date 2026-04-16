---
name: demo-setup-fga
description: Set up Okta FGA authorization model and tuples for per-tool and per-resource checks
user-invocable: true
---

# FGA Setup

You are helping an SE set up Okta Fine-Grained Authorization for the MCP Adapter demo. This creates the authorization model, writes relationship tuples, and verifies per-tool and per-resource checks.

## What You Need From the User

1. **FGA tenant** — create at https://dashboard.fga.dev (free)
2. **Store ID** from the FGA dashboard
3. **Client ID and Client Secret** from the FGA dashboard API credentials

## Steps

### Step 1: Update FGA Credentials

Edit `environments/ai-agent-demo/mcp-server/scripts/setup_fga.py` and update:
```python
FGA_API_URL = "https://api.us1.fga.dev"
FGA_STORE_ID = "YOUR-STORE-ID"
FGA_CLIENT_ID = "YOUR-CLIENT-ID"
FGA_CLIENT_SECRET = "YOUR-CLIENT-SECRET"
```

Also update `environments/ai-agent-demo/mcp-server/src/fga.ts` with the same values.

### Step 2: Run the Setup Script

```bash
cd environments/ai-agent-demo/mcp-server
python3 scripts/setup_fga.py
```

This creates:
- **Authorization model** with 5 types: user, team, tool, sfdc_account, snow_incident
- **67 tuples** covering teams, tool permissions, account ownership, incident access
- **7 verification checks** to confirm the model works

### Step 3: Verify

All 7 checks should pass:
```
PASS: deku (product)     → can_invoke_read  → search_accounts     = True
PASS: deku (product)     → can_invoke_write → create_opportunity  = False
PASS: deku (product)     → viewer           → acme-corp           = True
PASS: derek (sales)      → owner            → acme-corp           = True
PASS: derek (sales)      → owner            → northstar-insurance = False
PASS: bernie (sales)     → editor           → northstar-insurance = True
PASS: joe (leadership)   → can_invoke_write → update_opportunity  = True
```

### Step 4: Update Model ID

The script prints the new model ID. Update it in:
- `src/fga.ts` — the `FGA_MODEL_ID` constant
- Redeploy the MCP server

### Step 5: Deploy MCP Server with FGA

```bash
gh workflow run supersafe-ai-webapp-deploy.yml -f action=deploy-mcp-server
```

### Step 6: Test FGA at Runtime

```bash
# Deku (product) reads accounts — ALLOWED
curl -s -X POST https://mcp.YOUR-DOMAIN/api/tool \
  -H "Content-Type: application/json" \
  -H "X-User-Email: deku.midoriya@taskvantage.ai" \
  -d '{"name":"search_accounts","args":{"query":"Acme"}}'

# Deku creates opportunity — DENIED
curl -s -X POST https://mcp.YOUR-DOMAIN/api/tool \
  -H "Content-Type: application/json" \
  -H "X-User-Email: deku.midoriya@taskvantage.ai" \
  -d '{"name":"create_opportunity","args":{"name":"Test","account_name":"Acme","stage":"Prospecting","amount":100,"close_date":"2026-12-31"}}'
```

## Granting/Revoking User Access

After OIG approves an access request, sync FGA tuples:

```bash
# Grant CRM read access
python3 scripts/fga_webhook.py --action grant --user USER@EMAIL --level crm-read

# Grant all access
python3 scripts/fga_webhook.py --action grant --user USER@EMAIL --level all

# Revoke all access
python3 scripts/fga_webhook.py --action revoke --user USER@EMAIL
```

Available levels: `crm-read`, `crm-write`, `itsm-read`, `itsm-write`, `all`

## FGA Dashboard Tour Mode Warning

When you open the FGA Dashboard's Model Explorer for a **new store** for the first time, it forces a mandatory tour that creates a sample `doc/folder` model, overwriting yours. Re-run `setup_fga.py` to restore and update the model ID.

## The Three Authorization Layers

```
Layer 1: Okta Auth Server (scopes)     → Can the user access SF/SNOW tools at all?
Layer 2: MCP Server (scope filter)     → Which specific tools can they see?
Layer 3: Okta FGA (relationship check) → Can they act on THIS specific resource?
```

FGA adds Layer 3 — the per-resource check that scopes cannot express.
