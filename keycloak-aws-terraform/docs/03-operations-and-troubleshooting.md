# Operations and troubleshooting

Day-two work: checking health, upgrading, rolling back, and fixing the specific
errors you are most likely to meet.

---

## 1. First thing to run when something is wrong

```bash
./scripts/run.sh status
```

It prints the database endpoint, the Auto Scaling group name, the public URL,
and the load balancer's opinion of each server.

Read the `State` column:

| State | Meaning | Do this |
|---|---|---|
| `healthy` | Working | Nothing |
| `initial` | Registered, still being checked | Wait 2–5 minutes |
| `unhealthy` | Failing health checks | See section 5 |
| `draining` | Being removed, finishing requests | Normal during a deploy |
| `unused` | Registered but the ASG has no running instance | Check the ASG activity history |
| *(empty table)* | Nothing attached | Check that stack 2 applied, and `attach_asg = true` |

---

## 2. Getting a shell on a server

There is no SSH and no port 22. Use Session Manager:

```bash
# find the instances
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=keycloak-dev-keycloak" "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[].InstanceId' --output text

# open a shell
aws ssm start-session --target i-0123456789abcdef0
```

Then, in order of usefulness:

```bash
sudo tail -100 /var/log/keycloak-bootstrap.log   # what happened at boot
sudo docker ps                                    # is the container running?
sudo docker logs --tail 200 keycloak              # what is Keycloak saying?
sudo docker inspect keycloak --format '{{.State.Status}} {{.State.ExitCode}}'
curl -s localhost:9000/health/ready               # is it ready?
sudo cat /etc/keycloak.env | grep -v PASSWORD     # what settings did it get?
```

If Session Manager will not connect, the usual cause is no route to the internet
(NAT gateway missing or removed) or a missing `AmazonSSMManagedInstanceCore`
policy.

---

## 3. Reading the logs without logging in

With `enable_cloudwatch_logs = true` (the default), container output goes to
CloudWatch:

```bash
aws logs tail /keycloak/dev/keycloak --follow --since 15m
aws logs tail /keycloak/dev/keycloak --filter-pattern "ERROR"
```

Note: this is the **container's** log. The bootstrap script's log stays on the
instance at `/var/log/keycloak-bootstrap.log`. If the container never started,
CloudWatch will be empty and the answer is in the bootstrap log.

---

## 4. Upgrading Keycloak

```bash
# 1. edit 02-keycloak-compute/terraform.tfvars
keycloak_image_tag = "26.3.1"

# 2. see what changes (should be launch template only)
./scripts/run.sh plan keycloak

# 3. update the recipe, then replace the servers one at a time
./scripts/run.sh reconfigure keycloak
./scripts/run.sh redeploy

# 4. watch it
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name keycloak-dev-keycloak-asg \
  --query 'InstanceRefreshes[0].{Status:Status,Pct:PercentageComplete}'
```

### Before any major version upgrade

1. **Take a database snapshot.** Keycloak migrates the schema automatically on
   first boot, and the migration is **not reversible**.
   ```bash
   aws rds create-db-snapshot \
     --db-instance-identifier keycloak-dev-postgres \
     --db-snapshot-identifier keycloak-dev-before-26-3
   ```
2. Read the Keycloak upgrade notes for breaking changes.
3. Test in `environment = "test"` first.
4. Never let two different Keycloak versions run against one database at the
   same time — which is exactly why `latest` as a tag is dangerous.

### Rolling back

Rolling back the *image* is easy: put the old tag back and redeploy. Rolling
back the *schema* is not — you restore the snapshot into a new instance. Plan the
snapshot first, always.

---

## 5. Error messages, and what they actually mean

### `ParameterNotFound` when applying stack 2 or 3

```
Error: reading SSM Parameter (/keycloak/dev/network/vpc_id): ParameterNotFound
```

The earlier stack has not been applied, or `project_name` / `environment` /
`aws_region` differ between the tfvars files.

```bash
aws ssm get-parameters-by-path --path /keycloak/dev --recursive \
  --query 'Parameters[].Name' --output table
```

