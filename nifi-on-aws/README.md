# Apache NiFi on AWS — a complete, runnable kit

Run Apache NiFi on your Mac, then on one EC2 instance, then as a fault-tolerant
cluster behind a load balancer, then on EKS. Built twice — once with the AWS CLI
so you understand every piece, once with Terraform so it is reproducible — plus
tooling to export your flows and migrate them from older NiFi versions.

**Start with the guide:** [`docs/nifi-on-aws-guide.md`](docs/nifi-on-aws-guide.md)
— 15 chapters, written for someone who has never used NiFi, with a quiz at the
end of each chapter.

---

## ⚠️ Read these two things first

**1. NiFi 1.x is end of life.** `1.28.1` was the final release and support ended
in **December 2024**. If you are on 1.x, Chapter 6 of the guide is the one you
need.

**2. Do not run NiFi 2.7.2 or earlier.** **CVE-2026-25903** is a high-severity
authorization bypass affecting **1.1.0 through 2.7.2**, letting a lower-privileged
user bypass authorization on restricted components. The fix requires **2.8.0 or
later**. This kit pins **2.10.0**, and the Terraform *refuses to plan* on an
affected version on purpose.

---

## Four entry points — pick where you are

### 1. Your Mac (free, 10 minutes)

```bash
cd local-mac
./run.sh
# https://localhost:8443/nifi   admin / ChangeThisLocally123
```

Then do the back-pressure exercise in **guide Chapter 3 §3.4**. Stopping the
downstream processor and watching the upstream one halt by itself teaches the
NiFi model faster than anything else here.

A 3-node local cluster is in `docker-compose.cluster.yml` (wants ~8 GB of RAM).

### 2. One EC2 node (~$105/month)

```bash
cd cli
cp config.env.example config.env      # set NODE_COUNT=1
./00-preflight.sh                     # never skip this
./deploy-all.sh
```

No load balancer, no public endpoint, **no inbound firewall rules at all**. You
reach the UI by port-forwarding through SSM Session Manager — no open port, no
SSH key, no bastion, and every session in CloudTrail.

### 3. A cluster behind a load balancer (~$290–400/month)

Same scripts, `NODE_COUNT=3` and an ACM certificate **in the same region**:

```bash
cd cli
export NODE_COUNT=3
./deploy-all.sh
```

Or declaratively:

```bash
cd terraform
export TF_VAR_artifactory_password='...'
make plan VARS=example-cluster.tfvars   # read the plan
make apply
```

### 4. EKS (~$400–550/month)

```bash
cd eks
eksctl create cluster -f cluster.yaml   # 15-20 minutes
./install-controllers.sh
vi manifests/01-secrets.yaml            # placeholders - edit first
kubectl apply -f manifests/
```

---

## Migrating from an older NiFi

```bash
cd migration
./audit-for-nifi2.sh                     # what will break, on a live 1.x
./audit-for-nifi2.sh --flow flow.xml.gz  # deeper scan of a flow file
./export-everything.sh                   # flows + config + metadata
./import-flows.sh <export-dir> --dry-run
```

Three rules that catch everyone (guide Chapter 6):

1. **Upgrade to 1.27+ first**, then to 2.x. Jumping straight is not supported.
2. **Convert templates while still on 1.x.** Templates do not exist in 2.x and
   cannot be converted there. XML template files are useless to 2.x on their own.
3. **Copy `nifi.sensitive.props.key` to the new cluster before the first import.**
   Otherwise every encrypted credential arrives blank — and NiFi does not
   loudly tell you it happened.

---

## What is in here

| Path | What it is |
|---|---|
| `docs/nifi-on-aws-guide.md` | **The guide.** 15 chapters + 3 appendices. |
| `local-mac/` | docker-compose for one node and for a 3-node cluster, plus run/logs/stop scripts |
| `cli/` | 14 numbered bash scripts. One `NODE_COUNT` switch selects simple or cluster. |
| `cli/templates/` | the EC2 user-data bootstrap script |
| `terraform/` | 10 `.tf` files, two example tfvars, Makefile |
| `eks/` | eksctl cluster config, LB-controller installer, 5 manifests |
| `migration/` | export, audit and import tooling for flows and config |

