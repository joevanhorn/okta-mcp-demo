#!/usr/bin/env python3
"""
seed_demo_data.py - Populate Salesforce and ServiceNow with demo data for
the Bedrock XAA Product Intelligence Agent demo.

Reads demo_data_seed.yaml and creates/updates records in both systems so
the agent has realistic cross-referenced data to query.

=============================================================================
AUTHENTICATION
=============================================================================

Salesforce:
  - OAuth client credentials flow via a connected app
  - Provide --sf-client-id, --sf-client-secret, --sf-instance-url
  - Or store in SSM: /bedrock-xaa-demo/salesforce_*

ServiceNow:
  - Basic auth (username + password)
  - Provide --snow-instance-url, --snow-user, --snow-password
  - Or store in SSM: /bedrock-xaa-demo/servicenow_*

=============================================================================
USAGE
=============================================================================

  # Dry run (show what would be created):
  python3 seed_demo_data.py --mode dry-run

  # Seed Salesforce only:
  python3 seed_demo_data.py --mode populate --target salesforce \
    --sf-instance-url https://orgfarm-xxx.develop.my.salesforce.com \
    --sf-client-id 3MVG9... --sf-client-secret ABC123

  # Seed ServiceNow only:
  python3 seed_demo_data.py --mode populate --target servicenow \
    --snow-instance-url https://dev354223.service-now.com \
    --snow-user admin --snow-password 'xxx'

  # Seed both:
  python3 seed_demo_data.py --mode populate --target both

  # Reset (delete seeded data):
  python3 seed_demo_data.py --mode reset --target both

  # Read credentials from AWS SSM (for CI/CD):
  python3 seed_demo_data.py --mode populate --target both --use-ssm \
    --aws-profile taskvantage --aws-region us-east-2
"""

import argparse
import json
import os
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

import requests
import yaml

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
SCRIPT_DIR = Path(__file__).parent
CONFIG_DIR = SCRIPT_DIR.parent / "config"
DEFAULT_CONFIG = CONFIG_DIR / "demo_data_seed.yaml"
SSM_PREFIX = "/bedrock-xaa-demo"

# Salesforce custom fields — these map YAML fields to Salesforce API names.
# Standard fields (Name, Industry, etc.) map 1:1. Custom fields use __c suffix.
# If these custom fields don't exist yet, the script will skip them gracefully.
SF_ACCOUNT_CUSTOM_FIELDS = {
    "contract_arr": "Contract_ARR__c",
    "renewal_date": "Renewal_Date__c",
    "health_score": "Health_Score__c",
    "segment": "Segment__c",
    "status": "Account_Status__c",
}

SF_OPPORTUNITY_CUSTOM_FIELDS = {
    "competitor": "Competitor__c",
    "next_step": "NextStep",  # standard field
    "product_interest": "Product_Interest__c",
}


# ---------------------------------------------------------------------------
# Credential loading
# ---------------------------------------------------------------------------
def load_credentials_from_ssm(prefix, aws_profile=None, aws_region="us-east-2"):
    """Load credentials from AWS SSM Parameter Store."""
    try:
        import boto3
    except ImportError:
        print("ERROR: boto3 required for SSM. Install with: pip install boto3")
        sys.exit(1)

    session = boto3.Session(profile_name=aws_profile, region_name=aws_region)
    ssm = session.client("ssm")

    params = {}
    try:
        response = ssm.get_parameters_by_path(
            Path=prefix, WithDecryption=True, Recursive=True
        )
        for p in response.get("Parameters", []):
            key = p["Name"].split("/")[-1]
            params[key] = p["Value"]
    except Exception as e:
        print(f"WARNING: Could not read SSM parameters: {e}")

    return params


