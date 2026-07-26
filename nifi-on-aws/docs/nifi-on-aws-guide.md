# Apache NiFi on AWS

### From a container on your Mac to a fault-tolerant cluster, explained from scratch

---

## What this is

A complete, step-by-step guide to running Apache NiFi — first on your laptop, then on a single AWS server, then as a fault-tolerant cluster behind a load balancer, then on Kubernetes. Built twice: once by typing AWS CLI commands so you understand every piece, and once with Terraform so it is reproducible. Then taken apart safely, without leaving anything behind that quietly charges you money.

It also covers the two things most NiFi guides skip: **how to get your flows out** (exports, backups, the transition to a new cluster) and **how to move flows from an older NiFi version**, which in 2026 means the 1.x to 2.x jump and is genuinely the hardest part of the job.

Written for someone who has never used NiFi and is not an AWS expert. Every term is explained the first time it appears. Every command is a real command you can copy.

**All of the code lives in this repository** — `local-mac/`, `cli/`, `terraform/`, `eks/` and `migration/` are the runnable versions of everything below.

---

## What you will build

| Stage | What it is | Cost |
|---|---|---|
| **1. Local** | NiFi in Docker on your Mac. One node, then a 3-node cluster. | free |
| **2. Simple EC2** | One NiFi node on one AWS server, no public endpoint. | ~$75–95/month |
| **3. Cluster + ALB** | Three nodes across two data centres, load balancer, ZooKeeper. | ~$290–400/month |
| **4. EKS** | The same cluster on Kubernetes, with disks that follow their pods. | ~$400–550/month |

Those figures are order-of-magnitude. Check the AWS pricing calculator for your region.

> ### 💸 Do this before Stage 2
> **AWS Console → Billing → Budgets → Create budget.** Set a monthly amount and an email alert. It takes two minutes. Everybody who skips it eventually pays for the lesson.

---

## Prerequisites

**For Stage 1 (your Mac):**

| Thing | Why | Check |
|---|---|---|
| Docker Desktop | runs NiFi | `docker info` |
| **≥ 4 GB given to Docker** | NiFi starts with less and then behaves oddly | Docker Desktop → Settings → Resources |
| `curl` and `jq` | talking to the NiFi API | `jq --version` |
| A browser | the NiFi UI | you have one |

**For Stages 2–3, additionally:**

| Thing | Why |
|---|---|
| An AWS account you can create resources in | no way around it |
| AWS CLI **v2** | `aws --version` must say `aws-cli/2.x` |
| Terraform ≥ 1.6 | only for the Terraform chapter |
| An Artifactory Docker registry + a pull credential | where the NiFi image comes from |
| An **ACM certificate in the same region as the load balancer** | HTTPS. Wrong region is the classic mistake. |
| A domain name (optional) | a friendly URL instead of the raw ALB name |

**For Stage 4, additionally:** `kubectl`, `eksctl`, `helm`.

---

## Versions this was written against

| Component | Version | Note |
|---|---|---|
| **Apache NiFi** | **2.10.0** (June 2026) | Only the latest NiFi release gets fixes. |
| Java (inside the image) | 21 | NiFi 2.x requires Java 21. |
| Docker image | `apache/nifi:2.10.0` | pulled through Artifactory |
| ZooKeeper | 3.9 | cluster coordination |
| Terraform | ≥ 1.6, AWS provider ~> 5.60 | |
| EKS | 1.31 | |

> ### ⚠️ Two version facts that matter more than the rest
>
> **1. NiFi 1.x is end of life.** `1.28.1` was the final release and support ended in **December 2024**. Every fix and feature now lands only on 2.x. If you are on 1.x, Chapter 6 is the most important chapter here.
>
> **2. Do not run NiFi 2.7.2 or earlier.** **CVE-2026-25903** is a high-severity flaw affecting **1.1.0 through 2.7.2** that lets a lower-privileged user bypass authorization on restricted components. The fix requires **2.8.0 or later**. The Terraform in this repo refuses to plan with an affected version, on purpose.

---

# Chapter 1. What NiFi is, and why anyone uses it

## 1.1 The problem

You have data in one place and you need it somewhere else. Files land on an SFTP server and must end up in S3. Messages arrive on Kafka and must be filtered, reshaped and written to a database. A vendor drops CSVs hourly and someone has to validate them, split the bad rows off, and load the rest.

The obvious answer is a script. And for one job, a script is right.

Then it multiplies. You have forty of these. And every one of them needs the same boring machinery around it:

- **Retries.** The network failed. Try again — but not forever, and not instantly.
- **Back-pressure.** The destination is slower than the source. Something must slow down instead of filling memory until it dies.
- **Ordering and batching.** Some things must go in order. Some are far cheaper in batches of 1000.
- **Credentials.** Rotated, not in the source code.
- **Observability.** Which file failed? What did it contain? When? *Where exactly did record 4,812 come from?*
- **Restart safety.** The process was killed halfway. Nothing may be lost, and nothing may be processed twice.

Writing that once is a week. Writing it forty times, consistently, and keeping it working, is a team.

## 1.2 What NiFi actually is

**NiFi is a tool for building data pipelines by dragging boxes onto a canvas and connecting them with arrows.** Each box is a *processor* that does one thing — fetch a file, parse JSON, route on a value, write to S3. Each arrow is a *queue* between them.

The machinery from §1.1 comes with the boxes. Retries, back-pressure, batching, credential handling and a complete audit trail are properties of the framework, not code you write.

> ### 🧠 Background: where it came from
>
> NiFi was built inside the **NSA**, under the name *Niagarafiles*, and released to the Apache Software Foundation in 2014. That origin explains its personality: it is obsessive about **provenance** — being able to prove, for any individual piece of data, exactly where it came from, everything that happened to it, and what it looked like at each step.
>
> Most data tools treat that as a logging feature. In NiFi it is a first-class subsystem with its own repository on disk, and it is the main reason people choose NiFi over lighter alternatives.

## 1.3 The four words you need

| Word | What it means |
|---|---|
| **FlowFile** | One piece of data moving through the system, plus its metadata. Think of an envelope: **attributes** are what is written on the outside (filename, size, whatever tags you add), and **content** is what is inside. |
| **Processor** | A box that does one job to FlowFiles. NiFi ships with hundreds. |
| **Connection** | An arrow between processors. It is a real queue with a real size limit. |
| **Process Group** | A folder holding part of a flow, so a large flow stays readable. |

A flow is then: FlowFiles move along Connections between Processors, organised into Process Groups.

## 1.4 Honest pros and cons

**Where NiFi wins**

| | |
|---|---|
| **Provenance** | You can pick any record and see its complete history, including the actual bytes at each stage. Very few tools can do this. In a regulated environment it is often the deciding factor. |
| **No code for the common 80%** | Move, filter, reshape, route, enrich — all configuration. |
| **Back-pressure is built in** | Queues have limits. When one fills, the upstream processor stops. Nothing silently eats all your memory. |
| **Restart safety** | Work in progress is written to disk continuously. Kill the process mid-flight and it resumes. |
| **Operator-facing** | You can start, stop, and re-route a live pipeline from a browser, and watch queue depths change. |
| **Very broad connectivity** | S3, Kafka, JDBC, SFTP, HTTP, JMS, Azure, GCP, Elastic, and more. |

**Where NiFi hurts**

| | |
|---|---|
| **It is genuinely stateful** | This is the big one, and Chapter 2 is entirely about it. It changes how you do high availability, upgrades and backups. |
| **Heavy for small jobs** | A JVM, several repositories and a web UI to move one file a day is silly. Use a Lambda. |
| **Version control is awkward** | The flow is one compressed blob. Diffing and code review need NiFi Registry or Git integration, deliberately set up. |
| **Clicking does not scale to hundreds of flows** | Past a point you want templated, generated flows — and NiFi is not naturally built for that. |
| **The 1.x → 2.x upgrade is real work** | Templates and Variables were removed outright. Chapter 6. |
| **Easy to build something unmaintainable** | A canvas with 300 processors and no grouping is a swamp, and nothing stops you making one. |

## 1.5 NiFi versus the alternatives

| | NiFi | Airflow | Airbyte / Fivetran | Lambda + Step Functions |
|---|---|---|---|---|
| Shape of problem | continuous flow, record-level | scheduled batch, task ordering | source → warehouse replication | small event-driven jobs |
| Provenance | **excellent, per record** | task-level logs | limited | CloudWatch, per invocation |
| You write code | rarely | Python, always | no | yes |
| Streaming | yes | not really | mostly batch | yes |
| Operational weight | high | medium | low (hosted) | very low |
| Best when | traceability and routing logic matter | complex dependency graphs | standard warehouse loads | glue between AWS services |

**A fair summary:** if your problem is "replicate Postgres into Snowflake on a schedule", NiFi is the wrong tool and a managed connector will be cheaper and faster. If your problem is "ingest from twelve unreliable sources, validate and route by content, and be able to prove to an auditor what happened to any individual record", NiFi is exactly the right tool.

---

### 📝 Quiz — Chapter 1

**1.** Explain the difference between a FlowFile's *attributes* and its *content*, using the envelope comparison.

**2.** Name three pieces of "boring machinery" that NiFi gives you for free and that you would otherwise write yourself in every script.

**3.** A colleague wants to use NiFi to copy one small file from S3 to S3 once a day. Give a reasoned argument for a simpler tool.

**4.** What is provenance, and why is it the deciding factor for some organisations?

**5.** True or false: because you build flows by dragging boxes, NiFi flows are easy to code-review in a pull request. Explain.

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---

# Chapter 2. The five repositories, and why NiFi is not stateless

**This is the most important chapter in the guide.** Nearly every bad NiFi architecture comes from skipping it. If you read nothing else, read this.

## 2.1 The thing people assume

Most modern web applications are **stateless**. The app holds nothing important; all the durable data is in a database. That property is wonderful, because it means any instance is interchangeable. You can kill one, launch a fresh one, and nobody notices. Auto Scaling Groups, rolling deploys and "cattle not pets" all depend on it.

People assume NiFi works like that. It does not.

## 2.2 What NiFi keeps on local disk

```
   /opt/nifi/nifi-current/
   │
   ├── conf/                     ← YOUR FLOW LIVES HERE (flow.json.gz)
   │                               plus nifi.properties, authorizers.xml
   │
   ├── flowfile_repository/      ← metadata for every in-flight FlowFile
   │                               a write-ahead log; the "who is where" index
   │
   ├── content_repository/       ← THE ACTUAL BYTES of in-flight data
   │                               this is where your unprocessed data IS
   │
   ├── provenance_repository/    ← the audit trail. Often the biggest.
   │
   ├── database_repository/       ← component state (e.g. "last file I listed")
   │
   ├── state/                     ← local component state
   │
   └── logs/                      ← nifi-app.log and friends
```

Five of those hold live state, and losing each one loses something different:

| Directory | Lose it and… |
|---|---|
| `conf/` | your **flow design** is gone — every processor, every setting |
| `flowfile_repository/` | NiFi no longer knows what data it was holding |
| `content_repository/` | **the in-flight data itself is gone** |
| `provenance_repository/` | the audit trail is gone (the flow still works) |
| `database_repository/`, `state/` | components forget where they got to, so they may re-read or skip |

## 2.3 The consequence that changes your architecture

Read this slowly, because it is the whole point:

> **If a NiFi node dies and you replace it with a fresh instance, the data that was mid-journey on that node is gone.**

Not delayed. Gone — or, at best, stranded on an orphaned disk.

And here is the part that surprises people who know other clustered systems:

> **NiFi clustering does not rescue that data.**

A NiFi cluster gives you three things: every node runs the same flow, work is spread across nodes, and you can use the UI from any node. It does **not** replicate in-flight data between nodes. There is no quorum of copies. Each node's content repository is its own.

NiFi has an **offload** operation that moves a node's queued data to its peers — but *offloading requires the node to be alive*. It is a graceful maintenance operation, not a recovery mechanism. A node that has actually died cannot offload anything.

> ### ⚠️ Gotcha: this is why an Auto Scaling Group is dangerous for NiFi
>
> An ASG's entire job is: notice an unhealthy instance, **terminate it**, launch a fresh replacement. For a stateless app that is perfect.
>
> For NiFi that sequence is: notice a struggling node, **destroy the disk holding real customer data**, and start an empty one. The ASG will do this cheerfully, repeatedly, and report success.
>
> This is why the CLI scripts in this repo create **discrete EC2 instances with persistent EBS volumes** (`DeleteOnTermination=false`) rather than an ASG, and why the EKS version uses a **StatefulSet** whose disks follow their pods. Chapter 7 covers when an ASG *is* acceptable.

## 2.4 So how do you get fault tolerance?

Three strategies. Real systems use more than one.

**Strategy 1 — Make the disk outlive the instance.**

Put the repositories on a separate EBS volume that is not deleted when the instance is. Replace the instance, re-attach the volume, and NiFi picks up its in-flight data where it left off. This is what `cli/06-nifi-nodes.sh` does. On Kubernetes, a StatefulSet's PersistentVolumeClaim does it automatically and more cleanly — which is the strongest technical argument for EKS.

