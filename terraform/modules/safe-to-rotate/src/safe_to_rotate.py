"""Safe-to-rotate check (step 3.4).

Managed rotation revokes the key from two rotations back. Right before a rotation,
that key is the one on AWSPREVIOUS. If something still uses it (a key-baked AMI, a task
that was never redeployed), the next rotation takes that consumer down.

So, before rotating:
  1. Read the AWSPREVIOUS key ID from the secret (the ID only; the key value is not used).
  2. Ask Datadog when that key was last used (list endpoint: returns no key values).
  3. Used within IDLE_MINUTES  -> HOLD: do not rotate, send an alert.
     Not used / never used     -> rotate now.

The Datadog call itself uses the AWSCURRENT key, never the old one: calling the API with
the old key would update its "last used" date and make every check say HOLD.

Event input (optional): {"dry_run": true} decides and alerts but never rotates.
Never logs a key value.
"""

import json
import os
import urllib.parse
import urllib.request
from datetime import datetime, timezone

import boto3

sm = boto3.client("secretsmanager")
sns = boto3.client("sns")

SECRET_ID = os.environ["API_KEY_SECRET_ID"]
APP_KEY_SECRET_ID = os.environ["APP_KEY_SECRET_ID"]
SITE = os.environ.get("DD_SITE", "datadoghq.eu")
IDLE_MINUTES = int(os.environ.get("IDLE_MINUTES", "1440"))
TOPIC_ARN = os.environ["TOPIC_ARN"]


def log(msg, **fields):
    print(json.dumps({"msg": msg, **fields}, default=str))


def secret_json(stage):
    try:
        resp = sm.get_secret_value(SecretId=SECRET_ID, VersionStage=stage)
    except sm.exceptions.ResourceNotFoundException:
        return None
    return json.loads(resp["SecretString"])


def last_used(key_id, api_key, app_key):
    """Return (date_last_used or None, last4) for one API key ID, using the list endpoint."""
    page = 0
    while True:
        query = urllib.parse.urlencode({"page[size]": 100, "page[number]": page})
        req = urllib.request.Request(
            f"https://api.{SITE}/api/v2/api_keys?{query}",
            headers={"DD-API-KEY": api_key, "DD-APPLICATION-KEY": app_key, "Accept": "application/json"},
        )
        with urllib.request.urlopen(req, timeout=10) as r:
            data = json.load(r)["data"]
        for k in data:
            if k["id"] == key_id:
                a = k["attributes"]
                return a.get("date_last_used"), a.get("last4")
        if len(data) < 100:
            raise LookupError(f"API key id {key_id} not found in Datadog")
        page += 1


def alert(subject, text):
    sns.publish(TopicArn=TOPIC_ARN, Subject=subject[:99], Message=text)


def handler(event, context):
    dry_run = bool((event or {}).get("dry_run", False))

    previous = secret_json("AWSPREVIOUS")
    current = secret_json("AWSCURRENT")
    app_key = sm.get_secret_value(SecretId=APP_KEY_SECRET_ID)["SecretString"]

    if previous is None:
        decision, reason, used, last4 = "ROTATE", "no AWSPREVIOUS version yet", None, None
    else:
        used, last4 = last_used(previous["apiKeyId"], current["apiKey"], app_key)
        if used is None:
            decision, reason = "ROTATE", "AWSPREVIOUS key never used"
        else:
            age_min = (datetime.now(timezone.utc) - datetime.fromisoformat(used.replace("Z", "+00:00"))).total_seconds() / 60
            if age_min < IDLE_MINUTES:
                decision, reason = "HOLD", f"AWSPREVIOUS key ...{last4} last used {age_min:.0f} min ago (limit {IDLE_MINUTES})"
            else:
                decision, reason = "ROTATE", f"AWSPREVIOUS key ...{last4} idle for {age_min:.0f} min"

    log("decision", decision=decision, reason=reason, date_last_used=used, dry_run=dry_run)

    if decision == "HOLD":
        alert("poc-02 key rotation HELD",
              f"Rotation of {SECRET_ID} was NOT started.\n{reason}.\n"
              "Something still uses the key that the next rotation would revoke. "
              "Find it (census, Datadog API Keys page), move it to a runtime reader or redeploy it, "
              "then run the check again. The AWS rotation schedule remains the hard backstop.")
    elif not dry_run:
        sm.rotate_secret(SecretId=SECRET_ID)
        log("rotation started")

    return {"decision": decision, "reason": reason, "dry_run": dry_run}