def get_credentials(args):
    """Resolve credentials from args, SSM, or environment."""
    creds = {
        "sf_instance_url": args.sf_instance_url,
        "sf_client_id": args.sf_client_id,
        "sf_client_secret": args.sf_client_secret,
        "snow_instance_url": args.snow_instance_url,
        "snow_user": args.snow_user,
        "snow_password": args.snow_password,
    }

    # Fill gaps from SSM if requested
    if args.use_ssm:
        ssm_params = load_credentials_from_ssm(
            SSM_PREFIX, args.aws_profile, args.aws_region
        )
        ssm_map = {
            "sf_instance_url": "salesforce_instance_url",
            "sf_client_id": "salesforce_client_id",
            "sf_client_secret": "salesforce_client_secret",
            "snow_instance_url": "servicenow_instance_url",
            "snow_user": "servicenow_user",
            "snow_password": "servicenow_password",
        }
        for key, ssm_key in ssm_map.items():
            if not creds[key] and ssm_key in ssm_params:
                creds[key] = ssm_params[ssm_key]

    # Fill gaps from environment
    env_map = {
        "sf_instance_url": "SF_INSTANCE_URL",
        "sf_client_id": "SF_CLIENT_ID",
        "sf_client_secret": "SF_CLIENT_SECRET",
        "snow_instance_url": "SNOW_INSTANCE_URL",
        "snow_user": "SNOW_USER",
        "snow_password": "SNOW_PASSWORD",
    }
    for key, env_key in env_map.items():
        if not creds[key]:
            creds[key] = os.environ.get(env_key)

    return creds


# ---------------------------------------------------------------------------
# Salesforce Client
# ---------------------------------------------------------------------------
class SalesforceClient:
    """Simple Salesforce REST API client using OAuth client credentials."""

    def __init__(self, instance_url, client_id, client_secret):
        self.instance_url = instance_url.rstrip("/")
        self.client_id = client_id
        self.client_secret = client_secret
        self.access_token = None
        self.api_version = "v60.0"

    def authenticate(self):
        """Get access token via OAuth client credentials flow."""
        token_url = f"{self.instance_url}/services/oauth2/token"
        resp = requests.post(token_url, data={
            "grant_type": "client_credentials",
            "client_id": self.client_id,
            "client_secret": self.client_secret,
        })
        if resp.status_code != 200:
            raise Exception(f"Salesforce auth failed ({resp.status_code}): {resp.text}")
        data = resp.json()
        self.access_token = data["access_token"]
        # Update instance_url if Salesforce returns a different one
        if "instance_url" in data:
            self.instance_url = data["instance_url"]
        print(f"  Authenticated to Salesforce: {self.instance_url}")

    def _headers(self):
        return {
            "Authorization": f"Bearer {self.access_token}",
            "Content-Type": "application/json",
        }

    def _api_url(self, path):
        return f"{self.instance_url}/services/data/{self.api_version}/{path}"

    def query(self, soql):
        """Execute a SOQL query."""
        resp = requests.get(
            self._api_url("query"),
            headers=self._headers(),
            params={"q": soql},
        )
        resp.raise_for_status()
        return resp.json().get("records", [])

    def create(self, sobject, data):
        """Create a record. Returns the new record ID."""
        resp = requests.post(
            self._api_url(f"sobjects/{sobject}"),
            headers=self._headers(),
            json=data,
        )
        if resp.status_code == 201:
            return resp.json()["id"]
        raise Exception(f"Create {sobject} failed ({resp.status_code}): {resp.text}")

    def update(self, sobject, record_id, data):
        """Update an existing record."""
        resp = requests.patch(
            self._api_url(f"sobjects/{sobject}/{record_id}"),
            headers=self._headers(),
            json=data,
        )
        if resp.status_code == 204:
            return True
        raise Exception(f"Update {sobject}/{record_id} failed ({resp.status_code}): {resp.text}")

    def delete(self, sobject, record_id):
        """Delete a record."""
        resp = requests.delete(
            self._api_url(f"sobjects/{sobject}/{record_id}"),
            headers=self._headers(),
        )
        if resp.status_code == 204:
            return True
        raise Exception(f"Delete {sobject}/{record_id} failed ({resp.status_code}): {resp.text}")

    def find_or_create(self, sobject, match_field, match_value, data):
        """Find by a field value, or create if not found. Returns (id, created)."""
        escaped = match_value.replace("'", "\\'")
        results = self.query(
            f"SELECT Id FROM {sobject} WHERE {match_field} = '{escaped}' LIMIT 1"
        )
        if results:
            record_id = results[0]["Id"]
            self.update(sobject, record_id, data)
            return record_id, False
        else:
            record_id = self.create(sobject, {**data, match_field: match_value})
            return record_id, True