**Strategy 2 — Make the source replayable.** *(the best one)*

Design flows so losing in-flight data is survivable, because the source can be read again:

- Consuming from Kafka? Only commit the offset **after** the data is safely delivered. Lose a node and the next node re-reads from the last committed offset.
- Reading from SQS? Delete the message only after success. Unacknowledged messages reappear.
- Listing S3 or SFTP? Keep the "already processed" marker durable, and design the destination write to be **idempotent** so a repeat is harmless.

A flow built this way tolerates total node loss without losing a record. **This is worth more than any amount of infrastructure cleverness**, and it is the difference between a NiFi deployment that survives an incident and one that turns into a data-recovery exercise.

**Strategy 3 — Cluster for availability of the service.**

Three nodes means one can die and the pipeline keeps running on the other two. New data flows fine. Only the data that was on the dead node is affected. Combined with Strategy 1 or 2, that is genuine fault tolerance.

## 2.5 Sizing the disks

| Repository | Size guidance | Notes |
|---|---|---|
| `content_repository` | **the big one.** Peak in-flight bytes × safety factor | Fills up when a destination is down and queues back up. Run out of space and NiFi stops. |
| `provenance_repository` | often as big as content | Bounded by config, not by luck — set `nifi.provenance.repository.max.storage.size`. |
| `flowfile_repository` | small, but **write-heavy** | Latency-sensitive. Put it somewhere fast. |
| `conf`, `state`, `database` | small | |

> ### ✅ Best practice: separate volumes, not one big one
> The single biggest NiFi performance win is giving `content_repository` and `provenance_repository` their **own** volumes. Otherwise provenance writes and content reads fight over the same IOPS, and throughput collapses under load for no visible reason.
>
> The EKS manifests in this repo do this — seven separate PersistentVolumeClaims. The EC2 version uses one volume for simplicity; splitting it is the first upgrade to make.

## 2.6 What this means for backups

A backup of NiFi is **two separate things**, and most people only take one:

1. **The flow design** — portable JSON, exported through the API. Survives version changes. Chapter 5.
2. **The disks** — EBS snapshots. The only way to recover in-flight data.

Plus one thing that is neither, and that people lose:

3. **`nifi.sensitive.props.key`** — the key that encrypts passwords *inside* your flow. Without it, an exported flow is half a backup: the structure comes back and every credential is unreadable.

---

### 📝 Quiz — Chapter 2

**1.** Name the five directories that hold live state, and say what is lost if each one disappears.

**2.** A node in a 3-node NiFi cluster dies with 40,000 FlowFiles queued on it. Do the other two nodes take over that data? Explain.

**3.** Why is "offload the node" not a recovery mechanism?

**4.** Explain in your own words why an Auto Scaling Group that replaces unhealthy instances is risky for NiFi but ideal for a stateless web app.

**5.** Of the three fault-tolerance strategies, which one does the guide call the most valuable, and why?

**6.** You have one 500 GB volume for all repositories and throughput is poor under load. What is the first change to make, and why does it help?

**7.** You have exported every flow as JSON and stored it safely. Name the one additional item without which that export is only half a backup.

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---

# Chapter 3. Step one: NiFi on your Mac

Following the principle that one worked example beats any amount of theory. Ten minutes, no AWS account, no cost.

## 3.1 Start it

```bash
cd local-mac
./run.sh
```

That script checks Docker is running, warns you if Docker has under 4 GB of memory, detects Apple Silicon, creates the data directories, starts the container and then **waits until NiFi actually answers** — not merely until the container starts, which are very different moments with NiFi.

Expect 60–120 seconds on the first run, plus an image pull of about 1.5 GB.

When it finishes:

```
  URL        https://localhost:8443/nifi
  Username   admin
  Password   ChangeThisLocally123
```

> ### ⚠️ Gotcha: your browser will refuse the certificate
>
> NiFi generates its own self-signed certificate on first start, so Safari or Chrome shows a full-page security warning. That is expected here. Click through it (**Advanced → Proceed**).
>
> Two things follow from this. NiFi 2.x is **HTTPS-only** — there is no plain-HTTP mode to fall back to. And you should never click through such a warning against a real server, which is why Chapter 9 puts a proper ACM certificate on the load balancer.

## 3.2 The four things that go wrong

| Symptom | Cause | Fix |
|---|---|---|
| Container restarts in a loop | **password under 12 characters** — NiFi refuses to start and says so quietly in the boot log | use a longer one |
| `port is already allocated` | something else has 8443 | `lsof -i :8443`, or change the port mapping |
| Very slow, or dies during startup | Docker has too little memory | Docker Desktop → Settings → Resources → **4 GB or more** |
| Extremely slow on an M-series Mac | image is being emulated | `./run.sh` warns you; add `platform: linux/amd64` to be explicit |

Read the log when in doubt:

```bash
./logs.sh          # nifi-app.log — what the flow is doing
./logs.sh boot     # nifi-bootstrap.log — startup and JVM problems
```

## 3.3 Build a flow, in six clicks

Nothing teaches the model faster than making data move.

1. **Drag the processor icon** (top-left toolbar) onto the canvas. Search `GenerateFlowFile`. Add it.
2. **Double-click it → Scheduling.** Set *Run Schedule* to `5 sec`. Without this it runs as fast as it can and floods your queue instantly.
3. **Properties tab.** Set *Custom Text* to `hello from nifi` and *File Size* to `1 KB`.
4. **Add a second processor:** `LogAttribute`. This writes what it receives to `nifi-app.log`.
5. **Hover the edge of GenerateFlowFile** until a circle-arrow appears. Drag it to LogAttribute. In the dialog, tick the `success` relationship. Click Add.
6. **LogAttribute needs its own outlet.** Double-click it → *Settings* → under *Automatically Terminate Relationships*, tick `success`. This tells NiFi "data that reaches here is finished". Skip it and the processor shows a warning triangle and refuses to start.

Now select both (drag a box around them) and press the **▶ Start** button.

Watch the connection between them. The number goes up, then down as LogAttribute consumes. In another terminal:

```bash
./logs.sh
```

You will see your attributes printed every five seconds. **That is a working data pipeline.**

## 3.4 Feel back-pressure, deliberately

This is the single most useful five minutes you can spend learning NiFi.

1. **Stop** LogAttribute only. Leave GenerateFlowFile running.
2. Watch the queue between them climb: 10, 20, 50…
3. Right-click the connection → **Configure**. Note *Back Pressure Object Threshold* — 10,000 by default.
4. Set it to `20` and Apply.
5. Wait. When the queue hits 20, look at GenerateFlowFile: it **stops running**, and the connection turns a different colour.

Nothing crashed. Nothing filled memory. The upstream processor simply stopped because the downstream one could not keep up. **That is back-pressure**, and it is why NiFi survives a destination going down for an hour where a naive script would fall over.

Restart LogAttribute and watch the queue drain and GenerateFlowFile resume by itself.

## 3.5 Look inside the data

Right-click the queue → **List queue** → the ℹ️ icon on any row → **View** (or Download).

You are looking at the actual bytes of one FlowFile, mid-flight. Now click **Provenance** on the same row.

You get the full history of that single piece of data: it was CREATED by GenerateFlowFile at a timestamp, ROUTED down a connection, and so on. Click any event and you can see the content *at that point*, and the attributes before and after.

> ### 🧠 Background: why this is a big deal
>
> Every pipeline breaks eventually, and the question is always "what happened to *this specific record*?" In most systems the honest answer is "read the logs and guess". NiFi records the answer as data, per FlowFile, with the content attached. That is what people mean when they say NiFi has provenance.
>
> It is not free: the provenance repository is often the largest thing on disk. Chapter 13 covers keeping it bounded.

## 3.6 Try a real cluster locally

Once the single node makes sense:

```bash
docker compose -f docker-compose.cluster.yml up -d
```

Three NiFi nodes plus ZooKeeper. **This wants about 8 GB of RAM** — check Docker's memory limit first or nodes will die confusingly.

Open `https://localhost:8443/nifi`, then the **hamburger menu → Cluster**. You should see three nodes, all `CONNECTED`, with exactly one marked **Primary** and one **Coordinator**.

Things worth doing while it is up:

- Build a flow on one node. Open `https://localhost:8444/nifi` (node 2) and see the **same flow** — the flow is cluster-wide.
- `docker stop nifi-2`, then look at the Cluster view. The node goes to `DISCONNECTED`, and the other two carry on.
- `docker start nifi-2` and watch it rejoin.

> ### ⚠️ Gotcha: what makes cluster nodes fail to join
>
> Almost always one of three things, and the error messages are unhelpful for all of them:
>
> 1. **The sensitive props key differs between nodes.** They cannot read each other's flow and refuse to join. In the compose file every node gets the identical `NIFI_SENSITIVE_PROPS_KEY` on purpose.
> 2. **`NIFI_CLUSTER_ADDRESS` is not resolvable by the other nodes.** Each node advertises an address; if the others cannot resolve it, they sit at `Connecting` forever.
> 3. **Port 11443 is blocked.** That is the cluster protocol port.
>
> All three reappear on AWS in Chapter 9, in exactly the same order.

Clean up:

```bash
docker compose -f docker-compose.cluster.yml down -v
```

---

### 📝 Quiz — Chapter 3

**1.** Your NiFi container restarts in a loop. What is the first thing to check, and why does it produce that specific symptom?

**2.** You add `LogAttribute` and it shows a warning triangle and will not start. What is missing and what does it mean conceptually?

**3.** Describe what you see when back-pressure engages, and explain why this is better than the alternative.

**4.** Why does your browser warn about the certificate on `https://localhost:8443`, and why is there no plain-HTTP option?

**5.** In the local cluster, you build a flow on node 1 and open node 2. What do you see, and what does that tell you about where the flow lives?

**6.** Name the three usual reasons a node sits at `Connecting` and never joins.

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---
# Chapter 4. Debugging and logging flows

Put this before AWS on purpose: learn to debug on your laptop, where you can break things freely, and the same skills apply in production.

## 4.1 The five logs, and what each answers

NiFi writes several logs and they answer genuinely different questions. Reaching for the wrong one wastes a lot of time.

| Log | Answers | Read it when |
|---|---|---|
| **`nifi-app.log`** | what the flow is doing; processor errors and stack traces | almost always start here |
| **`nifi-user.log`** | who logged in, who was refused, which policy blocked them | permission problems |
| **`nifi-bootstrap.log`** | JVM startup, out-of-memory, "why won't it start" | NiFi never comes up |
| **`nifi-request.log`** | every HTTP request to the UI/API | UI misbehaving, proxy problems |
| **`nifi-deprecation.log`** | components you use that are going away | **before any upgrade — Chapter 6** |

```bash
./logs.sh          # app
./logs.sh user
./logs.sh boot
./logs.sh req
./logs.sh dep      # the one nobody knows about
```

That last one deserves attention. NiFi 1.x writes a dedicated log naming every deprecated component **your flows actually use**. It is the authoritative pre-upgrade checklist and it is sitting on disk already.

## 4.2 The four tools inside the UI

Logs are the last resort. NiFi's own instrumentation is usually faster.

**1. The bulletin board.** Errors surface as red squares on the processor and in **hamburger menu → Bulletin Board**. Hover a bulletin for the message. This is where "connection refused" and "invalid credentials" appear, immediately, without opening a log.

**2. Queue depth as a diagnostic.** A queue that only grows tells you where the bottleneck is, precisely. Walk downstream from the first growing queue and you find the slow or stopped processor. This is the fastest debugging tool NiFi has and it is just... looking at the canvas.

**3. List queue + View content.** Right-click a queue → List queue → ℹ️ → View. You see the actual bytes and every attribute. "The data isn't what I expected" becomes a five-second check rather than a theory.

**4. Data provenance.** Right-click a processor → **View data provenance**. Filter by time, type or component. Click an event to see content before and after, plus the full lineage graph.

> ### ✅ Best practice: replay, don't rebuild
> In a provenance event, the **Replay** button re-injects that exact FlowFile back into the flow at that point.
>
> This is enormously useful and underused. Instead of reproducing a bug by finding the original source file, you replay the failing FlowFile against your fixed processor, as many times as you like, with identical input.

## 4.3 Turning up the detail

`LogAttribute` is your `print()` statement. Drop it anywhere, route a copy of the data to it, and set *Log Level* to `info`. Instant visibility with no restart.

For framework-level detail, edit `conf/logback.xml`:

```xml
<!-- One specific processor, at DEBUG -->
<logger name="org.apache.nifi.processors.standard.InvokeHTTP" level="DEBUG"/>

<!-- Cluster and election problems -->
<logger name="org.apache.nifi.controller.cluster" level="DEBUG"/>

<!-- Who is being denied what -->
<logger name="org.apache.nifi.web.security" level="DEBUG"/>
```

NiFi reloads `logback.xml` automatically within about 30 seconds — **no restart needed**, which matters when you are debugging a production node.

