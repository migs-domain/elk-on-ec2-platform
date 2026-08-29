# ELK Platform on AWS — Documentation

## Table of Contents

1. [Prerequisites](#prerequisites)
2. [Architecture Overview](#architecture-overview)
3. [Repository Structure](#repository-structure)
4. [Bootstrap & First-Time Setup](#bootstrap--first-time-setup)
5. [Configuration Guide](#configuration-guide)
6. [TLS/Security Setup](#tlssecurity-setup)
7. [Ingestion Setup (Filebeat, Logstash, Fluentd)](#ingestion-setup)
8. [ILM Policies & Index Templates](#ilm-policies--index-templates)
9. [Monitoring & Alerting](#monitoring--alerting)
10. [Backups & DR](#backups--dr)
11. [Jenkins CI/CD Pipeline](#jenkins-cicd-pipeline)
12. [OS Selection Guide](#os-selection-guide)
13. [Rolling Upgrades](#rolling-upgrades)
14. [Operations Runbooks](#operations-runbooks)
15. [Dashboard Setup](#dashboard-setup)

> **New to any of these prerequisites?** See the step-by-step guides:
> - **[docs/prerequisites-setup.md](prerequisites-setup.md)** — IAM roles with exact policies, ACM certificate, Route 53
> - **[docs/jenkins-setup.md](jenkins-setup.md)** — Complete Jenkins installation, HTTPS config, credentials, pipeline job, troubleshooting

---

## Prerequisites

### Required Tools

| Tool          | Version   | Notes |
|---------------|-----------|-------|
| Terraform     | ≥ 1.6     | `brew install terraform` |
| Terragrunt    | ≥ 0.57    | `brew install terragrunt` |
| Packer        | ≥ 1.10    | `brew install packer` |
| AWS CLI       | ≥ 2.15    | Configure with SSO or keys |
| Ansible       | ≥ 2.16    | Only for Packer builds |
| jq            | any       | JSON parsing in scripts |
| OpenSSL       | ≥ 3.0     | TLS cert generation |

### AWS Prerequisites

For full step-by-step instructions on each item below, see **[prerequisites-setup.md](prerequisites-setup.md)**.

#### 1. AWS Accounts — single account or three

You can use **one AWS account** with three separate IAM roles (`TerraformDeployRole-dev/stable/prod`), or three fully separate accounts (better isolation for production). For learning, one account is fine.

#### 2. IAM Roles — TerraformDeployRole

Create one role per environment with this pattern:

- **Role name**: `TerraformDeployRole-dev` (repeat for stable, prod)
- **Policy**: A custom `TerraformDeployPolicy` that grants EC2, ASG, ELB, IAM (scoped), S3, KMS, SSM, Secrets Manager, CloudWatch, Route 53, ACM, CloudTrail, WAF, Firehose, DynamoDB, STS — see the [exact JSON in prerequisites-setup.md](prerequisites-setup.md#terraformdeployrole--exact-policy)
- **Trust relationship**: Allows your Jenkins EC2's IAM role (`JenkinsAgentRole`) to call `sts:AssumeRole` — see the [exact trust policy JSON in prerequisites-setup.md](prerequisites-setup.md#trust-relationship--how-jenkins-assumes-the-role)

> **Why not AdministratorAccess?** The scoped policy limits Terraform to only the services this project uses. `AdministratorAccess` works for a lab but is unsafe for anything shared.

**`JenkinsAgentRole`** — a minimal second role attached to the Jenkins EC2 instance. Its only permission is `sts:AssumeRole` on the three `TerraformDeployRole-*` ARNs. No access keys ever leave the instance; the AWS CLI and Terraform pick up credentials automatically via IMDS.

#### 3. ACM Certificate

You need an HTTPS certificate for the Kibana ALB. ACM provides free, auto-renewing certificates:

1. Request a certificate in ACM for `kibana.elk.yourdomain.com` (and optionally `*.elk.yourdomain.com`)
2. Validate ownership via DNS — ACM gives you a CNAME record to add to Route 53
3. Copy the resulting **Certificate ARN** and paste it into `infra-live/dev/us-east-1/alb/terragrunt.hcl`:
   ```hcl
   acm_certificate_arn = "arn:aws:acm:us-east-1:111111111111:certificate/YOUR-CERT-ARN"
   ```

See [prerequisites-setup.md → ACM Certificate Setup](prerequisites-setup.md#2-acm-certificate-setup) for the console walkthrough.

#### 4. Route 53 Hosted Zones

Two hosted zones are needed:

| Zone | Type | Purpose |
|------|------|---------|
| `yourdomain.com` | Public | External DNS for `kibana.elk.yourdomain.com` → ALB |
| `elk.internal` | Private (VPC-associated) | Internal node-to-node resolution |

After deploying the ALB (Step 6 of bootstrap), add a CNAME record pointing `kibana.elk.yourdomain.com` to the ALB DNS name output by Terraform.

See [prerequisites-setup.md → Route 53 Setup](prerequisites-setup.md#3-route-53-hosted-zone-setup) for step-by-step instructions.

#### 5. Jenkins — CI/CD Controller

Jenkins is the server that runs the Terraform pipeline. **If you have never used Jenkins before**, the full installation is in [prerequisites-setup.md → Jenkins Full Installation](prerequisites-setup.md#4-jenkins--full-installation-and-configuration). Summary:

1. Launch an Ubuntu 22.04 EC2 (`t3.medium`) with `JenkinsAgentRole` attached
2. Install Java 17, then Jenkins via the official apt repository
3. Install the required plugins: Pipeline, Git, Credentials Binding, AnsiColor, Timestamper, Slack, Workspace Cleanup
4. Install Terraform 1.7.5 + Terragrunt 0.57.0 + AWS CLI on the same instance
5. Create a Pipeline job pointing to the `Jenkinsfile` in this repository
6. Store three credentials (one per environment) of kind "Secret text" containing each `TerraformDeployRole-*` ARN

Jenkins does not need any AWS access keys configured — the `JenkinsAgentRole` instance profile handles authentication transparently.

#### 6. S3 + DynamoDB for Terraform State

Run the bootstrap script once before any `terragrunt apply`:
```bash
./scripts/bootstrap-remote-state.sh dev us-east-1
./scripts/bootstrap-remote-state.sh stable us-east-1
./scripts/bootstrap-remote-state.sh prod us-east-1
```
This creates the state S3 bucket (versioned, encrypted) and DynamoDB lock table.

### Network Prerequisites

- VPC CIDR plan per environment (defaults: dev=10.10.0.0/16, stable=10.20.0.0/16, prod=10.30.0.0/16)
- No CIDR overlaps if you plan VPC peering or Transit Gateway
- Your workstation/corporate IP for the bastion `bastion_allowed_cidrs` in `env.hcl`

---

## Architecture Overview

```
Internet
    │
    ▼
┌──────────────────────────────────────────────────────────────────┐
│  VPC (per environment)                                           │
│                                                                  │
│  Public Subnets (1-3 AZs)                                        │
│  ┌─────────────────┐    ┌───────────────┐                        │
│  │  ALB (Kibana)   │    │   Bastion     │                        │
│  │  ALB (App/Nginx)│    │   (SSH jump)  │                        │
│  └────────┬────────┘    └───────────────┘                        │
│           │                                                      │
│  Private Subnets (1-3 AZs)                                       │
│  ┌────────────────────────────────────────────────────────────┐  │
│  │  Elasticsearch Cluster                                     │  │
│  │  ┌─────────────┐  ┌─────────────┐  ┌─────────────────┐   │  │
│  │  │  3× Master  │  │ N× Data Hot │  │  N× Data Warm   │   │  │
│  │  │  (quorum)   │  │  (+ Content)│  │  (optional)     │   │  │
│  │  └─────────────┘  └─────────────┘  └─────────────────┘   │  │
│  │  ┌─────────────┐  ┌─────────────────────────────────┐    │  │
│  │  │ N× Ingest   │  │  N× Coordinating (optional)     │    │  │
│  │  └─────────────┘  └─────────────────────────────────┘    │  │
│  │                                                           │  │
│  │  ┌─────────────┐  ┌───────────┐  ┌──────────────────┐   │  │
│  │  │  N× Kibana  │  │N× Logstash│  │ App EC2 Hosts    │   │  │
│  │  │  (behind ALB)│  │  (S3 in) │  │ (Nginx+Filebeat  │   │  │
│  │  └─────────────┘  └───────────┘  │  +Fluentd)       │   │  │
│  │                                  └──────────────────┘   │  │
│  └────────────────────────────────────────────────────────────┘  │
│                                                                  │
│  VPC Endpoints: S3, SSM, Secrets Manager, KMS, CloudWatch, etc. │
└──────────────────────────────────────────────────────────────────┘
          │
          ▼
┌────────────────────────────────────────────┐
│  AWS Services                              │
│  S3 (snapshots, ALB logs, CloudTrail, WAF) │
│  CloudTrail, VPC Flow Logs, WAF ACL        │
│  SQS (event notifications for Logstash)    │
│  Kinesis Firehose (WAF → S3)               │
│  SSM Parameter Store (configs, certs)      │
│  Secrets Manager (passwords)               │
│  KMS (encryption keys)                     │
└────────────────────────────────────────────┘
```

### Port Matrix

| Source                  | Destination         | Port | Protocol | Notes |
|-------------------------|---------------------|------|----------|-------|
| Internet / corp         | ALB                 | 443  | HTTPS    | Kibana, App |
| ALB                     | Kibana nodes        | 5601 | HTTP     | Internal only |
| ALB                     | App hosts           | 80   | HTTP     | App traffic |
| Filebeat hosts          | ES Ingest nodes     | 9200 | HTTPS    | mTLS |
| Fluentd hosts           | ES Ingest nodes     | 9200 | HTTPS    | mTLS |
| Logstash nodes          | ES Ingest nodes     | 9200 | HTTPS    | mTLS |
| Filebeat hosts          | Logstash            | 5044 | Beats    | Optional |
| ES nodes (all)          | ES nodes (all)      | 9300 | Transport | mTLS |
| Metricbeat hosts        | ES HTTP             | 9200 | HTTPS    | Monitoring |
| Metricbeat hosts        | Logstash HTTP API   | 9600 | HTTP     | Monitoring |
| Metricbeat hosts        | Fluentd Prometheus  | 2020 | HTTP     | Metrics |
| Bastion                 | All nodes           | 22   | SSH      | Jump host |

---

## Repository Structure

```
elk-platform/
├── infra-modules/                # Reusable Terraform modules
│   ├── vpc/                      # VPC, subnets, IGW, NAT GW, flow logs
│   ├── vpc-endpoints/            # VPC Interface + Gateway endpoints
│   ├── security-groups/          # All SGs (ES master/data/ingest, Kibana, etc.)
│   ├── iam/                      # IAM roles + instance profiles per role
│   ├── s3-buckets/               # Snapshot, ALB, CloudTrail, WAF, access log buckets
│   ├── ec2-asg/                  # ASG + Launch Template (parameterized per role)
│   └── alb/                      # ALB for Kibana (internal) + App (public)
│
├── infra-live/                   # Terragrunt live config tree
│   ├── terragrunt.hcl            # Root: remote state, provider gen, shared inputs
│   ├── dev/
│   │   ├── env.hcl               # Dev-specific variables
│   │   └── us-east-1/
│   │       ├── vpc/
│   │       ├── vpc-endpoints/
│   │       ├── security-groups/
│   │       ├── iam/
│   │       ├── s3-buckets/
│   │       ├── alb/
│   │       ├── es-masters/
│   │       ├── es-data-hot/
│   │       ├── es-ingest/
│   │       ├── kibana/
│   │       └── logstash/
│   ├── stable/                   # Same layout; 3-AZ sizing
│   └── prod/                     # Same layout; prod sizing + optional warm tier
│
├── packer/                       # AMI builds
│   ├── elk-node.pkr.hcl          # Main Packer template (Ubuntu 22.04)
│   ├── scripts/                  # install-elastic.sh, os-hardening.sh, etc.
│   ├── ansible/                  # site.yml + roles/ for node config in AMI
│   └── vars/                     # dev.pkrvars.hcl, prod.pkrvars.hcl
│
├── configs/
│   ├── elasticsearch/            # Per-role elasticsearch.yml + JVM options + ILM
│   ├── logstash/                 # logstash.yml, pipelines.yml, pipelines/
│   ├── fluentd/                  # fluent-bit.conf, parsers.conf
│   ├── filebeat/                 # filebeat.yml, modules.d/
│   └── metricbeat/               # metricbeat.yml, modules.d/
│
├── scripts/
│   ├── bootstrap-remote-state.sh
│   ├── generate-tls-certs.sh
│   ├── setup-es-rbac.sh
│   └── verify-snapshot.sh
│
├── Jenkinsfile                   # CI/CD pipeline
├── CHANGELOG.md
└── docs/                         # This documentation tree
```

---

## Bootstrap & First-Time Setup

### Step 1: Bootstrap Terraform state

```bash
export ORG_PREFIX="acme"
export PROJECT="elk"
./scripts/bootstrap-remote-state.sh dev us-east-1
./scripts/bootstrap-remote-state.sh stable us-east-1
./scripts/bootstrap-remote-state.sh prod us-east-1
```

### Step 2: Update environment variables

Edit `infra-live/<env>/env.hcl` with:
- Real AWS account IDs
- Terraform role ARNs
- VPC CIDRs
- ACM certificate ARN (created separately in ACM)
- Bastion CIDR

### Step 3: Build AMIs with Packer

```bash
cd packer/
export PACKER_VPC_ID="vpc-xxxxxxxxxxxxx"
export PACKER_SUBNET_ID="subnet-xxxxxxxxxxxxx"
export ELK_VERSION="8.12.2"
export AWS_REGION="us-east-1"

# Build all roles (parallel recommended in CI)
./build-all-amis.sh --parallel
```

### Step 4: Generate TLS certificates

```bash
export AWS_REGION="us-east-1"
export SSM_PREFIX="/elk/dev"
export CLUSTER_NAME="acme-elk-dev-cluster"
export ELASTIC_VERSION="8.12.2"

./scripts/generate-tls-certs.sh
```

### Step 5: Store secrets in AWS Secrets Manager

```bash
# These passwords are used by setup-es-rbac.sh and by node bootstrap
aws secretsmanager create-secret \
  --name /elk/dev/elastic-password \
  --secret-string '{"password":"REPLACE_WITH_STRONG_PASSWORD"}' \
  --region us-east-1

aws secretsmanager create-secret \
  --name /elk/dev/filebeat-password \
  --secret-string '{"password":"REPLACE_WITH_STRONG_PASSWORD"}' \
  --region us-east-1

# Repeat for logstash-password, fluentd-password, metricbeat-password,
# kibana-system-password, kibana-encryption-key
```

### Step 6: Deploy infrastructure

```bash
cd infra-live/dev/us-east-1

# Deploy in dependency order
terragrunt apply --terragrunt-working-dir vpc
terragrunt apply --terragrunt-working-dir vpc-endpoints
terragrunt apply --terragrunt-working-dir security-groups
terragrunt apply --terragrunt-working-dir iam
terragrunt apply --terragrunt-working-dir s3-buckets
terragrunt apply --terragrunt-working-dir alb
terragrunt apply --terragrunt-working-dir es-masters
terragrunt apply --terragrunt-working-dir es-data-hot
terragrunt apply --terragrunt-working-dir es-ingest
terragrunt apply --terragrunt-working-dir kibana
terragrunt apply --terragrunt-working-dir logstash

# Or run all at once (Terragrunt handles dependency ordering)
terragrunt run-all apply
```

### Step 7: Post-deployment RBAC setup

```bash
export ES_HOST="https://es-ingest.acme-elk-dev.internal:9200"
export ELASTIC_PASSWORD="$(aws secretsmanager get-secret-value \
  --secret-id /elk/dev/elastic-password --query SecretString --output text | jq -r .password)"
export CA_CERT="/path/to/ca.crt"
export FILEBEAT_PASSWORD="..."
export LOGSTASH_PASSWORD="..."
export FLUENTD_PASSWORD="..."
export METRICBEAT_PASSWORD="..."
export KIBANA_SYSTEM_PASSWORD="..."

./scripts/setup-es-rbac.sh
```

### Step 8: Apply ILM policies and SLM

```bash
# Apply ILM policy for environment
curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
  -X PUT "${ES_HOST}/_ilm/policy/logs-dev-ilm-policy" \
  -H "Content-Type: application/json" \
  -d @configs/elasticsearch/ilm/dev-policy.json \
  --cacert $CA_CERT

# Register S3 snapshot repository
curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
  -X PUT "${ES_HOST}/_snapshot/s3_repository" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "s3",
    "settings": {
      "bucket": "acme-elk-dev-snapshots-<account_id>",
      "region": "us-east-1",
      "base_path": "elasticsearch-snapshots",
      "compress": true
    }
  }' --cacert $CA_CERT

# Apply SLM policy
curl -sk -u "elastic:${ELASTIC_PASSWORD}" \
  -X PUT "${ES_HOST}/_slm/policy/dev-daily-snapshot" \
  -H "Content-Type: application/json" \
  -d @configs/elasticsearch/slm/slm-policies.json \
  --cacert $CA_CERT
```

---

## TLS/Security Setup

### Certificate Authority Structure

```
Internal CA (elastic-stack-ca.p12)
├── es-master.crt    (transport + HTTP)
├── es-data.crt      (transport + HTTP)
├── es-ingest.crt    (transport + HTTP)
├── es-coord.crt     (transport + HTTP)
├── kibana.crt       (HTTP to ES)
├── logstash.crt     (mTLS to ES: logstash_writer identity)
├── filebeat.crt     (mTLS to ES: filebeat_writer identity)
├── fluentd.crt      (mTLS to ES: fluentd_writer identity)
└── metricbeat.crt   (mTLS to ES: remote_monitoring_user)
```

### Certificate Rotation Procedure

1. Generate new CA + certs: `./scripts/generate-tls-certs.sh`
2. New certs uploaded to SSM; nodes pull on next restart
3. Rolling restart masters → data → ingest → coord → kibana
4. Use `/_nodes/hot_threads` to verify each node reconnects before proceeding

### SSO for Kibana (Optional)

Kibana supports SAML/OIDC via `xpack.security.authc`:
```yaml
# kibana.yml addition
xpack.security.authc.providers:
  saml.saml1:
    order: 0
    realm: saml1
    description: "Log in with your company SSO"
    icon: "logoSecurity"
```
Configure the SAML realm in `elasticsearch.yml` on masters. Document IdP metadata URL and SP ACS URL.

---

## Ingestion Setup

### Filebeat (System + Nginx)

Deployed on app-host EC2 instances. Modules: `system`, `nginx`.

```bash
# On the app host (userdata handles this; manual steps shown for clarity)
filebeat modules enable nginx system
filebeat setup --pipelines -e  # Creates ingest pipelines in ES

# Test
filebeat test config -e
filebeat test output
```

### Logstash (S3 → ALB, VPC Flow, CloudTrail, WAF)

Logstash polls SQS queues backed by S3 event notifications. To set up S3 → SQS notifications:

```bash
# In the AWS Console or via Terraform (s3-buckets module):
# Enable S3 event notifications → SQS queue for each log bucket
# The SQS queue ARN is passed to the logstash IAM role
```

Pipeline configs in `configs/logstash/pipelines/`.

### Fluentd / Fluent Bit (App JSON logs)

Deployed alongside Nginx on app-host nodes. Config at `configs/fluentd/fluent-bit.conf`.
Prometheus metrics exposed on port 2020 for Metricbeat scraping.

```bash
# Test Fluent Bit config
fluent-bit --config /etc/fluent-bit/fluent-bit.conf --dry-run
```

---

## ILM Policies & Index Templates

| Environment | Hot → Warm | Warm → Delete | Rollover |
|-------------|-----------|---------------|----------|
| dev         | (none)    | 7d            | 40GB or 1d |
| stable      | 7d        | 30d           | 40GB or 1d |
| prod        | 14d → cold 60d | 180d    | 40GB or 1d |

Apply policies via the scripts in `configs/elasticsearch/ilm/`.

---

## OS Selection Guide

| OS | Pros | Cons |
|----|------|------|
| **Ubuntu 22.04 LTS** *(default)* | Best Elastic docs support, largest community, Canonical 5yr LTS, `apt` ecosystem matches Elastic .deb packages | Not a RHEL variant; some enterprise security tools expect RHEL-compatible |
| Amazon Linux 2023 | Tight AWS integration, faster boot, SSM by default, AWS support | Shorter LTS window; some Elastic docs reference Debian paths |
| Rocky Linux 9 | RHEL-compatible, enterprise hardening, CIS images available | Smaller community than Ubuntu; `dnf` ecosystem differs slightly |

**Recommendation**: Ubuntu 22.04 LTS as default. Switch via `os_type` Packer variable.

### AMI IDs (us-east-1, as of 2024)

| OS | AMI ID | Owner |
|----|--------|-------|
| Ubuntu 22.04 LTS | ami-0e001c9271cf7f3b9 | 099720109477 (Canonical) |
| Amazon Linux 2023 | ami-0c101f26f147fa7fd | 137112412989 (Amazon) |
| Rocky Linux 9 | ami-07a97eb6c4ec9f5b9 | 792107900819 (Rocky) |

> Note: AMIs change frequently. Use the data source in Packer/Terraform to always get the latest.

---

## Rolling Upgrades

### Procedure (8.x → 8.y)

1. Disable shard allocation: `PUT /_cluster/settings {"persistent": {"cluster.routing.allocation.enable": "primaries"}}`
2. Build new AMIs with target version via Packer
3. Update `elk_version` in `env.hcl` and `infra-live/<env>/<region>/es-masters/terragrunt.hcl`
4. Trigger Jenkins pipeline with `ACTION=apply`; instance refresh handles rolling restart
5. Verify each node joins before proceeding: `GET /_cat/nodes?v`
6. Re-enable allocation: `PUT /_cluster/settings {"persistent": {"cluster.routing.allocation.enable": null}}`
7. Repeat for data-hot → data-warm → ingest → coord → kibana → logstash

---

## Operations Runbooks

### Restore Snapshot to Dev

```bash
# List available snapshots
curl -sk -u "elastic:$ELASTIC_PASSWORD" \
  "${ES_HOST}/_cat/snapshots/s3_repository?v&format=json" --cacert $CA_CERT

# Restore specific snapshot (close target indices first)
curl -sk -u "elastic:$ELASTIC_PASSWORD" \
  -X POST "${ES_HOST}/_snapshot/s3_repository/<snapshot-name>/_restore" \
  -H "Content-Type: application/json" \
  -d '{"indices": "logs-aws.alb-*", "rename_pattern": "(.+)", "rename_replacement": "restored_$1"}' \
  --cacert $CA_CERT
```

### DR: Cross-Region Snapshot Copy

For prod, enable CRR on the S3 snapshot bucket or use a scheduled Lambda to copy snapshots:

```bash
# Manual cross-region copy
aws s3 sync \
  s3://acme-elk-prod-snapshots-<account-id>/elasticsearch-snapshots/ \
  s3://acme-elk-prod-snapshots-dr-<account-id>/elasticsearch-snapshots/ \
  --source-region us-east-1 \
  --region eu-west-1
```

### Scaling Data Nodes

```bash
# Update desired_capacity in terragrunt.hcl
# Then apply — ASG handles gradual addition; ES rebalances automatically

# Monitor rebalancing
watch -n5 'curl -sk -u elastic:$PASS "$ES_HOST/_cat/recovery?active_only&v"'
```

### Troubleshooting Heap Pressure

1. `GET /_nodes/stats/jvm` — check heap_used_percent
2. If heap > 85%: force GC → `POST /_nodes/<node>/_flush`
3. Check for large aggregation queries in slow_log: `/var/log/elasticsearch/*_index_search_slowlog.log`
4. Check for mapping explosions: `GET /_cat/fielddata?v&s=size:desc`

---

## Dashboard Setup

### Import Dashboards

```bash
# Import Filebeat dashboards
filebeat setup --dashboards -e

# Import Metricbeat dashboards
metricbeat setup --dashboards -e

# Import custom NDJSON dashboards
curl -sk -u "elastic:$ELASTIC_PASSWORD" \
  -X POST "${KIBANA_HOST}/api/saved_objects/_import" \
  -H "kbn-xsrf: true" \
  -H "Content-Type: multipart/form-data" \
  -F "file=@dashboards/elk-platform-dashboards.ndjson" \
  --cacert $CA_CERT
```

### Available Dashboards

| Dashboard | Data Source | Purpose |
|-----------|-------------|---------|
| ALB Latency / 5xx | `logs-aws.alb-*` | ALB request latency, error rates |
| VPC Top Talkers | `logs-aws.vpcflow-*` | Top source/dest IPs by bytes |
| CloudTrail Activity | `logs-aws.cloudtrail-*` | API calls, security events |
| ES JVM/Heap/GC | Metricbeat | Heap usage, GC pause times, node health |
| Logstash Throughput | Metricbeat | Events in/out, pipeline backpressure, DLQ depth |
| Fluent Bit Metrics | Metricbeat/Prometheus | Buffer fill, retry rates, plugin throughput |
| Filebeat Harvesters | Metricbeat | Harvester states, backlog |

---

## Cost Hygiene Notes

- **VPC Endpoints** eliminate NAT Gateway data charges for S3, SSM, KMS, CloudWatch (~\$45/mo per NAT GW avoided for high-throughput deployments)
- **ILM retention** prevents unbounded storage growth; tune per SLO
- **Right-sizing**: dev uses single-AZ spot-friendly instances; prod uses on-demand RI/SP with savings plan
- **EBS gp3** over gp2: ~20% cheaper, configurable IOPS/throughput without overprovisioning
- **Log rotation**: configured on all nodes via JVM GC log rotation flags + logrotate for service logs
- **S3 lifecycle on log buckets**: move to Glacier after 90d for CloudTrail/VPC flow logs you rarely query
