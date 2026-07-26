# Keycloak on AWS — Deployment Kit

Runnable code for a fault-tolerant Keycloak deployment: Docker containers from
JFrog Artifactory, running on EC2, behind an Application Load Balancer, backed
by Multi-AZ RDS PostgreSQL, managed by an Auto Scaling Group.

Two independent implementations of the same architecture:

| | Path | Use it when |
|---|---|---|
| **AWS CLI scripts** | `cli/linux-mac/`, `cli/windows/` | Learning; you want to see each API call; no Terraform in your org |
| **Terraform** | `terraform/` | Real use; you want reviewable, reproducible, version-controlled infrastructure |

Pick one. Running both against the same project name will create duplicate,
conflicting resources.

The full explanation of *why* every setting is what it is lives in
**[docs/keycloak-on-aws-guide.md](docs/keycloak-on-aws-guide.md)** (~3,700 lines,
middle-school reading level). This README is the operating manual.

---

## What gets built

```
                          THE INTERNET
                               |  HTTPS 443
                               v
      +====================== VPC 10.0.0.0/16 ======================+
      |     Availability Zone A       |     Availability Zone B     |
      |  PUBLIC   [ALB node] [NAT]    |  PUBLIC  [ALB node] [NAT]   |
      |  APP      [EC2 + Keycloak]    |  APP     [EC2 + Keycloak]   |
      |  DATA     [RDS PRIMARY] ======|===> [RDS STANDBY]           |
      |                    (synchronous replication)                |
      |     Auto Scaling Group spans both zones: min 2, max 6       |
      +=============================================================+
                               |  image pull via NAT
                               v
                     JFrog Artifactory
```

**Three layers of fault tolerance**

1. **Auto Scaling Group** — several instances, not one. `health_check_type = ELB`
   means the ASG trusts the load balancer's HTTP check, so it replaces
   instances whose *application* is broken, not just ones whose VM has died.
2. **Application Load Balancer** — routes only to healthy instances, terminates
   TLS, redirects HTTP to HTTPS. AWS runs it redundantly across both AZs.
3. **RDS Multi-AZ** — synchronous standby in a second data centre, automatic
   failover in 60–120 seconds with no data loss.

---

## Directory structure