> ### ⚠️ Gotcha: root DEBUG will hurt you
> Setting the root logger to `DEBUG` on a busy NiFi generates gigabytes per hour, fills the disk that your content repository shares, and can take the node down. Name the specific logger you need.

## 4.4 Common flow failures and what they mean

| Symptom | Usual cause |
|---|---|
| Processor shows a **warning triangle**, will not start | an unterminated relationship, or a required property empty |
| Queue grows forever | downstream stopped, or too slow — walk downstream |
| Data arrives but is empty | wrong relationship wired (`original` vs `success`), so you kept the wrong copy |
| Processor runs but produces nothing | Run Schedule is long, or the source genuinely has nothing |
| `PermissionDeniedException` in the log | a processor's credential, not your login. Check the controller service. |
| Everything grinds to a halt, no errors | **check disk free.** A full content repository stops NiFi. `df -h` |
| Random slow-down under load | provenance and content competing for IOPS (Chapter 2 §2.5) |

> ### ⚠️ Gotcha: the disk-full failure looks like a bug
> When the content repository fills, NiFi stops accepting new data and the UI becomes sluggish, often with nothing obvious in `nifi-app.log`. It looks like a mysterious hang.
>
> `df -h` is always worth running early. In AWS, the CloudWatch agent config in this repo reports `used_percent` on `/data` as a metric — **alarm on it at 75%**, which is Chapter 13.

---

### 📝 Quiz — Chapter 4

**1.** Match the log to the question: a user cannot log in; NiFi will not start at all; a processor throws an exception mid-flow.

**2.** What is `nifi-deprecation.log` for, and at what point in a project is it most valuable?

**3.** You have a queue of 200,000 FlowFiles that only grows. Describe your diagnostic procedure.

**4.** What does the provenance **Replay** button do, and why is it better than reproducing a bug from the original source?

**5.** Why should you never set the root logger to DEBUG on a busy NiFi node?

**6.** NiFi becomes very slow and stops accepting data, with nothing useful in the log. What do you check first?

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---

# Chapter 5. Getting everything out: exports, backups, transition

You need this before you migrate, before you upgrade, and before you destroy anything. It is also the answer to "how do we move from the old cluster to the new one".

## 5.1 The problem with how NiFi stores your flow

Your entire flow design lives in one file: `conf/flow.json.gz`. A single gzipped blob.

That is fine for NiFi and terrible for you:

- Not human-readable, so **not reviewable**.
- Not diffable, so you cannot see what changed between Tuesday and Friday.
- Tied to the version that wrote it — bundle coordinates and component definitions move between releases.
- All-or-nothing: you cannot take *one* pipeline from it.

What **is** portable is a **flow definition**: the JSON you get from *Download flow definition* on a process group. That is the unit that moves between instances and between versions.

## 5.2 Export everything, with one command

```bash
cd migration
NIFI_URL=https://localhost:8443 \
NIFI_USER=admin \
NIFI_PASSWORD=ChangeThisLocally123 \
  ./export-everything.sh
```

It walks the whole process-group tree and writes:

```
exports/2026-07-26_143000/
├── flows/                        one portable JSON per process group
├── config/
│   ├── parameter-contexts.json         the things people forget
│   ├── controller-services-root.json
│   ├── reporting-tasks.json
│   ├── registry-clients.json
│   ├── parameter-providers.json
│   └── nifi.properties                 (local runs only)
├── metadata/
│   ├── system-diagnostics.json         version, heap, disk
│   ├── cluster.json                    who was in the cluster
│   └── templates-list.json             1.x only
├── templates-legacy/             1.x only — must be converted, Chapter 6
└── MANIFEST.md                   what this is and how to restore it
```

The `config/` folder is the part that saves you. People export flows, migrate, and then spend a day rediscovering that their **controller services** (database connection pools, SSL contexts) and **parameter contexts** were never captured.

> ### 🧠 Background: how the script finds the right endpoint
>
> The URL for downloading a flow definition has moved between NiFi versions. Rather than guess, the script **probes** the known candidates and reports which one worked.
>
> That technique generalises. **Everything the NiFi UI does, it does through the same REST API.** If you cannot work out which endpoint to call, open the UI, press F12, go to the Network tab, do the thing by hand, and read the request. That single habit makes NiFi fully automatable.

## 5.3 What the export cannot contain

Be clear-eyed about the limits:

| Not included | Why | What to do |
|---|---|---|
| **In-flight data** | it is on disk in the content repository | EBS snapshot (`cli/backup.sh`) |
| **Decrypted passwords** | encrypted with the sensitive props key | keep the key |
| Provenance history | its own repository, very large | snapshot, or accept losing it |
| Users and policies (file-based) | `users.xml`, `authorizations.xml` | copy them from `conf/` |
| Custom NARs | JAR files you installed | keep them in source control |

> ### ⚠️ Gotcha: the sensitive properties key IS the backup
>
> This is the single most expensive mistake in NiFi operations, so it gets said three times in this guide.
>
> An exported flow definition contains sensitive values **encrypted** with `nifi.sensitive.props.key`. Import it into an instance with a different key and the flow arrives structurally perfect with every password blank or unreadable — and **NiFi does not loudly tell you this happened**. You find out when a processor fails to connect.
>
> Save the key separately, in a password manager, before you need it:
>
> ```bash
> aws secretsmanager get-secret-value \
>   --secret-id nifi-demo/sensitive-props-key \
>   --query SecretString --output text
> ```

## 5.4 Importing into a new instance

```bash
NIFI_URL=https://new-nifi.example.com \
NIFI_USER=admin NIFI_PASSWORD='...' \
  ./import-flows.sh exports/2026-07-26_143000 --dry-run   # check first
  ./import-flows.sh exports/2026-07-26_143000
```

The script checks every file parses before uploading anything, warns you about files containing encrypted values, and lays the imported groups out in a grid.

**Imported flows arrive stopped.** That is deliberate — nothing touches data until you have looked at it. Before starting anything:

1. **Fix ghost components.** A processor that no longer exists in this version appears greyed out. Replace it.
2. **Re-point controller services.** They are referenced by id; recreate and rebind.
3. **Check parameter contexts.** If the source used 1.x Variables, they did not come across — they no longer exist.
4. **Retype blank sensitive properties.**
5. **Start ONE group** and watch its queues before doing the rest.

## 5.5 The better long-term answer: NiFi Registry or Git

Exporting by script is a migration tool. For ongoing work, put flows under **version control**:

- **NiFi Registry** — a companion service. Right-click a process group → *Start version control*. You get commit history, diffs, and one-click rollback.
- **Git-based Flow Registry Client** — newer NiFi versions can commit flow definitions straight to a Git repository, which means your flows sit in the same review process as your code.

> ### ✅ Best practice
> Set up version control **before** you have thirty flows, not after. Retrofitting it means someone hand-importing thirty process groups, and the temptation to skip it is what produces clusters nobody dares upgrade.

---

### 📝 Quiz — Chapter 5

**1.** Why is `flow.json.gz` a poor unit of exchange, and what is the portable alternative?

**2.** Name three things in the `config/` export folder that people commonly forget, and what breaks without each.

**3.** You import a flow definition into a new cluster with a freshly generated sensitive props key. Everything looks correct. What is silently broken and when will you find out?

**4.** Give the general technique for discovering which REST endpoint performs a given NiFi UI action.

**5.** List four things a flow export does **not** contain.

**6.** Why do imported flows arrive stopped rather than running?

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---

# Chapter 6. Loading flows from older NiFi versions

The hard chapter, and in 2026 the one most people need. NiFi 1.x is end of life; 2.x is where everything happens. The jump is not a drop-in replacement.

## 6.1 What actually changed

| Removed or changed in 2.x | Impact | Replacement |
|---|---|---|
| **XML templates** | **gone entirely** | flow definitions (JSON) / Registry |
| **Variables / Variable Registry** | **gone entirely** | Parameter Contexts |
| `ExpressionLanguageScope.VARIABLE_REGISTRY` | gone | `ENVIRONMENT` scope, or parameters |
| **Java 8/11/17** | unsupported | **Java 21 required** |
| Event Driven scheduling | removed | Time Driven |
| Scripting in ECMAScript, Lua, Ruby, Jython | removed | Groovy, or the new **native Python** processor API |
| Many deprecated processors | deleted → "ghost components" | per-component alternatives |
| Relocated bundles (Jolt, Kafka, Hive) | bundle coordinates changed | update coordinates in the flow |
| Custom NARs built against 1.x API | will not load | rebuild against 2.x on Java 21 |

Two of those are the ones that cause real pain: **templates** and **variables**. Both were widely used and neither converts automatically.

## 6.2 The rule everybody breaks

> **Upgrade to NiFi 1.27.0 or later first. Then go to 2.x.**

Jumping from, say, 1.16 straight to 2.10 is not a supported path. The 1.27/1.28 releases contain the migration groundwork that makes the 2.x flow upgrade work. Skipping the bridge produces flows that fail to load with errors that are very hard to interpret.

So the real sequence is: **old 1.x → 1.28.1 → 2.10.0**.

## 6.3 Step 1: audit, before you build anything

```bash
cd migration
NIFI_URL=https://old-nifi.example.com NIFI_USER=admin NIFI_PASSWORD='...' \
  ./audit-for-nifi2.sh
```

It reports templates, variables, and where to look for the rest. Then get the flow file itself and audit that too — it is far more thorough:

```bash
# from the old instance
docker cp old-nifi:/opt/nifi/nifi-current/conf/flow.xml.gz .
./audit-for-nifi2.sh --flow flow.xml.gz
```

That pass scans for removed processors, `EVENT_DRIVEN` scheduling, removed scripting languages and `VARIABLE_REGISTRY` references.

**And read the log NiFi already wrote for you:**

```bash
docker exec old-nifi tail -200 /opt/nifi/nifi-current/logs/nifi-deprecation.log
```

That file lists the deprecated components *your* flows actually use. It is more authoritative than any generic checklist, including the one in this guide.

## 6.4 Step 2: convert templates — while still on 1.x

**Do this before you upgrade anything.** Templates cannot be converted on 2.x, because 2.x has no concept of a template.

For each template, in the old instance:

1. Drag the template onto the canvas. It becomes a normal process group.
2. Right-click that group → **Download flow definition**.
3. Save the JSON. **That** is what imports into 2.x.

Or via the API, for many at once:

```bash
./export-everything.sh    # downloads templates AND flow definitions
```

> ### ⚠️ Gotcha: a template downloaded as XML is useless to 2.x
> `export-everything.sh` saves any templates it finds into `templates-legacy/` so you do not lose them — but those XML files **cannot be imported into NiFi 2.x**. They exist only so you can drag each one onto a 1.x canvas and re-download it as JSON. If your old cluster is already gone and all you have is template XML, you need a 1.x instance to do the conversion.

## 6.5 Step 3: convert variables to parameter contexts

Variables were referenced as `${my_var}`. Parameters are referenced as `#{my_param}`. **The syntax is different, so every reference has to change.**

Work through it:

1. List the variables. In 1.x: right-click the canvas → **Variables**, per process group. Note names, values and which are sensitive.
2. In the new 2.x instance: **hamburger → Parameter Contexts → Create**. Add each as a parameter. Tick *Sensitive* for anything secret — something variables could never do, which is one reason they were removed.
3. Assign the context to the relevant process group (group Configuration → *Process Group Parameter Context*).
4. Change every `${my_var}` to `#{my_param}`.

Step 4 is the tedious one. Use the search box (top-right) for each variable name to find every reference.

> ### ✅ Best practice: this is an opportunity, not just a chore
> Variables could not hold secrets, so people put database passwords in processor properties or in files on disk. Parameter contexts support **sensitive parameters**. While you are rewriting every reference anyway, move those credentials into sensitive parameters properly.

## 6.6 Step 4: deal with removed processors

Common swaps:

| Old (1.x) | New (2.x) | Note |
|---|---|---|
| `GetHTTP`, `PostHTTP` | `InvokeHTTP` | needs no SSL Context Service for public HTTPS; different timeout defaults; set *Response FlowFile Naming Strategy* to `URL_PATH` if you relied on the filename |
| `GetFTP`, `GetSFTP` | `ListFTP` + `FetchFTP` | the list/fetch split is better for clustering: list on primary node, fetch on all |
| `ConsumeKafka_2_0` etc. | `ConsumeKafka` | version-suffixed processors consolidated |
| `GetAzureQueueStorage` | `GetAzureQueueStorage_v12` | |
| `JoltTransformJSON` | same name, **different bundle** | coordinates changed; may need editing in the flow |
| Jython / Lua / Ruby scripts | Groovy, or native Python processors | 2.x can run real Python processors |

A processor that no longer exists becomes a **ghost component**: it appears on the canvas greyed out, cannot be started, and blocks the group from running. NiFi does not silently drop it, which is good — you get a visible, fixable problem.

## 6.7 Step 5: the migration itself

The safest approach is **parallel deployment**, not in-place upgrade:

```
  1. Old 1.x cluster keeps running, untouched, serving production.
  2. Build a NEW 2.10 cluster alongside it (Chapter 9 or 11).
     -> Set nifi.sensitive.props.key to the OLD cluster's key.
  3. Import converted flow definitions into the new cluster. All stopped.
  4. Fix ghosts, rebind controller services, create parameter contexts.
  5. Point the new cluster at a TEST source. Verify record by record.
  6. Cut over one pipeline at a time:
       - stop the source processor on OLD
       - let its queues drain to empty
       - start the equivalent on NEW
       - watch both for an hour
  7. When every pipeline has moved and old queues are empty, decommission old.
```

Why parallel wins: at every step you can stop and go back. An in-place upgrade has a point of no return in the middle of it.

> ### ⚠️ Gotcha: set the sensitive key BEFORE the first import
>
> Step 2's parenthetical is the whole migration. Build the new cluster with the **old** key:
>
> ```bash
> export TF_VAR_nifi_sensitive_props_key='<the old cluster key>'
> terraform apply
> ```
>
> Import first and fix it later and you will be retyping every credential in every flow by hand.

## 6.8 Draining queues properly

Step 6 says "let its queues drain". Getting that right matters:

1. Stop only the **source** processors (the ones that bring new data in). Leave everything downstream running.
2. Watch queue counts fall to zero. Use the group's status bar, not guesswork.
3. If a queue will not drain, something downstream is broken or back-pressured — fix that before cutting over.
4. Only then stop the rest of the group.

Stopping the whole group at once instead leaves data sitting in queues, and that data is in the content repository of the *old* cluster, which you are about to decommission.

---

### 📝 Quiz — Chapter 6

**1.** State the required version path from NiFi 1.16 to 2.10, and why the intermediate step exists.

**2.** Why must XML templates be converted while you are still on 1.x? What are you left with if the old cluster is gone?

**3.** Variables became Parameter Contexts. Give the syntax change, and one capability parameters have that variables never did.

**4.** What is a "ghost component", and why is it arguably good that NiFi shows one rather than dropping it?

**5.** Give the single most authoritative source for which deprecated components *your* flows use.

**6.** Explain why parallel deployment is safer than an in-place upgrade.

**7.** In the cutover, you stop the source processors and wait. Why not just stop the whole process group at once?

**8.** You built the new cluster, imported everything, and now discover the sensitive props key was freshly generated. What is the consequence and could it have been avoided?

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---
# Chapter 7. The AWS architecture, and what fault tolerance really means here

## 7.1 The picture

```
                            you
                             │  HTTPS 443
                    ┌────────▼─────────┐
   PUBLIC SUBNETS   │  Application     │   ACM certificate
   (2 AZs)          │  Load Balancer   │   sticky sessions ON
                    └────┬────────┬────┘
                         │ 8443   │ 8443          ┌──────────────┐
                    ┌────▼───┐ ┌──▼─────┐         │ NAT Gateway  │ (public subnet)
   PRIVATE SUBNETS  │ nifi-0 │ │ nifi-1 │  ...    │ outbound only│
   (2 AZs)          │  AZ-a  │ │  AZ-b  │         └──────┬───────┘
                    └───┬────┘ └───┬────┘                │
                        │ 11443    │  cluster protocol    │ pull image
                        └────┬─────┘                      ▼
                             │                     JFrog Artifactory
                     ┌───────▼────────┐
                     │  ZooKeeper     │   elects Coordinator + Primary Node
                     └────────────────┘

   Each NiFi node has its OWN persistent EBS volume holding all repositories.
   DeleteOnTermination = false. That is the design, not an oversight.
```

## 7.2 Why each piece is there

| Piece | What it does | Why you cannot skip it |
|---|---|---|
| **VPC** | your own private network inside AWS | everything else lives in it |
| **Public subnets** | hold the load balancer and NAT Gateway | these are the only things the internet may touch |
| **Private subnets** | hold NiFi and ZooKeeper | no inbound route from the internet at all |
| **Internet Gateway** | two-way door for the public subnets | the ALB needs to be reachable |
| **NAT Gateway** | one-way door out for private subnets | **NiFi cannot pull its image from Artifactory without it** |
| **Security groups** | per-instance firewall | the actual access control |
| **ALB** | one stable HTTPS address, health checks | nodes come and go; the address must not |
| **ZooKeeper** | elects the Cluster Coordinator and Primary Node | without it, nodes cannot agree who is in charge |
| **EBS data volumes** | hold every NiFi repository | Chapter 2 — this is where your in-flight data is |
| **Secrets Manager** | Artifactory creds, sensitive key, admin password | so no secret is ever on disk or in a template |
| **CloudWatch Logs** | `nifi-app.log` shipped off the box | a dead instance takes its logs with it otherwise |

> ### 🧠 Background: why NAT is the surprising cost
>
> A NAT Gateway is about **$32/month each**, plus a charge per GB processed. In cluster mode this repo creates one per Availability Zone (so losing an AZ does not strand the other), which is $64/month before any data moves.
>
> It exists for one job: letting instances in private subnets reach *out* — to Artifactory for the image, to CloudWatch for logs, to Secrets Manager.
>
> **Cheaper options, with honest trade-offs:** a single NAT Gateway shared by both AZs (halves the cost, becomes a shared failure point); **VPC endpoints** for the AWS services (removes NAT for those specific services, but Artifactory is external so you still need NAT unless you mirror the image into **ECR**, which can be reached by endpoint). Mirroring to ECR is genuinely the best answer for a production build — see Chapter 12.

## 7.3 What the load balancer does and does not give you

**Does:**
- One HTTPS address that stays valid as nodes change
- TLS termination with a real certificate, so no browser warnings
- Health checks — a node that stops answering stops receiving traffic
- Spreads UI/API load across nodes

**Does not:**
- Rescue data on a dead node (Chapter 2)
- Make NiFi a cluster — that is ZooKeeper's job
- Balance *data* between nodes. NiFi has its own mechanism for that: **load-balanced connections**, configured per-connection inside NiFi, on port 6342.

> ### ⚠️ Gotcha: two ALB settings NiFi absolutely requires
>
> **1. Sticky sessions must be ON.** The NiFi UI is a single-page app making many API calls. Let those calls land on different nodes and you get random logouts, half-drawn canvases, and support tickets that make no sense. The scripts set `stickiness.enabled=true` with a 24-hour cookie.
>
> **2. The ALB's DNS name must be in `nifi.web.proxy.host`.** NiFi checks the `Host` header against an allow-list and rejects anything not on it, with **"Invalid host header"**. Symptom: a blank page through the load balancer, while the node is perfectly healthy directly.
>
> This is the NiFi equivalent of every reverse-proxy hostname problem, and it is the single most common failure when putting NiFi behind an ALB. `cli/06-nifi-nodes.sh --refresh-proxy` exists purely to fix it after the ALB is created.

## 7.4 The health check, which is fiddlier than it sounds

NiFi has no dedicated unauthenticated health endpoint the way some servers do. The best available choice is:

```
protocol:  HTTPS          (NiFi speaks HTTPS only — plain HTTP fails outright)
path:      /nifi-api/access/config
matcher:   200-401
```

`/nifi-api/access/config` tells a client how to authenticate, so it normally answers without a login — exactly what a health check needs.

The `200-401` range is deliberate. If your version or configuration demands authentication even there, a `401` still proves the web server is alive and serving. Without the range, an auth challenge reads as "unhealthy", the ALB drains **every** node, and you get a 503 with three perfectly healthy NiFi nodes running behind it.

> ### ✅ Best practice: verify the health check by hand first
> ```bash
> curl -k -o /dev/null -w '%{http_code}\n' https://<node-ip>:8443/nifi-api/access/config
> ```
> Run that from a machine inside the VPC before trusting the ALB. If it returns something outside 200–401 on your version, adjust the matcher rather than guessing why targets are unhealthy.

## 7.5 Fault tolerance, spelled out honestly

Here is what each failure actually does, with the design in this repo:

| Failure | What happens | Data impact |
|---|---|---|
| **NiFi process crashes** | Docker `restart unless-stopped` restarts it. Repositories are on disk, so it resumes. | none |
| **One node's instance dies** | ALB stops routing to it. Other nodes carry on. ZooKeeper elects a new Primary if needed. | **in-flight data on that node is stuck** until the volume is re-attached |
| **You replace the instance** | New instance, re-attach the same EBS volume, NiFi finds its repositories and resumes | none, *if* you re-attach |
| **You replace it and forget the volume** | fresh empty repositories | **in-flight data lost** |
| **An entire AZ fails** | nodes in the other AZ serve everything | data on the failed AZ's nodes is stuck until the AZ returns |
| **ZooKeeper dies (single instance)** | existing cluster keeps processing, but **no elections** — you cannot add nodes and Primary-only processors may stall | none directly |
| **The ALB fails** | AWS runs it across AZs; effectively does not happen as a whole | none |
| **Disk fills** | NiFi stops accepting data. Looks like a hang. | none if you catch it |

Two honest conclusions from that table:

**The single ZooKeeper is the weakest link in this design.** It is one instance. Production wants three, in three AZs. The EKS manifests do exactly that with a 3-replica StatefulSet and a PodDisruptionBudget; the EC2 scripts deploy one, because the guide's job there is to teach the mechanism. **Do not ship the single-ZooKeeper version.**

**Everything else depends on the disk surviving.** Which is why Chapter 2 matters more than this chapter.

## 7.6 Pros and cons of the big choices

**Fixed instances vs Auto Scaling Group**

| | Fixed instances (this repo) | Auto Scaling Group |
|---|---|---|
| Replaces a dead node automatically | ❌ you do it | ✅ |
| Preserves in-flight data | ✅ volume survives | ❌ **fresh empty disk** |
| Scales on load | ❌ | ✅ |
| Right for NiFi | ✅ usually | only if flows are fully replayable |

An ASG *is* acceptable when every flow follows Strategy 2 from Chapter 2 §2.4 — sources are replayable and destinations idempotent — so losing a node's in-flight data costs a re-read, not a record. If you can honestly say that of every flow, use an ASG and enjoy the automation. Most people cannot say it of every flow.

**One big EBS volume vs several**

| | One volume | Separate per repository |
|---|---|---|
| Simplicity | ✅ | ❌ more moving parts |
| Throughput under load | ❌ provenance and content fight for IOPS | ✅ noticeably better |
| Cost | same total GB | same |

Start with one, split when throughput matters. The EKS manifests are already split.

**gp3 vs io2 for the volumes**

gp3 gives you 3,000 IOPS baseline and lets you buy more independently of size — almost always right. io2 is for genuinely extreme, sustained IOPS and costs several times more. Start gp3.

---

### 📝 Quiz — Chapter 7

**1.** Why do the NiFi nodes sit in private subnets, and what single AWS component lets them still pull their image?

**2.** Name the two ALB settings NiFi requires, and the exact symptom of getting each one wrong.

**3.** Explain why the target group health check matcher is `200-401` rather than `200`.

**4.** A node dies with data queued on it. Walk through what the ALB, ZooKeeper and the other nodes each do, and state what happens to that data.

**5.** Identify the weakest point in the EC2 architecture as shipped, and say what production should do instead.

**6.** Under what specific condition is an Auto Scaling Group a reasonable choice for NiFi?

**7.** Your ALB reports all targets unhealthy but you can `curl` a node directly and get a valid response. Give two likely causes.

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---

# Chapter 8. The simple version: one NiFi node on EC2, with the AWS CLI

Start here on AWS. One node, no load balancer, no ZooKeeper, no public endpoint. Roughly **$75–95/month**, and everything you learn transfers to the cluster.

## 8.1 Configure

```bash
cd cli
cp config.env.example config.env
```

Edit `config.env`. The five that matter:

```bash
export PROJECT="nifi-lab"
export AWS_REGION="eu-west-1"
export NODE_COUNT=1                      # <-- 1 = simple mode
export ARTIFACTORY_REGISTRY="mycompany.jfrog.io"
export MY_IP_CIDR="$(curl -s https://checkip.amazonaws.com)/32"
```

`NODE_COUNT=1` is the switch. The ZooKeeper and ALB scripts detect it and skip themselves.

## 8.2 Check before you build

```bash
./00-preflight.sh
```

This does a read-only API call per service, confirms your AZs, and validates the config — including refusing a NiFi version that is end-of-life or affected by CVE-2026-25903.

**Do not skip this.** Discovering a missing IAM permission at step six, with half the infrastructure built and billing, is a specific and avoidable misery.

## 8.3 Build it

Either all at once:

```bash
./deploy-all.sh
```

Or one step at a time, which is how you learn what each does:

```bash
./01-network.sh          # VPC, 4 subnets, IGW, NAT, route tables   (~4 min)
./02-security-groups.sh  # one group, no inbound rules at all
./03-iam.sh              # instance role: SSM + CloudWatch + 3 secrets
./04-secrets.sh          # prompts once for the Artifactory password
./05-zookeeper.sh        # skips itself: NODE_COUNT=1
./06-nifi-nodes.sh       # the instance + its persistent data volume
./07-alb.sh              # skips itself: NODE_COUNT=1
./08-verify.sh
```

