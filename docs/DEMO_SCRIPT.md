# Okta MCP Adapter Demo — Demo Script & Architecture Reference

## For: Joe Van Horn (personal reference, not customer-facing)

---

## What's Real vs. What's Simulated

### Fully Real (live, working systems)

- Okta Identity Engine org with OIG (YOUR-ORG.okta.com)
- Okta custom auth server (`MCP Adapter Auth Server`) issuing scoped tokens based on group membership
- Four Okta groups (Cowork-CRM-Read/Write, Cowork-ITSM-Read/Write) with scope-gated access policies
- OIG access request workflows granting/revoking group membership
- OIG access certification campaigns
- Salesforce API calls returning real data (5 accounts, 5 opportunities — seeded from demo_data_seed.yaml)
- ServiceNow API calls returning real data (5 incidents, 6 enhancement requests — seeded)
- Backend MCP server (14 tools) filtering tools based on token scopes at mcp.YOUR-DOMAIN
- Okta FGA authorization model with 67 tuples — per-tool invocation checks and per-account/incident filtering at runtime
- Okta MCP Adapter deployed at adapter.YOUR-DOMAIN with Admin UI at admin.YOUR-DOMAIN
- Admin UI dashboard for managing adapter configuration, importing AI agents, and syncing managed connections
- XAA (Cross-Application Authorization) token exchange working end-to-end through the adapter
- Claude Code / Cowork invoking tools through the adapter
- PKCE + MFA authentication flow
- Bedrock agent dashboard at agent.YOUR-DOMAIN (first-party agent path)

### Real But Customer-Specific (adapter is PS-delivered, not self-service)

- Okta MCP Adapter — this is a real product delivered through PS engagement ($55K, 6-12 weeks). The adapter code running in the demo is the actual adapter (v0.14.0), not a simulation. But the customer can't download and deploy it themselves today.

### Representational (demonstrating the concept, not production-ready)

- The backend MCP server is purpose-built for this demo. In production, customers would either build their own backend MCP servers or use vendor-provided ones (e.g., if Salesforce or ServiceNow shipped their own MCP servers, the adapter would sit in front of them the same way).
- The scope-to-tool filtering on the backend is a pattern, not a shipped product feature. Today the adapter does per-backend scoped tokens. The backend enforcing tool-level filtering is our implementation choice to show what's possible.
- The Okta groups as entitlements model works today but isn't a productized "Cowork governance" feature — it's standard OIG group lifecycle management applied to a new use case.
- The FGA integration is wired into the backend MCP server at runtime. The adapter itself doesn't call FGA today — the backend does. This demonstrates the pattern; productized FGA integration in the adapter is on the roadmap.

### Roadmap / Not Yet Available

- Fine-grained per-tool entitlements in OIG (possible with custom connector work, not turnkey)
- OPA/FGA policy engine native in the adapter (on the adapter roadmap, "Later" phase)
- Admin UI dashboard for the adapter (deployed and working in this demo — moved from roadmap to live)
- Agent Gateway as a productized replacement for the adapter (announced, no GA date)
- SIEM streaming from the adapter (on roadmap, "Later" phase)
- Human-in-the-loop approval for sensitive tool calls (on roadmap, "Later" phase)

---

## Live Infrastructure

| Component | URL | Purpose |
|-----------|-----|---------|
| MCP Adapter | `https://adapter.YOUR-DOMAIN` | OAuth gateway for MCP clients |
| MCP Server | `https://mcp.YOUR-DOMAIN` | 14 tools (Salesforce + ServiceNow) with FGA checks |
| Admin UI | `https://admin.YOUR-DOMAIN` | Adapter administration console |
| Bedrock Dashboard | `https://agent.YOUR-DOMAIN` | First-party agent (Bedrock + Okta SSO) |
| Salesforce | `YOUR-SALESFORCE-INSTANCE` | CRM data (5 accounts, 5 opps) |
| ServiceNow | `YOUR-SERVICENOW-INSTANCE` | ITSM data (5 incidents, 6 enhancements) |

### Okta Resources

| Resource | ID | Purpose |
|----------|-----|---------|
| MCP Adapter Auth Server | `YOUR-AUTH-SERVER-ID` | Issues scoped tokens (sfdc:read/write, snow:read/write) |
| MCP Adapter OIDC App | `YOUR-MCP-ADAPTER-APP-ID` | Client for scope-gated auth |
| Admin UI OIDC App | `YOUR-ADMIN-UI-APP-ID` | Admin console SSO |
| Cowork-CRM-Read group | `YOUR-CRM-READ-GROUP-ID` | Salesforce read-only tools |
| Cowork-CRM-Write group | `YOUR-CRM-WRITE-GROUP-ID` | Salesforce read + write tools |
| Cowork-ITSM-Read group | `YOUR-ITSM-READ-GROUP-ID` | ServiceNow read-only tools |
| Cowork-ITSM-Write group | `YOUR-ITSM-WRITE-GROUP-ID` | ServiceNow read + write tools |

