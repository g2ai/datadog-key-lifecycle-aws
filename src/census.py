"""Census v1: find where Datadog API keys live in an AWS account.

Read only. Assumes the census-reader role, scans the chosen regions and
classifies each finding:

  COPY         the key value itself sits in the resource. The second rotation breaks it.
  DEPLOY-TIME  the resource points at the secret, but the value is read once, when it
               starts (ECS task definition "secrets"). Survives only if it is redeployed
               after each rotation (see the redeploy hook).
  REFERENCE    the consumer reads the secret at runtime (ENC[...], secret ARN). Survives.
  HIDDEN       AWS will not show the value (CloudFormation NoEcho). Check by hand.

v1 adds DEPLOY-TIME and, with --datadog-status, a LIVE / not live status for every COPY:
the last 4 characters are matched against the org's API keys (list endpoint, which never
returns key values). Needs DD_API_KEY and DD_APP_KEY in the environment; the app key
only needs the api_keys_read scope. The census role itself still cannot read secrets.

Never prints or stores a full key. Output shows the last 4 characters only.
Exit codes: 0 clean, 1 at least one COPY found (with --datadog-status: at least one
LIVE copy), 2 scan incomplete (errors, nothing else). An incomplete scan must never look clean.

Two modes, one must be chosen:
  --regions eu-west-1 us-east-1   daily / pre-rotation run on the regions in use
  --all-regions                   weekly sweep, finds keys in regions nobody expects

Usage:
  python src/census.py --profile poc02 --role-arn arn:aws:iam::123456789012:role/poc-02-census-reader --all-regions
"""

from __future__ import annotations

import argparse
import base64
import gzip
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from pathlib import Path

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# Same pattern as the datadog-api-key rule in .gitleaks.toml: prevention and
# discovery share one definition of "a Datadog API key".
KEY_IN_TEXT = re.compile(r"""(?i)api_key\s*[:=]\s*['"]?([a-f0-9]{32})\b""")
REF_IN_TEXT = re.compile(r"""(?i)api_key\s*[:=]\s*['"]?(ENC\[[^\]]+\]|arn:aws:(?:secretsmanager|ssm):\S+)""")

# For name/value pairs (env vars, parameters): the name must look like a key
# name, the value must be exactly 32 lowercase hex. This keeps checksums out.
KEY_NAME = re.compile(r"(?i)api[_-]?key")
KEY_VALUE = re.compile(r"^[a-f0-9]{32}$")
REF_VALUE = re.compile(r"ENC\[|arn:aws:secretsmanager:|arn:aws:ssm:")

COPY, DEPLOY_TIME, REFERENCE, HIDDEN = "COPY", "DEPLOY-TIME", "REFERENCE", "HIDDEN"

BOTO_CONFIG = Config(retries={"max_attempts": 8, "mode": "adaptive"})


@dataclass
class Finding:
    account: str
    region: str
    service: str
    resource: str
    field: str
    cls: str
    last4: str
    dd_status: str = ""


def classify_pair(name: str, value: str | None) -> tuple[str, str] | None:
    """Classify one name=value pair. Returns (class, last4) or None."""
    if not name or not KEY_NAME.search(name) or value is None:
        return None
    value = value.strip()
    if value == "****":
        return HIDDEN, "----"
    if KEY_VALUE.match(value):
        return COPY, value[-4:]
    if REF_VALUE.search(value):
        return REFERENCE, "----"
    return None


def classify_text(text: str) -> list[tuple[str, str]]:
    """Find keys and references inside a blob (user data, config files)."""
    results = [(COPY, m.group(1)[-4:]) for m in KEY_IN_TEXT.finditer(text)]
    results += [(REFERENCE, "----") for _ in REF_IN_TEXT.finditer(text)]
    return results


def decode_user_data(b64: str) -> str:
    raw = base64.b64decode(b64)
    if raw[:2] == b"\x1f\x8b":  # gzip compressed user data
        raw = gzip.decompress(raw)
    return raw.decode("utf-8", errors="replace")