Every script records what it created in `state/ids.env` and **skips work already done**. A failure at step 5 means fix and re-run step 5 — not start over.

## 8.4 What step 6 actually does

Worth reading, because it is the interesting one. The instance boots and its user-data script:

1. **Installs** Docker, jq, the CloudWatch agent.
2. **Finds the data volume** by looking for a disk with no mounted partitions.
3. **Formats it only if it has no filesystem.** This one `if` is what makes re-attaching an existing volume safe — the difference between recovery and destruction.
4. **Mounts it at `/data`** via its UUID in `/etc/fstab`, with `nofail` so a missing volume cannot stop the instance booting.
5. **Creates the seven repository directories** and `chown`s them to uid 1000, which is the `nifi` user inside the container. Wrong ownership shows up as NiFi failing to start with permission errors.
6. **Fetches three secrets** using the instance role. No credential is on disk.
7. **Logs in to Artifactory, pulls the image, then immediately deletes `/root/.docker/config.json`** — because `docker login` writes the credential to disk in plain base64, where a snapshot or a later intruder would find it.
8. **Runs NiFi** with the repositories bind-mounted from `/data`.
9. **Configures the CloudWatch agent** to ship all four NiFi logs plus disk and memory metrics.
10. **Waits for the API to answer**, not merely for the container to start.

## 8.5 Reach it, with nothing exposed

There is no load balancer and **no inbound security-group rule at all**. So how do you open the UI?

```bash
aws ssm start-session --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
```

Leave that running, and open **https://localhost:8443/nifi** in your browser.

Get the password:

```bash
aws secretsmanager get-secret-value --secret-id nifi-lab/nifi-admin \
  --query SecretString --output text | jq -r .password
```

> ### ✅ Best practice: this is genuinely the most secure option
> Port forwarding through Session Manager means: no open port, no public IP, no SSH key to manage, no bastion host, and every session recorded in CloudTrail. It costs nothing extra.
>
> For a single-node development NiFi this is better than an internet-facing load balancer in every respect except convenience. Use it as long as you can.

## 8.6 Watch the bootstrap

```bash
aws ssm start-session --target <instance-id>
# then, inside:
sudo tail -f /var/log/nifi-bootstrap.log
sudo docker ps
sudo docker logs nifi --tail 50
df -h /data
```

Expect 3–6 minutes end to end. The pull from Artifactory is usually the slow part.

## 8.7 Costs of this stage

| Item | ~Monthly |
|---|---|
| t3.large instance | $60 |
| **NAT Gateway** | **$32** + data |
| 100 GB gp3 data volume | $8 |
| 30 GB root volume | $2.40 |
| Secrets Manager (3) | $1.20 |
| CloudWatch Logs | $1–5 |
| **Total** | **~$105 + data** |

The NAT Gateway being a third of the bill for a single node surprises people. If you can mirror the NiFi image into **ECR** and reach it through a VPC endpoint, you can drop NAT entirely for a large saving — Chapter 12.

---

### 📝 Quiz — Chapter 8

**1.** What does setting `NODE_COUNT=1` change about which scripts do work?

**2.** The user-data script only formats the data volume "if it has no filesystem". Why is that conditional the most important line in the script?

**3.** Why does the bootstrap delete `/root/.docker/config.json` right after pulling the image?

**4.** The instance has no inbound security group rules. Explain how you open the UI, and give two security advantages over an internet-facing endpoint.

**5.** Why does the bootstrap `chown` the repository directories to uid 1000?

**6.** A single-node deployment costs about $105/month and the NAT Gateway is $32 of it. What is it for, and what is the main way to avoid it?

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---

# Chapter 9. The real thing: a cluster behind a load balancer

Same scripts, one setting changed.

## 9.1 Configure

```bash
export NODE_COUNT=3                   # odd number - elections cannot tie
export NIFI_INSTANCE_TYPE="m6i.large"
export ACM_CERT_ARN="arn:aws:acm:eu-west-1:1234:certificate/..."   # SAME REGION
export NIFI_HOSTNAME="nifi.example.com"          # optional
export HOSTED_ZONE_ID="Z0123456789ABCDEFGHIJ"    # optional
```

> ### ⚠️ Gotcha: the certificate must be in the load balancer's region
> ACM certificates are regional. A certificate in `us-east-1` cannot be used by an ALB in `eu-west-1`. `00-preflight.sh` checks this and refuses to continue, because the error you get otherwise is unhelpful.
>
> (The exception, which does not apply here, is CloudFront — that one specifically requires `us-east-1`.)

**Use an odd number of nodes.** Elections need a majority; an even number can tie.

## 9.2 Build

```bash
./deploy-all.sh
```

The extra work in cluster mode:

- `01-network.sh` creates **two** NAT Gateways, one per AZ
- `02-security-groups.sh` creates three groups and opens **11443** (cluster protocol) and **6342** (load-balanced connections) node-to-node
- `05-zookeeper.sh` launches ZooKeeper
- `06-nifi-nodes.sh` launches three nodes, **alternating across AZs**
- `07-alb.sh` creates the ALB, target group with stickiness, and the HTTPS listener
- `deploy-all.sh` then runs `./06-nifi-nodes.sh --refresh-proxy`

## 9.3 That last step is not optional

The nodes were launched *before* the ALB existed, so its DNS name was not yet available to put in `nifi.web.proxy.host`. Until it is there, every request through the load balancer is rejected with **"Invalid host header"** and you get a blank page.

```bash
./06-nifi-nodes.sh --refresh-proxy
```

This is a genuine ordering problem, not a bug in the scripts: you cannot know the ALB's DNS name before creating the ALB, and you cannot register targets before creating the instances. Terraform solves it more elegantly (Chapter 10) because it computes the whole dependency graph first.

## 9.4 Verify, in the right order

```bash
./08-verify.sh
```

It checks, in order of what isolates faults fastest:

1. Are the instances running?
2. Did the bootstrap script finish? (via SSM, reading the log)
3. **Are the ALB targets healthy?** ← the check that actually matters
4. Does the endpoint answer 200 or 401?
5. Reminds you to check cluster membership in the UI

Then open the UI and go to **hamburger menu → Cluster**. You want:

- All three nodes `CONNECTED`
- Exactly one **Primary Node**
- Exactly one **Cluster Coordinator**

## 9.5 When nodes will not join

The same three causes as Chapter 3 §3.6, in the same order:

| Symptom | Cause | Check |
|---|---|---|
| Stuck at `Connecting` forever | port 11443 blocked between nodes | the NiFi security group must allow 11443 **from itself** |
| Stuck at `Connecting` forever | `NIFI_CLUSTER_ADDRESS` not resolvable | VPC must have `enableDnsHostnames`; `01-network.sh` sets it |
| Joins, then is ejected | **sensitive props key differs** | all nodes read the same secret; check `04-secrets.sh` did not regenerate |
| Joins, then is ejected | clocks drifted | Amazon Time Sync is automatic on EC2; check anyway |
| Flow appears empty after a restart | a node with an empty flow won the election | raise `NIFI_ELECTION_MAX_WAIT`, and see below |

> ### ⚠️ Gotcha: the election that eats your flow
>
> When a cluster starts, nodes vote on whose flow is authoritative. If node 1 holding your real flow is slow to start and nodes 2 and 3 come up empty, **the empty flow can win** and overwrite the real one.
>
> Mitigations: set `NIFI_ELECTION_MAX_WAIT` generously (the scripts use `1 min`; EKS uses `2 mins`), start nodes in order rather than all at once (the EKS StatefulSet uses `OrderedReady` for exactly this reason), and **keep flow exports** so this is recoverable rather than fatal.

## 9.6 Prove the fault tolerance

Do not trust it until you have broken it. Three tests, in increasing usefulness.

**Test 1 — kill the container, keep the instance.**

```bash
aws ssm start-session --target <instance-id>
sudo docker stop nifi
```

Watch: ALB target goes unhealthy within ~90s and stops receiving traffic. Cluster view shows the node `DISCONNECTED`. **The UI keeps working** through the other nodes. Then `sudo docker start nifi` and it rejoins with its data intact — because the data was on the volume, not in the container.

**Test 2 — stop the instance entirely.**

```bash
aws ec2 stop-instances --instance-ids <id>
```

Same, but now confirm the **volume survived**:

```bash
aws ec2 describe-volumes --filters Name=tag:Project,Values=nifi-prod \
  --query 'Volumes[].[VolumeId,State,Attachments[0].InstanceId]' --output table
```

Start it again; NiFi finds its repositories and resumes. **This is the test that proves the whole design.**

**Test 3 — lose an Availability Zone.**

You cannot fail an AZ on demand, but you can simulate it: stop every instance in one AZ at once. Confirm the remaining AZ carries the load — and check whether your instance sizing actually allows one AZ to handle 100% of traffic. If you sized for exactly 50% each with no headroom, losing an AZ overloads the survivors, and you have discovered that in a test rather than an incident.

---

### 📝 Quiz — Chapter 9

**1.** Why must `NODE_COUNT` be an odd number?

**2.** Explain why `--refresh-proxy` is needed after creating the ALB, and why it is an ordering problem rather than a bug.

**3.** Your ACM certificate is in `us-east-1` and your ALB is in `eu-west-1`. What happens?

**4.** A node joins the cluster and is then ejected. Give the two most likely causes.

**5.** Describe the "election that eats your flow" and three ways to reduce the risk.

**6.** In Test 1 you stop the container and start it again, and no data is lost. Which architectural decision made that true?

**7.** Test 3 asks you to check instance sizing. What specific mistake is it looking for?

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---
# Chapter 10. The same thing, in Terraform

The CLI scripts teach you what exists. Terraform is how you actually live with it.

## 10.1 Why bother, having just built it by hand

| CLI scripts | Terraform |
|---|---|
| You see every API call | You declare the end state |
| Re-runnable via `state/ids.env` | Real state file, real dependency graph |
| Teardown is a script you wrote | `terraform destroy` derives the order |
| Drift is invisible | `terraform plan` shows drift |
| Review = reading bash | Review = reading a plan diff |

The decisive one is the last. `terraform plan` shows exactly what will change **before** it changes, in a form a colleague can review.

## 10.2 Run it

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
# edit it

export TF_VAR_artifactory_password='your-token'    # never in a file

make plan VARS=example-single.tfvars     # or example-cluster.tfvars
# READ THE PLAN
make apply
make output
```

## 10.3 Guardrails built into the variables

The variable definitions refuse dangerous input at plan time rather than letting you discover it later:

```hcl
variable "nifi_version" {
  validation {
    condition = can(regex("^2\\.(([89])|([1-9][0-9]+))\\.", var.nifi_version))
    error_message = "Use NiFi 2.8.0 or later. 1.x is EOL and <=2.7.2 has a known authorisation bypass."
  }
}
```

Also enforced: `node_count` must be 1 or an odd number ≥ 3; `allowed_cidr` may not be `0.0.0.0/0`; and the HTTPS listener has a `precondition` that fails with a readable message if you set `node_count > 1` without a certificate.

> ### ✅ Best practice: put the guardrail in the variable, not the README
> A validation block is checked every time. A warning in a README is read once, by the person who wrote it.

## 10.4 The data volumes, and the one thing to understand

```hcl
resource "aws_ebs_volume" "data" {
  count = var.node_count
  size  = var.data_volume_gb
  # ...
}

