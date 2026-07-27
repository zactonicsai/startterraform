# Line-by-line code walkthrough

This document walks through **every file** in the project, block by block, in
the order Terraform effectively cares about. Read it with the code open next to
you.

Reminder of how Terraform files work:

* Terraform reads **every** `.tf` file in a folder and glues them together.
  The file names are for humans only.
* `resource` = "build this thing".
* `data` = "look up something that already exists; don't build it".
* `variable` = "a knob someone can turn".
* `output` = "print this when you're done, and let other code read it".
* `locals` = "a nickname for a value I use a lot".
* `${...}` inside a string means "paste the value of this here".

---

## Table of contents

- [Stack 1 — 01-network-database](#stack-1--01-network-database)
  - [versions.tf](#01--versionstf)
  - [variables.tf](#01--variablestf)
  - [network.tf](#01--networktf)
  - [database.tf](#01--databasetf)
  - [ssm_exports.tf](#01--ssm_exportstf)
  - [outputs.tf](#01--outputstf)
- [Stack 2 — 02-keycloak-compute](#stack-2--02-keycloak-compute)
  - [data.tf](#02--datatf)
  - [security.tf](#02--securitytf)
  - [iam.tf](#02--iamtf)
  - [asg.tf](#02--asgtf)
  - [templates/user_data.sh.tftpl](#02--templatesuser_datashtftpl)
  - [outputs.tf](#02--outputstf)
- [Stack 3 — 03-public-access](#stack-3--03-public-access)
  - [alb.tf](#03--albtf)
  - [outputs.tf](#03--outputstf)
- [scripts/run.sh](#scriptsrunsh)

---

# Stack 1 — 01-network-database

## 01 — versions.tf

```hcl
terraform {
  required_version = ">= 1.5.0"
```

"Refuse to run on Terraform older than 1.5." Older versions do not understand
some of the syntax used here. Failing early with a clear message beats failing
halfway through with a confusing one.

```hcl
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.60"
    }
```

A **provider** is a plugin that knows how to talk to one service. `~> 5.60`
means "any 5.x from 5.60 up, but never 6.0". Version 6 could rename things and
break the code, so we allow bug fixes but not surprises.

```hcl
    random = { source = "hashicorp/random", version = "~> 3.6" }
```

Used once, to invent the database password.

```hcl
  # backend "s3" { ... }
```

Commented out on purpose. By default Terraform saves its notebook (the *state
file*) next to the code as `terraform.tfstate`. That is perfect for learning and
wrong for a team, because two people applying at the same time will corrupt it.
Uncomment this block to store state in S3 with locking.

```hcl
provider "aws" {
  region = var.aws_region

  default_tags {
    tags = merge({ Project = ..., Environment = ..., ManagedBy = "terraform", Stack = "01-..." }, var.extra_tags)
  }
}
```

`default_tags` stamps these labels onto **every single resource** this provider
creates. You write it once instead of on 32 resources. `merge()` combines our
standard tags with whatever extra tags the user added in tfvars. Six months
later, tags are how you answer "what is this thing and who pays for it?".

---

## 01 — variables.tf

Every variable follows the same shape:

```hcl
variable "vpc_cidr" {
  description = "The whole private IP range for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}
```

* `description` shows up in `terraform plan` errors and in generated docs. Always
  write one.
* `type` catches mistakes early — pass a string where a number belongs and
  Terraform stops before touching AWS.
* `default` makes the variable optional. No default means "you must supply this".

Some variables also validate their input:

```hcl
variable "project_name" {
  validation {
    condition     = can(regex("^[a-z0-9-]{2,20}$", var.project_name))
    error_message = "project_name must be 2-20 characters of lowercase letters, numbers or dashes."
  }
}
```

`regex` is a pattern. This one says "2 to 20 characters, only lowercase letters,
digits and dashes." Why? Because AWS resource names have rules, and a capital
letter in `project_name` would produce an illegal load balancer name **20
minutes into the build**. Catching it in the first second is far kinder.

`can(...)` means "try this and give me true or false instead of crashing".

---

## 01 — network.tf

```hcl
data "aws_availability_zones" "available" {
  state = "available"
}
```

A `data` block **asks a question**. This one asks AWS: "which data centres in
this region are usable right now?" We do not hard-code `us-east-1a`, because
that name does not exist in other regions — that is what makes the template
portable.

```hcl
locals {
  name_prefix = "${var.project_name}-${var.environment}"
  azs         = slice(data.aws_availability_zones.available.names, 0, var.availability_zone_count)
  nat_gateway_count = var.enable_nat_gateway ? (var.single_nat_gateway ? 1 : var.availability_zone_count) : 0
  ssm_prefix  = "/${var.project_name}/${var.environment}"
}
```

* `name_prefix` becomes `keycloak-dev`. Used in every resource name.
* `slice(list, 0, 2)` takes the first two items. If AWS returns six AZs and we
  asked for 2, we take the first two.
* The nat line is two questions stacked: *"Do we want NAT at all? If yes, do we
  want one or one-per-AZ?"* `a ? b : c` means "if a then b else c".
* `ssm_prefix` becomes `/keycloak/dev` — the folder in Parameter Store.

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
}
```

The VPC is the fenced land. `10.20.0.0/16` gives you 65,536 addresses.

Both DNS settings **must** be true. Without them, RDS never gets a private DNS
name and Keycloak cannot resolve the database host from the secret. This one
line has caused a great many confused evenings.

```hcl
resource "aws_internet_gateway" "main" { vpc_id = aws_vpc.main.id }
```

The road between your land and the internet. Notice `aws_vpc.main.id` — this is
how Terraform learns the **order** of things. It sees the reference and knows
the VPC must exist first. You never write the order down yourself.

### Subnets, and the maths behind them

```hcl
resource "aws_subnet" "public" {
  count             = var.availability_zone_count
  cidr_block        = cidrsubnet(var.vpc_cidr, var.public_subnet_newbits, count.index)
  availability_zone = local.azs[count.index]
  map_public_ip_on_launch = true
}
```

`count = 2` means "make two of these". Inside, `count.index` is 0 then 1, so
each copy gets a different subnet and a different data centre.

`cidrsubnet("10.20.0.0/16", 8, 0)` = `10.20.0.0/24`. Read it as: *take the big
range, chop it into pieces that are 8 bits smaller, and give me piece number 0.*

| Call | Result | Addresses |
|---|---|---|
| `cidrsubnet(vpc, 8, 0)` | 10.20.0.0/24 | 256 |
| `cidrsubnet(vpc, 8, 1)` | 10.20.1.0/24 | 256 |
| `cidrsubnet(vpc, 8, 10)` | 10.20.10.0/24 | 256 |

Private subnets deliberately start at index **10**:

```hcl
cidr_block = cidrsubnet(var.vpc_cidr, var.private_subnet_newbits, count.index + 10)
```

That leaves a clean gap so the two groups never collide, and so you can add
public subnets later without renumbering anything. `10.20.0.x` = public,
`10.20.1x.x` = private is also just easy to read at a glance.

`map_public_ip_on_launch = true` on public subnets, `false` on private ones —
this is literally the difference between the two.

### NAT Gateway

```hcl
resource "aws_eip" "nat" {
  count      = local.nat_gateway_count
  domain     = "vpc"
  depends_on = [aws_internet_gateway.main]
}

resource "aws_nat_gateway" "main" {
  count         = local.nat_gateway_count
  allocation_id = aws_eip.nat[count.index].id
  subnet_id     = aws_subnet.public[count.index].id
}
```

An **Elastic IP** is a permanent public address. The NAT Gateway uses it as its
return address.

The NAT Gateway lives in a **public** subnet even though it serves private ones.
That trips people up. Think of it as a mail room on the ground floor: the
offices upstairs are sealed, but their post still goes out through the lobby.

`depends_on` is the manual version of the ordering Terraform usually works out
by itself. An Elastic IP cannot be created before the internet gateway exists,
but nothing in the code references it, so we say so explicitly.

### Route tables

```hcl
resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.main.id
}
```

A route table is a signpost. `0.0.0.0/0` means "everything I don't otherwise
know about". So: *anything not inside the VPC, send to the internet gateway.*

```hcl
resource "aws_route" "private_nat" {
  count          = var.enable_nat_gateway ? var.availability_zone_count : 0
  nat_gateway_id = var.single_nat_gateway ? aws_nat_gateway.main[0].id : aws_nat_gateway.main[count.index].id
}
```

Same idea for private subnets, but pointing at the NAT instead. The ternary
picks the shared NAT (`[0]`) or the one in this AZ (`[count.index]`).

A route table does nothing until it is **associated** with a subnet:

```hcl
resource "aws_route_table_association" "public" {
  count          = var.availability_zone_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}
```

### Flow logs (optional)

```hcl
data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service", identifiers = ["vpc-flow-logs.amazonaws.com"] }
  }
}
```

An IAM **trust policy** answers "who is allowed to *wear* this role?". Here:
only the VPC flow-logs service. Writing it as a `data` block instead of raw JSON
means Terraform checks the syntax for you.

Every flow-log resource has `count = var.enable_vpc_flow_logs ? 1 : 0` — the
standard Terraform way of saying "build this only if the flag is on".

---

## 01 — database.tf

```hcl
resource "aws_db_subnet_group" "main" {
  subnet_ids = aws_subnet.private[*].id
}
```

`aws_subnet.private[*].id` is a **splat**: "the id of every private subnet",
giving a list. The subnet group tells RDS which neighbourhoods it may live in.
RDS demands at least two AZs even for a single-AZ database, so it can fail over
later without rebuilding.

```hcl
resource "aws_security_group" "database" {
  name        = "${local.name_prefix}-db-sg"
  description = "Postgres access for Keycloak only"
  vpc_id      = aws_vpc.main.id

  lifecycle { create_before_destroy = true }
}
```

Notice: **no ingress rules at all**. The database's firewall starts completely
shut. Stack 2 adds the single rule that opens 5432 for Keycloak. This is the
"the stack that needs the door creates the door" rule, and it is what keeps the
three stacks free of circular dependencies.

`create_before_destroy` tells Terraform: when you must replace this, build the
new one first. Otherwise AWS refuses to delete a security group that things are
still attached to.

```hcl
resource "random_password" "db" {
  length           = var.db_password_length
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}
```

32 random characters. `override_special` lists which punctuation is allowed —
RDS rejects `/`, `@`, `"` and space in a master password, so they are left out.
Discovering that at apply time is annoying; avoiding it entirely is better.

### The database itself

```hcl
  engine_version = var.db_engine_version   # "16"
```

Giving the **major** version only lets AWS pick the newest patch level. Pin
`"16.4"` exactly if you need reproducibility down to the patch.

```hcl
  max_allocated_storage = var.db_max_allocated_storage > 0 ? var.db_max_allocated_storage : null
```

`null` means "don't set this at all". So `0` in tfvars turns storage autoscaling
off, rather than trying to set a maximum of zero.

```hcl
  storage_encrypted   = true
  publicly_accessible = false
  multi_az            = var.db_multi_az
```

Encryption on, public access off. These two are not optional in any serious
setup, so they are hard-coded rather than left as knobs.

```hcl
  final_snapshot_identifier = var.db_skip_final_snapshot ? null : "${local.name_prefix}-final-${formatdate("YYYYMMDDhhmmss", timestamp())}"

  lifecycle { ignore_changes = [final_snapshot_identifier] }
```

Snapshot names must be unique, so we stamp the current time into it. But
`timestamp()` changes every single second, which would make Terraform think the
database needs rebuilding on every plan. `ignore_changes` says "once it is set,
stop looking at it".

### The secret

```hcl
resource "aws_secretsmanager_secret" "db" {
  name                    = "${local.name_prefix}/database"
  recovery_window_in_days = var.secret_recovery_window_days
}
```

`recovery_window_in_days` is the AWS recycle bin. Normally, deleting a secret
schedules it for deletion 7–30 days later, and **the name stays reserved**. So
`destroy` then `apply` fails with *"a secret with this name is scheduled for
deletion"*. Setting `0` in dev deletes it instantly and makes rebuild loops
painless. Use 7–30 in production, where undo matters more than speed.

```hcl
resource "aws_secretsmanager_secret_version" "db" {
  secret_string = jsonencode({
    engine = "postgres", host = aws_db_instance.main.address, ...
  })
}
```

The secret and its *contents* are two separate resources — the container and
what is inside it. `jsonencode` turns a Terraform map into proper JSON, escaping
anything that needs escaping. That is why the boot script can do `jq -r .password`
safely even when the password contains punctuation.

---

## 01 — ssm_exports.tf

```hcl
resource "aws_ssm_parameter" "private_subnet_ids" {
  name  = "${local.ssm_prefix}/network/private_subnet_ids"
  type  = "StringList"
  value = join(",", aws_subnet.private[*].id)
}
```

Parameter Store only holds text, so a list becomes `subnet-aaa,subnet-bbb`.
Stack 2 turns it back into a list with `split(",", ...)`.

Standard-tier parameters are **free**, which makes this a very cheap way to pass
values between stacks.

Note what is stored: the secret's **name and ARN**, never its contents. The
password stays in Secrets Manager where it is encrypted and access-logged.

---

## 01 — outputs.tf

```hcl
output "database_endpoint" {
  description = "Private DNS name of the PostgreSQL server."
  value       = aws_db_instance.main.address
}
```

Outputs do two jobs: they print useful values after `apply`, and they can be
read by scripts with `terraform output -raw database_endpoint`. The helper
script's `status` command works exactly this way.

There is deliberately **no output for the password**. Outputs land in the state
file and on the terminal. Anything genuinely secret stays in Secrets Manager.

---

# Stack 2 — 02-keycloak-compute

## 02 — data.tf

```hcl
data "aws_ssm_parameter" "vpc_id" {
  name = "${local.ssm_prefix}/network/vpc_id"
}
```

Stack 2's whole connection to stack 1 is a handful of lookups like this. If
stack 1 has not been applied, you get `ParameterNotFound` — a clear message
telling you to build stack 1 first. That is a feature, not a bug.

```hcl
locals {
  private_subnet_ids = split(",", data.aws_ssm_parameter.private_subnet_ids.value)
  db_port            = tonumber(data.aws_ssm_parameter.db_port.value)
}
```

Everything comes back as text, so we convert it once here and use the tidy
version everywhere else.

```hcl
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}
```

"Which AWS account am I in, and which region?" Used to build ARNs without
hard-coding an account number:

```hcl
artifactory_secret_arn = "arn:aws:secretsmanager:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:secret:${var.artifactory_secret_name}*"
```

The trailing `*` matters. Secrets Manager appends six random characters to every
secret ARN, so an exact-match policy would never match.

```hcl
data "aws_ssm_parameter" "al2023_ami" {
  name = var.cpu_architecture == "arm64" ? ".../al2023-ami-kernel-default-arm64" : ".../al2023-ami-kernel-default-x86_64"
}
```

AWS publishes the id of the newest Amazon Linux 2023 image at a public
parameter path. Reading it means you always boot a patched image, and you never
hard-code an AMI id that is region-specific and out of date within a month.

---

## 02 — security.tf

```hcl
resource "aws_vpc_security_group_ingress_rule" "keycloak_cluster" {
  security_group_id            = aws_security_group.keycloak.id
  from_port                    = 7800
  to_port                      = 7800
  referenced_security_group_id = aws_security_group.keycloak.id
}
```

This rule points at **itself**: "members of this group may talk to other members
of this group on port 7800." That is how Keycloak nodes find each other when
clustering is enabled.

```hcl
resource "aws_vpc_security_group_ingress_rule" "database_from_keycloak" {
  security_group_id            = local.db_security_group   # <- stack 1's firewall
  from_port                    = local.db_port
  referenced_security_group_id = aws_security_group.keycloak.id
}
```

The single most important rule in the project. Read it as: *"On the database's
firewall, allow port 5432 from anything wearing the Keycloak badge."*

Why reference a security group instead of an IP range?

* Servers get new IPs every time the ASG replaces one. A group reference just
  keeps working.
* `10.20.10.0/24` would also allow *anything else* that happens to land in that
  subnet. The group reference allows exactly the Keycloak servers, nothing else.

And because this rule is owned by stack 2, `destroy keycloak` closes the door
again automatically.

---

## 02 — iam.tf

```hcl
data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals { type = "Service", identifiers = ["ec2.amazonaws.com"] }
  }
}
```

"EC2 instances may wear this badge." Nobody else.

```hcl
data "aws_iam_policy_document" "keycloak" {
  statement {
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = compact([ local.db_secret_arn, var.artifactory_auth_enabled ? local.artifactory_secret_arn : "" ])
  }
```

**This is least privilege in action.** The role may read *these two specific
secrets* — not `secretsmanager:*` on `*`. If a server is ever compromised, the
attacker gets the Keycloak database password and nothing else in the account.

`compact()` removes empty strings from the list, so when Artifactory auth is off
that entry simply disappears rather than becoming an invalid empty ARN.

```hcl
resource "aws_iam_role_policy_attachment" "ssm_core" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}
```

This AWS-managed policy enables **Session Manager**. It is the reason there is no
SSH key and no port 22 anywhere in this project:

```bash
aws ssm start-session --target i-0123456789abcdef0
```

You get a shell. It is logged, it is permission-controlled, and there is no key
file to leak.

```hcl
resource "aws_iam_instance_profile" "keycloak" {
  role = aws_iam_role.keycloak.name
}
```

A small piece of AWS plumbing: EC2 cannot attach a role directly, only an
instance profile that wraps one. It exists purely to be attached.

---

## 02 — asg.tf

```hcl
locals {
  extra_env_lines = join("\n", [for k, v in var.keycloak_extra_env : "${k}=${v}"])
```

A **for expression**. It walks the map `{KC_LOG_LEVEL = "INFO"}` and produces
`["KC_LOG_LEVEL=INFO"]`, then joins with newlines so it can be pasted straight
into the env file.

```hcl
  user_data = templatefile("${path.module}/templates/user_data.sh.tftpl", {
    aws_region     = var.aws_region
    db_secret_name = local.db_secret_name
    ...
  })
}
```

`templatefile` reads the boot script and replaces every `${placeholder}` with a
real value. The result is a finished shell script.

### The launch template

```hcl
resource "aws_launch_template" "keycloak" {
  name_prefix = "${local.name_prefix}-keycloak-"
  image_id    = data.aws_ssm_parameter.al2023_ami.value
  user_data   = base64encode(local.user_data)
```

`name_prefix` (not `name`) lets Terraform create a new version safely alongside
the old one. AWS requires user data to be base64-encoded, so we encode it.

```hcl
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }
```

`http_tokens = "required"` forces **IMDSv2**. The old IMDSv1 let anything that
could trick your app into making an HTTP request read the instance's AWS
credentials — the root cause of several very large breaches. Requiring a session
token closes that hole.

`hop_limit = 2` allows one extra network hop, so a process **inside the Docker
container** can still reach the metadata service. With the default of 1, the
container cannot fetch credentials and the boot script fails in a way that is
genuinely hard to diagnose.

```hcl
  lifecycle { create_before_destroy = true }
```

Build the new version before removing the old, so the ASG is never left
pointing at a template that does not exist.

### The Auto Scaling group

```hcl
resource "aws_autoscaling_group" "keycloak" {
  vpc_zone_identifier = local.private_subnet_ids
  min_size            = 2
  max_size            = 4
  desired_capacity    = 2
```

The babysitter. `desired_capacity = 2` means "keep two alive". Because
`vpc_zone_identifier` lists subnets in two different AZs, AWS spreads them
across two data centres automatically.

```hcl
  health_check_grace_period = 300
```

Five minutes of grace before health checks count. Keycloak needs time to boot,
pull the image and create around a hundred database tables. Set this too low and
the ASG kills each server just before it becomes ready — an infinite loop of
half-built servers, and a classic first-day failure.

```hcl
  launch_template {
    id      = aws_launch_template.keycloak.id
    version = aws_launch_template.keycloak.latest_version
  }
```

"Always use the newest version of the recipe."

```hcl
  dynamic "instance_refresh" {
    for_each = var.enable_instance_refresh ? [1] : []
    content {
      strategy = "Rolling"
      preferences { min_healthy_percentage = 50 }
    }
  }
```

A `dynamic` block is a block that may or may not exist. `for_each = [1]` creates
one; `for_each = []` creates none. This is the standard way to make an entire
block optional.

`min_healthy_percentage = 50` with 2 servers means "never take both down at
once" — so a rolling update stays online.

```hcl
  lifecycle {
    ignore_changes = [target_group_arns, load_balancers]
  }
```

Stack 3 attaches this ASG to a load balancer target group. Without
`ignore_changes`, stack 2 would notice the attachment it did not create and
remove it — and stack 3 would put it back, forever. This one line stops the two
stacks fighting.

Note there is deliberately **no** `create_before_destroy` on the ASG: it has a
fixed name, and creating a replacement first would collide with the existing
name.

---

## 02 — templates/user_data.sh.tftpl

This is a shell script with Terraform placeholders in it. One rule while
reading:

* `${aws_region}` — Terraform replaces this before the server sees it.
* `$DB_HOST` — a plain shell variable, filled in on the server itself.

That is why the script never writes `${DB_HOST}` with braces: Terraform would
try to resolve it and fail.

```bash
set -euo pipefail
exec > /var/log/keycloak-bootstrap.log 2>&1
set -x
```

* `set -e` — stop at the first failed command instead of ploughing on.
* `set -u` — treat an unset variable as an error.
* `set -o pipefail` — a pipeline fails if *any* stage fails, not just the last.
* `exec > file 2>&1` — send all output, normal and errors, to one log file.
* `set -x` — print each command before running it.

Together: when something breaks, the log shows exactly which command broke.

```bash
for i in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then break; fi
  sleep 2
done
```

`systemctl start docker` returns as soon as the service is *starting*, not when
it is *ready*. This loop waits for the daemon to actually answer. Every retry
loop in this script exists because some cloud operation is eventually consistent.

```bash
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
INSTANCE_ID=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)
```

`169.254.169.254` is a magic address that only exists inside EC2 and answers
questions about the machine you are on. Two steps because IMDSv2 is required:
first get a session token, then use it. This is exactly the protection
`http_tokens = "required"` enforces.

```bash
DB_SECRET=$(aws secretsmanager get-secret-value --secret-id "${db_secret_name}" --query SecretString --output text)
DB_PASS=$(echo "$DB_SECRET" | jq -r .password)
```

No credentials anywhere. The `aws` CLI picks up temporary credentials from the
instance profile automatically. `jq -r .password` pulls one field out of the
JSON; `-r` means raw, so you get the value without surrounding quotes.

```bash
install -m 600 /dev/null /etc/keycloak.env
cat > /etc/keycloak.env <<ENVEOF
KC_DB_PASSWORD=$DB_PASS
...
ENVEOF
```

`install -m 600` creates the file with owner-only permissions **before** anything
is written to it — so there is no moment where the password sits in a
world-readable file.

Why a file instead of `-e KC_DB_PASSWORD=...`? Because command-line arguments
are visible to every user on the box via `ps aux`. Environment files are not.

```bash
docker run -d --name keycloak --restart unless-stopped \
  --env-file /etc/keycloak.env \
  -p 8080:8080 -p 9000:9000 \
  "${keycloak_image}" start
```

* `-d` — run in the background.
* `--restart unless-stopped` — restart on crash and after a reboot, unless a
  human deliberately stopped it.
* `-p 8080:8080` — the app. `-p 9000:9000` — health and metrics.
* `start` — production mode. (`start-dev` would use an in-memory database and
  throw away every user on restart.)

```bash
for i in $(seq 1 60); do
  if curl -sf "http://localhost:9000/health/ready" >/dev/null; then
    echo "=== Keycloak is READY after $((i * 5)) seconds ==="
    exit 0
  fi
  sleep 5
done
docker logs --tail 100 keycloak || true
exit 0
```

Waits up to five minutes and, if Keycloak never comes up, dumps the container log
into the bootstrap log so the failure is diagnosable without logging in. It exits
`0` either way — a slow start should not mark the whole boot as failed; that is
the load balancer's job to decide.

---

## 02 — outputs.tf

Half of this file is not really outputs — it is `aws_ssm_parameter` resources
publishing values for stack 3:

```hcl
resource "aws_ssm_parameter" "asg_name" {
  name  = "${local.ssm_prefix}/keycloak/asg_name"
  value = aws_autoscaling_group.keycloak.name
}
```

Stack 3 reads this to know which Auto Scaling group to attach.

```hcl
output "session_manager_hint" {
  value = "aws ssm start-session --target <instance-id> --region ${var.aws_region}"
}
```

A small kindness: the exact command to get a shell, printed where you will see
it, so nobody has to look it up.

---

# Stack 3 — 03-public-access

## 03 — alb.tf

```hcl
locals {
  https_ready = var.enable_https && var.acm_certificate_arn != ""
}
```

HTTPS needs *both* the flag and a certificate. Bundling the check into one local
means the rest of the file just asks `local.https_ready` and cannot get it wrong.

```hcl
resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  count     = length(var.allowed_cidr_blocks)
  from_port = 80
  cidr_ipv4 = var.allowed_cidr_blocks[count.index]
}
```

One rule per allowed IP range, because each rule holds exactly one CIDR. With
the default `["0.0.0.0/0"]` you get one rule open to the world; with three office
IPs you get three rules.

```hcl
resource "aws_vpc_security_group_ingress_rule" "keycloak_from_alb" {
  security_group_id            = local.keycloak_sg_id      # stack 2's firewall
  referenced_security_group_id = aws_security_group.alb.id # this stack's ALB
}
```

Again, the door is created by the stack that needs it. **Destroying stack 3
closes this door**, so the Keycloak servers immediately become unreachable from
outside — which is precisely the behaviour you want from "turn off public
access".

```hcl
resource "aws_lb" "keycloak" {
  name               = substr("${local.name_prefix}-alb", 0, 32)
  load_balancer_type = "application"
  internal           = var.internal
  subnets            = local.public_subnet_ids
```

`substr(..., 0, 32)` because AWS rejects load balancer names longer than 32
characters. A long `project_name` would otherwise blow up at apply time.

The load balancer needs **at least two subnets in different AZs** — that is why
stack 1 insists on `availability_zone_count >= 2`.

```hcl
  drop_invalid_header_fields = true
```

Throws away malformed HTTP headers before they reach Keycloak. Cheap protection
against request-smuggling tricks.

### Target group and health checks

```hcl
resource "aws_lb_target_group" "keycloak" {
  port        = local.keycloak_port   # 8080
  target_type = "instance"

  health_check {
    path = "/health/ready"
    port = tostring(local.management_port)   # 9000
  }
```

Traffic goes to **8080**; health checks go to **9000**. In Keycloak 25 and newer
the health endpoints moved to a separate management port. Point the health check
at 8080 and every server is marked unhealthy forever — the single most common
Keycloak-behind-a-load-balancer mistake.

`/health/ready` means "ready to serve traffic" (database reachable, caches
warm). `/health/live` only means "the process is running", which is not enough.

```hcl
  deregistration_delay = var.deregistration_delay   # 30
```

When a server is removed, the load balancer stops sending *new* requests but
waits 30 seconds for in-flight ones to finish. The default is 300 seconds, which
makes every deployment feel five minutes slower than it needs to be.

```hcl
  dynamic "stickiness" {
    for_each = var.enable_stickiness ? [1] : []
    content { type = "lb_cookie", cookie_duration = 3600 }
  }
```

The load balancer sets a cookie so a visitor keeps landing on the same server.
Necessary while each server has its own cache. Turn it off once you enable
`jdbc-ping` clustering in stack 2.

### Attachment and listeners

```hcl
resource "aws_autoscaling_attachment" "keycloak" {
  autoscaling_group_name = local.asg_name
  lb_target_group_arn    = aws_lb_target_group.keycloak.arn
}
```

The bridge between stack 2 and stack 3, and the reason the dependency arrow
points one way only: stack 3 knows about stack 2, stack 2 knows nothing about
stack 3.

```hcl
resource "aws_lb_listener" "http" {
  port = 80

  dynamic "default_action" {
    for_each = local.https_ready && var.redirect_http_to_https ? [1] : []
    content { type = "redirect", redirect { port = "443", status_code = "HTTP_301" } }
  }

  dynamic "default_action" {
    for_each = local.https_ready && var.redirect_http_to_https ? [] : [1]
    content { type = "forward", target_group_arn = aws_lb_target_group.keycloak.arn }
  }
}
```

Two dynamic blocks with **opposite** conditions: exactly one of them exists.
Either port 80 redirects to HTTPS, or it forwards to Keycloak. This is the
standard Terraform pattern for "if / else" on a block.

---

## 03 — outputs.tf

```hcl
output "keycloak_admin_console_url" {
  value = local.https_ready ? "https://${aws_lb.keycloak.dns_name}/admin" : "http://${aws_lb.keycloak.dns_name}/admin"
}
```

The payoff. Also `alb_zone_id`, which you need if you want a Route 53 alias
record pointing at the load balancer, and `health_check_command`, a
copy-pasteable AWS CLI call for checking target health.

---

# scripts/run.sh

```bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
```

Works out where the project lives from where the script lives, so you can call
it from any directory.

```bash
if command -v terraform >/dev/null 2>&1; then TF_BIN="terraform"
elif command -v tofu >/dev/null 2>&1; then TF_BIN="tofu"
```

Uses Terraform if present, OpenTofu otherwise. `TF_BIN=tofu ./scripts/run.sh ...`
forces a choice.

```bash
resolve_stack() {
  case "${1:-}" in
    1|db|database|network|net)  echo "$STACK_1" ;;
```

Accepts whichever name you happen to think of. Small thing; saves a lot of
"which folder was it again?".

```bash
tf() {
  local dir="$1"; shift
  ( cd "$ROOT_DIR" && "$TF_BIN" -chdir="$dir" "$@" )
}
```

`-chdir` tells Terraform to run inside a folder without the script permanently
changing directory. The surrounding `( )` runs it in a subshell, so the change
is thrown away afterwards.

```bash
cmd_destroy() {
  if [ "$stack" = "all" ]; then
    do_destroy "$STACK_3"; do_destroy "$STACK_2"; do_destroy "$STACK_1"
```

**Reverse order**, always. Delete the front door before the land.

```bash
confirm() {
  [ "$AUTO_APPROVE" = "1" ] && return 0
  read -r answer
  [ "$answer" = "yes" ] || { info "Cancelled"; exit 0; }
}
```

Destructive commands make you type the whole word `yes`. `AUTO_APPROVE=1` skips
it for CI pipelines, where there is no human to ask.

```bash
cmd_redeploy() {
  do_apply "$STACK_2"
  aws autoscaling start-instance-refresh \
    --auto-scaling-group-name "$asg" \
    --preferences '{"MinHealthyPercentage":50,"InstanceWarmup":300}'
}
```

Two steps in one command: update the recipe, then tell AWS to replace the
running servers one at a time. This is the command you use to roll out a new
Keycloak version with no downtime.

`run.bat` is a line-for-line translation of the same logic for Windows, with
`setlocal EnableDelayedExpansion` and `!VAR!` in place of `$VAR` inside blocks —
a Batch quirk, not a difference in behaviour.