### FGA Store

| Detail | Value |
|--------|-------|
| Store ID | `YOUR-FGA-STORE-ID` |
| Model ID | `YOUR-FGA-MODEL-ID` |
| Types | user, team, tool, sfdc_account, snow_incident |
| Tuples | 67 (teams, tool perms, account ownership, incident access) |

---

## Architecture Narrative

### The Problem (2 minutes)

"Your employees are adopting AI agents — Claude Cowork, Claude Code, GitHub Copilot, Glean. These agents connect to your enterprise systems through MCP, which is becoming the standard protocol for agent-to-tool communication.

The problem: MCP has no native identity layer. The 'S' in MCP stands for Security — which is to say, there isn't one. When an agent connects to your ServiceNow or Salesforce through an MCP server, there's no standardized way to authenticate the user, scope their access, or audit what happened.

Anthropic's Claude Enterprise gives you some controls — you can enable or disable connectors org-wide, and you can restrict specific tool actions globally. But you can't say 'Marketing gets CRM read access, Engineering gets ITSM write access.' It's all-or-nothing at the org level.

That gap is what the Okta MCP Adapter fills."

### The Architecture (3 minutes)

"The adapter sits between the AI agent and your backend systems. It's a 'Backend-for-Frontend' pattern — the agent connects to the adapter, the adapter handles authentication and authorization through Okta, and then proxies the tool calls to your backend MCP servers with a scoped token.

Here's the flow:

1. User opens Claude Cowork and connects to the enterprise MCP connector
2. The adapter initiates a PKCE authorization code flow against your Okta custom auth server
3. User authenticates with their Okta credentials + MFA
4. Okta evaluates the user's group membership and issues a token with scoped claims — if you're in the CRM Write group, your token includes `sfdc:read` and `sfdc:write` scopes
5. The adapter caches the token and proxies all subsequent tool calls to the backend
6. The backend MCP server reads the scopes from the token and only exposes tools the user is authorized for
7. For high-value operations, Okta FGA checks the user's relationship to the specific resource — can this rep modify *this account's* opportunities?
8. The agent literally cannot see or invoke tools outside the user's entitlements

The critical point: this isn't just authentication. It's authorization at three layers — coarse entitlements via scopes, tool-level visibility, and fine-grained per-resource checks via FGA — all mediated by Okta, governed by your existing identity infrastructure."