# --- Collectors: one per service, each returns findings for one region ---

def scan_ssm(session, account, region):
    ssm = session.client("ssm", region_name=region, config=BOTO_CONFIG)
    names = []
    for page in ssm.get_paginator("describe_parameters").paginate():
        names += [p["Name"] for p in page["Parameters"]]
    out = []
    for i in range(0, len(names), 10):  # GetParameters takes up to 10 names
        resp = ssm.get_parameters(Names=names[i:i + 10], WithDecryption=True)
        for p in resp["Parameters"]:
            hit = classify_pair(p["Name"], p["Value"])
            hits = [hit] if hit else classify_text(p["Value"])
            for cls, last4 in hits:
                out.append(Finding(account, region, "ssm", p["Name"], f"value ({p['Type']})", cls, last4))
            # Old versions keep old values. A key "migrated" to ENC[...] is still
            # readable from history until it is rotated. Only key-like names are
            # checked, to keep one extra API call per parameter to a minimum.
            if KEY_NAME.search(p["Name"]):
                out += scan_ssm_history(ssm, account, region, p["Name"], p["Version"])
    return out


def scan_ssm_history(ssm, account, region, name, current_version):
    out = []
    pages = ssm.get_paginator("get_parameter_history").paginate(Name=name, WithDecryption=True)
    for page in pages:
        for h in page["Parameters"]:
            if h["Version"] == current_version:
                continue
            hit = classify_pair(name, h.get("Value"))
            if hit and hit[0] == COPY:
                out.append(Finding(account, region, "ssm", name,
                                   f"history v{h['Version']} ({h['Type']})", COPY, hit[1]))
    return out


def scan_launch_templates(session, account, region):
    ec2 = session.client("ec2", region_name=region, config=BOTO_CONFIG)
    out = []
    for page in ec2.get_paginator("describe_launch_templates").paginate():
        for lt in page["LaunchTemplates"]:
            # Every version, not only $Latest: old versions keep old keys.
            versions = ec2.get_paginator("describe_launch_template_versions").paginate(
                LaunchTemplateId=lt["LaunchTemplateId"])
            for vpage in versions:
                for v in vpage["LaunchTemplateVersions"]:
                    ud = v.get("LaunchTemplateData", {}).get("UserData")
                    if not ud:
                        continue
                    for cls, last4 in classify_text(decode_user_data(ud)):
                        out.append(Finding(account, region, "ec2-launch-template",
                                           f"{lt['LaunchTemplateName']} v{v['VersionNumber']}",
                                           "user data", cls, last4))
    return out


def scan_lambda(session, account, region):
    lam = session.client("lambda", region_name=region, config=BOTO_CONFIG)
    out = []
    # FunctionVersion=ALL: published versions keep the env vars they were published with.
    for page in lam.get_paginator("list_functions").paginate(FunctionVersion="ALL"):
        for fn in page["Functions"]:
            variables = (fn.get("Environment") or {}).get("Variables") or {}
            for name, value in variables.items():
                hit = classify_pair(name, value)
                if hit:
                    ver = fn.get("Version", "$LATEST")
                    out.append(Finding(account, region, "lambda", f"{fn['FunctionName']}:{ver}",
                                       f"env {name}", *hit))
    return out


def scan_ecs(session, account, region):
    ecs = session.client("ecs", region_name=region, config=BOTO_CONFIG)
    out = []
    for page in ecs.get_paginator("list_task_definitions").paginate(status="ACTIVE"):
        for arn in page["taskDefinitionArns"]:
            td = ecs.describe_task_definition(taskDefinition=arn)["taskDefinition"]
            label = f"{td['family']}:{td['revision']}"
            for c in td.get("containerDefinitions", []):
                for env in c.get("environment", []):
                    hit = classify_pair(env.get("name", ""), env.get("value"))
                    if hit:
                        out.append(Finding(account, region, "ecs-task-def", label,
                                           f"{c['name']} environment {env['name']}", *hit))
                for sec in c.get("secrets", []):
                    if KEY_NAME.search(sec.get("name", "")):
                        # ECS injects "secrets" once, at task start: a reference on paper,
                        # a copy in practice until the task is replaced.
                        out.append(Finding(account, region, "ecs-task-def", label,
                                           f"{c['name']} secrets {sec['name']}", DEPLOY_TIME, "----"))
    return out


