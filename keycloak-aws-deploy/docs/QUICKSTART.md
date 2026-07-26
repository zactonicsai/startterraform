# Quickstart

The condensed command sequence. For explanations see
[keycloak-on-aws-guide.md](keycloak-on-aws-guide.md); for the operating manual
see [../README.md](../README.md).

---

## 0. Before you touch anything

```bash
aws sts get-caller-identity          # right account?
aws configure get region             # right region?
aws acm list-certificates            # cert in THIS region?
```

Set a billing budget with alerts. The full stack is ~$290–320/month.

You need: an ACM cert in the ALB's region, a domain, and Artifactory host +
service username + access token.

---

## 1. Optional: build the optimized image

Skipping this costs 20–60 seconds on every instance boot, which directly slows
autoscaling.

```bash
export ARTIFACTORY_HOST=mycompany.jfrog.io
export ARTIFACTORY_USER=svc-keycloak-deploy
export ARTIFACTORY_TOKEN=...
./docker/build-and-push.sh 26.4.0
# -> mycompany.jfrog.io/docker-local/keycloak:26.4.0-optimized
```

---

## 2A. Deploy with the CLI scripts

**Linux / macOS**

```bash
cp config.env.example config.env && $EDITOR config.env
./cli/linux-mac/00-preflight.sh
./cli/linux-mac/deploy-all.sh
```

**Windows**

```bat
cd cli\windows
copy config.bat.example config.bat && notepad config.bat
00-preflight.bat
deploy-all.bat
```

Roughly 20–30 minutes. Every script is re-runnable; a failure means fix and
re-run that one script, not start over.

---

## 2B. Deploy with Terraform

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars && $EDITOR terraform.tfvars
export TF_VAR_artifactory_token="..."

make init
make plan            # read it: "to destroy" must be 0 on a fresh build
make apply
make output
```

15–25 minutes, mostly Multi-AZ RDS.

---

## 3. Verify

```bash
./cli/linux-mac/10-verify.sh
# or
cd terraform && make health
```

The single most useful check — it catches a wrong `KC_HOSTNAME`, which is the
most common misconfiguration:

```bash
curl -s https://auth.example.com/realms/master/.well-known/openid-configuration | jq -r .issuer
# Must be exactly: https://auth.example.com/realms/master
```

First boot takes 4–6 minutes: image pull, JVM start, and database schema
creation.

---

## 4. Secure it, immediately

```bash
aws secretsmanager get-secret-value --secret-id "<project>/keycloak-bootstrap-admin-..." \
  --query SecretString --output text | jq
```

Log in at `https://auth.example.com/admin`, then:

1. Create a real named admin with OTP/MFA
2. **Delete `tmpadmin`**
3. Delete the bootstrap secret
4. Create a separate realm for your applications — never `master`
5. Enable Brute Force Detection
6. Set strict redirect URIs on every client (never `*`)
7. Attach an SNS topic to the alarms

---

## 5. Prove it survives failure

```bash
# traffic loop in another terminal:
while true; do curl -s -o /dev/null -w "%{http_code} " https://auth.example.com/realms/master; sleep 1; done

./cli/linux-mac/test-failover.sh kill-instance
./cli/linux-mac/test-failover.sh kill-container    # the one people skip
./cli/linux-mac/test-failover.sh db-failover
```

Unbroken `200`s means it works.

---

## 6. Tear it down

```bash
./cli/linux-mac/pre-destroy-backup.sh    # snapshot first
./cli/linux-mac/destroy-all.sh
./cli/linux-mac/orphan-hunt.sh           # do not skip
```

Terraform:

```bash
# set enable_deletion_protection = false in terraform.tfvars first
terraform apply -var-file=terraform.tfvars -target=aws_db_instance.main -target=aws_lb.main
make destroy-plan && make destroy
../cli/linux-mac/orphan-hunt.sh
```

Re-run the orphan hunt in 48 hours — billing data lags by a day.

---

## Command cheat sheet

```bash
# Health
aws elbv2 describe-target-health --target-group-arn <arn> --output table

# Container logs (instance-local logs die with the instance)
./cli/linux-mac/troubleshoot.sh logs

# Shell, no SSH
aws ssm start-session --target i-0123456789abcdef0

# Stop the ASG destroying the instance you want to inspect
./cli/linux-mac/troubleshoot.sh freeze
./cli/linux-mac/troubleshoot.sh thaw

# Roll out a new image version
aws autoscaling start-instance-refresh --auto-scaling-group-name <asg> \
  --preferences '{"MinHealthyPercentage":100,"InstanceWarmup":300}'

# Read a secret
aws secretsmanager get-secret-value --secret-id <name> --query SecretString --output text | jq
```