# ---------------------------------------------------------------------------
# ServiceNow Client
# ---------------------------------------------------------------------------
class ServiceNowClient:
    """Simple ServiceNow REST API client using basic auth."""

    def __init__(self, instance_url, username, password):
        self.instance_url = instance_url.rstrip("/")
        self.auth = (username, password)

    def _headers(self):
        return {
            "Content-Type": "application/json",
            "Accept": "application/json",
        }

    def query_table(self, table, query=None, fields=None, limit=10):
        """Query a ServiceNow table."""
        params = {"sysparm_limit": limit}
        if query:
            params["sysparm_query"] = query
        if fields:
            params["sysparm_fields"] = ",".join(fields)

        resp = requests.get(
            f"{self.instance_url}/api/now/table/{table}",
            auth=self.auth,
            headers=self._headers(),
            params=params,
        )
        resp.raise_for_status()
        return resp.json().get("result", [])

    def create_record(self, table, data):
        """Create a record in a table. Returns the sys_id."""
        resp = requests.post(
            f"{self.instance_url}/api/now/table/{table}",
            auth=self.auth,
            headers=self._headers(),
            json=data,
        )
        if resp.status_code in (200, 201):
            return resp.json()["result"]["sys_id"]
        raise Exception(f"Create {table} failed ({resp.status_code}): {resp.text}")

    def update_record(self, table, sys_id, data):
        """Update a record."""
        resp = requests.patch(
            f"{self.instance_url}/api/now/table/{table}/{sys_id}",
            auth=self.auth,
            headers=self._headers(),
            json=data,
        )
        if resp.status_code == 200:
            return True
        raise Exception(f"Update {table}/{sys_id} failed ({resp.status_code}): {resp.text}")

    def delete_record(self, table, sys_id):
        """Delete a record."""
        resp = requests.delete(
            f"{self.instance_url}/api/now/table/{table}/{sys_id}",
            auth=self.auth,
            headers=self._headers(),
        )
        if resp.status_code == 204:
            return True
        raise Exception(f"Delete {table}/{sys_id} failed ({resp.status_code}): {resp.text}")

    def find_or_create(self, table, match_field, match_value, data):
        """Find by field or create. Returns (sys_id, created)."""
        results = self.query_table(
            table, query=f"{match_field}={match_value}", limit=1
        )
        if results:
            sys_id = results[0]["sys_id"]
            self.update_record(table, sys_id, data)
            return sys_id, False
        else:
            sys_id = self.create_record(table, {**data, match_field: match_value})
            return sys_id, True