def scan_cloudformation(session, account, region):
    cfn = session.client("cloudformation", region_name=region, config=BOTO_CONFIG)
    out = []
    for page in cfn.get_paginator("describe_stacks").paginate():
        for st in page["Stacks"]:
            for p in st.get("Parameters", []):
                hit = classify_pair(p["ParameterKey"], p.get("ParameterValue"))
                if hit:
                    out.append(Finding(account, region, "cloudformation", st["StackName"],
                                       f"parameter {p['ParameterKey']}", *hit))
    return out


def count_datadog_secrets(session, region):
    """Metadata only. The role is denied GetSecretValue on purpose."""
    sm = session.client("secretsmanager", region_name=region, config=BOTO_CONFIG)
    n = 0
    for page in sm.get_paginator("list_secrets").paginate():
        n += sum(1 for s in page["SecretList"] if "datadog" in s["Name"].lower())
    return n


COLLECTORS = {
    "ssm": scan_ssm,
    "ec2-launch-template": scan_launch_templates,
    "lambda": scan_lambda,
    "ecs-task-def": scan_ecs,
    "cloudformation": scan_cloudformation,
}


def scan_region(creds, account, region):
    session = boto3.Session(**creds)
    findings, errors = [], []
    for service, fn in COLLECTORS.items():
        try:
            findings += fn(session, account, region)
        except (ClientError, BotoCoreError) as e:
            errors.append(f"{region} {service}: {e}")
    try:
        secrets = count_datadog_secrets(session, region)
    except (ClientError, BotoCoreError) as e:
        secrets = 0
        errors.append(f"{region} secretsmanager: {e}")
    return findings, errors, secrets


def assume(profile, role_arn):
    base = boto3.Session(profile_name=profile)
    c = base.client("sts").assume_role(RoleArn=role_arn, RoleSessionName="census")["Credentials"]
    return {
        "aws_access_key_id": c["AccessKeyId"],
        "aws_secret_access_key": c["SecretAccessKey"],
        "aws_session_token": c["SessionToken"],
    }, base.region_name or "eu-west-1"


def datadog_status(findings, site):
    """Mark each COPY as LIVE (matches an active org API key) or not live. Values never leave AWS."""
    api_key, app_key = os.environ.get("DD_API_KEY"), os.environ.get("DD_APP_KEY")
    if not api_key or not app_key:
        raise SystemExit("--datadog-status needs DD_API_KEY and DD_APP_KEY (api_keys_read) in the environment")
    by_last4, page = {}, 0
    while True:
        query = urllib.parse.urlencode({"page[size]": 100, "page[number]": page})
        req = urllib.request.Request(f"https://api.{site}/api/v2/api_keys?{query}",
                                     headers={"DD-API-KEY": api_key, "DD-APPLICATION-KEY": app_key})
        with urllib.request.urlopen(req, timeout=15) as r:
            data = json.load(r)["data"]
        for k in data:
            a = k["attributes"]
            by_last4.setdefault(a.get("last4"), []).append(a)
        if len(data) < 100:
            break
        page += 1
    for f in findings:
        if f.cls != COPY:
            continue
        hits = by_last4.get(f.last4, [])
        if not hits:
            f.dd_status = "not live"
        elif len(hits) == 1:
            used = (hits[0].get("date_last_used") or "never")[:16]
            f.dd_status = f"LIVE (used {used})"
        else:
            f.dd_status = f"LIVE? {len(hits)} keys share last4"


