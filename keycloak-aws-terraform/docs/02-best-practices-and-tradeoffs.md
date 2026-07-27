# Best practices, trade-offs, and why each decision was made

Every design choice in this project traded something away. This document is the
honest list: what was chosen, what it cost, and when you should choose
differently.

---

## 1. Why three stacks instead of one?

### Pros

* **Blast radius.** A mistake in the Keycloak stack cannot delete your database.
  The scariest resource in the project lives in a folder you rarely touch.
* **Speed.** `apply` on stack 2 takes about 2 minutes. A single combined stack
  would re-check the database every time — RDS refreshes are slow.
* **Selective destroy.** "Turn off public access but keep the data" is one
  command. In a single stack it would be `-target` flags, which HashiCorp
  explicitly describes as an exceptional-circumstances tool.
* **Different change rates.** Networks change yearly, databases monthly,
  application servers weekly. Grouping things by how often they change is the
  single most useful way to split infrastructure code.
* **Ownership and permissions.** A network team can own stack 1 with permissions
  an app team does not have.

### Cons

* **Three `apply` runs instead of one.** More commands, more to get wrong.
* **Ordering is now your problem.** Apply forward, destroy backward. The scripts
  handle it, but a newcomer running things by hand can get it wrong.
* **Cross-stack values need plumbing.** Parameter Store is that plumbing.
* **Drift between stacks is possible.** Change `environment` in one tfvars and
  not the others, and stack 2 simply cannot find stack 1.

### When one stack is genuinely better

A throwaway demo you will destroy in an hour. Fewer moving parts wins when the
lifetime is short.

---

## 2. Why Parameter Store instead of `terraform_remote_state`?

The alternative would be:

```hcl
data "terraform_remote_state" "database" {
  backend = "s3"
  config  = { bucket = "...", key = "keycloak/01/terraform.tfstate" }
}
```

### Why we did not

| Issue | Detail |
|---|---|
| **State files contain secrets** | Reading another stack's state means reading *everything* in it, including the database password. Anyone who can run stack 2 can dump stack 1's secrets. |
| **Tight coupling** | Stack 2 must know the backend type, bucket, key and region of stack 1. Change stack 1's backend and stack 2 breaks. |
| **You cannot bring your own network** | With Parameter Store, an existing VPC can be used by writing a few parameters by hand. With remote state you would have to fake an entire state file. |
| **Local backend does not work** | The default local backend cannot be read across folders in a portable way. |

### What it costs

* Standard-tier parameters are free but **eventually consistent** — a value
  written milliseconds ago might not be readable instantly. In practice, apply
  runs are minutes apart, so this never bites.
* Parameters are a second source of truth. If someone edits one by hand, stack 2
  silently uses the wrong value. Mitigate by treating the `/project/env/*` path
  as Terraform-owned.
* Values are stored as **plain `String`**, so anyone with `ssm:GetParameter` can
  read the VPC id. That is fine — none of it is secret. Note that the database
  *password* is never in Parameter Store, only the secret's name.

---

## 3. Why EC2 + Docker instead of ECS, EKS, or App Runner?

| Option | Pros | Cons | Verdict |
|---|---|---|---|
| **EC2 + Docker (chosen)** | Simple, transparent, cheap, easy to debug (`ssm start-session` then `docker logs`), no new concepts | You patch the OS; no orchestration; scaling is coarse | Right for 1–3 environments |
| ECS Fargate | No servers to patch, per-second billing, native rolling deploys | More AWS concepts, harder to shell into, ~30% pricier at steady load | **Best choice** if you already use ECS |
| EKS | Full Kubernetes, official Keycloak Operator, real clustering | ~$73/month for the control plane alone, plus a large learning curve | Only if you already run Kubernetes |
| App Runner | Simplest of all | Cannot reach a private RDS without extra VPC wiring; less control over health checks | Not a fit |

The deciding factor: this template is meant to be **read and understood**. EC2
with Docker has the fewest layers between "the code says" and "the thing does".

**If you outgrow it,** the signals are: more than ~5 servers, needing more than
one deploy a day, or an ops team already fluent in ECS/EKS.

---

## 4. Why an image from Artifactory instead of Docker Hub?

### Pros

* **Supply chain control.** You know exactly which bytes run. A public tag can
  be re-pushed; your internal copy cannot.
* **No rate limits.** Docker Hub throttles anonymous pulls, and a scale-up event
  is exactly when you cannot afford a failed pull.
* **Scanning and policy.** Artifactory (with Xray) scans for CVEs and can block
  images that fail policy.
* **Availability.** If Docker Hub has an outage, your scale-up still works.
* **Audit.** Who pulled what, when.

### Cons

* **One more thing to run.** Artifactory itself must be highly available, or you
  have moved the single point of failure rather than removed it.
* **Credentials to manage.** Hence the secret in Secrets Manager, and hence the
  need to rotate that token.
* **Staleness.** A mirrored image only updates when someone pulls a new tag. Set
  a reminder to check for Keycloak security releases.

### Best practice for the tag

