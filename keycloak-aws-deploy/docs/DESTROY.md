# Tearing It Down Safely

Two things go wrong when people delete AWS infrastructure:

1. **They delete something they needed** — usually the database, usually with
   no snapshot.
2. **They think they deleted everything but didn't**, and find a $90 bill three
   months later from NAT Gateways, idle Elastic IPs, and orphaned volumes.

Order matters, because AWS refuses to delete a resource other resources depend
on. Work **inside out**: the things that use the network go first, the network
goes last.

---

## Pre-destroy checklist

- [ ] **Confirm the account and region.** More production data has been lost to
      "wrong terminal window" than to any technical failure.
      ```bash
      aws sts get-caller-identity && aws configure get region
      ```

- [ ] **Take a manual RDS snapshot.** Automated backups are deleted with the
      instance; manual snapshots survive.
      ```bash
      ./cli/linux-mac/pre-destroy-backup.sh
      ```

- [ ] **Export the Keycloak realm config.** A DB snapshot is opaque; a realm
      export is readable JSON you can diff and re-import elsewhere.
      ```bash
      aws ssm start-session --target <instance-id>
      sudo docker exec keycloak /opt/keycloak/bin/kc.sh export \
        --dir /tmp/kc-export --users realm_file
      sudo docker cp keycloak:/tmp/kc-export /tmp/kc-export
      ```

- [ ] **Record an inventory**, so you can verify it's gone afterwards.
      ```bash
      aws resourcegroupstaggingapi get-resources \
        --tag-filters "Key=Project,Values=<project>" \
        --query 'ResourceTagMappingList[].ResourceARN' --output text | tee pre-destroy.txt
      ```

- [ ] **Check nothing else depends on this Keycloak.** Every application
      configured to use it will break. Grep your codebase for the hostname.

- [ ] **Tell people.** Post in the channel. Get an acknowledgment.

- [ ] **Note the current bill**, so you can confirm it drops.

---

## Terraform teardown

### 1. Preview

```bash
cd terraform
terraform plan -destroy -var-file=terraform.tfvars -out=destroy.tfplan
```

It ends with `Plan: 0 to add, 0 to change, N to destroy.` **Check N against
your expectations.** If it says 3, your state file is missing things. If it says
200, you may be pointed at a shared state file containing other people's
infrastructure.

```bash
terraform show -json destroy.tfplan | \
  jq -r '.resource_changes[] | select(.change.actions[0]=="delete") | .address' | sort
```

### 2. Disable the safety switches, deliberately

You set these on purpose; remove them on purpose.

**a) Deletion protection.** In `terraform.tfvars`:

```hcl
enable_deletion_protection = false

# Leave FALSE so Terraform takes a final snapshot on the way out.
db_skip_final_snapshot = false
```

Apply that change *first*, so the flag is actually cleared in AWS before you
try to destroy:

```bash
terraform apply -var-file=terraform.tfvars \
  -target=aws_db_instance.main -target=aws_lb.main
```

**b) `prevent_destroy`.** If you uncommented it in `rds.tf`, Terraform fails
with `Instance cannot be destroyed`. There is **no CLI flag to override this** —
you must edit the file and remove the line. That friction is the entire point.
Note in your commit message why.

### 3. Destroy

```bash
terraform plan -destroy -var-file=terraform.tfvars -out=destroy.tfplan
terraform apply destroy.tfplan
```

10–20 minutes, most of it RDS taking its final snapshot.

### 4. Things that commonly fight back

| Symptom | Why | Fix |
|---|---|---|
| `DependencyViolation` on a security group | The ALB's network interfaces take minutes to release | Wait 5 min, run destroy again |
| `Subnet has dependencies` | Same — leftover ENIs | Wait, retry |
| Secret deletion "pending" | Recovery window, by design | Expected |
| CloudWatch log groups remain | Auto-created by the Docker `awslogs` driver, so outside state | Delete manually |
| RDS takes 10+ minutes | Taking the final snapshot | Be patient; do not interrupt |

Finding a stuck ENI:

```bash
aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'NetworkInterfaces[].{Id:NetworkInterfaceId,Desc:Description,Status:Status}' \
  --output table
```

### 5. Confirm state is empty

```bash
terraform state list      # should print nothing
```

⚠️ **Never delete a state file that still contains resources.** That orphans
real, billable infrastructure Terraform no longer knows about, and you'll be
hunting it by hand.

---

## CLI teardown

```bash
./cli/linux-mac/pre-destroy-backup.sh
./cli/linux-mac/destroy-all.sh
```

Windows:

```bat
pre-destroy-backup.bat
destroy-all.bat
```

`destroy-all` is deliberately interactive. It asks you to type the project name,
then `DESTROY`, and for the database it offers three choices:

- **`snapshot`** — delete but take a final snapshot first. **Recommended.**
- **`nuke`** — delete with no snapshot. Requires typing `NUKE`. No undo. AWS
  support cannot recover it.
- **`keep`** — leave the database running. Note its subnet group and security
  group then cannot be deleted either.

---

## The correct order (what the script does)

```
 1. ASG -> desired/min/max = 0, wait for instances to drain
 2. Delete ASG
 3. Delete launch template
 4. Delete ALB listeners
 5. Delete ALB (disable deletion protection first), WAIT for ENIs to release
 6. Delete target group
 7. RDS: disable deletion protection -> delete WITH final snapshot -> wait
 8. Delete DB subnet group + parameter group
 9. Delete NAT gateways, WAIT
10. Release Elastic IPs          (order matters: NAT must be gone first)
11. Disassociate + delete route tables, then subnets
12. Detach + delete internet gateway
13. Revoke cross-referencing SG rules, then delete security groups
14. Delete VPC                   (its refusal is a useful signal you missed something)
15. IAM: remove role from profile -> delete profile -> detach policies -> delete role
16. Schedule secret deletion     (keep DB creds >= as long as the snapshot)
17. Route 53 records, CloudWatch log groups, alarms
18. Orphan hunt
19. Check the bill in 48 hours
```

Two non-obvious points:

**Step 5's wait.** The ALB's network interfaces are removed asynchronously.
Deleting security groups or subnets immediately gives you `DependencyViolation`
and leaves you guessing. Waiting 60 seconds is faster than debugging.

**Step 16.** Keep the database credentials at least as long as you keep the
snapshot. Deleting the password while keeping the snapshot gives you an
encrypted box you cannot open.

---

## The orphan hunt

```bash
./cli/linux-mac/orphan-hunt.sh
```

Run it. Then run it again 48 hours later, because AWS billing data lags by up
to a day.

### What silently keeps costing money

| Resource | Cost if forgotten | Why it's easy to miss |
|---|---|---|
| **NAT Gateway** | ~$32–45/mo each | Not attached to anything obvious; invisible in the instance list |
| **Elastic IP, unassociated** | ~$3.60/mo each | AWS charges *specifically* for idle EIPs |
| **EBS volume, unattached** | ~$0.08/GB/mo | Left behind if `delete_on_termination` was false |
| **Manual RDS snapshots** | ~$0.095/GB/mo | Deliberately survive instance deletion |
| **EBS snapshots / AMIs** | ~$0.05/GB/mo | Custom AMIs keep their backing snapshots |
| **CloudWatch log groups** | ~$0.03/GB/mo, forever | Default retention is "never expire" |
| **Load balancer** | ~$16–20/mo | Runs happily with zero targets |
| **Secrets Manager** | ~$0.40/secret/mo | Small enough that nobody notices |
| **Route 53 hosted zone** | $0.50/mo | Often shared — leave it if other records use it |

The catch-all, and the single most useful query:

```bash
aws resourcegroupstaggingapi get-resources \
  --tag-filters "Key=Project,Values=<project>" \
  --query 'ResourceTagMappingList[].ResourceARN' --output text
```

This is *why* the kit tags everything and Terraform uses `default_tags`.

---

## Confirm the bill dropped

```bash
aws ce get-cost-and-usage \
  --time-period Start=$(date -u -d '2 days ago' +%Y-%m-%d),End=$(date -u +%Y-%m-%d) \
  --granularity DAILY --metrics UnblendedCost \
  --group-by Type=DIMENSION,Key=SERVICE \
  --query 'ResultsByTime[].Groups[?Metrics.UnblendedCost.Amount!=`0`].[Keys[0],Metrics.UnblendedCost.Amount]' \
  --output text
```

Check **48 hours after** teardown. If a service you thought you deleted still
shows charges, go back to the orphan hunt.

---

## Deliberately left behind

The scripts intentionally do **not** delete:

- **RDS snapshots** (manual and final) — your only route back. ~$0.095/GB/month.
- **Secrets in their recovery window** — restorable for 7–30 days.

Delete them separately, once you are certain:

```bash
aws rds delete-db-snapshot --db-snapshot-identifier <id>
aws secretsmanager delete-secret --secret-id <id> --force-delete-without-recovery
```

`--force-delete-without-recovery` frees the name immediately, which helps if
you plan to rebuild right away. There is absolutely no undo.
