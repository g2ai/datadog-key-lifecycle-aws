# Running this at scale (10 to 100 AWS accounts)

The lab runs in one AWS account and one Datadog org. This page describes how the same
modules map to an estate of 10 to 100 accounts. Parts marked "not built" are design only.

## 1. One key per account, one secret name everywhere

- Each account gets its own managed secret `datadog/api-key` (type `DatadogApiKey`) and its
  own rotation. One Datadog API key per account limits the blast radius of a leak and makes
  the key name (`aws-sm-api-key-<secret name>-<timestamp>`) point to one account.
- The secret **name** is the same in every account. Golden images and task definitions use
  `ENC[datadog/api-key;apiKey]` (name, not ARN), so one AMI or one task definition works in
  every account. Proven in the lab with the AMI-ref build.

## 2. Where the admin credentials live

Managed rotation needs a Datadog service account key pair (`DatadogAdminKey` secret).

| Option | How | Trade-off |
|---|---|---|
| Per account (lab) | Admin secret in every account | Simple. N copies of a powerful credential |
| Central | Admin secret in a security account, shared with a resource policy and a KMS key policy | One copy. Cross-account reads and KMS grants to maintain (not built) |

Either way, the Datadog service account should get a custom role with only the API key and
application key permissions rotation needs, not the Datadog Admin Role used in the lab.

## 3. Rotation schedule and the safe-to-rotate check

- Two keys are valid at any time (AWSCURRENT and AWSPREVIOUS). A key dies at the second
  rotation after it was created, so with a check every **45 days** no key lives longer than
  about 90 days.
- EventBridge Scheduler runs the check every 45 days per account. Set `schedule_start_date`:
  a `rate()` schedule without a start date runs right after it is created (seen in the lab:
  an apply triggered one unplanned rotation).
- The check holds the rotation if the key about to be revoked was used in the last day.
  Datadog rounds `date_last_used` down to the hour, so the idle limit must be well above one
  hour (prod: 1440 minutes).
- The managed rotation schedule (`rate(90 days)`) stays as a backstop: a hold cannot last forever.
- The check must never call Datadog with the old key. A call made with a key can update its
  "last used" time, which would turn every check into a hold.
- The check also holds while any version carries `AWSPENDING`. The lab saw `AWSPENDING` left on
  the current version twice: after repeated `rotate-secret` calls, and after a failed rotation
  that AWS retried and completed once the fault was fixed. Alert on the hold, check both keys,
  then remove the label with `update-secret-version-stage --remove-from-version-id`.

## 4. Consumers: one rule

**A consumer survives rotation if it reads the key again before the second rotation.**

| Consumer type | Reads the key | What to do at scale |
|---|---|---|
| Agent with secrets backend (EC2, ECS B) | At runtime, on a timer and after a 403 | Default. Refresh interval far below 45 days (1 h in the lab AMI) |
| Lambda extension | At runtime, reload timer | Extension v99+ for the managed secret's `apiKey` field |
| ECS task definition `secrets` | Once, at task start | Tag the service `DatadogKeyDelivery=deploy-time`; the redeploy hook redeploys it on every key change |
| Key in an AMI, user data, env var, SSM parameter | Never again | Find with the census, migrate before the next rotation |

The redeploy hook uses the native `Secret Label Updated` event. Native events reach the
default bus without a CloudTrail trail. The rotation alerts use CloudTrail-derived events
(`RotationSucceeded`, `RotationFailed`), which do need a trail: use one organization trail.

## 5. Census across accounts

- Deploy the `census-reader` role to every account (StackSets or Terraform per account),
  trusted by one security account. The role reads key locations and is denied
  `GetSecretValue`.
- **Daily** (`--regions` in use): before each rotation check. **Weekly sweep**
  (`--all-regions`): finds keys in regions nobody expects. An SCP that denies unused regions
  makes the sweep cheaper and the daily run safer.
- Exit codes gate pipelines: 0 clean, 1 live copy found, 2 scan incomplete. An incomplete
  scan never looks clean.
- `--datadog-status` marks each copy as LIVE or not live (last 4 characters matched against
  the org's API keys with an `api_keys_read` app key). Copies of revoked keys are clean-up
  work; live copies block rotation.
- Limits: detection is name-based for name/value pairs (`api_key` in the name), and the
  census cannot see inside AMIs or container images. That is why the safe-to-rotate check
  exists: it catches what the census cannot see.

## 6. Monitoring

- **AWS side:** a revoked key means the Agent's data never reaches Datadog, so Datadog cannot
  alert on the 403 itself. Count `API Key invalid` lines in CloudWatch Logs (metric filter
  plus alarm) for every log group that holds Agent logs.
- **Datadog side:** no-data monitors per host group or ECS task family.
- ECS reports a task as running while its Agent drops every payload. Service health is not
  monitoring health.
- In the lab the CloudWatch alarm fired in about 2 minutes and the Datadog no-data monitor
  detected the gap in about 10. The monitor's email was not delivered, so send a test
  notification from every new monitor before trusting it.

## 7. Cost per account [ESTIMATE]

| Item | Monthly |
|---|---|
| 2 secrets (API key, admin) | $0.80 at $0.40 per secret ([AWS pricing](https://aws.amazon.com/secrets-manager/pricing/)) |
| API calls: Agent refresh every hour on 100 hosts | about 72,000 calls, about $0.36 at $0.05 per 10,000 |
| Lambda, EventBridge, SNS for checks and hooks | well inside free tiers at this volume |
| Organization trail | first copy of management events free; S3 storage extra |

For 100 accounts: roughly $80 to $120 per month, driven by secret count and refresh calls.

## 8. Not built: next steps

- **Cross-account wiring:** census role in every account trusted by a security account, and a
  central admin secret shared by resource policy (sections 2 and 5).
- **Custom Datadog role** for the rotation service account instead of the Admin Role.
- **Workload Identity Federation** for Agents on EC2, so hosts carry no static key
  (see [security review](security-review.md)).
- **Remote Terraform state** and a configurable name prefix, so more than one copy of the
  lab can run in one account.