```hcl
keycloak_image_tag = "26.2.4"    # good: exact, reproducible
keycloak_image_tag = "26.2"      # okay: patch updates on rebuild
keycloak_image_tag = "latest"    # bad: two servers can run different versions
```

`latest` is genuinely dangerous here: if the ASG replaces one instance a week
after the others booted, you can end up with mismatched Keycloak versions
sharing one database schema.

---

## 5. Why a NAT Gateway, and how to avoid it

The Keycloak servers are in private subnets, so they need a NAT Gateway to reach
Artifactory. At about **$32/month plus data**, it is the largest fixed cost in
the whole project — for what is essentially one image download per instance
launch.

### The alternatives, honestly compared

| Approach | Monthly | Trade-off |
|---|---|---|
| **NAT Gateway (chosen)** | ~$32 | Managed, HA within its AZ, zero maintenance |
| VPC interface endpoints | ~$7 per endpoint per AZ | Works for AWS services (Secrets Manager, SSM, ECR, CloudWatch) but **not** for a third-party Artifactory host. Cheaper only if you also move the registry to ECR. |
| NAT instance (t4g.nano) | ~$3 | You patch it, it is a single point of failure, and you must disable source/dest checks |
| Public subnets + public IPs | $0 NAT, ~$3.60/IP | Servers are directly addressable from the internet. Security groups still block traffic, but you have removed a defence layer. **Not recommended for an identity server.** |
| Bake the image into a custom AMI | ~$0 | No pull at boot at all, and much faster starts. But you now maintain an AMI pipeline (Packer + a rebuild on every Keycloak release). |

**The genuinely best answer at scale:** mirror the image to **ECR** and use a VPC
endpoint. No NAT, no internet egress, faster pulls. It is not the default here
only because the requirement specified Artifactory.

---

## 6. Sticky sessions vs a real cluster

### What the default does

`enable_stickiness = true` gives each browser a cookie that pins it to one
server. Each Keycloak keeps its own in-memory cache.

**Pros:** works immediately, zero configuration, no extra ports.
**Cons:** if that server dies, its users are logged out. Load can end up uneven.
Admin console actions may not appear on the other node right away.

### What clustering does

`keycloak_cache_stack = "jdbc-ping"` (Keycloak 26.2+) makes the nodes discover
each other through a table in the PostgreSQL database and share their caches
over port 7800 — the port stack 2's self-referencing security group rule already
opens.

**Pros:** sessions survive a node failure; you can turn stickiness off; single
logout works properly everywhere.
**Cons:** more moving parts; a network partition can cause split-brain; every
session write now touches the network.

### Recommendation

Start sticky. Move to `jdbc-ping` before real users depend on it, and then set
`enable_stickiness = false` in stack 3.

> Older guides mention the `kubernetes` or `tcpping` stacks, or a custom
> `cache-ispn.xml`. On modern Keycloak, `jdbc-ping` is the simplest correct
> choice on EC2 because it reuses the database you already have.

---

## 7. Secrets: what this template does, and what it should do at scale

### Currently

| Secret | Where it lives | Grade |
|---|---|---|
| Database password | Generated by Terraform → Secrets Manager. Never printed, never in git. | **Good** |
| Artifactory credentials | Created by you, by hand, in Secrets Manager. Never in Terraform. | **Good** |
| Keycloak admin password | In `terraform.tfvars`. Defaults to `admin`. | **Bad** |

### Fixing the admin password properly

1. Create the secret by hand:
   ```bash
   aws secretsmanager create-secret --name keycloak/dev/admin \
     --secret-string '{"username":"admin","password":"<long random string>"}'
   ```
2. Add its ARN to the IAM policy in `iam.tf`.
3. Read it in the boot script the same way the database secret is read.
4. Delete the variable from tfvars.

Even then, remember the bootstrap admin only matters on **first boot** — after
that the account lives in the database. The real best practice is to use it once,
create a named admin account with MFA, and delete the bootstrap user.

### The state file problem

Terraform's state file contains **everything**, including `random_password` in
plain text. So:

* Never commit `terraform.tfstate` to git. (The included `.gitignore` handles it.)
* Use an S3 backend with `encrypt = true`, versioning on, and a bucket policy
  that denies unencrypted transport.
* Restrict who can read that bucket as tightly as you restrict production
  database access — because it *is* production database access.

---

## 8. Networking choices

### Two AZs, not three

Two is the minimum RDS and ALB accept, and it survives one data centre failure.
Three AZs costs 50% more compute and a third NAT Gateway if you are not sharing.

Change `availability_zone_count = 3` if you need to survive one AZ failure
*while already running degraded*. Most people do not.

### One NAT Gateway, not one per AZ

`single_nat_gateway = true` saves ~$32/month, but creates a real dependency: if
that one AZ has a problem, servers in the *other* AZ lose outbound internet.

Does that matter? Only at instance launch — running Keycloak servers talk to the
database over private addressing and need no internet at all. So the failure
mode is "we cannot scale up during an AZ outage", not "we are down". For
production, set `single_nat_gateway = false` and accept the extra cost.

### `/16` VPC with `/24` subnets