Compare the three tfvars files line by line. This is the number-one cause of
failed first runs.

---

### Targets stuck `unhealthy`

Work through this in order:

1. **Is Keycloak even running?** Shell in, `docker ps`. If the container is
   missing, read `/var/log/keycloak-bootstrap.log`.
2. **Is it ready?** `curl -s localhost:9000/health/ready` on the instance. If
   this works but the load balancer disagrees, it is a security group problem.
3. **Is the health check on the right port?** It must be **9000**, not 8080.
   ```bash
   aws elbv2 describe-target-groups --names keycloak-dev-tg \
     --query 'TargetGroups[0].{Port:Port,HCPort:HealthCheckPort,HCPath:HealthCheckPath}'
   ```
4. **Can the load balancer reach the servers?** Stack 3 creates those rules; if
   stack 3 was applied before stack 2 finished, re-apply it.
5. **Give it time.** First boot legitimately takes 3–5 minutes.

---

### Boot log: `FATAL: could not read the database secret`

The IAM role could not fetch the secret. Causes, in order of likelihood:

* No internet route — the NAT gateway is missing, so the AWS API is unreachable.
  Check `enable_nat_gateway = true` and that `aws_route.private_nat` exists.
* The secret name changed (you rebuilt stack 1 and did not re-apply stack 2).
* The IAM policy does not cover that ARN.

Test from the instance:

```bash
aws sts get-caller-identity            # should show the keycloak role
aws secretsmanager get-secret-value --secret-id keycloak-dev/database
```

---

### Boot log: `FATAL: could not pull the image`

```bash
# on the instance
sudo docker pull mycompany.jfrog.io/docker-remote/keycloak/keycloak:26.2
```

* `no such host` → wrong registry name, or DNS/NAT problem.
* `unauthorized` → the Artifactory secret is wrong, expired, or the token lacks
  read permission on that repo.
* `manifest unknown` → the tag does not exist in that repository path.
* `no matching manifest for linux/arm64` → you set `cpu_architecture = "arm64"`
  but the mirror only has an x86_64 build.

---

### Keycloak log: `Failed to obtain JDBC connection`

The database is unreachable. Check, from the instance:

```bash
sudo dnf install -y nc && nc -zv <db-endpoint> 5432
```

If it hangs, the security group rule is missing — that rule is created by stack
2 (`database_from_keycloak`). Re-apply stack 2.

---

### `Error: creating Secrets Manager Secret: InvalidRequestException: You can't create this secret because a secret with this name is already scheduled for deletion`

You destroyed and immediately re-applied. Either wait, or force it:

```bash
aws secretsmanager delete-secret --secret-id keycloak-dev/database \
  --force-delete-without-recovery
```

`secret_recovery_window_days = 0` (the default in this template) prevents this
in dev.

---

### `Error: deleting EC2 Subnet: DependencyViolation`

Something still lives in the subnet. Almost always: you tried to destroy stack 1
while stack 2 still exists.

**Destroy backwards: 3 → 2 → 1.**

```bash
./scripts/run.sh destroy alb
./scripts/run.sh destroy keycloak
./scripts/run.sh destroy db
```

---

### `Error: deleting Security Group: DependencyViolation`

Same family of problem: another security group's rule still references this one,
or an ENI is still attached. Destroying in the right order fixes it. If a
load-balancer ENI is lingering, wait a few minutes — AWS releases them
asynchronously — then re-run destroy.

---

### `InvalidParameterValue: Cannot find version 16.x for postgres`

That version is not offered in your region. List what is:

```bash
aws rds describe-db-engine-versions --engine postgres \
  --query 'DBEngineVersions[].EngineVersion' --output table
```

---

### `Error: Provider produced inconsistent final plan` after changing subnets

Changing `availability_zone_count` or `vpc_cidr` renumbers subnets and can force
a database replacement. **Never do this on a live environment.** Build a new
`environment` instead and migrate.

---

