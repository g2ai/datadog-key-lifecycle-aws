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
| Packer leaves its temporary public key in `~/.ssh/authorized_keys` | Low (private key deleted, no port 22) | `ssh_clear_authorized_keys = true` |
| Base AMI not pinned | Two builds can differ | Pin `source_ami` |
| `/api/v1/validate` calls update "last used" | Breaks the safe-to-rotate signal | Never validate old keys; check scripts are lab-only |
| Census is name-based and cannot see inside images | Missed copies | Safe-to-rotate check as the second line |
| CLI changes to resources Terraform does not track (rule state) are not detected | Silent drift | Set every attribute that matters explicitly (`state = "ENABLED"`) |