# ---------------------------------------------------------------------------
# Salesforce Seeding
# ---------------------------------------------------------------------------
def seed_salesforce(sf, config, mode="populate"):
    """Seed Salesforce with accounts and opportunities from config."""
    accounts = config.get("salesforce_accounts", [])
    opportunities = config.get("salesforce_opportunities", [])
    account_ids = {}  # name -> Salesforce ID mapping for opportunity linking

    print(f"\n{'='*60}")
    print("SALESFORCE SEEDING")
    print(f"{'='*60}")

    if mode == "dry-run":
        print(f"\n  Would create/update {len(accounts)} accounts:")
        for a in accounts:
            print(f"    - {a['name']} ({a['industry']}, {a['type']})")
        print(f"\n  Would create/update {len(opportunities)} opportunities:")
        for o in opportunities:
            print(f"    - {o['name']} (${o['amount']:,.0f}, {o['stage']})")
        return

    # Seed accounts
    print(f"\n  Seeding {len(accounts)} accounts...")
    for acct in accounts:
        data = {
            "Industry": acct.get("industry"),
            "Type": acct.get("type"),
            "AnnualRevenue": acct.get("annual_revenue"),
            "NumberOfEmployees": acct.get("employees"),
            "BillingCity": acct.get("billing_city"),
            "BillingStateCode": acct.get("billing_state"),
            "BillingCountryCode": "US",
            "Description": acct.get("notes"),
        }
        # Add custom fields if they exist — skip gracefully if not
        for yaml_key, sf_field in SF_ACCOUNT_CUSTOM_FIELDS.items():
            if acct.get(yaml_key) is not None:
                data[sf_field] = acct[yaml_key]

        try:
            record_id, created = sf.find_or_create("Account", "Name", acct["name"], data)
            action = "Created" if created else "Updated"
            account_ids[acct["name"]] = record_id
            print(f"    {action}: {acct['name']} ({record_id})")
        except Exception as e:
            # If custom field fails, retry without custom fields
            if "__c" in str(e):
                print(f"    WARNING: Custom field error for {acct['name']}, retrying without custom fields...")
                data = {k: v for k, v in data.items() if not k.endswith("__c")}
                try:
                    record_id, created = sf.find_or_create("Account", "Name", acct["name"], data)
                    action = "Created" if created else "Updated"
                    account_ids[acct["name"]] = record_id
                    print(f"    {action}: {acct['name']} ({record_id}) [standard fields only]")
                except Exception as e2:
                    print(f"    ERROR: {acct['name']}: {e2}")
            else:
                print(f"    ERROR: {acct['name']}: {e}")

    # Seed opportunities
    print(f"\n  Seeding {len(opportunities)} opportunities...")
    for opp in opportunities:
        acct_name = opp.get("account")
        acct_id = account_ids.get(acct_name)

        if not acct_id:
            # Try to look up the account
            try:
                results = sf.query(
                    f"SELECT Id FROM Account WHERE Name = '{acct_name}' LIMIT 1"
                )
                if results:
                    acct_id = results[0]["Id"]
                    account_ids[acct_name] = acct_id
            except Exception:
                pass

        if not acct_id:
            print(f"    SKIP: {opp['name']} — account '{acct_name}' not found")
            continue

        data = {
            "AccountId": acct_id,
            "StageName": opp.get("stage", "Prospecting"),
            "Amount": opp.get("amount"),
            "CloseDate": opp.get("close_date"),
            "Probability": opp.get("probability"),
            "Type": opp.get("type"),
            "Description": opp.get("notes"),
            "NextStep": opp.get("next_step"),
        }
        # Custom fields
        for yaml_key, sf_field in SF_OPPORTUNITY_CUSTOM_FIELDS.items():
            val = opp.get(yaml_key)
            if val is not None:
                if isinstance(val, list):
                    val = "; ".join(val)
                data[sf_field] = val

        try:
            record_id, created = sf.find_or_create("Opportunity", "Name", opp["name"], data)
            action = "Created" if created else "Updated"
            print(f"    {action}: {opp['name']} ({record_id})")
        except Exception as e:
            if "__c" in str(e):
                data = {k: v for k, v in data.items() if not k.endswith("__c")}
                try:
                    record_id, created = sf.find_or_create("Opportunity", "Name", opp["name"], data)
                    action = "Created" if created else "Updated"
                    print(f"    {action}: {opp['name']} ({record_id}) [standard fields only]")
                except Exception as e2:
                    print(f"    ERROR: {opp['name']}: {e2}")
            else:
                print(f"    ERROR: {opp['name']}: {e}")


def reset_salesforce(sf, config):
    """Delete seeded Salesforce records."""
    print(f"\n{'='*60}")
    print("SALESFORCE RESET")
    print(f"{'='*60}")

    # Delete opportunities first (child records)
    for opp in config.get("salesforce_opportunities", []):
        try:
            results = sf.query(
                f"SELECT Id FROM Opportunity WHERE Name = '{opp['name']}' LIMIT 1"
            )
            if results:
                sf.delete("Opportunity", results[0]["Id"])
                print(f"  Deleted opportunity: {opp['name']}")
            else:
                print(f"  Not found: {opp['name']}")
        except Exception as e:
            print(f"  ERROR deleting opportunity {opp['name']}: {e}")

    # Then accounts
    for acct in config.get("salesforce_accounts", []):
        try:
            results = sf.query(
                f"SELECT Id FROM Account WHERE Name = '{acct['name']}' LIMIT 1"
            )
            if results:
                sf.delete("Account", results[0]["Id"])
                print(f"  Deleted account: {acct['name']}")
            else:
                print(f"  Not found: {acct['name']}")
        except Exception as e:
            print(f"  ERROR deleting account {acct['name']}: {e}")


