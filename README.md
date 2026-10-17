# Datadog key lifecycle on AWS: find, rotate, remove

Rotating a Datadog API key is one API call. The hard part is everything that still holds the old key: an AMI with the key baked in, an ECS task that read it at deploy time, a Lambda, a parameter someone copied years ago. This repo is a working lab that answers three questions for one AWS account, built so the same modules can run per account at scale:

1. **Find.** Where do copies of the Datadog key live, and which of them are still live? (`src/census.py`)
2. **Rotate.** Rotate the key with AWS Secrets Manager managed external secrets, and check first that nothing still uses the key that will be revoked. (`terraform/modules/rotation`, `terraform/modules/safe-to-rotate`)
3. **Remove.** Show which delivery patterns survive a rotation and which go dark, then fix the ones that break. (EC2, Lambda, ECS Fargate consumers)

Status: lab build complete. Tested on Datadog EU (`datadoghq.eu`), AWS `eu-west-1`.

## What the lab showed

Each consumer was tested across real rotations. Results from the lab:

| Consumer | How it gets the key | After rotation |
|---|---|---|
| EC2, AMI-baked | key written into `datadog.yaml` in the image | Goes dark when the key is revoked (two rotations later). Only a rebuild fixes it. |
| EC2, AMI-ref | `api_key: ENC[...]` read from Secrets Manager by the Agent secrets backend | No gap |
| Lambda | Datadog extension reads the secret ARN | No gap |
| ECS A | task definition `secrets` (read once at deploy) | 403 from Datadog while ECS still shows the task as running. Fixed by the redeploy hook. |
| ECS B | Agent secrets backend with refresh on 403 | Recovers by itself within about 1 second of the first 403 |

Other findings:

- Datadog cannot see a rejected key. A CloudWatch Logs metric filter on `API Key invalid` alarmed in about 2 minutes; the Datadog no-data monitor needed about 10.
- Datadog reports `date_last_used` rounded down to the hour, so "idle" checks need a margin (120 minutes in the lab).
- Repeated `rotate-secret` calls can leave `AWSPENDING` stuck. The safe-to-rotate check holds while any version carries `AWSPENDING`.

## Architecture

```mermaid
flowchart LR
  subgraph AWS account
    SM[(Secrets Manager<br/>DatadogApiKey<br/>DatadogAdminKey)]
    SCH[Scheduler<br/>rate 45 days] --> STR[Lambda<br/>safe-to-rotate]
    STR -- "last used?" --> DDAPI
    STR -- "RotateSecret" --> SM
    SM -- "managed rotation" --> DDAPI
    SM -- "Secret Label Updated" --> EB[EventBridge]
    EB --> HOOK[Lambda<br/>redeploy hook] --> ECSA[ECS A<br/>deploy-time key]
    EB --> SNS[SNS email]
    SM --> ECSB[ECS B<br/>Agent secrets backend]
    SM --> LMB[Lambda<br/>Datadog extension]
    SM --> EC2R[EC2 AMI-ref]
    EC2B[EC2 AMI-baked<br/>key in image]
    CW[CloudWatch alarm<br/>API Key invalid] --> SNS
    CEN[census.py<br/>read-only role] -. scans .-> SM
  end
  DDAPI[Datadog API<br/>datadoghq.eu]
```

Docs: [scale design](docs/scale.md), [security review](docs/security-review.md).

## Repo layout

```text
packer/                 AMI-ref (no key) and AMI-baked (anti-pattern) images
src/census.py           finds key copies across regions; --datadog-status marks LIVE copies
scripts/                load-secrets.ps1 (Datadog values into TF_VAR_*), check-dd-keys.ps1
terraform/modules/      datadog-secrets, rotation, rotation-alerts, cloudtrail, census-reader,
                        consumer-access, redeploy-hook, safe-to-rotate
terraform/envs/lab/     the lab: wires the modules, network, hosts, Lambda, ECS, monitoring
terraform/envs/seed/    planted key copies for the census test (destroy after use)
```

## Prerequisites and costs

Tools (versions used in the lab; Windows PowerShell 5.1):