resource "aws_volume_attachment" "data" {
  count        = var.node_count
  volume_id    = aws_ebs_volume.data[count.index].id
  instance_id  = aws_instance.nifi[count.index].id
  skip_destroy = true
}
```

The volumes are a **separate resource**, not an inline `ebs_block_device`. That is the whole trick: Terraform can replace an **instance** without touching the **disk**. With an inline block device, `user_data_replace_on_change` would destroy your in-flight data every time you edited the bootstrap script.

`skip_destroy = true` on the attachment stops Terraform trying to force-detach a mounted filesystem, which can corrupt it.

> ### ⚠️ Gotcha: `terraform destroy` DOES delete these volumes
> Terraform manages them, so destroy removes them. Snapshot first, every time:
>
> ```bash
> make snapshot     # then confirm they reach 'completed'
> make destroy
> ```
>
> When reading any plan, search for **`must be replaced`** against `aws_ebs_volume`. If you see it, stop and work out why — that line means data loss.

## 10.5 Terraform solves the ALB ordering problem

Chapter 9 needed `--refresh-proxy` because the CLI cannot know the ALB's DNS name before creating it. Terraform builds the dependency graph first, so it can simply reference it:

```hcl
proxy_hosts = join(",", compact([
  "localhost:8443",
  local.is_cluster ? "${aws_lb.nifi[0].dns_name}:443" : "",
  var.nifi_hostname != "" ? "${var.nifi_hostname}:443" : "",
]))
```

Terraform sees that `user_data` depends on `aws_lb.nifi`, creates the load balancer first, and bakes the correct value into the instance on its first boot. No second pass.

## 10.6 State belongs in S3

The commented backend in `versions.tf`:

```hcl
backend "s3" {
  bucket       = "my-tf-state"
  key          = "nifi/terraform.tfstate"
  region       = "eu-west-1"
  encrypt      = true
  use_lockfile = true      # S3-native locking; no DynamoDB table needed
}
```

Local state means one person, one laptop, and no locking. Two people applying at once with local state produces a genuinely bad afternoon.

---

### 📝 Quiz — Chapter 10

**1.** Give the single strongest argument for Terraform over the CLI scripts.

**2.** Why are the data volumes a separate `aws_ebs_volume` resource rather than an inline `ebs_block_device`?

**3.** What does `skip_destroy = true` prevent?

**4.** What phrase should you search for in a plan before applying, and why?

**5.** Explain how Terraform avoids the `--refresh-proxy` step the CLI needed.

**6.** Why should the state file live in S3 rather than on your machine?

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---

# Chapter 11. NiFi on EKS

The same cluster, on Kubernetes. This is where NiFi's statefulness stops being awkward, because Kubernetes has a purpose-built answer for it.

## 11.1 Prerequisites

| Tool | Check | Why |
|---|---|---|
| `kubectl` | `kubectl version --client` | talk to the cluster |
| `eksctl` | `eksctl version` | create the cluster from one YAML |
| `helm` | `helm version` | install the load balancer controller |
| `aws` v2 | `aws --version` | credentials |
| IAM permissions | — | EKS, EC2, IAM, ELB, and creating roles |

Plus the concepts: a **Pod** is one or more containers, a **Deployment** manages interchangeable pods, a **StatefulSet** manages pods with identity, a **Service** gives a stable name, an **Ingress** requests a load balancer, and a **PersistentVolumeClaim** requests a disk.

## 11.2 Create the cluster

```bash
cd eks
eksctl create cluster -f cluster.yaml       # 15-20 minutes. Genuinely.
```

Two lines in `cluster.yaml` deserve attention.

```yaml
iam:
  withOIDC: true
```

This enables **IRSA** — IAM Roles for Service Accounts — which lets a specific pod assume a specific IAM role. Without it, the only way to give a pod AWS permissions is to give **every** pod on the node the same permissions.

```yaml
addons:
  - name: aws-ebs-csi-driver
    wellKnownPolicies:
      ebsCSIController: true
```

> ### ⚠️ Gotcha: without the EBS CSI driver, nothing works and nothing says why
>
> The EBS CSI driver is what actually creates and attaches EBS volumes when a PersistentVolumeClaim asks for one. Without it, **every PVC stays `Pending` forever**, so every NiFi pod stays `Pending`, and nothing in the pod's events mentions a missing driver.
>
> This is the most common EKS-StatefulSet surprise. Check it:
> ```bash
> eksctl get addon --cluster nifi-cluster | grep ebs
> kubectl get pvc -n nifi         # anything Pending after 2 min = suspect this
> ```

## 11.3 Install the load balancer controller

```bash
./install-controllers.sh
```

A Kubernetes `Ingress` object is only a *request*. Something has to read it and build a real ALB. On EKS that something is the AWS Load Balancer Controller, installed with an IAM policy plus an IRSA-bound service account.

**Symptom if you skip it:** you apply the Ingress, `kubectl get ingress` shows a blank `ADDRESS` forever, and there is no error anywhere.

## 11.4 Deploy NiFi

```bash
# EDIT THIS FIRST - it ships with placeholders
vi manifests/01-secrets.yaml

kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/
kubectl -n nifi get pods -w
```

Order matters: the namespace and StorageClass first, then everything else.

## 11.5 Why a StatefulSet — the actual payoff

This is the reason to consider EKS at all:

| Property | Deployment | **StatefulSet** |
|---|---|---|
| Pod names | random suffixes | `nifi-0`, `nifi-1`, `nifi-2` |
| DNS name per pod | no | `nifi-0.nifi-headless.nifi.svc.cluster.local` |
| Disk follows the pod | no | **yes — its own PVC, reattached on reschedule** |
| Start/stop order | arbitrary | ordered |

That third row is Chapter 2's problem, solved by the platform. If `nifi-1` dies and Kubernetes reschedules it — even onto a different node — it gets **its own disks back**, with its in-flight data. On plain EC2 you arrange that yourself with persistent volumes and careful instance handling. Here it is the default behaviour of the object.

The stable DNS name is what makes clustering work:

```yaml
- name: POD_NAME
  valueFrom: { fieldRef: { fieldPath: metadata.name } }
- name: NIFI_CLUSTER_ADDRESS
  value: "$(POD_NAME).nifi-headless.$(POD_NAMESPACE).svc.cluster.local"
```

Kubernetes expands `$(VAR)` from earlier entries, so each pod advertises its own stable address. Compare Chapter 9, where a node advertises an EC2 private DNS name that changes when the instance is replaced.

## 11.6 Choices in the manifests worth knowing

**`podManagementPolicy: OrderedReady`** — pods start one at a time, `nifi-0` fully ready before `nifi-1` begins. This directly mitigates the "election that eats your flow" from Chapter 9 §9.5. `Parallel` is faster and riskier.

**`fsGroup: 1000`** — the image runs as uid 1000. Without this, the mounted volumes are not writable by NiFi and it fails to start with permission errors on its repositories.

**Three probes, doing different jobs.** A `startupProbe` with `failureThreshold: 40` allows up to ~400 seconds to boot; `readinessProbe` controls whether traffic is sent; `livenessProbe` restarts a wedged pod. Using only a liveness probe forces a choice between killing NiFi during its slow startup or being too forgiving later. Three probes avoids the trade-off.

**Seven `volumeClaimTemplates`** — content, provenance, flowfile and the rest each get their own volume, which is the IOPS-separation best practice from Chapter 2 §2.5, easier here than on EC2.

**`reclaimPolicy: Retain` on the StorageClass** — deleting the StatefulSet must not delete the disks holding in-flight data. See §11.9 for the cost consequence.

**ZooKeeper as a 3-replica StatefulSet with a PodDisruptionBudget** — `maxUnavailable: 1` stops a node drain taking two ZooKeeper pods at once and losing quorum. This is the fix for the EC2 design's weakest link (Chapter 7 §7.5).

> ### 🧠 Background: the ZooKeeper-free option
> NiFi 2.x can elect its leader using **Kubernetes leases** instead of ZooKeeper:
> ```
> nifi.cluster.leader.election.implementation=KubernetesLeaderElectionManager
> ```
> It needs RBAC permission on leases and a matching state provider. It is genuinely appealing — one less system to run.
>
> These manifests use ZooKeeper anyway, for one reason: it behaves identically on EC2 and EKS, so the guide can explain one mechanism. **Check the documentation for your exact NiFi version before relying on the Kubernetes option**, and test failover deliberately.

## 11.7 The Ingress

Same two NiFi requirements as the ALB chapter, expressed as annotations:

```yaml
alb.ingress.kubernetes.io/backend-protocol: HTTPS      # NiFi is HTTPS-only
alb.ingress.kubernetes.io/success-codes: '200-401'     # auth challenge = alive
alb.ingress.kubernetes.io/target-group-attributes: >-
  stickiness.enabled=true,stickiness.type=lb_cookie,...
```

And `NIFI_WEB_PROXY_HOST` in the StatefulSet must contain your public hostname, or "Invalid host header" again.

## 11.8 Verify

```bash
kubectl -n nifi get pods,pvc,svc,ingress
kubectl -n nifi logs nifi-0 -f
kubectl -n nifi exec nifi-0 -- curl -ks https://localhost:8443/nifi-api/access/config

# port-forward without exposing anything
kubectl -n nifi port-forward nifi-0 8443:8443
# then https://localhost:8443/nifi
```

| Symptom | Cause |
|---|---|
| PVC `Pending` > 2 min | EBS CSI driver addon missing (§11.2) |
| Ingress `ADDRESS` blank | load balancer controller not installed (§11.3) |
| Pod `CrashLoopBackOff` | password < 12 chars, or `fsGroup` missing |
| Pods running, nodes not clustering | ZooKeeper not ready, or headless service wrong |
| 502/503 through the ALB | `backend-protocol: HTTPS` missing |

## 11.9 Tearing down EKS

```bash
kubectl delete -f manifests/
kubectl delete namespace nifi
eksctl delete cluster -f cluster.yaml --disable-nodegroup-eviction
```

> ### ⚠️ Gotcha: the PVCs survive, and keep billing
> The StorageClass sets `reclaimPolicy: Retain` — deliberately, so an accidental `kubectl delete` cannot destroy in-flight data. The consequence is that deleting the namespace leaves **every EBS volume in place, still charged for**.
>
> That is the correct default and a real trap. After teardown:
> ```bash
> kubectl get pv                      # may still list them
> aws ec2 describe-volumes --filters Name=status,Values=available \
>   --query 'Volumes[].[VolumeId,Size,CreateTime]' --output table
> ```
> Snapshot what you want, then delete the rest. `cli/orphan-hunt.sh` finds them too.

---

### 📝 Quiz — Chapter 11

**1.** What does `withOIDC: true` enable, and what is the alternative you are avoiding?

**2.** Your NiFi pods are stuck `Pending` and so are their PVCs. What is the most likely cause and how do you confirm it?

**3.** Give the three StatefulSet properties NiFi needs, and say which one solves Chapter 2's problem.

**4.** Explain how `NIFI_CLUSTER_ADDRESS` gets a different, stable value in each pod.

**5.** Why `OrderedReady` rather than `Parallel`?

**6.** What does `fsGroup: 1000` do and what breaks without it?

**7.** Why three separate probes instead of one liveness probe?

**8.** You delete the namespace after a demo. What is still costing you money, and why was it designed that way?

*Answers in [Appendix A](#appendix-a--quiz-answers).*

---

# Chapter 12. EC2 or EKS, and a best-practice checklist

## 12.1 The honest comparison

| | **EC2 (Chapters 8–10)** | **EKS (Chapter 11)** |
|---|---|---|
| Baseline cost | none beyond the instances | **~$73/month control plane** before any node |
| Time to first NiFi | ~10 min | ~25 min (cluster creation alone is 15–20) |
| Skills needed | Linux, Docker, AWS | all of that **plus Kubernetes** |
| Disk follows the node | you arrange it | **built in (PVC)** |
| Rolling upgrade | you script it | built in, ordered |
| Separate volume per repository | more work | trivial |
| Debugging | `ssm start-session`, `docker logs` | `kubectl logs`, `kubectl describe` |
| Failure modes to learn | EC2 + NiFi | EC2 + NiFi + **Kubernetes** |
| Right when… | NiFi is your only workload | you already run Kubernetes |

**The recommendation, plainly:**

- **You do not already run Kubernetes →** use EC2. The control plane cost is minor; the operational learning curve is not. Adding Kubernetes to run one stateful application means two systems to debug at 2am instead of one.
- **You already run Kubernetes →** use EKS. You have the skills and tooling, and the StatefulSet genuinely solves NiFi's hardest infrastructure problem more cleanly than anything you would build on EC2.
- **Either way**, the flow-level decisions from Chapter 2 §2.4 matter more than this choice.

## 12.2 Best practices, grouped

**Security**

| ✅ | Why |
|---|---|
| Private subnets; nothing inbound except through the ALB | reduces exposure to one reviewable place |
| SSM Session Manager instead of SSH | no keys, no port 22, auditable |
| Secrets in Secrets Manager, fetched by instance role | nothing on disk, nothing in a template |
| **Delete `/root/.docker/config.json` after pulling** | `docker login` leaves the credential in plain base64 |
| IMDSv2 required (`HttpTokens=required`) | blocks a class of SSRF metadata theft |
| Encrypt every EBS volume | free, and one less finding in an audit |
| Restrict the ALB to known CIDRs | a public NiFi UI is a bad idea |
| Replace single-user auth with **OIDC** for anything real | one login per person, revocable |
| Rotate the Artifactory credential; keep the **sensitive key** forever | opposite lifecycles, easy to confuse |

> ### 🧠 Background: point NiFi at the Keycloak you already have
> Single-user auth is one shared password — fine for a laptop, wrong for a team. NiFi supports OIDC, so any OpenID Connect provider works, including a self-hosted Keycloak.
>
> Broadly: register a NiFi client in your identity provider, set `nifi.security.user.oidc.discovery.url` to its discovery document plus the client id and secret, and map claims to NiFi user identities. Then authorise those identities in NiFi's policies. Check the docs for your NiFi version — the property names have shifted between releases.

**Reliability**

| ✅ | Why |
|---|---|
| **Design flows to be replayable** | worth more than any infrastructure (Ch 2 §2.4) |
| Odd node count | elections cannot tie |
| Nodes across at least 2 AZs | survive one AZ |
| **Three ZooKeepers in production** | the shipped single one is the weakest link |
| Persistent volumes, `DeleteOnTermination=false` | in-flight data survives instance replacement |
| Separate volumes for content and provenance | biggest throughput win |
| Generous `NIFI_ELECTION_MAX_WAIT` | stops an empty flow winning |
| Sticky sessions on the ALB | mandatory for the UI |
| Size so one AZ can carry 100% | otherwise an AZ loss overloads the survivors |

**Cost**

| ✅ | Why |
|---|---|
| Budget alert **before** you build | the two-minute step everyone skips |
| **Mirror the image to ECR + VPC endpoint** | can remove the NAT Gateway entirely — often the largest single saving |
| Always set log retention | unset means "never expire", billed forever |
| Bound the provenance repository | otherwise it grows until the disk is full |
| Run `orphan-hunt.sh` after every teardown | EIPs, volumes and NAT are the classic silent charges |
| Stop the lab overnight | a dev cluster does not need to run at 3am |

**Operations**

| ✅ | Why |
|---|---|
| **Flows in NiFi Registry or Git from day one** | retrofitting is painful |
| Export flows on a schedule, not just before changes | `export-everything.sh` in cron |
| Snapshot data volumes before any destroy | `make snapshot` |
| Alarm on `/data` `used_percent` at 75% | a full disk stops NiFi and looks like a hang |
| Read `nifi-deprecation.log` before any upgrade | your own authoritative checklist |
| Test failover deliberately (Ch 9 §9.6) | untested failover is a hypothesis |
| **External Secrets Operator on EKS** | keeps secrets out of Git properly |

---

# Chapter 13. Debugging and logging on AWS

Chapter 4 covered NiFi's own tools. These still work — provenance, bulletins, queue inspection — and are still your first stop. This chapter is about the AWS layer around them.

## 13.1 Getting at the logs

The CloudWatch agent ships four log streams per node:

```bash
aws logs describe-log-streams --log-group-name /nifi-prod/nifi \
  --order-by LastEventTime --descending --max-items 10