### Terraform hangs at `Still creating... [10m0s elapsed]` on RDS

Normal. A PostgreSQL instance takes 8–12 minutes, and Multi-AZ takes longer.

---

## 6. Scaling

### Manually, right now

```bash
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name keycloak-dev-keycloak-asg --desired-capacity 3
```

Fast, but the next `apply` will put it back. For a permanent change edit
`asg_desired_capacity` in tfvars and `reconfigure keycloak`.

### Automatically

```hcl
enable_cpu_autoscaling = true
cpu_target_percent     = 60
asg_max_size           = 6
```

Keycloak is more often memory- or database-bound than CPU-bound, so CPU target
tracking is a blunt instrument. If you are hitting limits, check database
connections and JVM heap before adding servers.

---

## 7. Database operations

### Snapshot before anything risky

```bash
aws rds create-db-snapshot \
  --db-instance-identifier keycloak-dev-postgres \
  --db-snapshot-identifier keycloak-dev-manual-$(date +%Y%m%d)
```

### Restore

A restore creates a **new** instance with a new endpoint. Afterwards, update the
secret so Keycloak follows it:

```bash
aws rds restore-db-instance-from-db-snapshot \
  --db-instance-identifier keycloak-dev-postgres-restored \
  --db-snapshot-identifier keycloak-dev-manual-20260727

# point the secret at the new host, then roll the servers
aws secretsmanager put-secret-value --secret-id keycloak-dev/database \
  --secret-string '{"engine":"postgres","host":"NEW-ENDPOINT","port":5432,"dbname":"keycloak","username":"kcadmin","password":"..."}'
./scripts/run.sh redeploy
```

Note that Terraform still believes the original instance is the real one, so
treat this as an emergency procedure and reconcile the code afterwards.

### Connect with psql

The database is private, so tunnel through an instance:

```bash
aws ssm start-session --target i-0123... \
  --document-name AWS-StartPortForwardingSessionToRemoteHost \
  --parameters '{"host":["keycloak-dev-postgres.xxx.rds.amazonaws.com"],"portNumber":["5432"],"localPortNumber":["5432"]}'

# in another terminal
psql -h localhost -p 5432 -U kcadmin -d keycloak
```

---

## 8. Turning things off to save money

```bash
# end of the day - keeps all data, saves ~$46/month
./scripts/run.sh destroy alb
./scripts/run.sh destroy keycloak

# next morning - about 5 minutes
./scripts/run.sh apply keycloak
./scripts/run.sh apply alb
```

Cheaper still, and slower to restore: set `asg_desired_capacity = 0` and
`reconfigure keycloak`. That keeps the load balancer and its DNS name, so the
URL does not change — but you still pay for the ALB.

**The URL changes** whenever you rebuild the load balancer. Use a Route 53 alias
record if you need a stable name.

---

## 9. Recovering when Terraform loses track

### "It exists in AWS but not in state"

Import it:

```bash
terraform -chdir=01-network-database import aws_vpc.main vpc-0123456789
```

### "It is in state but no longer in AWS"

```bash
terraform -chdir=01-network-database state rm aws_vpc.main
```

### "I deleted things by hand and now nothing matches"

```bash
./scripts/run.sh plan db     # shows everything it wants to recreate
```

Read that plan very carefully before applying. If the database is in the list of
things to create, stop — you are about to lose data.

### Lost the local state file entirely

This is why the S3 backend exists. Without state, Terraform will try to build a
second copy of everything. Options: restore the file from backup, import
resources one by one, or (in a sandbox) delete everything by hand and start over.

---

## 10. A short daily checklist

```bash
./scripts/run.sh status                       # both targets healthy?
aws logs tail /keycloak/dev/keycloak --since 24h --filter-pattern "ERROR"
aws rds describe-db-instances \
  --db-instance-identifier keycloak-dev-postgres \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Storage:AllocatedStorage}'
./scripts/run.sh plan all                     # any unexpected drift?
```

That last one is the most valuable habit in the list: if `plan` shows changes
you did not make, somebody changed something by hand.
