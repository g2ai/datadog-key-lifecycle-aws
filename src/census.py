"""Census v0: find where Datadog API keys live in an AWS account.

Read only. Assumes the census-reader role, scans every enabled region and
classifies each finding:

  COPY       the key value itself sits in the resource. Rotation breaks it.
  REFERENCE  the resource points at a secret (ENC[...], secret ARN). Survives rotation.
  HIDDEN     AWS will not show the value (CloudFormation NoEcho). Check by hand.

Never prints or stores a full key. Output shows the last 4 characters only.
Exit code 1 when at least one COPY is found, so it can gate a pipeline.

Usage:
  python src/census.py --profile poc02 --role-arn arn:aws:iam::123456789012:role/poc-02-census-reader
"""

from __future__ import annotations

import argparse
import base64
import gzip
import json
import re
import sys
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

COPY, REFERENCE, HIDDEN = "COPY", "REFERENCE", "HIDDEN"

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
                        out.append(Finding(account, region, "ecs-task-def", label,
                                           f"{c['name']} secrets {sec['name']}", REFERENCE, "----"))
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


def print_table(findings):
    cols = ["account", "region", "service", "resource", "field", "cls", "last4"]
    heads = ["ACCOUNT", "REGION", "SERVICE", "RESOURCE", "FIELD", "CLASS", "LAST4"]
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
    ap.add_argument("--regions", nargs="*", help="limit to these regions (default: all enabled)")
    ap.add_argument("--out-dir", default="census-output", help="where the JSON report goes")
    args = ap.parse_args()

    creds, home_region = assume(args.profile, args.role_arn)
    session = boto3.Session(**creds)
    account = session.client("sts").get_caller_identity()["Account"]
    regions = args.regions or sorted(
        r["RegionName"] for r in session.client("ec2", region_name=home_region).describe_regions()["Regions"])

    print(f"Census v0  account {account}  regions {len(regions)}", file=sys.stderr)
    findings, errors, secrets = [], [], 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        for f, e, s in pool.map(lambda r: scan_region(creds, account, r), regions):
            findings += f
            errors += e
            secrets += s

    order = {COPY: 0, HIDDEN: 1, REFERENCE: 2}
    findings.sort(key=lambda f: (order[f.cls], f.region, f.service, f.resource))
    print_table(findings)

    counts = {k: sum(1 for f in findings if f.cls == k) for k in (COPY, REFERENCE, HIDDEN)}
    print(f"\nSummary: {counts[COPY]} COPY, {counts[REFERENCE]} REFERENCE, {counts[HIDDEN]} HIDDEN")
    print(f"Secrets Manager: {secrets} secret(s) with 'datadog' in the name (values not read)")
    if errors:
        print(f"\n{len(errors)} scan error(s):", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)

    out_dir = Path(args.out_dir)
    out_dir.mkdir(exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    report = {"account": account, "scanned_at": stamp, "regions": regions, "counts": counts,
              "datadog_secrets": secrets, "errors": errors, "findings": [asdict(f) for f in findings]}
    path = out_dir / f"census-{account}-{stamp}.json"
    path.write_text(json.dumps(report, indent=2))
    print(f"Report: {path}", file=sys.stderr)

    sys.exit(1 if counts[COPY] else 0)


if __name__ == "__main__":
    main()