# errors across ALL nodes at once - the thing that is painful without CloudWatch
aws logs filter-log-events --log-group-name /nifi-prod/nifi \
  --filter-pattern "ERROR" --max-items 40 \
  --query 'events[].message' --output text

# one node, last 15 minutes
aws logs filter-log-events --log-group-name /nifi-prod/nifi \
  --log-stream-name-prefix i-0abc123 \
  --start-time $(( ($(date +%s) - 900) * 1000 ))
```

That cross-node search is the real win. Without it you are opening three SSM sessions and grepping three files by hand.

Or go to the box:

```bash
aws ssm start-session --target i-0abc123
sudo docker logs nifi --tail 100 -f
sudo tail -f /data/nifi/logs/nifi-app.log
sudo tail -f /var/log/nifi-bootstrap.log     # if it never started
df -h /data                                   # always worth checking
```

## 13.2 The alarms that matter

**Disk on `/data` — the important one.** The agent config publishes `used_percent` for `/data`:

```bash
aws cloudwatch put-metric-alarm \
  --alarm-name nifi-prod-data-disk-75 \
  --namespace nifi-prod/NiFi --metric-name used_percent \
  --dimensions Name=path,Value=/data \
  --statistic Average --period 300 --evaluation-periods 2 \
  --threshold 75 --comparison-operator GreaterThanThreshold \
  --alarm-actions <your-sns-topic-arn>
```

75% not 90%, because a NiFi disk that is filling is usually filling *fast* — a destination went down and the content repository is absorbing everything.

Also worth having: **unhealthy ALB targets** (`UnHealthyHostCount` ≥ 1), **ALB 5xx count**, and **memory used** above 90%.

## 13.3 Keep the provenance repository from eating the disk

The most common cause of a full NiFi disk is provenance growing without limit. Bound it explicitly:

```properties
nifi.provenance.repository.max.storage.size=10 GB
nifi.provenance.repository.max.storage.time=7 days
```

**This is a real trade-off, so decide it deliberately.** Provenance is one of the main reasons to use NiFi (Chapter 1), and shrinking the window shortens how far back you can investigate. Sizing it at "as much as the disk allows" is not a plan, though — it just means the incident where you need provenance is also the incident where the disk filled.

## 13.4 Log retention

```bash
aws logs put-retention-policy --log-group-name /nifi-prod/nifi --retention-in-days 90
```

The scripts always set retention, because the default is **never expire** — a log group that bills for storage forever. `orphan-hunt.sh` reports groups with no retention for exactly this reason.

---

# Chapter 14. Destroying it all, safely

The chapter people skip, then pay for.

## 14.1 Before you touch anything

```
[ ] Flows exported?              migration/export-everything.sh
[ ] Sensitive props key saved OUTSIDE AWS?     <-- the one people lose
[ ] Data volumes snapshotted?    cli/backup.sh   or   make snapshot
[ ] Anyone else using this?      ask
[ ] Snapshots actually 'completed', not 'pending'?
```

That second line, once more, because it is the expensive one:

```bash
aws secretsmanager get-secret-value --secret-id nifi-prod/sensitive-props-key \
  --query SecretString --output text
```

Put it in a password manager. Without it, every flow export you just took has unreadable credentials inside it.

## 14.2 The CLI teardown

```bash
cd cli
./backup.sh          # flows + snapshots + the key
./destroy-all.sh
```

`destroy-all.sh` asks four things: type the project name, type `DESTROY`, confirm you have a backup, and choose what happens to the data volumes:

| Choice | Result |
|---|---|
| `snapshot` | snapshot each, wait for completion, then delete — **recommended** |
| `delete` | delete now, irreversible |
| `keep` | leave them; they keep billing and you clean up later |

Then it works in reverse order of creation:

```
 1. listener            9. route tables, subnets
 2. load balancer      10. internet gateway
    (wait 90s)         11. security groups (retried)
 3. target group       12. VPC
 4. record volumes     13. IAM role + profile
 5. terminate instances 14. log group (asks)
 6. handle volumes     15. secrets (asks, 7-day window)
 7. NAT gateways
 8. elastic IPs
```

> ### ⚠️ Gotcha: the 90-second wait is not padding
> An ALB leaves network interfaces behind for a while after deletion. Delete its security group or subnets too soon and you get `DependencyViolation` — which is the single most common reason a teardown "randomly" fails partway through and leaves a half-deleted VPC.

**On secrets:** they are *scheduled* for deletion with a 7-day recovery window, not erased. The name stays reserved for those seven days, so an immediate re-deploy hits "already exists" — expected, not a bug. (`04-secrets.sh` detects and restores a scheduled-for-deletion secret; the Terraform sets `recovery_window_in_days = 0` so re-applies work immediately.)

## 14.3 Terraform teardown

```bash
make snapshot     # FIRST. terraform destroy deletes the volumes.
# confirm snapshots are 'completed'
make destroy      # shows a destroy plan, then asks you to type DESTROY
```

## 14.4 EKS teardown

```bash
kubectl delete -f manifests/
kubectl delete namespace nifi
eksctl delete cluster -f cluster.yaml --disable-nodegroup-eviction
```

Then check for retained volumes (Chapter 11 §11.9) — `reclaimPolicy: Retain` means they survive.

## 14.5 Always finish with the orphan hunt

```bash
./orphan-hunt.sh
```

It looks for what silently survives, with cost hints:

| Orphan | ~Cost |
|---|---|
| Unassociated Elastic IPs | $3.60/mo each |
| NAT Gateways | $32/mo each |
| Load balancers | $18/mo each |
| **Available (unattached) EBS volumes** | $0.08/GB/mo — the big one after a NiFi teardown |
| EBS snapshots | $0.05/GB/mo |
| Log groups with no retention | grows forever |
| Secrets pending deletion | $0.40/mo each |

It deliberately **deletes nothing**. After a NiFi teardown, an unattached volume or a snapshot may be the only remaining copy of your in-flight data, so the script reports and leaves the decision to you.

Finally, check the bill actually dropped. **Cost Explorer**, daily granularity, filtered by service. Watch **EC2-Other** (that is where NAT and EBS hide), **Elastic Load Balancing** and **Secrets Manager**. Data lags up to 24 hours.

---

# Chapter 15. Troubleshooting by symptom

| Symptom | Likely cause | Fix |
|---|---|---|
| Container restarts in a loop | admin password < 12 chars | longer password |
| Container restarts in a loop | `/data` not mounted, cannot write repositories | `df -h /data`; check `fstab` and the volume attachment |
| **Blank page / "Invalid host header"** | ALB DNS not in `nifi.web.proxy.host` | `./06-nifi-nodes.sh --refresh-proxy` |
| 503 from the ALB | no healthy targets | `./troubleshoot.sh`, read the Reason column |
| Target `Target.ResponseCodeMismatch` | health check outside 200–401 | verify by hand with `curl -k`; adjust matcher |
| Target `Target.Timeout` | still starting, or SG blocks 8443 from ALB | wait; check the group rule |
| Node stuck at `Connecting` | port 11443 blocked between nodes | allow 11443 from the NiFi group **to itself** |
| Node stuck at `Connecting` | `NIFI_CLUSTER_ADDRESS` unresolvable | VPC DNS hostnames enabled? |
| Node joins then ejected | sensitive props key differs | all nodes must read the same secret |
| Node joins then ejected | clock drift | check time sync |
| Flow empty after restart | empty flow won the election | restore an export; raise `ELECTION_MAX_WAIT`; start ordered |
| Random logouts, half-drawn canvas | stickiness off | enable on the target group |
| `docker pull` failed in bootstrap | NAT missing, or Artifactory creds wrong | `/var/log/nifi-bootstrap.log` |
| Everything slow, no errors | **disk full** | `df -h`; bound provenance |
| Slow under load only | provenance and content sharing IOPS | separate volumes |
| Processor warning triangle | unterminated relationship / empty required property | open it and read the tooltip |
| Queue grows forever | downstream stopped or slower | walk downstream from the first growing queue |
| Ghost (greyed) component after import | processor removed in 2.x | replace it — Chapter 6 §6.6 |
| Passwords blank after import | wrong sensitive props key | Chapter 6 §6.7 |
| PVC `Pending` (EKS) | EBS CSI driver addon missing | `eksctl get addon` |
| Ingress ADDRESS blank (EKS) | LB controller not installed | `./install-controllers.sh` |
| Bill did not drop after teardown | orphans | `./orphan-hunt.sh`, then Cost Explorer |

---

# Appendix A — Quiz answers

## Chapter 1
**1.** Attributes are metadata written "on the envelope" — filename, size, custom tags — cheap to read and route on. Content is the payload inside. NiFi routes on attributes without reading content, which is why routing is fast.
**2.** Any three of: retries with back-off, back-pressure, batching, credential handling, provenance/observability, restart safety.
**3.** A JVM, five repositories and a web UI to move one small file daily is disproportionate — cost, patching, and operational surface all for one `cp`. A Lambda on a schedule, or `aws s3 cp` in cron, is the right size. Use NiFi when you need its machinery.
**4.** Provenance is the recorded history of every individual FlowFile — where it came from, each transformation, and the content at each step. It is decisive where you must *prove* what happened to a specific record, as in regulated industries.
**5.** False. The flow is stored as one compressed blob (`flow.json.gz`), which is not diffable. You need NiFi Registry or Git integration to get reviewable history.

## Chapter 2
**1.** `conf/` (flow design), `flowfile_repository/` (what data is where), `content_repository/` (the actual in-flight bytes), `provenance_repository/` (audit trail), `database_repository/` + `state/` (component state, e.g. last-listed marker).
**2.** No. NiFi does not replicate in-flight data between nodes; each node's content repository is its own. That data is unavailable until the disk is recovered.
**3.** Offloading transfers a node's queued work to peers, but requires the node to be running to send it. A dead node cannot offload. It is a graceful maintenance operation, not recovery.
**4.** A stateless app holds nothing important, so terminate-and-replace is harmless. NiFi holds real in-flight data on local disk, so the ASG's normal behaviour destroys data and starts an empty node — and reports success.
**5.** Strategy 2, replayable sources. If the source can be re-read and the destination is idempotent, total node loss costs a re-read rather than lost records. No infrastructure design achieves that on its own.
**6.** Split `content_repository` and `provenance_repository` onto separate volumes. They are both IO-heavy; on one volume they compete for the same IOPS and throughput collapses under load.
**7.** `nifi.sensitive.props.key`. Exported flows contain values encrypted with it; without the key those credentials cannot be decrypted.

## Chapter 3
**1.** The admin password — NiFi refuses to start with fewer than 12 characters, and the message is easy to miss, so the container exits and Docker restarts it repeatedly.
**2.** An unterminated relationship. Every outgoing relationship must either be connected onward or explicitly auto-terminated; conceptually you are telling NiFi "data reaching here is finished" so it knows the FlowFile's fate.
**3.** The queue reaches its threshold, changes colour, and the **upstream** processor stops scheduling. Nothing crashes and memory does not grow. The alternative — unbounded buffering — ends in an out-of-memory failure.
**4.** NiFi generates a self-signed certificate on first start, which no browser trusts. NiFi 2.x is HTTPS-only; there is no plain-HTTP mode.
**5.** The same flow. The flow definition is cluster-wide, not per-node — nodes agree on one flow and each runs it.
**6.** Mismatched sensitive props keys; `NIFI_CLUSTER_ADDRESS` not resolvable by peers; port 11443 blocked.

## Chapter 4
**1.** Login failure → `nifi-user.log`. Will not start → `nifi-bootstrap.log`. Processor exception → `nifi-app.log`.
**2.** It lists deprecated components your flows actually use. Most valuable immediately before a version upgrade — it is your own authoritative migration checklist.
**3.** Walk downstream from the first growing queue until you find the stopped, failing or slow processor. Check its bulletins, then `nifi-app.log`. Also check disk space.
**4.** Replay re-injects that exact FlowFile into the flow at that point, so you can test a fix against identical input without finding and re-sending the original source data.
**5.** It produces gigabytes per hour, which fills the disk shared with the content repository and can take the node down.
**6.** Disk space — `df -h`. A full content repository stops NiFi accepting data and often logs nothing obvious.

## Chapter 5
**1.** It is a single gzipped blob: unreadable, undiffable, version-tied and all-or-nothing. The portable unit is a **flow definition** (JSON) downloaded per process group.
**2.** Parameter contexts (parameters resolve to nothing), controller services (database/SSL references dangle), reporting tasks (monitoring silently absent). Registry clients and parameter providers also qualify.
**3.** Every sensitive value is undecryptable — the flow looks structurally perfect with blank or unreadable credentials. You find out when a processor fails to connect, because NiFi does not announce it loudly.
**4.** Do the action in the UI with browser DevTools open on the Network tab, and read the request. The UI uses the same REST API.
**5.** In-flight data, decrypted passwords, provenance history, file-based users/policies, custom NARs.
**6.** So nothing touches real data before you have fixed ghost components, rebound controller services, recreated parameter contexts and retyped blank secrets.

## Chapter 6
**1.** 1.16 → **1.28.1** → 2.10.0. The 1.27+/1.28 releases contain the migration groundwork that makes the 2.x flow upgrade work; skipping it produces flows that fail to load with opaque errors.
**2.** NiFi 2.x has no concept of a template, so it cannot convert one. If the old cluster is gone and you only have template XML, you need to stand up a 1.x instance to drag each onto a canvas and re-download it as JSON.
**3.** `${my_var}` becomes `#{my_param}`. Parameters can be marked **sensitive**; variables could never hold secrets.
**4.** A processor referenced by the flow that no longer exists in this version — greyed out, unstartable, blocking the group. Good, because it is a visible fixable problem rather than a silent removal.
**5.** `nifi-deprecation.log` on the old instance.
**6.** The old cluster keeps serving production untouched, so every step is reversible. An in-place upgrade has a point of no return in the middle.
**7.** Stopping the whole group leaves data sitting in queues — and that data lives in the content repository of the cluster you are about to decommission. Stopping only sources lets downstream drain to empty first.
**8.** Every encrypted value in every imported flow is unreadable and must be retyped by hand. Avoidable: build the new cluster with the old key before the first import (`TF_VAR_nifi_sensitive_props_key`).

