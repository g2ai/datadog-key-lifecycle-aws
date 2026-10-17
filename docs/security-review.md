# Security review

What protects the Datadog API key in this design, and where the gaps are.

## 1. Key values never land in code, plan, state or logs

- Values enter Terraform as **ephemeral variables** and are written with **write-only
  arguments** (`secret_string_wo`). A scan of `terraform show -json` found no key values.
- Local values live in a file outside the repo, loaded into the shell by
  `scripts/load-secrets.ps1`, which checks the shape and never prints a value.
- gitleaks runs as a pre-commit hook with a custom Datadog API key rule.
- The census, the check scripts and both Lambdas print the last 4 characters at most.

## 2. Least privilege per role

| Role | Can | Cannot |
|---|---|---|
| `census-reader` | Read key locations (SSM incl. history, launch templates, Lambda, ECS, CloudFormation); decrypt via SSM only | `GetSecretValue` / `BatchGetSecretValue` (explicit Deny) |
| Rotation role | Read the admin secret, manage the API key secret | Anything else; trust limited by `aws:SourceAccount` and `aws:SourceArn` |
| EC2 instance profile (AMI-ref) | `GetSecretValue` on `<name>-??????` | No KMS permission needed (AWS managed key) |
| Lambda consumer | Same secret read + own log group | |
| ECS execution role | Pull, own logs, inject the secret (deploy-time variant) | |
| ECS task role (runtime variant) | Same secret read | |
| Redeploy hook | `ListServices` in one cluster (`ecs:cluster` condition), `UpdateService` on its services | `iam:PassRole` (not needed) |
| Safe-to-rotate | Read the API key secret and the read-only app key; rotate only that secret; publish alerts | |

Trust policies for ECS tasks and the scheduler use `aws:SourceAccount`; the SNS topic
accepts service publishes only from the project's EventBridge rule and alarms.

## 3. Datadog credentials are scoped

| Key | Scope |
|---|---|
| Rotation admin app key (service account) | API and application key management |
| Key-check app key | `api_keys_read` only. List endpoint, never returns key values |
| Monitors app key | `monitors_read`, `monitors_write` |

## 4. Known gaps and trade-offs

| Item | Risk | Fix |
|---|---|---|
| Service account uses the Datadog Admin Role | Broad if the admin secret leaks | Custom role with key permissions only |
| Admin secret is not rotated | Long-lived credential | Rotate the service account app key on its own schedule |
| One ECS execution role for both variants | Runtime variant's execution role can read the secret it does not need | Separate execution roles |
| Safe-to-rotate uses the current API key for its Datadog call | Key value in Lambda memory | Dedicated low-value API key for checks |
| Packer left its temporary public key in `~/.ssh/authorized_keys` | Low (private key deleted, no port 22) | Fixed: `ssh_clear_authorized_keys = true`; verified on a host from the rebuilt image |
| Base AMI was not pinned | Two builds can differ | Fixed: `source_ami` pinned in `packer/base-ami.auto.pkrvars.hcl`, looked up from the AWS public SSM parameter |
| Calls made with a key can update its "last used" (seen in the UI after `/api/v1/validate`; a later check did not show it within minutes, so timing is unclear) | Breaks the safe-to-rotate signal | Never call Datadog with the old key; check scripts are lab-only |
| Census is name-based and cannot see inside images | Missed copies | Safe-to-rotate check as the second line |
| CLI changes to resources Terraform does not track (rule state) are not detected | Silent drift | Set every attribute that matters explicitly (`state = "ENABLED"`) |
| Datadog no-data monitor email was not delivered in the lab | Outage seen in Datadog but nobody told | CloudWatch alarm is the primary alert; test monitor notifications after setup |
| A static API key on every host is the root of the problem | Copies spread | Datadog Workload Identity Federation (see below), not built |

## 5. Next step: no static key on hosts (not built)

Datadog Workload Identity Federation lets the Agent (7.83 and later, on EC2 using IMDS) prove
its AWS identity to Datadog and receive a managed API key that Datadog rotates itself. The
static key stays only as a fallback. It needs the Datadog AWS integration and an intake mapping
in the Datadog org. This would remove most of the copies the census looks for, but it does not
cover every consumer type, so the census and the rotation flow in this repo are still needed.
Check the current Datadog docs for status and supported platforms before relying on it.
