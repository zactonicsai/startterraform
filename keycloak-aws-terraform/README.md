# Keycloak on AWS — a three-stack Terraform template

Build a working, highly available **Keycloak** login server on AWS with three
separate Terraform projects that you can apply, change, or delete **one at a
time**.

Everything in here is written to be read by someone who has never used
Terraform before. If a word looks scary, there is a plain-English explanation
right next to it.

---

## Table of contents

1. [What are we even building?](#1-what-are-we-even-building)
2. [The words you need to know](#2-the-words-you-need-to-know)
3. [The big picture](#3-the-big-picture)
4. [Before you start](#4-before-you-start)
5. [Step-by-step: build it once](#5-step-by-step-build-it-once)
6. [What the folders and files are](#6-what-the-folders-and-files-are)
7. [Stack 1 — network + database + secret](#7-stack-1--network--database--secret)
8. [Stack 2 — the Keycloak servers](#8-stack-2--the-keycloak-servers)
9. [Stack 3 — the public front door](#9-stack-3--the-public-front-door)
10. [The helper scripts](#10-the-helper-scripts)
11. [Changing things later (reconfigure)](#11-changing-things-later-reconfigure)
12. [Deleting things (destroy only part of it)](#12-deleting-things-destroy-only-part-of-it)
13. [Reusing this as a template](#13-reusing-this-as-a-template)
14. [What it costs](#14-what-it-costs)
15. [Pros and cons of this simple setup](#15-pros-and-cons-of-this-simple-setup)
16. [Best practices already baked in](#16-best-practices-already-baked-in)
17. [Before you call it production](#17-before-you-call-it-production)
18. [More reading](#18-more-reading)

---

## 1. What are we even building?

**Keycloak** is a free, open-source program that handles logging in. Instead of
every app you write having its own username and password page, all of them send
people to Keycloak. Keycloak checks who you are and hands the app a signed note
saying "this is really Priya, and she is a teacher." That note is a token, and
the rules for making it are standards called OpenID Connect, OAuth 2.0 and SAML.

Think of Keycloak as the **front desk of a big office building**. You show your
ID once at the desk, get a visitor badge, and then every room in the building
just checks the badge instead of asking for your ID again.

Keycloak needs three things to work well:

| It needs | Because | We build it in |
|---|---|---|
| A database | To remember users, realms, clients and sessions | Stack 1 |
| Servers to run on | Something has to actually execute the program | Stack 2 |
| A public address | So browsers and apps can reach it | Stack 3 |

That is exactly why this project is split into three Terraform stacks.

---

## 2. The words you need to know

| Word | Plain meaning |
|---|---|
| **Terraform** | A tool where you *describe* what cloud stuff you want in text files, and it builds it. Describe it once, build it a hundred times identically. |
| **Stack** | One folder of Terraform files that gets built and deleted as a unit. We have three. |
| **Apply** | "Go build what I described." |
| **Destroy** | "Delete what you built." |
| **Plan** | "Show me what you *would* do, but don't touch anything." Always safe. |
| **State file** | Terraform's notebook. It remembers which real AWS thing matches which line of your code. Lose it and Terraform forgets it owns your infrastructure. |
| **VPC** | Your own private, fenced-off network inside AWS. Nothing gets in unless you allow it. |
| **Subnet** | A neighbourhood inside the VPC. *Public* subnets have a road to the internet, *private* ones do not. |
| **Availability Zone (AZ)** | A separate data centre building. Spreading across two means one building can burn down and you stay online. |
| **Security group** | A firewall wrapped around one resource. Default answer is "no"; you list the exceptions. |
| **EC2** | A virtual computer you rent by the second. |
| **Auto Scaling group (ASG)** | A babysitter for EC2 servers: "always keep exactly 2 alive; if one dies, build a new one." |
| **Launch template** | The recipe the babysitter follows to build each server. |
| **RDS** | A database that AWS runs, patches and backs up for you. |
| **Secrets Manager** | An encrypted vault for passwords. |
| **Parameter Store (SSM)** | A free key/value notepad in AWS. We use it to pass values between stacks. |
| **ALB** | Application Load Balancer. A traffic cop that takes requests from the internet and shares them between your servers. |
| **Docker image** | A frozen, ready-to-run copy of a program with everything it needs inside. |
| **Artifactory** | A private warehouse for Docker images that your company controls. |
| **NAT Gateway** | A one-way door. Private servers can call *out* to the internet, but nothing can call *in*. |

---

## 3. The big picture

```
                              INTERNET
                                 |
                                 v
                    +-------------------------+
   STACK 3          |  Application Load       |   public subnets
   public access    |  Balancer  (port 80)    |   10.20.0.0/24, 10.20.1.0/24
                    +-----------+-------------+
                                | forwards to port 8080
                                | health-checks port 9000
        +-----------------------+------------------------+
        |                                                |
        v                                                v
  +-----------+                                    +-----------+
  | Keycloak  |   STACK 2                          | Keycloak  |    private subnets
  | EC2 #1    |   Auto Scaling group               | EC2 #2    |    10.20.10.0/24
  | docker    |   (always keeps 2 alive)           | docker    |    10.20.11.0/24
  +-----+-----+                                    +-----+-----+
        |                                                |
        +----------------------+-------------------------+
                               | port 5432
                               v
                    +-------------------------+
   STACK 1          |  RDS PostgreSQL         |   same private subnets
   data + network   |  + Secrets Manager      |
                    +-------------------------+
```

**Traffic only ever flows downward.** The internet can reach the load balancer.
The load balancer can reach Keycloak. Keycloak can reach the database. Nothing
skips a level, and nothing reaches the database from outside.

### How the three stacks talk to each other

Stack 2 needs to know the VPC id and the secret name that stack 1 created. It
does **not** read stack 1's state file. Instead:

```
Stack 1  --writes-->  SSM Parameter Store  --read by-->  Stack 2
   /keycloak/dev/network/vpc_id
   /keycloak/dev/network/private_subnet_ids
   /keycloak/dev/database/secret_name        Stack 2 --writes--> Stack 3
   ...                                          /keycloak/dev/keycloak/asg_name
```

Why bother? Because it keeps the stacks **independent**. You can delete stack 3
without Terraform complaining that stack 2 depends on it, and each team can own
one stack with its own state file and its own permissions.

There is one more rule that makes this work, and it is worth remembering:

> **The stack that needs the door creates the door.**

Stack 1 creates the database firewall but leaves it completely shut. Stack 2
adds the one rule that lets Keycloak in on port 5432. Stack 3 adds the rule that
lets the load balancer into Keycloak on port 8080. Destroy stack 3 and that door
closes again automatically. No loops, no orphans.

---

## 4. Before you start

You need five things.

**1. An AWS account** with permission to create VPCs, EC2, RDS, IAM roles, load
balancers and secrets. A personal sandbox account is perfect.

**2. The AWS CLI, logged in.** Check it works:

```bash
aws sts get-caller-identity
```

You should see your account number. If not, run `aws configure`.

**3. Terraform 1.5 or newer** (or OpenTofu, which is the same thing):

```bash
terraform version
```

**4. A Keycloak image in your Artifactory.** This template pulls the image from
your private registry, not from the public internet. Set up a remote/proxy
repository in Artifactory that mirrors Docker Hub, then confirm the path:

```bash
docker pull mycompany.jfrog.io/docker-remote/keycloak/keycloak:26.2
```

**5. Artifactory credentials stored in AWS.** The servers read them at boot.
Create the secret once, by hand:

```bash
aws secretsmanager create-secret \
  --name keycloak/artifactory-credentials \
  --secret-string '{"username":"svc-keycloak","password":"YOUR-API-TOKEN"}'
```

> If your Artifactory repo allows anonymous pulls, skip step 5 and set
> `artifactory_auth_enabled = false` in `02-keycloak-compute/terraform.tfvars`.

---

## 5. Step-by-step: build it once

### Step 1 — open the settings files

Three files hold every setting. They are called `terraform.tfvars` and there is
one in each stack folder. Terraform reads them automatically.

Open all three and make sure these three lines are **identical** in each:

```hcl
aws_region   = "us-east-1"
project_name = "keycloak"
environment  = "dev"
```

Those three values are the glue. They build every resource name
(`keycloak-dev-vpc`) and every Parameter Store path (`/keycloak/dev/...`). If
they disagree, stack 2 will not find stack 1.

### Step 2 — point stack 2 at your Artifactory

In `02-keycloak-compute/terraform.tfvars`:

```hcl
artifactory_registry  = "mycompany.jfrog.io"          # <- change this
artifactory_repo_path = "docker-remote/keycloak/keycloak"
keycloak_image_tag    = "26.2"
```

Those three lines are glued together into the full image name:
`mycompany.jfrog.io/docker-remote/keycloak/keycloak:26.2`

### Step 3 — look before you leap

```bash
./scripts/run.sh plan db
```

`plan` changes nothing. It prints a list where `+` means "will create". Read it.
If it says it will create about 30 things — a VPC, subnets, a database, a
secret — you are in good shape.

### Step 4 — build the database and network

```bash
./scripts/run.sh apply db
```

Terraform shows the plan again and asks you to type `yes`. **This takes about
10 minutes**, because creating a real PostgreSQL server is slow. Go get a drink.

When it finishes you will see outputs like:

```
database_endpoint    = "keycloak-dev-postgres.abc123.us-east-1.rds.amazonaws.com"
database_secret_name = "keycloak-dev/database"
```

### Step 5 — build the Keycloak servers

```bash
./scripts/run.sh apply keycloak
```

About 2 minutes for Terraform to finish. But the servers themselves need another
**3 to 5 minutes** after that to boot, install Docker, pull the image, and let
Keycloak create around 100 database tables. Be patient; this is normal.

### Step 6 — build the public front door

```bash
./scripts/run.sh apply alb
```

About 3 minutes. At the end you get your URL:

```
keycloak_admin_console_url = "http://keycloak-dev-alb-1234567890.us-east-1.elb.amazonaws.com/admin"
```

### Step 7 — check that the servers are healthy

```bash
./scripts/run.sh status
```

Wait until both servers say `healthy`:

```
| Instance            | State    | Why  |
| i-0abc...           | healthy  | None |
| i-0def...           | healthy  | None |
```

If they say `initial`, the servers are still booting. Give it a few more minutes.

### Step 8 — log in

Open the `keycloak_admin_console_url` in a browser.

* Username: `admin`
* Password: `admin`

You are in. 🎉

### Step 9 — change that password immediately

`admin/admin` is a demo default and the URL is on the public internet. In the
admin console go to **Users → admin → Credentials → Reset password**, or better,
create a new admin user and delete the default one.

Then, so the setting does not come back on the next rebuild, edit
`02-keycloak-compute/terraform.tfvars` and set a real password there too. Even
better: put the password in Secrets Manager and stop keeping it in a file at all
(see [docs/02-best-practices-and-tradeoffs.md](docs/02-best-practices-and-tradeoffs.md)).

### Step 10 — when you are done, tear it down

```bash
./scripts/run.sh destroy all
```

This deletes everything so you stop paying. It asks you to type `yes` first.

---

## 6. What the folders and files are

```
keycloak-aws-terraform/
│
├── README.md                     <- you are here
├── .gitignore                    <- keeps secrets and state out of git
│
├── 01-network-database/          STACK 1: the land, the database, the secret
│   ├── versions.tf               which Terraform + provider versions to use
│   ├── variables.tf              every knob you can turn (with descriptions)
│   ├── network.tf                VPC, subnets, internet gateway, NAT, routes
│   ├── database.tf               PostgreSQL, its firewall, the password secret
│   ├── ssm_exports.tf            values handed to stacks 2 and 3
│   ├── outputs.tf                what gets printed after apply
│   └── terraform.tfvars          >>> YOUR SETTINGS GO HERE <<<
│
├── 02-keycloak-compute/          STACK 2: the servers running Keycloak
│   ├── versions.tf
│   ├── variables.tf
│   ├── data.tf                   reads stack 1's values out of Parameter Store
│   ├── security.tf               Keycloak firewall + the door into the database
│   ├── iam.tf                    the ID badge each server wears
│   ├── asg.tf                    launch template + Auto Scaling group
│   ├── outputs.tf                outputs + values handed to stack 3
│   ├── terraform.tfvars          >>> YOUR SETTINGS GO HERE <<<
│   └── templates/
│       └── user_data.sh.tftpl    the boot script that starts the container
│
├── 03-public-access/             STACK 3: the public front door
│   ├── versions.tf
│   ├── variables.tf
│   ├── alb.tf                    load balancer, target group, listeners, rules
│   ├── outputs.tf                the URL you have been waiting for
│   └── terraform.tfvars          >>> YOUR SETTINGS GO HERE <<<
│
├── scripts/
│   ├── run.sh                    Linux / macOS driver
│   └── run.bat                   Windows driver (same commands)
│
└── docs/
    ├── 01-line-by-line-code-walkthrough.md   every block of code explained
    ├── 02-best-practices-and-tradeoffs.md    pros, cons, production checklist
    └── 03-operations-and-troubleshooting.md  day-2 ops and error messages
```

**Why so many small `.tf` files?** Terraform does not care — it glues every
`.tf` file in a folder together before running. The split is purely so humans
can find things.

---

## 7. Stack 1 — network + database + secret

### What it builds

| Thing | Count | Job |
|---|---|---|
| VPC | 1 | The fenced private network, `10.20.0.0/16` |
| Public subnets | 2 | Where the load balancer and NAT live |
| Private subnets | 2 | Where the database and Keycloak live |
| Internet gateway | 1 | The road between the VPC and the internet |
| NAT gateway | 1 | One-way door so private servers can download the image |
| Route tables | 3 | The maps that say where traffic goes |
| RDS PostgreSQL | 1 | Keycloak's memory |
| Security group | 1 | Firewall around the database, starts fully closed |
| Secrets Manager secret | 1 | Holds the generated database password |
| SSM parameters | 9 | Values handed to stacks 2 and 3 |

### The clever bit: nobody ever types the database password

```hcl
resource "random_password" "db" {
  length = 32
}
```

Terraform invents a 32-character password. It goes straight into RDS and into
Secrets Manager as JSON:

```json
{
  "engine": "postgres",
  "host": "keycloak-dev-postgres.abc.us-east-1.rds.amazonaws.com",
  "port": 5432,
  "dbname": "keycloak",
  "username": "kcadmin",
  "password": "...32 random characters...",
  "jdbc_url": "jdbc:postgresql://.../keycloak"
}
```

No human ever sees it, and it never lands in git. In stack 2, each server reads
this secret at boot using its IAM role.

To read it yourself when debugging:

```bash
aws secretsmanager get-secret-value \
  --secret-id keycloak-dev/database \
  --query SecretString --output text | jq
```

### The settings you are most likely to change

```hcl
vpc_cidr                = "10.20.0.0/16"   # must not clash with other networks
availability_zone_count = 2                # 2 is the minimum for RDS + ALB
enable_nat_gateway      = true             # needed to pull the Docker image
single_nat_gateway      = true             # one shared gateway = cheapest
db_instance_class       = "db.t4g.micro"   # smallest/cheapest option
db_multi_az             = false            # true = standby copy, double cost
db_deletion_protection  = false            # true in production!
```

---

## 8. Stack 2 — the Keycloak servers

### What it builds

| Thing | Job |
|---|---|
| Security group | Firewall around the Keycloak servers |
| Ingress rule on the DB firewall | Opens port 5432 for Keycloak *only* |
| IAM role + instance profile | The ID badge: read our secrets, nothing else |
| CloudWatch log group | Where the container's log lines land |
| Launch template | The recipe for building one Keycloak server |
| Auto Scaling group | Keeps exactly 2 servers alive across 2 AZs |
| SSM parameters | Values handed to stack 3 |

### How a server boots — the seven steps

The file `templates/user_data.sh.tftpl` runs once, automatically, the first time
each server starts:

1. **Install tools** — `docker` (runs the container), `jq` (reads JSON),
   `aws` (talks to AWS).
2. **Find out who I am** — asks AWS for its own instance id, using IMDSv2, the
   secure method that blocks a whole family of credential-theft attacks.
3. **Read the database secret** — allowed because of the IAM role. Retries 10
   times, because networking sometimes takes a moment to settle.
4. **Log in to Artifactory and pull the image** — retries 5 times.
5. **Write `/etc/keycloak.env`** with permissions `600` (owner-only). Passwords
   live in a locked file instead of on the command line, where anyone running
   `ps` could read them.
6. **Start the container** with `--restart unless-stopped`, so it comes back by
   itself after a reboot or a crash.
7. **Wait for `/health/ready`** and log the result.

Everything it prints is saved to `/var/log/keycloak-bootstrap.log` on the
server. That file is the first place to look when something goes wrong.

### The environment variables Keycloak actually gets

| Variable | Value | Why |
|---|---|---|
| `KC_DB` | `postgres` | Use PostgreSQL, not the built-in dev database |
| `KC_DB_URL_HOST/PORT/DATABASE` | from the secret | Where to connect |
| `KC_DB_USERNAME/PASSWORD` | from the secret | How to log in |
| `KC_HTTP_ENABLED` | `true` | The load balancer already handles TLS |
| `KC_PROXY_HEADERS` | `xforwarded` | Trust `X-Forwarded-*` so Keycloak knows the real client address and builds correct URLs |
| `KC_HOSTNAME_STRICT` | `false` | Work with whatever hostname the load balancer has |
| `KC_HEALTH_ENABLED` | `true` | Turns on `/health/ready` for the health check |
| `KC_METRICS_ENABLED` | `true` | Turns on `/metrics` for Prometheus |
| `KC_BOOTSTRAP_ADMIN_USERNAME/PASSWORD` | `admin` / `admin` | First-time admin (Keycloak 26+ name) |
| `KEYCLOAK_ADMIN/_PASSWORD` | `admin` / `admin` | Same thing, older name, kept for compatibility |

> **Important detail:** in Keycloak 25 and newer, health and metrics moved to a
> separate **management port 9000**. The app is on 8080; the health check is on
> 9000. Point the health check at 8080 and every server looks broken forever.
> This template already gets that right.

### Two servers, one cache — the session gotcha

By default each server keeps its own memory of who is logged in. If server A
starts your login and the second request lands on server B, the login can fail.

There are two fixes and this template supports both:

* **Sticky sessions (default).** The load balancer gives you a cookie so you
  always come back to the same server. Simple, works today, but if that server
  dies you get logged out.
* **A real cluster.** Set `keycloak_cache_stack = "jdbc-ping"` in stack 2's
  tfvars (Keycloak 26.2+). The servers find each other through the database and
  share sessions. Then you can turn stickiness off in stack 3.

---

## 9. Stack 3 — the public front door

### What it builds

| Thing | Job |
|---|---|
| Security group | Who may talk to the load balancer |
| 2 ingress rules on the Keycloak firewall | Lets the load balancer in on 8080 and 9000 |
| Application Load Balancer | The traffic cop, in the public subnets |
| Target group | The list of servers traffic may go to |
| Auto Scaling attachment | Plugs stack 2's ASG into that list |
| Listener on port 80 | "When traffic arrives on 80, forward it" |
| Listener on port 443 | Only when you turn HTTPS on |

### Why an ALB is the lowest-cost sensible option

| Option | Cost per month | Verdict |
|---|---|---|
| **Application Load Balancer** | ~$16 + ~$0.008/hour of usage | **Chosen.** Cheapest managed HTTP option. Free TLS termination, health checks, sticky sessions. |
| Network Load Balancer | ~$16 similar | Same price, but no cookies and no path rules. Worse fit for Keycloak. |
| CloudFront + ALB | ALB price + CDN | Better for global users, adds cost and complexity. |
| One EC2 running NGINX | ~$4 | Cheapest on paper. But *you* patch it, monitor it, and it is a single point of failure. Not worth it. |
| API Gateway | Per-request | Gets expensive fast at login volumes. |

### Health checks

```hcl
health_check {
  path     = "/health/ready"
  port     = "9000"          # the management port, NOT 8080
  matcher  = "200"
  interval = 30
}
```

A server must answer `200 OK` twice in a row to be called healthy, and fail
three times in a row to be taken out of rotation.

### Turning on HTTPS

Right now the site is plain HTTP, which is fine for a demo and **not fine** for
real logins — passwords would cross the internet unencrypted.

To fix it (about 10 minutes of work):

1. Own a domain name and request a **free** certificate in AWS Certificate
   Manager, in the same region.
2. Paste the certificate ARN into `03-public-access/terraform.tfvars`:
   ```hcl
   enable_https           = true
   acm_certificate_arn    = "arn:aws:acm:us-east-1:1234:certificate/abc-123"
   redirect_http_to_https = true
   ```
3. `./scripts/run.sh reconfigure alb`
4. Point a DNS CNAME from `sso.yourcompany.com` at the `alb_dns_name` output.
5. In stack 2 set `keycloak_hostname = "sso.yourcompany.com"` and
   `./scripts/run.sh redeploy`.

---

## 10. The helper scripts

Both scripts do exactly the same thing. Use `run.sh` on Linux/macOS and
`run.bat` on Windows.

```
./scripts/run.sh <command> [stack] [extra flags]
scripts\run.bat <command> [stack] [extra flags]
```

### Stack names (any of these work)

| You type | You get |
|---|---|
| `db`, `database`, `network`, `1` | 01-network-database |
| `keycloak`, `kc`, `compute`, `app`, `2` | 02-keycloak-compute |
| `alb`, `lb`, `public`, `3` | 03-public-access |
| `all` or nothing | all three, in the safe order |

### Commands

| Command | What it does | Dangerous? |
|---|---|---|
| `init` | Downloads the AWS provider plugin | No |
| `validate` | Checks the code for mistakes | No |
| `fmt` | Tidies up the formatting | No |
| `plan` | Shows what *would* change | No |
| `apply` | Builds or updates | Yes-ish |
| `reconfigure` | Applies again after you edited tfvars | Yes-ish |
| `redeploy` | Rolling restart so servers pick up new settings | Yes-ish |
| `destroy` | Deletes | **Yes** |
| `output` | Prints a stack's outputs | No |
| `status` | Health summary of the whole system | No |
| `clean` | Deletes local `.terraform` folders only | No |

### Handy examples

```bash
./scripts/run.sh plan all                 # preview everything
./scripts/run.sh apply db                 # only the database stack
./scripts/run.sh destroy alb              # take the site offline, keep the data
./scripts/run.sh reconfigure keycloak     # new image tag from tfvars
./scripts/run.sh redeploy                 # rolling restart of the servers
./scripts/run.sh status                   # are my servers healthy?
./scripts/run.sh apply keycloak -var 'asg_desired_capacity=3'   # extra flags pass through

AUTO_APPROVE=1 ./scripts/run.sh apply all # no typing "yes" (use in CI only)
TF_BIN=tofu ./scripts/run.sh plan all     # use OpenTofu instead of Terraform
```

---

## 11. Changing things later (reconfigure)

The workflow is always the same three moves:

1. Edit the `terraform.tfvars` in the stack you want to change.
2. `./scripts/run.sh plan <stack>` and read what will happen.
3. `./scripts/run.sh reconfigure <stack>`.

### The one thing that surprises everyone

When you change a Keycloak setting — a new image tag, a new admin password, a
new environment variable — Terraform updates the **launch template**. That is
the recipe for *future* servers. The two servers already running keep the old
settings until they are replaced.

So a Keycloak change is always **two** commands:

```bash
./scripts/run.sh reconfigure keycloak   # update the recipe
./scripts/run.sh redeploy               # replace the servers, one at a time
```

`redeploy` starts an **instance refresh**: AWS kills one server, waits for the
replacement to be healthy, then kills the second. Because
`min_healthy_percentage = 50`, at least one server stays up the whole time and
users do not notice.

### Common changes and where to make them

| I want to... | File | Setting |
|---|---|---|
| Upgrade Keycloak | stack 2 tfvars | `keycloak_image_tag` |
| Run 3 servers instead of 2 | stack 2 tfvars | `asg_desired_capacity` |
| Use bigger servers | stack 2 tfvars | `instance_type` |
| Save ~20% on compute | stack 2 tfvars | `cpu_architecture = "arm64"` + `instance_type = "t4g.small"` |
| Turn on HTTPS | stack 3 tfvars | `enable_https`, `acm_certificate_arn` |
| Restrict who can reach it | stack 3 tfvars | `allowed_cidr_blocks` |
| Make the database highly available | stack 1 tfvars | `db_multi_az = true` |
| Grow database storage | stack 1 tfvars | `db_allocated_storage` |

---

## 12. Deleting things (destroy only part of it)

This is the main reason the project is split in three.

| Command | What disappears | What survives | Typical reason |
|---|---|---|---|
| `destroy alb` | Load balancer, public access, the URL | Servers and **all data** | Save money overnight; the site is just unreachable |
| `destroy keycloak` | The 2 EC2 servers | **All data**, network, load balancer | Rebuild the servers from scratch |
| `destroy db` | Database, **all users and realms**, network | Nothing meaningful | You are finished with the whole project |
| `destroy all` | Everything | Nothing | End of the experiment |

### Order matters

Destroy **backwards**: 3 → 2 → 1. The script does this automatically for
`destroy all`.

If you try to destroy stack 1 while stack 2 still exists, Terraform will fail
with something like *"resource has a dependent object"*. That is not a bug —
it is the seat belt working. Stack 2's firewall rule is still attached to
stack 1's database firewall, so AWS refuses to delete it. Destroy stack 2 first.

### After `destroy alb`, the URL changes

A new load balancer gets a brand-new DNS name. If you have a real domain
pointing at it, update the CNAME after every rebuild — or use a Route 53 alias
record so it follows automatically.

### Two settings that block destroy on purpose

Both are `false` in this template so experimenting is easy. Flip them to `true`
in production:

```hcl
db_deletion_protection     = true   # stack 1
enable_deletion_protection = true   # stack 3
```

---

## 13. Reusing this as a template

Nothing in the code is hard-coded to one company, region or environment.
Everything comes from variables.

### Run a second copy alongside the first

Change **one word** in all three tfvars files:

```hcl
environment = "test"      # was "dev"
```

You now get `keycloak-test-vpc`, `keycloak-test-postgres`, parameters under
`/keycloak/test/...` — a completely separate system in the same AWS account
that cannot touch the dev one.

> Give it a different `vpc_cidr` too (say `10.30.0.0/16`) if you ever plan to
> peer the two networks together.

Because each environment needs its own state file, either copy the project
folder per environment, or use Terraform workspaces / separate backend keys.

### Use it in a different company

1. `project_name` → your product name.
2. `artifactory_registry` and `artifactory_repo_path` → your registry.
3. `vpc_cidr` → an IP range your network team gives you.
4. `extra_tags` → your cost centre and owner tags.
5. Switch the backend from local to S3 (uncomment the block in each
   `versions.tf`) so the state is shared and locked.

### Reuse it inside an existing VPC

You already have a VPC and are not allowed to make another? Do not run stack 1's
network part. Instead, write the SSM parameters yourself and stacks 2 and 3 will
happily consume them:

```bash
aws ssm put-parameter --name /keycloak/dev/network/vpc_id \
  --type String --value vpc-0123456789 --overwrite
aws ssm put-parameter --name /keycloak/dev/network/private_subnet_ids \
  --type StringList --value subnet-aaa,subnet-bbb --overwrite
aws ssm put-parameter --name /keycloak/dev/network/public_subnet_ids \
  --type StringList --value subnet-ccc,subnet-ddd --overwrite
# ...plus the /database/* parameters if you also bring your own database
```

That decoupling is a direct benefit of using Parameter Store instead of reading
each other's state files.

### Turn a stack into a reusable module

Each folder is already shaped like a Terraform module: inputs in
`variables.tf`, outputs in `outputs.tf`, no hard-coded values. To publish one,
move it into `modules/`, delete its `terraform.tfvars` and `provider` block, and
call it from a root module.

---

## 14. What it costs

Rough `us-east-1` prices for the default settings, running 24/7.

| Thing | Monthly |
|---|---|
| NAT Gateway (1) | ~$32 + data |
| Application Load Balancer | ~$16 + traffic |
| 2 × t3.small EC2 | ~$30 |
| RDS db.t4g.micro + 20 GB gp3 | ~$15 |
| Secrets Manager (1 secret) | ~$0.40 |
| Parameter Store (Standard) | free |
| CloudWatch Logs (light use) | ~$1 |
| **Total** | **~$95 / month** |

### Ways to spend less

| Change | Saves | Cost of the change |
|---|---|---|
| `destroy alb` when not in use | ~$16/mo | Site unreachable; URL changes on rebuild |
| `destroy keycloak` + `destroy alb` overnight | ~$46/mo | 5-minute rebuild in the morning; data safe |
| `asg_desired_capacity = 1` | ~$15/mo | No redundancy; a reboot is an outage |
| `cpu_architecture = "arm64"` + `t4g.small` | ~$6/mo | Must confirm your image has an arm64 build |
| `use_spot_instances = true` | ~$20/mo | AWS can reclaim a server with 2 minutes' notice |
| `enable_nat_gateway = false` | ~$32/mo | Servers cannot pull the image unless you add VPC endpoints or move them to public subnets |
| `db_backup_retention_days = 1` | ~$1/mo | Only one day to recover from a mistake |

> **The single biggest saving is turning things off.** `destroy all` at the end
> of the day and `apply all` in the morning costs about 15 minutes and takes the
> bill to nearly zero — the data is gone too, so only do this on a sandbox.

---

## 15. Pros and cons of this simple setup

### Pros

* **Genuinely highly available at the app layer.** Two servers in two different
  data centres, with a babysitter that rebuilds any server that dies.
* **No password is ever typed, stored in git, or printed.** It is generated,
  vaulted, and read at boot with a temporary IAM credential.
* **No SSH keys and no port 22.** Shell access goes through AWS Session Manager,
  which is logged and permission-controlled.
* **Split into three stacks**, so you can rebuild the servers without risking the
  database, and turn public access off with one command.
* **Everything is a variable.** Change one word to get a second environment.
* **Self-healing.** The container restarts on crash; the ASG replaces dead
  servers; the load balancer stops sending traffic to sick ones.
* **Cheap to run and cheap to switch off.**
* **Repeatable.** Delete it all and rebuild it identically in 20 minutes.

### Cons — and they are real

| Problem | Why it matters | Fix |
|---|---|---|
| **`admin/admin` by default** | Anyone who finds the URL owns your identity system | Change it in step 9; move it to Secrets Manager |
| **Plain HTTP by default** | Passwords cross the internet in the clear | Turn on `enable_https` with an ACM certificate |
| **Database is single-AZ** | One data centre problem = full outage, restore from backup | `db_multi_az = true` (roughly doubles DB cost) |
| **Sticky sessions, not a real cluster** | A dying server logs its users out | `keycloak_cache_stack = "jdbc-ping"` |
| **State file is local** | If your laptop dies, Terraform forgets what it owns; two people applying at once corrupt it | Move to the S3 backend with locking |
| **`terraform.tfvars` is in git** | Convenient for a template, wrong for real secrets | Keep non-secret settings; move secrets to Secrets Manager |
| **Docker container, not a container platform** | No orchestration, no built-in image scanning | Fine at this size; consider ECS/EKS if it grows |
| **`start` not `start --optimized`** | Keycloak re-runs its build step on every boot, adding ~30s | Build a pre-optimized image in your CI |
| **NAT Gateway is the biggest bill line** | ~$32/month for what is mostly one image download | VPC endpoints, or a NAT instance, or cache the image in a custom AMI |
| **No WAF, no rate limiting** | Login endpoints are a favourite brute-force target | Add AWS WAF; enable Keycloak brute-force detection |
| **No automated backup testing** | Backups you have never restored are just hopes | Practise a restore |
| **No monitoring or alarms** | You find out it is down when a user tells you | CloudWatch alarms on unhealthy hosts, CPU, DB connections |

---

## 16. Best practices already baked in

You get these for free just by using the template:

1. **Least privilege IAM.** The servers' role can read *two specific secrets*
   and *its own* parameters. Not `secretsmanager:*` on `*`.
2. **IMDSv2 required.** `http_tokens = "required"` blocks the SSRF attacks that
   have leaked cloud credentials at several large companies.
3. **No SSH, no key pairs.** Session Manager instead — logged and revocable.
4. **Encryption everywhere.** RDS storage, EBS volumes and Secrets Manager are
   all encrypted at rest.
5. **The database is never public.** `publicly_accessible = false`, private
   subnets, and a firewall that only names the Keycloak security group.
6. **Firewalls reference each other, not IP ranges.** "Allow the Keycloak
   security group" keeps working when servers are replaced and IPs change;
   "allow 10.20.10.0/24" would also allow anything else in that subnet.
7. **Version pinning.** `required_version` and `~> 5.60` mean the same code
   builds the same thing next year.
8. **Tag everything.** `default_tags` puts Project, Environment, ManagedBy and
   Stack on every resource, so the cost report actually makes sense.
9. **`plan` before `apply`, always.** The scripts make this the easy path.
10. **Health checks that check the app, not the machine.** `/health/ready` says
    "Keycloak answered", not merely "the computer is on".
11. **Rolling updates.** Instance refresh replaces servers one at a time.
12. **Retries in the boot script.** Cloud APIs are occasionally slow; retrying is
    the difference between a flaky build and a reliable one.
13. **Every variable has a description and, where it matters, validation** — so
    a typo fails at plan time with a clear message, not at 2 a.m.

---

## 17. Before you call it production

Work through this list. Nothing here is optional for a real identity system.

**Security**
- [ ] Change `admin/admin`; move the admin password into Secrets Manager
- [ ] `enable_https = true` with a real ACM certificate
- [ ] Narrow `allowed_cidr_blocks` if the audience is internal
- [ ] Add AWS WAF with rate limiting on `/realms/*/protocol/*`
- [ ] Turn on Keycloak brute-force detection in the admin console
- [ ] `enable_vpc_flow_logs = true`
- [ ] Use a customer-managed KMS key (`kms_key_arn`) if compliance requires it
- [ ] Set up secret rotation for the database password

**Reliability**
- [ ] `db_multi_az = true`
- [ ] `db_deletion_protection = true` and `enable_deletion_protection = true`
- [ ] `db_skip_final_snapshot = false`
- [ ] `asg_health_check_type = "ELB"` (after stack 3 exists)
- [ ] `keycloak_cache_stack = "jdbc-ping"`, then `enable_stickiness = false`
- [ ] Practise restoring the database from a snapshot

**Operations**
- [ ] Move state to S3 with DynamoDB locking
- [ ] Run apply from CI, not from laptops
- [ ] CloudWatch alarms: unhealthy hosts, CPU, DB connections, DB storage
- [ ] `enable_access_logs = true` on the load balancer
- [ ] Pin an exact image tag (`26.2.4`, not `26.2` and never `latest`)
- [ ] Build a pre-optimized Keycloak image so boots are faster
- [ ] Write down the runbook: how to roll back a bad image

---

## 18. More reading

* [docs/01-line-by-line-code-walkthrough.md](docs/01-line-by-line-code-walkthrough.md)
  — every block of code, explained in order.
* [docs/02-best-practices-and-tradeoffs.md](docs/02-best-practices-and-tradeoffs.md)
  — the reasoning behind each design decision, and what to do differently at
  scale.
* [docs/03-operations-and-troubleshooting.md](docs/03-operations-and-troubleshooting.md)
  — every error message you are likely to hit, and how to fix it.

External:

* Keycloak documentation — https://www.keycloak.org/documentation
* Keycloak on production — https://www.keycloak.org/server/configuration-production
* Terraform AWS provider — https://registry.terraform.io/providers/hashicorp/aws/latest/docs
* AWS Well-Architected Framework — https://aws.amazon.com/architecture/well-architected/