---

## The one design decision to understand

**NiFi is not stateless.** Five local directories hold live state, and
`content_repository/` holds the actual bytes of data that is mid-journey.
NiFi clustering does **not** replicate that between nodes, and "offload"
requires the node to still be alive.

So an Auto Scaling Group — exactly right for a stateless app — will notice a
struggling NiFi node, **terminate the disk holding real data**, start an empty
replacement, and report success.

That is why this kit uses **discrete EC2 instances with persistent EBS volumes**
(`DeleteOnTermination=false`) rather than an ASG, and a **StatefulSet with
per-pod PVCs** on EKS. Guide Chapter 2 is the load-bearing chapter; read it
before changing the architecture.

---

## Two things the load balancer needs

1. **Sticky sessions ON.** The NiFi UI is a single-page app making many API
   calls. Scatter them across nodes and you get random logouts and half-drawn
   canvases.
2. **The ALB's DNS name in `nifi.web.proxy.host`.** NiFi checks the `Host`
   header against an allow-list and answers **"Invalid host header"** otherwise
   — a blank page in front of perfectly healthy nodes. Run
   `./06-nifi-nodes.sh --refresh-proxy` after creating the ALB.

The health check also uses matcher `200-401`, so an authentication challenge
still counts as "the web server is alive".

---

## Costs

| Stage | ~Monthly | Note |
|---|---|---|
| Local | free | |
| Single EC2 node | ~$105 | **$32 of it is the NAT Gateway** |
| Cluster + ALB | ~$290–400 | two NAT Gateways, three nodes, ALB |
| EKS | ~$400–550 | includes ~$73 control plane |

Order-of-magnitude figures — check the AWS pricing calculator for your region.

> **Set a budget alert before Stage 2.** AWS Console → Billing → Budgets.
> Two minutes. Everyone who skips it eventually pays for the lesson.

The NAT Gateway being a third of a single-node bill surprises people. Mirroring
the NiFi image into **ECR** and reaching it through a VPC endpoint can remove
NAT entirely — guide Chapter 12.

---

## Tearing it down

```bash
cd cli
./backup.sh          # flows + EBS snapshots + the sensitive key
./destroy-all.sh     # typed confirmations; asks what to do with data volumes
./orphan-hunt.sh     # ALWAYS. Finds what silently survived.
```

Terraform: `make snapshot` **then** `make destroy` — destroy deletes the data
volumes.

EKS: the StorageClass sets `reclaimPolicy: Retain`, so deleting the namespace
leaves every EBS volume in place, still billing. That is the correct default and
a real trap.

`orphan-hunt.sh` deliberately deletes nothing — after a NiFi teardown, an
unattached volume may be the only remaining copy of your in-flight data.

---

## Prerequisites

**Local:** Docker Desktop with **≥ 4 GB** given to it, `curl`, `jq`.
**AWS:** an account, AWS CLI **v2**, an Artifactory Docker registry and pull
credential, and (for cluster mode) an **ACM certificate in the load balancer's
region**.
**Terraform:** ≥ 1.6. **EKS:** `kubectl`, `eksctl`, `helm`.

---

## Versions

| Component | Version |
|---|---|
| Apache NiFi | **2.10.0** (June 2026) |
| Java (in the image) | 21 (required by NiFi 2.x) |
| ZooKeeper | 3.9 |
| Terraform / AWS provider | ≥ 1.6 / ~> 5.60 |
| EKS | 1.31 |

---

## License

MIT — see [`LICENSE`](LICENSE). Provided as teaching material; review it against
your own security and compliance requirements before production use.
