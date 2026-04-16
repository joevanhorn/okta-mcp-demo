---
name: demo-verify
description: Run all health checks and verification for the MCP Adapter demo before presenting
user-invocable: true
---

# Pre-Demo Verification

You are helping an SE verify their MCP Adapter demo is ready before presenting. Run all checks and report the status.

## Run These Checks

Execute all of the following and report results in a summary table.

### 1. Wake ServiceNow (FIRST!)

ServiceNow dev instances hibernate. The user must wake it at developer.servicenow.com before proceeding. Ask them to confirm it's awake, then verify:

```bash
curl -s -u 'SNOW_USER:SNOW_PASS' \
  'https://SNOW_INSTANCE.service-now.com/api/now/table/incident?sysparm_limit=1&sysparm_fields=number' \
  -H 'Accept: application/json'
```

If you get HTML back, the instance is still hibernating.

### 2. MCP Server Health

```bash
curl -s https://mcp.DOMAIN/health
```

Expected: `{"status":"ok","tools":14}`

### 3. MCP Adapter Health

```bash
curl -s https://adapter.DOMAIN/.well-known/oauth-protected-resource
```

Expected: JSON with `resource` and `authorization_servers` fields.

### 4. Admin UI

```bash
curl -s -o /dev/null -w "%{http_code}" https://admin.DOMAIN/api/test-env
```

Expected: `200`

### 5. Salesforce Data

```bash
curl -s -X POST https://mcp.DOMAIN/api/tool \
  -H "Content-Type: application/json" \
  -d '{"name":"search_accounts","args":{"query":"Acme"}}' | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Accounts: {len(d.get(\"accounts\",[]))}')
for a in d.get('accounts',[]):
    print(f'  {a[\"name\"]} ({a[\"industry\"]})')
"
```

Expected: Acme Corp (Technology)

### 6. ServiceNow Data

```bash
curl -s -X POST https://mcp.DOMAIN/api/tool \
  -H "Content-Type: application/json" \
  -d '{"name":"search_incidents","args":{"query":"Acme","priority":"all"}}' | python3 -c "
import sys,json; d=json.load(sys.stdin)
print(f'Incidents: {len(d.get(\"incidents\",[]))}')
for i in d.get('incidents',[]):
    print(f'  {i[\"number\"]}: {i[\"short_description\"][:50]}')
"
```

Expected: 3 Acme Corp incidents (INC-4512, INC-4518, INC-4521)

### 7. FGA Checks

```bash
python3 environments/ai-agent-demo/mcp-server/scripts/setup_fga.py
```

Expected: All 7 verification checks pass. If the FGA model was overwritten by the dashboard tour, this recreates it.

### 8. FGA at Runtime

```bash
# Should ALLOW
curl -s -X POST https://mcp.DOMAIN/api/tool \
  -H "Content-Type: application/json" \
  -H "X-User-Email: joe.vanhorn@okta.com" \
  -d '{"name":"search_accounts","args":{"query":"Acme"}}' | python3 -c "import sys,json; d=json.load(sys.stdin); print(f'OK: {len(d.get(\"accounts\",[]))} accounts')"

# Should DENY
curl -s -X POST https://mcp.DOMAIN/api/tool \
  -H "Content-Type: application/json" \
  -H "X-User-Email: deku.midoriya@taskvantage.ai" \
  -d '{"name":"create_opportunity","args":{"name":"Test","account_name":"Acme","stage":"Prospecting","amount":100,"close_date":"2026-12-31"}}'
```

Expected: First returns accounts, second returns `"Authorization denied by FGA"`

### 9. Adapter Tool Discovery

Check the adapter logs for the most recent tools/list:

```bash
# The user should re-authenticate in Claude Code and then check
# In Claude Code: /mcp should show 14 tools under okta-adapter
```

### 10. Demo User State

Verify the demo user (e.g., Bronko) is NOT in any Cowork groups (for the zero-access Act 1):

```bash
curl -s "https://ORG.okta.com/api/v1/users/USER_ID/groups" \
  -H "Authorization: SSWS TOKEN" | python3 -c "
import sys,json
groups = json.load(sys.stdin)
cowork = [g for g in groups if 'Cowork' in g.get('profile',{}).get('name','')]
print(f'Cowork groups: {len(cowork)}')
for g in cowork:
    print(f'  {g[\"profile\"][\"name\"]}')
if not cowork:
    print('  NONE — ready for Act 1 (zero access)')
"
```

## Summary Table

After running all checks, present a summary:

| Check | Status | Notes |
|-------|--------|-------|
| ServiceNow awake | | |
| MCP Server (14 tools) | | |
| Adapter health | | |
| Admin UI | | |
| Salesforce data | | |
| ServiceNow data | | |
| FGA model (7/7 checks) | | |
| FGA runtime (allow/deny) | | |
| Claude Code tools (14) | | |
| Demo user (0 groups) | | |

If any check fails, refer to `environments/ai-agent-demo/docs/ADAPTER_SETUP_LESSONS.md` for the corresponding gotcha and fix.