| Tool | Version |
|---|---|
| Terraform | 1.15 or later (providers: aws `~> 6.68`, datadog `~> 4.25`, archive `~> 2.8`) |
| Packer | 1.16 or later (amazon plugin `~> 1.8`) |
| AWS CLI | v2, with IAM Identity Center (SSO) |
| Python | 3.12 with `boto3` from `requirements.txt` |
| gitleaks | 8.30.1 (pre-commit hook) |

Accounts:

- An AWS account you can delete things in, with two SSO profiles: `poc02` (apply) and `poc02-ro` (read-only, for plan).
- A Datadog org (a trial works). In Datadog create a service account and these keys. You only keep the values in a local file outside the repo.

| Value | What it is |
|---|---|
| `DD_ADMIN_API_KEY`, `DD_ADMIN_API_KEY_ID` | API key for the admin secret that Secrets Manager uses to call Datadog |
| `DD_ADMIN_APP_KEY`, `DD_ADMIN_APP_KEY_ID` | Application key of the service account, used by the managed rotation |
| `DD_SERVICE_ACCOUNT_ID` | The service account ID |
| `DD_CONSUMER_API_KEY`, `DD_CONSUMER_API_KEY_ID` | The API key the Agents use. This is the key that rotates. |
| `DD_KEYCHECK_APP_KEY` | Application key with only `api_keys_read`, for the safe-to-rotate check |
| `DD_MONITORS_APP_KEY` | Application key with only `monitors_read` and `monitors_write`, for the Terraform Datadog provider |

Costs (AWS, `eu-west-1`). Everything that runs continuously is off by default.

