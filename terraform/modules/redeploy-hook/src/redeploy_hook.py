"""Redeploy hook: when the Datadog API key secret gets a new AWSCURRENT version,
force a new deployment of every ECS service that gets the key at deploy time.

Which services? Those tagged <TAG_KEY>=<TAG_VALUE> (default DatadogKeyDelivery=deploy-time).
Tag-based, so new services opt in with a tag and no change to this function.
Services that read the key at runtime (Agent secrets backend) are not touched.
"""

import json
import os

import boto3

ecs = boto3.client("ecs")

CLUSTER = os.environ["CLUSTER"]
TAG_KEY = os.environ.get("TAG_KEY", "DatadogKeyDelivery")
TAG_VALUE = os.environ.get("TAG_VALUE", "deploy-time")


def log(msg, **fields):
    print(json.dumps({"msg": msg, **fields}))


def handler(event, context):
    detail = event.get("detail", {})
    log("key changed", secret=detail.get("name"), label=detail.get("labelUpdated"),
        version=detail.get("versionId"))

    arns = []
    for page in ecs.get_paginator("list_services").paginate(cluster=CLUSTER):
        arns += page["serviceArns"]

    redeployed, skipped = [], []
    for i in range(0, len(arns), 10):  # DescribeServices takes up to 10 services
        resp = ecs.describe_services(cluster=CLUSTER, services=arns[i:i + 10], include=["TAGS"])
        for svc in resp["services"]:
            tags = {t["key"]: t["value"] for t in svc.get("tags", [])}
            if svc["status"] == "ACTIVE" and tags.get(TAG_KEY) == TAG_VALUE:
                ecs.update_service(cluster=CLUSTER, service=svc["serviceName"], forceNewDeployment=True)
                redeployed.append(svc["serviceName"])
            else:
                skipped.append(svc["serviceName"])

    log("done", cluster=CLUSTER, redeployed=redeployed, skipped=skipped)
    return {"redeployed": redeployed}
