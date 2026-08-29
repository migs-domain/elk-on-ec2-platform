# Security — Secrets and Sensitive Files

## NEVER commit these files to git

### TLS Materials
*.key
*.p12
*.csr
ca.crt  # (git-ignored; fetched from SSM at runtime)

### Terraform state
*.tfstate
*.tfstate.*
.terraform/
tfplan.binary

### Secrets
.env
.env.*
secrets.yml
secrets.json
*-password*
*_password*
*_secret*

### Packer manifest (contains AMI IDs — not secret but noisy)
packer-manifest.json
manifests/

### Logs
logs/*.log

### Editor
.idea/
.vscode/
*.swp
*.swo

## Secrets management

All secrets are stored in:
- **AWS Secrets Manager**: Passwords (elastic, kibana_system, filebeat_writer, logstash_writer, etc.)
- **AWS SSM Parameter Store** (SecureString): TLS certificates, configs with embedded credentials
- **AWS KMS**: Encryption of SSM parameters and S3 buckets

## Fetching secrets at runtime

Nodes bootstrap via userdata.sh.tpl which calls:
```bash
aws secretsmanager get-secret-value --secret-id /elk/<env>/elastic-password
aws ssm get-parameter --name /elk/<env>/certs/node.crt --with-decryption
```

No secrets should ever appear in:
- Git commits
- CloudWatch Logs (mask with log4j PatternLayout)
- EBS snapshots of root volumes (data volumes are separate, encrypted)
- Terraform state files (never store passwords in TF vars/state; use SSM data sources)