# ---------------------------------------------------------------------------
# ServiceNow Seeding
# ---------------------------------------------------------------------------
def seed_servicenow(snow, config, mode="populate"):
    """Seed ServiceNow with incidents and enhancement requests from config."""
    incidents = config.get("servicenow_incidents", [])
    enhancements = config.get("servicenow_enhancements", [])

    print(f"\n{'='*60}")
    print("SERVICENOW SEEDING")
    print(f"{'='*60}")

    if mode == "dry-run":
        print(f"\n  Would create/update {len(incidents)} incidents:")
        for inc in incidents:
            print(f"    - {inc['number']}: {inc['short_description']} ({inc['priority']})")
        print(f"\n  Would create/update {len(enhancements)} enhancement requests:")
        for enh in enhancements:
            print(f"    - {enh['number']}: {enh['title']} ({enh['votes']} votes)")
        return

    # Map priority labels to ServiceNow numeric values
    priority_map = {"P1": "1", "P2": "2", "P3": "3", "P4": "4"}
    state_map = {
        "Open": "1",
        "In Progress": "2",
        "On Hold": "3",
        "Resolved": "6",
        "Closed": "7",
        "Escalated": "2",  # Map to In Progress with escalation flag
    }

    # Seed incidents
    print(f"\n  Seeding {len(incidents)} incidents...")
    for inc in incidents:
        now = datetime.now(timezone.utc)
        opened_at = now - timedelta(days=inc.get("opened_days_ago", 1))

        data = {
            "short_description": inc["short_description"],
            "description": inc.get("description", "").strip(),
            "priority": priority_map.get(inc.get("priority", "P3"), "3"),
            "state": state_map.get(inc.get("state", "Open"), "1"),
            "assigned_to": inc.get("assigned_to", ""),
            # assignment_group requires valid sys_id — skip for seeding.
            # The group name is preserved in the description for demo queries.
            "company": inc.get("customer", ""),
            "opened_at": opened_at.strftime("%Y-%m-%d %H:%M:%S"),
        }

        # Set escalation if state is "Escalated"
        if inc.get("state") == "Escalated":
            data["escalation"] = "1"

        # Set SLA breach flag
        if inc.get("sla_breach"):
            data["made_sla"] = "false"

        try:
            sys_id, created = snow.find_or_create(
                "incident", "number", inc["number"], data
            )
            action = "Created" if created else "Updated"
            print(f"    {action}: {inc['number']} - {inc['short_description'][:50]}...")
        except Exception as e:
            print(f"    ERROR: {inc['number']}: {e}")

    # Seed enhancement requests as incidents with subcategory="Enhancement".
    # Most ServiceNow dev instances don't have a dedicated enhancement table.
    print(f"\n  Seeding {len(enhancements)} enhancement requests (as incidents)...")

    priority_text_map = {"High": "2", "Medium": "3", "Low": "4"}

    for enh in enhancements:
        now = datetime.now(timezone.utc)
        submitted = now - timedelta(days=enh.get("submitted_days_ago", 30))

        # Include vote count and product area in description for agent queries
        desc = enh.get("description", "").strip()
        desc += f"\n\nProduct Area: {enh.get('product_area', 'N/A')}"
        desc += f"\nRequested By: {enh.get('requested_by', 'N/A')}"
        desc += f"\nVotes: {enh.get('votes', 0)}"
        desc += f"\nStatus: {enh.get('status', 'N/A')}"

        data = {
            "short_description": enh["title"],
            "description": desc,
            "priority": priority_text_map.get(enh.get("priority", "Medium"), "3"),
            "category": "Enhancement",
            "subcategory": enh.get("product_area", ""),
            "company": enh.get("requested_by", ""),
            "opened_at": submitted.strftime("%Y-%m-%d %H:%M:%S"),
        }

        try:
            sys_id, created = snow.find_or_create(
                "incident", "number", enh["number"], data
            )
            action = "Created" if created else "Updated"
            print(f"    {action}: {enh['number']} - {enh['title'][:50]}...")
        except Exception as e:
            print(f"    ERROR: {enh['number']}: {e}")