```
keycloak-aws-deploy/
│
├── README.md                     you are here
├── config.env.example            copy to config.env for the shell scripts
├── .gitignore                    keeps secrets and state out of git
│
├── cli/
│   ├── linux-mac/                bash. The reference implementation.
│   │   ├── lib/common.sh          shared helpers, state, colours
│   │   ├── 00-preflight.sh        verify tools, creds, config, cert
│   │   ├── 01-network.sh          VPC, 6 subnets, IGW, NAT, routes
│   │   ├── 02-security-groups.sh  the three chained firewalls
│   │   ├── 03-secrets.sh          generate passwords -> Secrets Manager
│   │   ├── 04-iam.sh              least-privilege role + instance profile
│   │   ├── 05-rds.sh              Multi-AZ PostgreSQL   (slowest: 10-20 min)
│   │   ├── 06-alb.sh              ALB, target group, health checks, listeners
│   │   ├── 07-launch-template.sh  render user-data, create launch template
│   │   ├── 08-asg.sh              ASG, scaling policy, CloudWatch alarms
│   │   ├── 09-dns.sh              Route 53 alias record
│   │   ├── 10-verify.sh           end-to-end checks
│   │   ├── deploy-all.sh          runs 00-09 in order
│   │   ├── troubleshoot.sh        health | logs | shell | events | freeze | thaw
│   │   ├── test-failover.sh       chaos tests
│   │   ├── pre-destroy-backup.sh  snapshot + inventory before teardown
│   │   ├── destroy-all.sh         interactive teardown in dependency order
│   │   └── orphan-hunt.sh         find anything still billing
│   │
│   └── windows/                  .bat equivalents of every script above
│       ├── config.bat.example
│       └── lib/
│           ├── init.bat           loads config + state
│           ├── save.bat           persists an ID to state\ids.bat
│           ├── confirm.bat        typed confirmation prompt
│           ├── render.ps1         @@TOKEN@@ substitution + LF line endings
│           └── lt-template.json   launch template JSON skeleton
│
├── terraform/
│   ├── versions.tf                provider pins + S3 backend (commented)
│   ├── variables.tf               every knob, with validation rules
│   ├── locals.tf                  AZ discovery + subnet maths
│   ├── network.tf                 VPC, subnets, NAT, routes, flow logs
│   ├── security.tf                chained security groups
│   ├── secrets.tf                 random passwords + Secrets Manager
│   ├── iam.tf                     role, policy, instance profile
│   ├── rds.tf                     Multi-AZ PostgreSQL
│   ├── alb.tf                     ALB, target group, listeners
│   ├── compute.tf                 launch template, ASG, instance refresh
│   ├── alarms.tf                  CloudWatch alarms
│   ├── dns.tf                     Route 53
│   ├── outputs.tf                 URLs, secret names, next steps
│   ├── user-data.sh.tftpl         boot script (Terraform template form)
│   ├── terraform.tfvars.example   copy to terraform.tfvars
│   ├── example-dev.tfvars         ~$120/mo cut-down settings
│   ├── example-prod.tfvars        3 AZs, Graviton, 30-day backups
│   └── Makefile                   make plan / apply / destroy-plan / destroy
│
├── docker/
│   ├── Dockerfile                 optimized image (skips build on every boot)
│   ├── build-and-push.sh
│   └── build-and-push.bat
│
├── templates/
│   └── user-data.sh.tmpl          boot script (@@TOKEN@@ form, for CLI path)
│
└── docs/
    ├── keycloak-on-aws-guide.md   the full explanatory guide
    ├── QUICKSTART.md              condensed command sequence
    └── DESTROY.md                 teardown checklist and order
```

---

## Prerequisites

| # | Requirement | Check |
|---|---|---|
| 1 | AWS account you can create resources in | `aws sts get-caller-identity` |
| 2 | AWS CLI v2 | `aws --version` |
| 3 | `jq` (Linux/macOS path) | `jq --version` |
| 4 | Terraform ≥ 1.6 (Terraform path) | `terraform version` |
| 5 | PowerShell (Windows path) | pre-installed |
| 6 | A domain you control | — |
| 7 | ACM certificate **in the same region as the ALB** | `aws acm list-certificates` |
| 8 | Artifactory host, service username, access token | ask your platform team |
| 9 | The exact Keycloak image path **with a version tag** | never `:latest` |

IAM permissions needed: EC2, RDS, ELBv2, AutoScaling, SecretsManager, IAM
role creation, CloudWatch, Route 53, SSM read.