def print_table(findings):
    cols = ["account", "region", "service", "resource", "field", "cls", "last4", "dd_status"]
    heads = ["ACCOUNT", "REGION", "SERVICE", "RESOURCE", "FIELD", "CLASS", "LAST4", "DATADOG"]
    rows = [[str(getattr(f, c)) for c in cols] for f in findings]
    widths = [max([len(h)] + [len(r[i]) for r in rows]) for i, h in enumerate(heads)]
    line = "  ".join(h.ljust(w) for h, w in zip(heads, widths))
    print(line)
    print("-" * len(line))
    for r in rows:
        print("  ".join(v.ljust(w) for v, w in zip(r, widths)))


def main():
    ap = argparse.ArgumentParser(description="Find Datadog API key copies and references in AWS")
    ap.add_argument("--profile", required=True, help="AWS CLI profile used only to assume the role")
    ap.add_argument("--role-arn", required=True, help="census-reader role ARN")
    mode = ap.add_mutually_exclusive_group(required=True)
    mode.add_argument("--regions", nargs="+", help="daily mode: scan only these regions")
    mode.add_argument("--all-regions", action="store_true", help="sweep mode: scan every enabled region")
    ap.add_argument("--out-dir", default="census-output", help="where the JSON report goes")
    ap.add_argument("--datadog-status", action="store_true",
                    help="mark each COPY as LIVE / not live in Datadog (needs DD_API_KEY, DD_APP_KEY)")
    ap.add_argument("--dd-site", default="datadoghq.eu")
    args = ap.parse_args()

    creds, home_region = assume(args.profile, args.role_arn)
    session = boto3.Session(**creds)
    account = session.client("sts").get_caller_identity()["Account"]
    regions = args.regions or sorted(
        r["RegionName"] for r in session.client("ec2", region_name=home_region).describe_regions()["Regions"])

    mode = "sweep" if args.all_regions else "daily"
    print(f"Census v1  account {account}  mode {mode}  regions {len(regions)}", file=sys.stderr)
    findings, errors, secrets = [], [], 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        for f, e, s in pool.map(lambda r: scan_region(creds, account, r), regions):
            findings += f
            errors += e
            secrets += s

    if args.datadog_status:
        datadog_status(findings, args.dd_site)

    order = {COPY: 0, DEPLOY_TIME: 1, HIDDEN: 2, REFERENCE: 3}
    findings.sort(key=lambda f: (order[f.cls], f.region, f.service, f.resource))
    print_table(findings)

    counts = {k: sum(1 for f in findings if f.cls == k) for k in (COPY, DEPLOY_TIME, REFERENCE, HIDDEN)}
    live = sum(1 for f in findings if f.dd_status.startswith("LIVE"))
    print(f"\nSummary: {counts[COPY]} COPY, {counts[DEPLOY_TIME]} DEPLOY-TIME, "
          f"{counts[REFERENCE]} REFERENCE, {counts[HIDDEN]} HIDDEN")
    if args.datadog_status:
        print(f"Datadog: {live} of {counts[COPY]} COPY findings match a live API key")
    print(f"Secrets Manager: {secrets} secret(s) with 'datadog' in the name (values not read)")
    if errors:
        print(f"\n{len(errors)} scan error(s):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report = {"account": account, "scanned_at": stamp, "mode": mode, "regions": regions, "counts": counts,
              "datadog_status": bool(args.datadog_status), "live_copies": live,
              "datadog_secrets": secrets, "errors": errors, "findings": [asdict(f) for f in findings]}
    path = out_dir / f"census-{account}-{stamp}.json"
    path.write_text(json.dumps(report, indent=2))
    print(f"Report: {path}", file=sys.stderr)

    failing = live if args.datadog_status else counts[COPY]
    if failing:
        sys.exit(1)
    sys.exit(2 if errors else 0)


if __name__ == "__main__":
    main()