## Chapter 7
**1.** They have no inbound route from the internet, which removes most of the attack surface. The **NAT Gateway** gives them outbound-only access to pull the image.
**2.** Sticky sessions on — without them, random logouts and half-drawn canvases. ALB DNS name in `nifi.web.proxy.host` — without it, "Invalid host header" and a blank page.
**3.** If the endpoint demands authentication on that version, a 401 still proves the web server is alive. With a bare `200`, an auth challenge reads as unhealthy, the ALB drains every node, and you get a 503 in front of three healthy nodes.
**4.** ALB marks the target unhealthy and stops routing to it; ZooKeeper elects a new Primary if the dead node held it; the surviving nodes continue processing new data. The dead node's in-flight data is stuck until its volume is recovered.
**5.** The single ZooKeeper instance. Production should run three across three AZs, as the EKS manifests do.
**6.** When every flow is genuinely replayable — replayable source, idempotent destination — so losing a node's in-flight data costs a re-read rather than records.
**7.** The health check matcher excludes the code NiFi returns (needs `200-401`), or the security group does not allow 8443 from the ALB's group. A missing `backend-protocol: HTTPS` equivalent (ALB talking HTTP to an HTTPS-only port) is a third.

## Chapter 8
**1.** `05-zookeeper.sh` and `07-alb.sh` detect it and skip themselves; `01-network.sh` creates one NAT instead of two; `02-security-groups.sh` creates no inbound rules at all.
**2.** It is what makes re-attaching an existing volume safe. Formatting unconditionally would erase the in-flight data on every boot — the difference between recovery and destruction.
**3.** `docker login` writes the registry credential to that file in plain base64. Leaving it means an EBS snapshot or any later intruder gets your Artifactory credential.
**4.** SSM `AWS-StartPortForwardingSession` to local port 8443. Advantages: no open port and no public IP; no SSH key to manage; no bastion; sessions recorded in CloudTrail.
**5.** The container runs as uid 1000 (`nifi`). Without matching ownership on the bind-mounted directories, NiFi cannot write its repositories and fails to start with permission errors.
**6.** It gives private instances outbound access to pull the image from Artifactory and reach CloudWatch/Secrets Manager. Avoid it by mirroring the image into ECR and reaching it through a VPC endpoint.

## Chapter 9
**1.** Elections need a majority; an even number can tie.
**2.** The nodes are created before the ALB, so its DNS name cannot be in `nifi.web.proxy.host` on first boot. You cannot know the name before creating the load balancer, and cannot register targets before creating the instances — a genuine ordering constraint, which Terraform resolves with a dependency graph.
**3.** It cannot be attached — ACM certificates are regional. `00-preflight.sh` catches it, because the raw error is unhelpful.
**4.** Mismatched sensitive props keys, or clock drift between nodes.
**5.** On startup nodes vote on whose flow is authoritative; if the node holding the real flow is slow, an empty flow can win and overwrite it. Reduce risk with a generous `NIFI_ELECTION_MAX_WAIT`, ordered startup (`OrderedReady`), and keeping flow exports.
**6.** Putting the repositories on a persistent volume outside the container, so container state is disposable.
**7.** Sizing each AZ for exactly 50% with no headroom — losing one AZ then overloads the survivors.

## Chapter 10
**1.** `terraform plan` shows exactly what will change before it changes, in a reviewable form.
**2.** So Terraform can replace an instance without destroying the disk. With an inline block device, `user_data_replace_on_change` would destroy in-flight data on every bootstrap edit.
**3.** Terraform attempting to force-detach a mounted filesystem, which can corrupt it.
**4.** `must be replaced`, especially against `aws_ebs_volume` — it means data loss.
**5.** It computes the dependency graph first, so `user_data` can reference `aws_lb.nifi[0].dns_name`; the ALB is created first and the correct value is baked into the instance's first boot.
**6.** Local state means one machine, no locking, and no shared history. Two concurrent applies against local state corrupt your view of reality.

## Chapter 11
**1.** IRSA — binding an IAM role to a specific Kubernetes service account. Without it, the only way to grant AWS permissions is to give every pod on the node the same permissions.
**2.** The `aws-ebs-csi-driver` addon is missing, so nothing fulfils the PVCs. Confirm with `eksctl get addon --cluster nifi-cluster | grep ebs` and `kubectl get pvc -n nifi`.
**3.** Stable pod names, stable per-pod DNS, and a PVC that follows the pod. The third solves Chapter 2 — a rescheduled pod gets its own disks and in-flight data back.
**4.** `POD_NAME` comes from a `fieldRef` on `metadata.name`; Kubernetes expands `$(POD_NAME)` inside the later `NIFI_CLUSTER_ADDRESS` value, producing a unique stable FQDN per pod.
**5.** Pods start one at a time so the first is fully ready before the next begins, which reduces the chance of an empty flow winning the election.
**6.** It makes mounted volumes group-writable by gid 1000, matching the image's `nifi` user. Without it NiFi cannot write its repositories and crash-loops.
**7.** `startupProbe` allows a long slow boot; `readinessProbe` gates traffic; `livenessProbe` restarts a wedged pod. One liveness probe forces a choice between killing NiFi during startup or being too forgiving afterwards.
**8.** The EBS volumes behind the PVCs, because `reclaimPolicy: Retain` deliberately protects in-flight data from an accidental delete. Snapshot what you need and delete the rest.

---

# Appendix B — Glossary

| Term | Meaning |
|---|---|
| **ALB** | Application Load Balancer. One stable HTTPS address in front of several nodes. |
| **AZ** | Availability Zone. A separate data centre within an AWS region. |
| **Back-pressure** | A full queue causing the upstream processor to stop, instead of buffering forever. |
| **Bulletin** | A short error/warning surfaced in the NiFi UI. |
| **Cluster Coordinator** | The NiFi node that accepts joins and coordinates the cluster. Elected. |
| **Connection** | A queue between two processors. Has real size limits. |
| **Content repository** | Where the actual bytes of in-flight data live, on local disk. |
| **Controller service** | Shared configuration used by processors — a DB pool, an SSL context. |
| **Flow definition** | Portable JSON export of a process group. The unit that moves between versions. |
| **FlowFile** | One piece of data plus its metadata, moving through the flow. |
| **Ghost component** | A processor in an imported flow that no longer exists in this NiFi version. |
| **IMDSv2** | The token-based EC2 metadata service. Required to block a class of SSRF attacks. |
| **IRSA** | IAM Roles for Service Accounts — per-pod AWS permissions on EKS. |
| **NAT Gateway** | Lets private instances reach out to the internet, but not be reached. |
| **NAR** | NiFi Archive — the packaging format for processors and extensions. |
| **Parameter Context** | Named, reusable values for a process group. Replaced Variables in 2.x. |
| **Primary Node** | The one node that runs "primary node only" processors. Elected. |
| **Process Group** | A folder containing part of a flow. |
| **Processor** | A box that does one job to FlowFiles. |
| **Provenance** | The recorded history of every FlowFile — where it came from, what happened. |
| **PVC** | PersistentVolumeClaim. A Kubernetes request for a disk. |
| **Sensitive props key** | `nifi.sensitive.props.key` — encrypts secrets inside your flow. Do not lose it. |
| **StatefulSet** | Kubernetes object giving pods stable names, DNS and their own disks. |
| **Sticky session** | Load balancer sending one user's requests to the same node. Required by NiFi's UI. |
| **Template** | The old 1.x XML flow export. **Removed in 2.x.** |
| **ZooKeeper** | The service NiFi uses to elect its Coordinator and Primary Node. |

---

# Appendix C — Command cheat sheet

**Local**
```bash
cd local-mac && ./run.sh                 # start
./logs.sh [app|user|boot|req|dep]        # logs
./stop.sh                                # stop, keep data
./stop.sh --wipe                         # stop, delete everything
docker compose -f docker-compose.cluster.yml up -d    # 3-node cluster (~8GB RAM)
```

**Export / migrate**
```bash
cd migration
./export-everything.sh                   # flows + config + metadata
./audit-for-nifi2.sh                     # live pre-upgrade audit
./audit-for-nifi2.sh --flow flow.xml.gz  # deeper audit of a flow file
./import-flows.sh <dir> --dry-run
./import-flows.sh <dir>
```

**AWS CLI**
```bash
cd cli
cp config.env.example config.env
./00-preflight.sh                        # never skip
./deploy-all.sh
./08-verify.sh
./troubleshoot.sh
./06-nifi-nodes.sh --refresh-proxy       # after creating the ALB
./backup.sh
./destroy-all.sh
./orphan-hunt.sh                         # after EVERY teardown
```

**Terraform**
```bash
cd terraform
export TF_VAR_artifactory_password='...'
make plan VARS=example-single.tfvars
make apply
make output
make snapshot                            # BEFORE destroy
make destroy
```

**EKS**
```bash
cd eks
eksctl create cluster -f cluster.yaml    # 15-20 min
./install-controllers.sh
kubectl apply -f manifests/00-namespace.yaml
kubectl apply -f manifests/
kubectl -n nifi get pods,pvc,ingress
kubectl -n nifi logs nifi-0 -f
kubectl -n nifi port-forward nifi-0 8443:8443
eksctl delete cluster -f cluster.yaml --disable-nodegroup-eviction
```

**Reaching a private node**
```bash
aws ssm start-session --target <id>
aws ssm start-session --target <id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8443"],"localPortNumber":["8443"]}'
```

**Secrets**
```bash
aws secretsmanager get-secret-value --secret-id <p>/nifi-admin \
  --query SecretString --output text | jq -r .password
aws secretsmanager get-secret-value --secret-id <p>/sensitive-props-key \
  --query SecretString --output text        # SAVE THIS OUTSIDE AWS
```

**Logs on AWS**
```bash
aws logs filter-log-events --log-group-name /<p>/nifi \
  --filter-pattern "ERROR" --max-items 40 --query 'events[].message' --output text
```

---

*Built against Apache NiFi 2.10.0 (June 2026), Terraform ≥1.6 with AWS provider ~>5.60, and EKS 1.31. NiFi 1.x is end-of-life; CVE-2026-25903 requires NiFi 2.8.0 or later.*