**Set a billing budget with alerts before you start.** The full HA stack runs
roughly **$290–320/month**; see [Cost](#cost) below.

---

## Path A — AWS CLI (Linux / macOS)

```bash
cd keycloak-aws-deploy

# 1. Configure
cp config.env.example config.env
$EDITOR config.env          # fill in region, domain, cert ARN, Artifactory

# 2. Verify before spending anything
./cli/linux-mac/00-preflight.sh

# 3. Deploy — either all at once...
./cli/linux-mac/deploy-all.sh

#    ...or step by step, which is better the first time
./cli/linux-mac/01-network.sh
./cli/linux-mac/02-security-groups.sh
./cli/linux-mac/03-secrets.sh
./cli/linux-mac/04-iam.sh
./cli/linux-mac/05-rds.sh            # 10-20 minutes. Multi-AZ is slow.
./cli/linux-mac/06-alb.sh
./cli/linux-mac/07-launch-template.sh
./cli/linux-mac/08-asg.sh
./cli/linux-mac/09-dns.sh

# 4. Verify
./cli/linux-mac/10-verify.sh
```

**Every script is re-runnable.** IDs are recorded in
`cli/linux-mac/state/ids.env`, and each script skips work already recorded. If
a step fails, fix the cause and run that one script again — you do not start
over.

**If you lose your terminal:** nothing is lost. The state file is on disk.

---

## Path A — AWS CLI (Windows)

```bat
cd keycloak-aws-deploy\cli\windows

copy config.bat.example config.bat
notepad config.bat

00-preflight.bat
deploy-all.bat
10-verify.bat
```

State goes to `cli\windows\state\ids.bat`.

**Two notes on the Windows path.** Batch has no `sed`, `jq`, or `base64`, so
`lib\render.ps1` handles token substitution — and it also forces Unix (LF)
line endings on the generated user-data, because a CRLF boot script fails on
Amazon Linux with a confusing `$'\r': command not found`.

If you have WSL or Git Bash, the bash scripts are the reference implementation
and are better tested. The `.bat` files exist for environments where that
isn't an option.

---

## Path B — Terraform

```bash
cd keycloak-aws-deploy/terraform

cp terraform.tfvars.example terraform.tfvars
$EDITOR terraform.tfvars

# Keep the Artifactory token out of files entirely
export TF_VAR_artifactory_token="your-token-here"

make init
make plan          # READ THE OUTPUT. On a fresh build, "to destroy" must be 0.
make apply         # applies the exact plan you just reviewed
make output
make health
```

Or without the Makefile:

```bash
terraform init
terraform fmt -recursive && terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

**Why `-out=tfplan` then apply the file?** `terraform apply` on its own
re-plans, and the world may have changed since you looked. Applying a saved
plan guarantees you get exactly what you reviewed.

**Use the S3 backend for anything real.** Uncomment the `backend "s3"` block in
`versions.tf`. Local state on a laptop means: lose the file and Terraform
forgets it created anything, then a later apply builds a duplicate stack.

Preset variable files:

```bash
make plan TFVARS=example-dev.tfvars    # ~$120/mo, single AZ DB, 1 instance
make plan TFVARS=example-prod.tfvars   # 3 AZs, Graviton, 30-day backups
```

Expect **15–25 minutes**, almost all of it waiting for Multi-AZ RDS.

---

## After deployment — do this immediately

The stack creates a temporary Keycloak admin called `tmpadmin`. It exists to
get you in once.

```bash
# Get the password
aws secretsmanager get-secret-value \
  --secret-id "<bootstrap_admin_secret_name from outputs>" \
  --query SecretString --output text | jq
```

1. Log in at `https://your-domain/admin`
2. Create a real named admin account and **enable OTP/MFA on it**
3. **Delete the `tmpadmin` user**
4. Delete (or rotate to garbage) the bootstrap secret
5. **Create a separate realm for your applications** — never put end users in
   `master`
6. Turn on Brute Force Detection under Realm Settings → Security Defenses
7. Set strict redirect URIs on every client — never `*`
8. Attach an SNS topic to the CloudWatch alarms, or they fire into the void

Verify the OIDC issuer, which catches the single most common misconfiguration:

```bash
curl -s https://your-domain/realms/master/.well-known/openid-configuration | jq -r .issuer
# Must be exactly: https://your-domain/realms/master
# An internal IP or the raw ALB hostname means KC_HOSTNAME is wrong.
```

---

## Deploying a new Keycloak version

```bash
# 1. Build and push the optimized image
./docker/build-and-push.sh 26.4.1

# 2. Update the image reference
#    config.env       -> KC_IMAGE=...:26.4.1-optimized
#    terraform.tfvars -> keycloak_image = "...:26.4.1-optimized"

# 3a. Terraform: instance_refresh handles the rolling replacement
cd terraform && make plan && make apply

# 3b. CLI: create a new launch template version, then refresh
./cli/linux-mac/07-launch-template.sh
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name <asg-name> \
  --preferences '{"MinHealthyPercentage":100,"InstanceWarmup":300}'
```

⚠️ **Snapshot the database before any version upgrade.** Keycloak runs
Liquibase schema migrations on start. If ten instances start at once against
an old schema they contend for the migration lock, and a node that waits too
long can fail. For a version bump: scale to **one** instance, let it migrate
alone, verify, then scale back up. Also upgrade one minor version at a time —
never jump 22 → 26.

---

## Testing that fault tolerance actually works

Untested fault tolerance is a hope, not a property.

```bash
./cli/linux-mac/test-failover.sh kill-instance    # ASG replaces it
./cli/linux-mac/test-failover.sh kill-container   # proves health_check_type=ELB
./cli/linux-mac/test-failover.sh db-failover      # Multi-AZ, 60-120s
./cli/linux-mac/test-failover.sh watch            # live health dashboard
```

Run a traffic loop in a second terminal while you do it:

```bash
while true; do curl -s -o /dev/null -w "%{http_code} " https://your-domain/realms/master; sleep 1; done
```

You want an unbroken stream of `200`s. If you see errors during
`kill-instance`, either `asg_min_size` is 1 or both instances landed in one AZ.

The `kill-container` test is the one people skip and shouldn't: it breaks the
application while leaving the VM perfectly healthy. If nothing happens, your
ASG health check type is still `EC2`, which cannot see application failure.

---

## Troubleshooting

```bash
./cli/linux-mac/troubleshoot.sh health    # target + RDS status
./cli/linux-mac/troubleshoot.sh logs      # container logs from CloudWatch
./cli/linux-mac/troubleshoot.sh shell     # SSM session (no SSH, no keys)
./cli/linux-mac/troubleshoot.sh events    # ASG + RDS event history
./cli/linux-mac/troubleshoot.sh freeze    # stop the ASG killing your evidence
./cli/linux-mac/troubleshoot.sh thaw      # re-enable self-healing
```

| Symptom | Most likely cause |
|---|---|
| Instances launch and are killed in a loop | `KC_HEALTH_ENABLED` not true, or port 9000 not open from the ALB SG, or grace period under 300s |
| Login redirects to a private IP | `KC_HOSTNAME` wrong — check the issuer |
| Random logouts, "invalid state" on login | Cluster not forming — check `--cache-stack=jdbc-ping` and the port 7800 self-referencing SG rule |
| Cannot reach the database | VPC `enable_dns_hostnames` off, or the RDS SG rule missing |
| Image pull fails on boot | NAT route missing, token expired, tag doesn't exist, or IAM lacks `GetSecretValue` on that ARN |
| `terraform apply`: secret name already exists | Destroyed and re-applied inside the recovery window — `name_prefix` prevents this |

`troubleshoot.sh freeze` is worth remembering: a self-healing ASG destroys the
broken instance you were about to inspect. Freeze it, investigate, thaw it.

Full symptom list: [docs/keycloak-on-aws-guide.md § 10](docs/keycloak-on-aws-guide.md).

---

## Tearing it down

Read **[docs/DESTROY.md](docs/DESTROY.md)** first. Short version:

```bash
# 1. Snapshot and inventory FIRST
./cli/linux-mac/pre-destroy-backup.sh

# 2a. CLI teardown — interactive, correct dependency order
./cli/linux-mac/destroy-all.sh

# 2b. Terraform teardown
cd terraform
# set enable_deletion_protection = false in terraform.tfvars, then:
terraform apply -var-file=terraform.tfvars -target=aws_db_instance.main -target=aws_lb.main
make destroy-plan     # read the resource list
make destroy

# 3. NEVER SKIP THIS
./cli/linux-mac/orphan-hunt.sh
```

**Why step 3 matters.** These survive a careless teardown and keep billing:
NAT Gateways (~$35/mo each), unassociated Elastic IPs (~$3.60/mo each),
unattached EBS volumes, manual RDS snapshots, load balancers with zero
targets, and CloudWatch log groups (which default to *never expire*).

Re-run `orphan-hunt.sh` **48 hours later** — AWS billing data lags by up to a
day, so an immediate check tells you nothing.

---

## Cost

Rough monthly, us-east-1, on-demand. Verify against the AWS Pricing Calculator
for your region.

| Item | Full HA | Dev (`example-dev.tfvars`) |
|---|---|---|
| EC2 | 2 × t3.medium ≈ $60 | 1 × t3.small ≈ $15 |
| RDS | db.t3.medium Multi-AZ ≈ $130 | db.t3.micro single-AZ ≈ $25 |
| ALB | ≈ $20 + LCUs | ≈ $20 |
| NAT Gateway | 2 × ≈ $70 + data | 1 × ≈ $35 + data |
| Secrets Manager | ≈ $1.20 | ≈ $1.20 |
| CloudWatch | ≈ $5–20 | ≈ $3 |
| **Total** | **≈ $290–320** | **≈ $100–120** |

Ways to cut it: `single_nat_gateway = true`; Graviton instance types (`t4g`,
`m7g`, `db.m6g` — roughly 20% cheaper, but verify your image is arm64);
Savings Plans once you know your baseline; scheduled scaling to zero for dev
outside working hours; VPC endpoints plus mirroring images into ECR, which can
eliminate NAT entirely.

---

## Security notes

Built in by default:

- **No SSH.** No port 22 rule anywhere. Shell access via SSM Session Manager —
  no key files, every session logged in CloudTrail.
- **IMDSv2 required** (`http_tokens = "required"`). Protects the instance's IAM
  credentials from SSRF — the exact vulnerability behind the 2019 Capital One
  breach.
- **Security group chaining.** Rules reference other security groups, not CIDR
  blocks. Launching an instance in the app subnet does *not* grant database
  access unless it also carries the app security group.
- **Database unreachable from the internet.** Private subnet,
  `publicly_accessible = false`, ingress only from the app SG.
- **Encryption at rest** on EBS and RDS; **TLS 1.2/1.3 only** at the ALB;
  `rds.force_ssl = 1` on the parameter group.
- **No secrets in user data, launch templates, or AMIs.** Fetched at boot from
  Secrets Manager via the instance role, and the Docker registry credentials
  are deleted from disk immediately after the image pull.
- **Least-privilege IAM.** The secrets policy names three exact ARNs, never
  `Resource: "*"`.

Worth adding for production: AWS WAF on the ALB with rate limiting on the token
endpoint; restricting `/admin` to corporate IP ranges via an ALB listener rule;
Secrets Manager automatic rotation; separate AWS accounts per environment.

---

## Things this kit does not do

Being explicit so you can plan around them:

- **No multi-region.** Everything is Multi-AZ — it survives one data centre
  failing, not an entire AWS region. Multi-region Keycloak needs cross-site
  replication in active/passive mode plus Aurora Global Database, and is a
  substantially larger project.
- **No CI/CD pipeline.** No GitHub Actions or CodePipeline definitions.
- **No SNS topics or on-call routing.** The alarms exist but have no actions.
- **No realm configuration as code.** Realms, clients and identity providers
  are configured through the admin console or the Keycloak Admin API; consider
  the `keycloak` Terraform provider or realm import files for that layer.
- **No RDS Proxy.** Worth adding if you expect to scale past a handful of
  nodes — see the connection-pool maths in
  [the guide § 6.4](docs/keycloak-on-aws-guide.md).

---

## Two things to verify before trusting this

1. **Keycloak environment variable names change between versions.** This kit
   targets Keycloak 26.x: `KC_BOOTSTRAP_ADMIN_USERNAME`,
   `KC_PROXY_HEADERS=xforwarded`, health on the management port 9000. Versions
   24 and earlier used `KEYCLOAK_ADMIN` and `KC_PROXY=edge`, and recent
   releases have changed cache-stack defaults. Check the release notes for the
   exact tag you deploy.
2. **The cost figures are order-of-magnitude.** AWS pricing changes; check the
   calculator.

Deploy into a scratch account first, run the failover tests, destroy it
completely, and confirm the bill returns to zero. Doing that full cycle once,
before it matters, is worth more than reading any documentation three times.