### The Three Authorization Layers (visual)

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: Okta Auth Server (Coarse)                          │
│   User in Cowork-CRM-Read group → token has sfdc:read scope │
│   → Can access Salesforce tools at all? YES/NO              │
├─────────────────────────────────────────────────────────────┤
│ Layer 2: MCP Server Scope Filter (Tool-Level)               │
│   Token has sfdc:read but NOT sfdc:write                    │
│   → Sees search_accounts, get_account_details               │
│   → Does NOT see create_opportunity, update_opportunity      │
├─────────────────────────────────────────────────────────────┤
│ Layer 3: Okta FGA (Per-Resource)                            │
│   user:derek.jeter → owner → sfdc_account:acme-corp        │
│   → Can edit Acme Corp opportunities? YES                   │
│   → Can edit NorthStar opportunities? NO (Bernie owns it)   │
└─────────────────────────────────────────────────────────────┘
```

### Live Demo Flow (10-15 minutes)

#### Act 1: No Access (2 minutes)

- Connect to the MCP adapter as a user who is NOT in any Cowork groups
- Show: authentication succeeds (user is a valid Okta user with MFA)
- Show: zero tools available — the agent has nothing to work with
- Talking point: "Authentication and authorization are separate. You can be a valid employee and still have no agent entitlements. Zero standing privilege."

#### Act 2: Access Request (3 minutes)

- Switch to OIG end-user portal
- Submit an access request for "Cowork: CRM Read Access"
- Show the approval workflow firing (approve as the manager)
- Show the user being added to `Cowork-CRM-Read` group

#### Act 3: Scoped Access (3 minutes)

- Reconnect to the MCP adapter as the same user
- Show: read-only Salesforce tools now appear (`search_accounts`, `get_account_details`, `search_opportunities`, `list_contacts`)
- Ask the agent to search for open opportunities — show real Salesforce data coming back (Acme Corp $2.4M renewal, Pinnacle Financial $1.2M prospect)
- Try to ask the agent to create an opportunity — show that the tool doesn't exist, the agent can't even attempt it
- Talking point: "The agent doesn't know what it can't do. There's no error, no rejection — the write tools simply aren't there."

#### Act 4: Elevated Access (3 minutes)

- Submit another access request for "Cowork: CRM Write Access" with time-bound access (e.g., 2 hours)
- Approve it
- Reconnect — now write tools appear alongside read tools (`create_opportunity`, `update_opportunity`, `log_activity`)
- Create an opportunity through the agent — show it appearing in Salesforce
- Talking point: "Time-bound access means this elevated entitlement auto-revokes in 2 hours. No cleanup needed, no standing privilege accumulation."

#### Act 5: FGA Deep Dive (3 minutes)

- Show the FGA model in the FGA Dashboard (types: user, team, tool, sfdc_account)
- Demonstrate the territory model: Derek Jeter owns Acme Corp and Pinnacle Financial, Bernie Williams owns NorthStar Insurance
- Show that Deku (product team) can VIEW all accounts but cannot WRITE to any — even if he somehow got write scopes, FGA blocks the tool invocation
- Show that Derek can edit Acme opportunities but NOT NorthStar opportunities
- Talking point: "Scopes get you through the door. FGA controls what you can touch once inside. And because FGA checks happen at every invocation — not at authentication — revoking a relationship takes effect immediately."

#### Act 6: Certification (2 minutes)

- Show the OIG certification campaign view
- Show the reviewer seeing the user's Cowork entitlements
- Revoke CRM Write access through the certification
- Talking point: "Quarterly reviews now cover agent entitlements alongside everything else. Same workflow your governance team already knows."

#### Optional Act 7: Cross-Platform (2 minutes)

- Connect as a user in `Cowork-ITSM-Read` but NOT in any CRM groups
- Show: ServiceNow tools appear, Salesforce tools do not
- Ask about P1 incidents — real ServiceNow data (Acme Corp's 3 P1s) comes back
- Talking point: "Different teams, different tools, same governance model. Your SOC team gets ITSM access, your sales team gets CRM access, and Okta manages the boundary."

#### Optional Act 8: First-Party vs. Third-Party (2 minutes)

- Show the Bedrock agent dashboard at agent.YOUR-DOMAIN querying the same data
- Talking point: "Same MCP server, same tools, same data — but two trust models. The Bedrock agent is your first-party agent built internally, accessing data via service credentials. Claude Cowork is a third-party agent accessing data through user-scoped entitlements. Okta governs both."

### The Roadmap (2 minutes)

"What you've seen today uses the Okta MCP Adapter, which is available now as a professional services engagement. Here's where this is going:

**Available now:**
- Per-user authentication with MFA
- Per-backend scoped tokens based on Okta group membership
- Tool-level filtering on the backend MCP server
- Full OIG governance — access requests, time-bound access, certifications
- Audit trail of all agent-to-resource interactions
- Okta FGA for fine-grained per-resource authorization at invocation time
- Admin UI dashboard for adapter configuration and AI agent management
- XAA token exchange for cross-application authorization

**Coming next (adapter roadmap):**
- Level 2 token caching for performance
- Service account patterns for M2M scenarios

**Coming later:**
- OPA/FGA policy engine native in the adapter
- SIEM streaming for security monitoring integration
- Human-in-the-loop approval workflows for sensitive operations

**The deeper authorization story (Okta FGA):**

What we've shown today answers three questions in sequence: 'is this user authenticated?' (Okta SSO), 'which tools can they access?' (scoped tokens), and 'can they act on this specific resource?' (FGA). The third layer is live in this demo — the backend MCP server calls Okta FGA's Check API on every tool invocation. If a sales rep's territory changes, the next tool call reflects the change immediately, no re-authentication needed.

**Product direction (Okta platform):**
- Agent Gateway — a productized, Okta-managed control plane that replaces the need for a PS-deployed adapter
- Universal Logout for AI Agents — kill switch for revoking agent access across all active sessions
- Deeper OIG integration with agent-specific resource types and entitlement models"

---

## Anticipated Questions and Responses

**Q: Why not just use Anthropic's built-in connector controls?**
A: Anthropic gives you org-wide on/off toggles and per-tool-action restrictions, but those are global — every user gets the same view. The adapter makes access identity-aware. Different users see different tools based on who they are in Okta.

**Q: Does this work with agents other than Claude?**
A: Yes. The adapter speaks MCP, which is the standard protocol. Any MCP-compatible agent can connect — Claude Code, GitHub Copilot, Glean, custom agents. The auth and scoping work the same way regardless of the client.

**Q: What about XAA? Isn't that supposed to solve this?**
A: XAA solves the problem for apps that natively support it — both apps need to be in the OIN with OIDC and XAA enabled. The adapter solves the problem for everything else. Third-party agents don't support XAA today, so the adapter restores XAA-level security by acting as the intermediary. We validated this the hard way — XAA's token exchange works between OIN apps, but custom OIDC apps and third-party agents need the adapter pattern.

**Q: What happens when Agent Gateway ships?**
A: Agent Gateway is the productized evolution of this pattern. When it GAs, customers on the adapter can migrate to a fully managed solution. The adapter gives you the security posture today rather than waiting for the product roadmap.

**Q: Can we see what the agent actually did?**
A: The adapter logs every tool invocation with the authenticated user's identity, the tool called, the parameters, and the timestamp. Today that's in the adapter's own logs and CloudWatch. SIEM streaming is on the roadmap to push those events into Splunk, Cribl, or your existing SIEM pipeline.

**Q: How granular can the entitlements get?**
A: Three levels of granularity, each appropriate for different needs:
1. **Tier-based** (read/write/admin) using Okta groups — that's what you've seen with the adapter today, it works with OIG out of the box.
2. **Per-tool** using OIG custom entitlements — architecturally possible, adds governance overhead.
3. **Per-resource** using Okta FGA — the backend checks whether the user has a relationship to the specific resource being acted on. This is live in the demo — Derek can edit Acme's opportunities but not NorthStar's.

These layers compose; you don't have to pick one.

**Q: What is Okta FGA and how does it fit here?**
A: Okta FGA is our Fine-Grained Authorization service, built on OpenFGA — the open-source implementation of Google's Zanzibar authorization model. It lets you define relationships between users and resources (like "Derek owns account Acme Corp") and check permissions derived from those relationships at runtime. For agent authorization, FGA answers the question OAuth scopes structurally cannot: "can this user do this thing to *this specific object*?" Scopes tell you they have write access to CRM tools. FGA tells you they can write to *this account's* opportunities. The other advantage is timing — scope checks happen at authentication, FGA checks happen at every invocation. If you revoke a relationship, the next tool call is denied immediately, no re-auth required.

**Q: Do we need FGA from day one?**
A: No. Start with tier-based scopes — that gets you identity-aware access control, OIG governance, and audit logging. Layer in FGA when you have high-value write operations where the resource identity matters. Most customers will find that tier-based covers 80% of the risk, and FGA addresses the remaining 20% for sensitive operations like creating records, modifying data, or accessing restricted accounts.

**Q: How does this compare to what competitors offer for agent security?**
A: Most competitors are either (a) building their own proprietary agent gateways that don't integrate with your existing IdP, or (b) relying on the agent platform's built-in controls which are org-wide, not identity-aware. Okta's approach is unique in three ways: we use your existing identity infrastructure (no new identity silo), we compose with OIG for lifecycle governance (access requests, certifications, time-bound access), and we offer FGA for fine-grained authorization that no other IdP provides at this layer.

---

## Fallback Plan

If the Cowork remote connector flow doesn't work (PKCE redirect issue through Anthropic's cloud):

1. Demo the full flow with Claude Code (local, stdio-based) — all the same tools, auth, and scoping work identically. The `.mcp.json` in the repo root is pre-configured.
2. Show the Cowork connector settings screen to demonstrate where the remote URL would be configured
3. Explain: "The protocol and security model are identical. Cowork uses remote HTTP transport, Claude Code uses local stdio, but the adapter handles both. We're validating the Cowork remote flow with Anthropic and expect it to be fully supported."

---

## Pre-Demo Checklist

- [ ] **Wake ServiceNow dev instance** at developer.servicenow.com (they hibernate after inactivity!)
- [ ] Verify MCP server is healthy: `curl https://mcp.YOUR-DOMAIN/health`
- [ ] Verify adapter is healthy: `curl https://adapter.YOUR-DOMAIN/.well-known/oauth-protected-resource`
- [ ] Verify Admin UI is accessible: open `https://admin.YOUR-DOMAIN` in a browser
- [ ] Verify FGA is working: `python3 environments/ai-agent-demo/mcp-server/scripts/setup_fga.py` (re-runs checks)
- [ ] Verify demo user is NOT in any Cowork groups (for Act 1)
- [ ] Verify OIG access request catalog items exist for the Cowork groups
- [ ] Verify Salesforce data is present: query "Acme Corp" through the MCP server
- [ ] Verify ServiceNow data is present: query incidents through the MCP server
- [ ] Have the FGA Dashboard open in a browser tab (https://dashboard.fga.dev)
- [ ] Have the Okta Admin Console open in a browser tab
- [ ] Have Claude Code configured with `.mcp.json` as fallback
