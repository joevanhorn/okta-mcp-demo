# Okta MCP Adapter Demo

**Securing AI Agent Access with Identity Governance**

A complete, deployable demo showing how Okta secures AI agent access to enterprise systems through the [Model Context Protocol (MCP)](https://modelcontextprotocol.io). Three authorization layers compose to give enterprises identity-aware, governed, fine-grained control over what AI agents can do.

## Architecture

```
┌─────────────────┐     ┌──────────────────────┐     ┌────────────────────┐     ┌───────────┐
│  Claude Code    │     │   Okta MCP Adapter    │     │  MCP Server        │     │ Okta FGA  │
│  (AI Agent)     │────▶│   (OAuth Gateway)     │────▶│  (14 Tools)        │────▶│ (Per-     │
│                 │     │                       │     │                    │     │  Resource  │
│                 │     │  Layer 1: Identity     │     │  Layer 2: Scope    │     │  Checks)  │
│                 │     │  PKCE + MFA + Scopes  │     │  Tool Filtering    │     │           │
│                 │     │                       │     │                    │     │  Layer 3   │
└─────────────────┘     └──────────┬───────────┘     └──────┬─────────────┘     └───────────┘
                                   │                        │
                              ┌────┴─────┐           ┌─────┴──────┐
                              │  Okta    │           │ Salesforce │
                              │  OIG     │           │ ServiceNow │
                              │  Groups  │           │ (Live APIs)│
                              └──────────┘           └────────────┘
```

**Layer 1 — Okta Auth Server**: Authenticates the user, evaluates group membership, issues scoped tokens (`sfdc:read`, `snow:write`, etc.)

**Layer 2 — MCP Server**: Reads token scopes, filters `tools/list` response. Write tools are invisible to read-only users.

**Layer 3 — Okta FGA**: Per-tool invocation checks and per-resource authorization. Sales reps can only modify accounts in their territory.

## What's Included

| Component | Description |
|-----------|-------------|
| **MCP Server** | TypeScript server with 14 tools (7 Salesforce, 7 ServiceNow), scope-based filtering, and FGA runtime checks |
| **FGA Model** | Authorization model with 5 types, 67 tuples covering teams, tools, accounts, and incidents |
| **Data Seeding** | Python script to populate Salesforce + ServiceNow with cross-referenced demo data |
| **Terraform** | ECS infrastructure templates for MCP Server, Adapter, and Admin UI |
| **Documentation** | Build guide, demo script, 25 setup gotchas, visual aid (HTML) |
| **Claude Code Skills** | 5 interactive setup skills (`/demo-setup-data`, `/demo-setup-okta`, etc.) |

## Quick Start

### Prerequisites

- Okta OIE org with OIG and AI Agents feature enabled
- Salesforce developer org ([free](https://developer.salesforce.com/signup))
- ServiceNow developer instance ([free](https://developer.servicenow.com))
- AWS account (for ECS deployment, ~$83/month)
- Okta FGA tenant ([free](https://dashboard.fga.dev))
- Node.js 18+, Python 3.10+, Claude Code CLI

### 5-Step Setup

```bash
# 1. Clone and configure
git clone https://github.com/YOUR-USERNAME/okta-mcp-demo.git
cd okta-mcp-demo
cp .env.example .env
# Edit .env with your Okta, Salesforce, ServiceNow, and FGA credentials

# 2. Configure Okta (auth server, groups, policies, AI agent)
# Follow docs/DEMO_BUILD_GUIDE.md Phase 2, or use:
claude /demo-setup-okta

# 3. Deploy infrastructure
# Follow docs/DEMO_BUILD_GUIDE.md Phase 3, or use:
claude /demo-setup-infra

# 4. Seed demo data
source .env
python3 mcp-server/scripts/seed_demo_data.py --mode populate --target both \
  --sf-instance-url $SFDC_INSTANCE_URL --sf-client-id $SFDC_CLIENT_ID \
  --sf-client-secret $SFDC_CLIENT_SECRET \
  --snow-instance-url $SNOW_INSTANCE_URL --snow-user $SNOW_USERNAME \
  --snow-password $SNOW_PASSWORD

# 5. Connect Claude Code
claude mcp add --transport http okta-adapter https://adapter.YOUR-DOMAIN
```

### Claude Code Skills

If using Claude Code in this repo, interactive skills guide you through each phase:

| Skill | Purpose |
|-------|---------|
| `/demo-setup-data` | Seed Salesforce + ServiceNow |
| `/demo-setup-okta` | Configure Okta auth server, groups, policies |
| `/demo-setup-infra` | Deploy to AWS ECS |
| `/demo-setup-fga` | Set up FGA model and tuples |
| `/demo-verify` | Run 10 pre-demo health checks |

## What This Demonstrates

### For Prospects

1. **Zero Standing Privilege** — Users authenticate but see no tools until explicitly granted entitlements via OIG
2. **Identity-Aware Scoping** — Different users see different tools based on their Okta group membership
3. **Governed Lifecycle** — Access requests, manager approvals, time-bound access, quarterly certifications — all through existing OIG workflows
4. **Fine-Grained Authorization** — Okta FGA checks per-tool invocation rights and per-resource relationships at every call
5. **Full Audit Trail** — Every tool invocation logged with user identity, tool name, and parameters

### The Demo Narrative

> "Your employees are adopting AI agents. These agents connect to your enterprise systems through MCP. The problem: MCP has no native identity layer. The Okta MCP Adapter fills that gap — authentication, authorization, and governance, using your existing Okta infrastructure."

See [docs/DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) for the full 15-minute demo flow.

## Documentation

| Document | Description |
|----------|-------------|
| [DEMO_BUILD_GUIDE.md](docs/DEMO_BUILD_GUIDE.md) | Complete setup guide (5 phases, ~2-3 hours) |
| [DEMO_SCRIPT.md](docs/DEMO_SCRIPT.md) | Demo narrative, talk track, and Q&A |
| [ADAPTER_SETUP_LESSONS.md](docs/ADAPTER_SETUP_LESSONS.md) | 25 known gotchas with symptoms and fixes |
| [demo-visual-aid.html](docs/demo-visual-aid.html) | Printable architecture overview (open in browser) |

## Cost

| Resource | Monthly |
|----------|---------|
| ECS Fargate (5 services) | ~$45 |
| RDS PostgreSQL | ~$15 |
| ALB | ~$20 |
| Route53 + ACM | ~$2 |
| **Total** | **~$83** |

Tear down: `gh workflow run deploy.yml -f action=terraform-destroy`

## License

Apache 2.0