def reset_servicenow(snow, config):
    """Delete seeded ServiceNow records."""
    print(f"\n{'='*60}")
    print("SERVICENOW RESET")
    print(f"{'='*60}")

    for inc in config.get("servicenow_incidents", []):
        try:
            results = snow.query_table("incident", f"number={inc['number']}", limit=1)
            if results:
                snow.delete_record("incident", results[0]["sys_id"])
                print(f"  Deleted incident: {inc['number']}")
            else:
                print(f"  Not found: {inc['number']}")
        except Exception as e:
            print(f"  ERROR: {inc['number']}: {e}")

    for enh in config.get("servicenow_enhancements", []):
        try:
            results = snow.query_table("incident", f"number={enh['number']}", limit=1)
            if results:
                snow.delete_record("incident", results[0]["sys_id"])
                print(f"  Deleted enhancement: {enh['number']}")
            else:
                print(f"  Not found: {enh['number']}")
        except Exception as e:
            print(f"  ERROR: {enh['number']}: {e}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    parser = argparse.ArgumentParser(
        description="Seed Salesforce and ServiceNow with demo data for Bedrock XAA demo"
    )
    parser.add_argument(
        "--config", default=str(DEFAULT_CONFIG),
        help="Path to demo_data_seed.yaml (default: config/demo_data_seed.yaml)"
    )
    parser.add_argument(
        "--mode", choices=["populate", "reset", "dry-run"], default="dry-run",
        help="Mode: populate (create/update), reset (delete), dry-run (preview)"
    )
    parser.add_argument(
        "--target", choices=["salesforce", "servicenow", "both"], default="both",
        help="Which system to seed"
    )

    # Salesforce credentials
    sf_group = parser.add_argument_group("Salesforce")
    sf_group.add_argument("--sf-instance-url", help="Salesforce instance URL")
    sf_group.add_argument("--sf-client-id", help="Connected app client ID")
    sf_group.add_argument("--sf-client-secret", help="Connected app client secret")

    # ServiceNow credentials
    snow_group = parser.add_argument_group("ServiceNow")
    snow_group.add_argument("--snow-instance-url", help="ServiceNow instance URL")
    snow_group.add_argument("--snow-user", help="ServiceNow username")
    snow_group.add_argument("--snow-password", help="ServiceNow password")

    # SSM
    ssm_group = parser.add_argument_group("AWS SSM")
    ssm_group.add_argument("--use-ssm", action="store_true", help="Read credentials from SSM")
    ssm_group.add_argument("--aws-profile", default=None, help="AWS CLI profile")
    ssm_group.add_argument("--aws-region", default="us-east-2", help="AWS region")

    args = parser.parse_args()

    # Load config
    config_path = Path(args.config)
    if not config_path.exists():
        print(f"ERROR: Config file not found: {config_path}")
        sys.exit(1)

    with open(config_path) as f:
        config = yaml.safe_load(f)

    print(f"Loaded config: {config_path}")
    print(f"Persona: {config['persona']['name']} ({config['persona']['title']})")
    print(f"Mode: {args.mode}")
    print(f"Target: {args.target}")

    # Dry run doesn't need credentials
    if args.mode == "dry-run":
        if args.target in ("salesforce", "both"):
            seed_salesforce(None, config, mode="dry-run")
        if args.target in ("servicenow", "both"):
            seed_servicenow(None, config, mode="dry-run")
        print(f"\n{'='*60}")
        print("DRY RUN COMPLETE — no changes made")
        print(f"{'='*60}")
        return

    # Resolve credentials
    creds = get_credentials(args)

    # Salesforce
    if args.target in ("salesforce", "both"):
        if not all([creds["sf_instance_url"], creds["sf_client_id"], creds["sf_client_secret"]]):
            print("ERROR: Salesforce credentials required (--sf-instance-url, --sf-client-id, --sf-client-secret)")
            sys.exit(1)

        sf = SalesforceClient(
            creds["sf_instance_url"],
            creds["sf_client_id"],
            creds["sf_client_secret"],
        )
        sf.authenticate()

        if args.mode == "populate":
            seed_salesforce(sf, config)
        elif args.mode == "reset":
            reset_salesforce(sf, config)

    # ServiceNow
    if args.target in ("servicenow", "both"):
        if not all([creds["snow_instance_url"], creds["snow_user"], creds["snow_password"]]):
            print("ERROR: ServiceNow credentials required (--snow-instance-url, --snow-user, --snow-password)")
            sys.exit(1)

        snow = ServiceNowClient(
            creds["snow_instance_url"],
            creds["snow_user"],
            creds["snow_password"],
        )

        if args.mode == "populate":
            seed_servicenow(snow, config)
        elif args.mode == "reset":
            reset_servicenow(snow, config)

    print(f"\n{'='*60}")
    print(f"{args.mode.upper()} COMPLETE")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
