# Changelog

All notable changes to the ELK Platform on AWS are documented here.
Follows [Keep a Changelog](https://keepachangelog.com/en/1.0.0/) format.
Uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

---

## [1.0.0] — 2024-01-15

### Added

#### Infrastructure (infra-modules)
- **vpc**: Per-environment VPC with public/private subnets, IGW, NAT GW (HA per AZ), VPC flow logs
- **vpc-endpoints**: S3 Gateway + Interface endpoints (SSM, Secrets Manager, KMS, CloudWatch, EC2, ELB, STS) to eliminate NAT data charges
- **security-groups**: Least-privilege SGs for bastion, ES master/data/ingest, Kibana, Logstash, Fluentd, Filebeat hosts, ALB, monitoring
- **iam**: Least-privilege IAM roles for Elasticsearch, Logstash, Kibana, app-host, and snapshot operations; separate policies per capability
- **s3-buckets**: KMS-encrypted, versioned, blocked-public S3 buckets for snapshots, ALB logs, CloudTrail, VPC flow logs, WAF logs, S3 access logs; CloudTrail trail, Kinesis Firehose for WAF, WAF Web ACL
- **ec2-asg**: Generalized ASG + Launch Template module for any node role with IMDSv2, gp3 data volumes, and parameterized user-data bootstrap
- **alb**: Internal ALB for Kibana + public ALB for app hosts; TLS 1.3 only; WAF association; ALB access logging

#### Infrastructure (infra-live)
- **dev/us-east-1**: Full environment config: VPC, endpoints, SGs, IAM, S3, ALB, ES masters (3×m6i.large), data-hot (1×r6i.xlarge), ingest, Kibana, Logstash
- **stable/us-east-1**: 3-AZ HA config: 3 masters, 2× r6i.2xlarge data-hot, 2× ingest, 2× Kibana, 2× Logstash
- **prod/us-east-1**: 3-AZ production config: 3 masters, 3× r6i.2xlarge data-hot, optional warm tier, 2-3× ingest, 2× coord, 2× Kibana, 2× Logstash
- Root `terragrunt.hcl` with S3+DynamoDB remote state, provider generation, assume-role per environment

#### AMI Builds (Packer)
- `elk-node.pkr.hcl`: Single template builds all 7 node roles (es-master, es-data, es-ingest, es-coord, kibana, logstash, app-host)
- IMDSv2-enforced AMIs; encrypted boot volumes; AMI version tracking via manifest
- Scripts: `install-elastic.sh`, `install-monitoring-agents.sh`, `install-role-extras.sh`, `os-hardening.sh`, `configure-systemd.sh`
- CIS-aligned OS hardening: SSH restrictions, sysctl hardening, swap disabled, auditd, fail2ban, unattended-upgrades

#### Elasticsearch Configs
- Per-role `elasticsearch.yml`: master, data-hot, data-warm, ingest (no data, high thread pool)
- JVM options: G1GC, GC logging with rotation, heap dump on OOM, JDK 17 modules
- xpack.security enabled on all roles; transport mTLS, HTTP TLS enforced
- EC2 discovery via tags (`ClusterName`, `NodeRole`)

#### Logstash Pipelines
- **ALB access logs** (`alb-logs.conf`): dissect parsing, GeoIP, UserAgent, ECS normalization, ILM output
- **VPC Flow Logs** (`vpc-flow-logs.conf`): dissect v5 fields, timestamp parsing, RFC1918-aware GeoIP, protocol name translation
- **CloudTrail** (`cloudtrail.conf`): Records array split, GeoIP, ECS normalization
- **WAF** (`waf-logs.conf`): JSON Firehose format, GeoIP, ECS normalization
- `pipelines.yml`: Persistent queue (4GB each), DLQ enabled per pipeline
- `logstash.yml`: HTTP API, config reload, JSON logging

#### Fluent Bit
- `fluent-bit.conf`: App JSON, Nginx access/error, systemd journal inputs; ECS normalization; ES mTLS output with filesystem buffering
- `parsers.conf`: JSON, nginx_combined, nginx_error, syslog, docker parsers
- Prometheus metrics endpoint on port 2020

#### Filebeat
- `filebeat.yml`: mTLS output to ES, ILM, bulk settings
- Modules: `nginx.yml`, `system.yml`

#### Metricbeat
- `metricbeat.yml`: System metrics + stack monitoring output
- Modules: `elasticsearch.yml` (xpack), `logstash.yml` (xpack), `system.yml`, `prometheus.yml` (Fluent Bit metrics)

#### ILM Policies
- `dev-policy.json`: hot → delete at 7d
- `stable-policy.json`: hot 7d → warm 21d → delete at 30d
- `prod-policy.json`: hot 14d → warm 60d → cold 90d → delete at 180d

#### Monitoring & Alerting
- Elasticsearch Watcher alerts: JVM heap >80%, unassigned shards, disk watermark >75%, Logstash PQ near capacity
- `verify-snapshot.sh`: Cron-based snapshot age and status verification with Slack alerting

#### Security & TLS
- `generate-tls-certs.sh`: CA + per-node + per-shipper certs via elasticsearch-certutil; uploads to SSM
- `setup-es-rbac.sh`: Creates filebeat_writer, logstash_writer, fluentd_writer, metricbeat_monitoring users with least-privilege roles
- All passwords stored in AWS Secrets Manager; never committed to git
- `.gitignore` excludes `*.key`, `*.p12`, `*.crt`, `tfplan*`

#### CI/CD (Jenkins)
- `Jenkinsfile`: 10-stage pipeline — checkout → setup → lint → validate → plan → approval → apply → smoke tests → destroy
- Manual approval gate for stable and prod
- Slack notifications on plan and result
- Plan artifacts archived per build
- Credential management via Jenkins credentials store + SSM/Secrets Manager

#### Documentation
- `docs/README.md`: Full installation, architecture, security, ingestion, ILM, monitoring, DR, upgrades
- Port matrix, OS selection guide (Ubuntu/AL2023/Rocky9 pros/cons + AMI IDs)
- Dashboard setup and NDJSON import instructions
- Cost hygiene notes

### Design Decisions / Deviations from Spec

1. **Fluent Bit instead of Fluentd**: Used Fluent Bit (v3.x) as the implementation of "Fluentd" — it is the modern successor, written in C, lower memory footprint, ships Prometheus metrics natively, and is supported by AWS. Where the spec says "Fluentd", Fluent Bit is the deployed agent. Pure Fluentd (td-agent) is available as an alternative; parameterize via Packer `install-role-extras.sh`.

2. **EC2 discovery (not seed hosts)**: Used `discovery.seed_providers: ec2` with tag-based discovery. This is more maintainable than a static seed list in ASG environments where IPs change. Requires the EC2 discovery plugin (bundled in ES 8.x) and the correct IAM `ec2:DescribeInstances` permission.

3. **IMDSv2 required**: Enforced on both Packer builds and Launch Templates. Some older agents may need configuration to use the token endpoint; handled in bootstrap script.

4. **Coordinating nodes in prod only**: Optional in dev/stable. The `es-coord` module exists but is not in the dev/stable live configs. Add as needed when Kibana query volume justifies it.

5. **Logstash `logstash-input-kinesis` vs SQS**: Both are provided. SQS-backed ingestion (S3 event notifications → SQS → Logstash S3 input) is preferred as it's event-driven and more cost-effective than Kinesis at moderate volume.

---

## Version Policy

- **Major versions** (X.0.0): Breaking changes to module APIs, major topology changes
- **Minor versions** (1.X.0): New features, new data sources, new environments
- **Patch versions** (1.0.X): Bug fixes, config tuning, security patches

## ELK Version Pinning

Elastic Stack version is pinned at `8.12.2` and enforced in:
- `infra-live/*/env.hcl` → `elk_version`
- `packer/elk-node.pkr.hcl` → `elk_version` variable default
- `infra-modules/ec2-asg/variables.tf` → `elk_version` variable default

To upgrade, update all three locations and rebuild AMIs before applying infra changes.