| Item | Cost | Guardrail |
|---|---|---|
| Secrets Manager | $0.40 per secret per month, $0.05 per 10,000 API calls ([pricing](https://aws.amazon.com/secrets-manager/pricing/)) | 3 secrets |
| EC2 t3.micro x2 | per hour while on | `hosts_enabled = false` by default |
| ECS Fargate 0.25 vCPU / 0.5 GB x2 | per hour while on | `ecs_enabled = false` by default |
| CloudTrail | first management trail copy is free; S3 storage | one trail |
| Lambda, EventBridge, SNS, CloudWatch | free tier at lab volume | |

Set an AWS budget alert before you start. Run the teardown at the end.

## Quickstart

All commands are PowerShell. Run them from the repo root unless a step says otherwise.

### 1. Clone and install

```powershell
git clone https://github.com/g2ai/datadog-key-lifecycle-aws.git
cd datadog-key-lifecycle-aws
py -3.12 -m pip install -r requirements.txt
```

### 2. Sign in to AWS

```powershell
aws sso login --profile poc02
aws sts get-caller-identity --profile poc02-ro
```

### 3. Load the Datadog values

Copy `.env.example` to `$HOME\poc-secrets\poc-02.env` (outside the repo) and fill in the values from the table above. Then load them into this PowerShell window only. Note the leading dot.

```powershell
. .\scripts\load-secrets.ps1
```

Every line must say `ok`. The script never prints a value.

### 4. Set the alert email

```powershell
Copy-Item terraform\envs\lab\terraform.tfvars.example terraform\envs\lab\terraform.tfvars
notepad terraform\envs\lab\terraform.tfvars
```

`terraform.tfvars` is git-ignored.

### 5. Build the AMI (only if you want the EC2 hosts)

The base image is pinned in `packer/base-ami.auto.pkrvars.hcl`. Update it from the public SSM parameter when you want a newer base:

```powershell
aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 --query Parameter.Value --output text --profile poc02-ro --region eu-west-1
```

```powershell
cd packer
packer init .
packer validate .
packer build -only="ref.*" .
cd ..
```

The AMI-baked image writes a live key into the image. Build it only to repeat the "goes dark" test, and deregister it afterwards.

### 6. Apply the lab

```powershell
cd terraform\envs\lab
terraform init
terraform plan -out lab.tfplan
terraform apply -var aws_profile=poc02 lab.tfplan
```

Confirm the SNS subscription email. The base apply creates the secrets, the rotation role, alerts, the census reader role, the Lambda consumer, the safe-to-rotate check (schedule disabled in the lab) and the monitoring. No hosts and no ECS tasks run yet.

Turn consumers on only for a test session:

```powershell
terraform apply -var aws_profile=poc02 -var hosts_enabled=true -var ecs_enabled=true
```

### 7. Find key copies

```powershell
cd ..\..\..
$role = terraform -chdir=terraform\envs\lab output -raw census_reader_role_arn
py -3.12 src\census.py --profile poc02-ro --role-arn $role --regions eu-west-1 us-east-1
```

Add `--datadog-status` to mark each copy LIVE or not live (needs `DD_API_KEY` and `DD_APP_KEY` with `api_keys_read` in the environment). The report goes to `census-output\`.

### 8. Check before rotating (dry run)

```powershell
'{"dry_run": true}' | Set-Content -Encoding ascii dryrun.json
aws lambda invoke --function-name poc-02-safe-to-rotate --payload fileb://dryrun.json --profile poc02 --region eu-west-1 out.json
Get-Content out.json
```

`ROTATE` means the key that would be revoked has been idle longer than `keycheck_idle_minutes`. `HOLD` sends an email with the reason.

### 9. Rotate

```powershell
aws secretsmanager rotate-secret --secret-id poc-02/datadog-api-key --profile poc02 --region eu-west-1
```

Run it once. Rotation is asynchronous: wait for the success email before you check anything.

```powershell
aws secretsmanager list-secret-version-ids --secret-id poc-02/datadog-api-key --profile poc02 --region eu-west-1
```

## Demo scenarios

1. **Baked key goes dark.** Hosts on, rotate twice. The AMI-baked host stops reporting about a minute after the second rotation revokes its key. The AMI-ref host has no gap.
2. **ECS lies.** Disable the redeploy hook rule, rotate twice. ECS A shows `running: 1` while its Agent log fills with `API Key invalid`. The CloudWatch alarm fires in about 2 minutes. Enable the rule again (`terraform apply` restores it).
3. **Self-healing Agent.** ECS B gets one 403, refreshes the secret and carries on.
4. **Hold the rotation.** Use the old key from any client, then run the dry run. The check holds and names the key by its last 4 characters.
5. **Find the copies.** Apply `terraform/envs/seed` (planted copies in SSM, Lambda env, launch templates, ECS, CloudFormation), run the census, destroy the seed.

## Teardown

```powershell
cd terraform\envs\lab
terraform apply -var aws_profile=poc02 -var hosts_enabled=false -var ecs_enabled=false
terraform destroy -var aws_profile=poc02
```

Then deregister the AMIs and delete their snapshots, revoke the Datadog keys and application keys, and delete the service account. Secrets are deleted with a 7-day recovery window, so the same secret names cannot be reused for 7 days unless you delete them with `--force-delete-without-recovery`.

## Screenshots

Added in the documentation phase.

## What I learned

Written in the documentation phase.

## Limitations

- One account and one region for the lab. The multi-account design is in [docs/scale.md](docs/scale.md) and is not built.
- Datadog EU site only is tested. Other sites need `api_url` and `--dd-site` changes.
- Resource names use the fixed prefix `poc-02`, so one copy of the lab per account.
- Terraform state is local.
- The Datadog no-data monitor detected the outage but its email was not delivered in the lab. The CloudWatch alarm is the primary alert.
- Datadog Workload Identity Federation (keyless Agent auth) is noted as a next step, not built.

## References

- AWS Secrets Manager, managed external secrets partners: https://docs.aws.amazon.com/secretsmanager/latest/userguide/mes-partners.html
- AWS announcement, managed external secrets for Datadog and Snowflake (May 2026): https://aws.amazon.com/about-aws/whats-new/2026/05/secrets-manager-managed-external-secrets-datadog-snowflake/
- Datadog Agent secrets management: https://docs.datadoghq.com/agent/configuration/secrets-management/
- Datadog Lambda extension configuration: https://docs.datadoghq.com/serverless/guide/agent_configuration/
- AWS Secrets Manager pricing: https://aws.amazon.com/secrets-manager/pricing/

## License

See [LICENSE](LICENSE).