Roomy on purpose. A `/24` holds 251 usable addresses — far more than 2 servers
need, but it leaves space to add Lambda functions, extra services, or bigger
ASGs later without renumbering anything. IP addresses inside a private VPC are
free; renumbering a live network is not.

**Do check** that `10.20.0.0/16` does not overlap with your corporate network if
you will ever use VPN or VPC peering. Overlapping ranges cannot be peered, and
fixing it means rebuilding.

---

## 9. Security groups: reference groups, not CIDRs

Compare:

```hcl
# Weaker
cidr_ipv4 = "10.20.10.0/24"

# Stronger
referenced_security_group_id = aws_security_group.keycloak.id
```

The first allows *anything* that happens to get an address in that subnet. The
second allows exactly the instances wearing that security group — and keeps
working when the ASG replaces instances and every IP changes.

This is one of the highest-value habits in AWS networking, and it costs nothing.

---

## 10. IAM: least privilege in practice

The instance role can:

* read **two named secrets**,
* read parameters under **its own** `/project/env/` path,
* use Session Manager and write CloudWatch logs.

That is all. Compare with what you usually find in tutorials:

```hcl
# Please do not
actions   = ["secretsmanager:*"]
resources = ["*"]
```

If a Keycloak instance is compromised, the difference is "the attacker learned
one database password" versus "the attacker can read every secret in the
account".

**Next level:** add a condition so the role only works from your VPC:

```hcl
condition {
  test     = "StringEquals"
  variable = "aws:SourceVpc"
  values   = [local.vpc_id]
}
```

---

## 11. Health checks: `/health/ready` on port 9000

Three things people get wrong, all of which this template gets right:

1. **Wrong port.** Keycloak 25+ serves health on the management port (9000), not
   8080. Wrong port = every target permanently unhealthy.
2. **Wrong path.** `/health/live` means "the JVM is running". `/health/ready`
   means "I can actually serve requests, and the database is reachable". Only
   the second one belongs in a load balancer health check.
3. **Grace period too short.** Keycloak's first boot creates ~100 tables. With a
   60-second grace period the ASG kills each instance just before it finishes,
   forever. 300 seconds is the safe default here.

---

## 12. Cost engineering

Default cost: **~$95/month**. Breakdown and savings are in the main README.

The principle worth internalising: **the biggest lever is not instance size, it
is uptime.** A dev environment used 8 hours a day, 5 days a week is idle 76% of
the time. `destroy all` at night is a 76% saving and beats every other
optimisation combined.

To make that practical, keep the data: `destroy alb` + `destroy keycloak` at
night (saves ~$46/month, database survives) and `apply` in the morning takes 5
minutes.

Second lever: **Graviton.** `cpu_architecture = "arm64"` with `t4g.small` is
~20% cheaper for equal performance. Confirm your Artifactory mirror carries an
arm64 build — the official Keycloak image is multi-architecture, but a mirror
may only have synced one platform.

---

## 13. Terraform habits worth copying

| Habit | Why |
|---|---|
| Pin `required_version` and provider versions | The same code builds the same thing next year |
| `description` on every variable and output | Your future self is a different person |
| `validation` blocks on formatted strings | Fail in 1 second, not 20 minutes |
| `default_tags` on the provider | Cost allocation actually works |
| Never `-target` in normal operation | It is an escape hatch; needing it regularly means your stacks are wrong |
| `plan` before every `apply` | The only way to catch an accidental `destroy` of a database |
| Small, focused files | Terraform does not care; humans do |
| Never commit `.tfstate` or `.tfvars` with secrets | Both are plain text |
| Prefer `for_each` over `count` for named things | Removing item #1 from a `count` list re-indexes everything after it |
| Run `terraform fmt` before committing | Ends formatting arguments permanently |

### `count` vs `for_each`, briefly

This project uses `count` for subnets because they are genuinely identical and
positional (`subnet[0]`, `subnet[1]`). If subnets had distinct roles or names,
`for_each` over a map would be better: deleting one entry would not shuffle the
others and trigger unrelated rebuilds.

---

## 14. What is deliberately missing

Honest list of things a production identity platform needs that this template
does not include:

| Missing | Why it was left out | What to add |
|---|---|---|
| WAF | Extra cost; not needed for a demo | AWS WAF with a rate rule on `/realms/*/protocol/*` |
| Monitoring and alarms | Very account-specific | CloudWatch alarms: unhealthy host count, CPU, DB connections, free storage |
| Backup testing | Cannot be automated generically | A scheduled restore drill into a scratch account |
| Custom themes | Application concern | Bake into the image, or mount from S3 |
| Realm-as-code | Would need the Keycloak provider | `terraform-provider-keycloak`, applied as a 4th stack |
| Multi-region DR | Doubles the cost and complexity | Cross-region read replica + Route 53 failover |
| Secret rotation | Needs a Lambda | Secrets Manager rotation + an instance refresh |
| CI/CD pipeline | Every org differs | GitHub Actions or CodePipeline running `plan` on PR and `apply` on merge |

Adding realm configuration as a **fourth stack** is the most natural next step:
it would use the Keycloak provider to define realms, clients and roles in code,
so a fresh environment comes up fully configured rather than empty.
