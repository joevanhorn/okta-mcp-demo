---
name: demo-setup-data
description: Seed Salesforce and ServiceNow with demo data for the MCP Adapter demo
user-invocable: true
---

# Seed Demo Data

You are helping an SE set up demo data for the Okta MCP Adapter demo. This seeds Salesforce and ServiceNow with cross-referenced data that the Product Intelligence Agent can query.

## What You Need From the User

1. **Salesforce credentials**:
   - Instance URL (e.g., `https://orgfarm-xxx.develop.my.salesforce.com`)
   - Connected App Client ID
   - Connected App Client Secret
   - The connected app must have Client Credentials Flow enabled with a Run As user

2. **ServiceNow credentials**:
   - Instance URL (e.g., `https://devXXXXX.service-now.com`)
   - Local admin username (NOT a federated Okta user)
   - Password
   - **Important**: ServiceNow dev instances hibernate — the user must wake it at developer.servicenow.com first

## Steps

1. **Run dry-run first** to preview what will be created:
```bash
python3 environments/ai-agent-demo/bedrock-agent/scripts/seed_demo_data.py --mode dry-run
```

2. **Seed both systems**:
```bash
python3 environments/ai-agent-demo/bedrock-agent/scripts/seed_demo_data.py \
  --mode populate --target both \
  --sf-instance-url SF_URL \
  --sf-client-id SF_CLIENT_ID \
  --sf-client-secret SF_CLIENT_SECRET \
  --snow-instance-url SNOW_URL \
  --snow-user SNOW_USER \
  --snow-password 'SNOW_PASSWORD'
```

3. **Verify** by querying both systems:
```bash
# Salesforce
curl -s -X POST https://mcp.YOUR-DOMAIN/api/tool \
  -H "Content-Type: application/json" \
  -d '{"name":"search_accounts","args":{"query":"Acme"}}' | python3 -m json.tool | head -15

# ServiceNow
curl -s -X POST https://mcp.YOUR-DOMAIN/api/tool \
  -H "Content-Type: application/json" \
  -d '{"name":"search_incidents","args":{"query":"Acme","priority":"all"}}' | python3 -m json.tool | head -15
```

## Expected Data

The seed creates:
- **Salesforce**: 5 accounts (Acme Corp, Pinnacle Financial, NorthStar Insurance, Meridian Healthcare, Apex Manufacturing) + 5 opportunities
- **ServiceNow**: 5 incidents (3 P1s at Acme Corp) + 6 enhancement requests ranked by votes

## Customization

Edit `environments/ai-agent-demo/bedrock-agent/config/demo_data_seed.yaml` to change company names, industries, revenue figures, or incident descriptions before seeding.

## Troubleshooting

- **Salesforce 400 on BillingState**: The script uses `BillingStateCode` + `BillingCountryCode` (ISO codes). If your org doesn't have state/country picklists enabled, edit the script to use `BillingState` + `BillingCountry` instead.
- **ServiceNow 401**: Use local admin credentials, not federated Okta users. ServiceNow basic auth doesn't work with SSO accounts.
- **ServiceNow HTML response**: The instance is hibernating. Wake it at developer.servicenow.com.
- **Custom fields skipped**: The script gracefully falls back to standard fields if custom fields (`Contract_ARR__c`, etc.) don't exist on your org.
