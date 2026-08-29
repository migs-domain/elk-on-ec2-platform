# Prerequisites — Detailed Setup Guide

This guide walks through every prerequisite from scratch. It assumes you have:
- An AWS account (or three)
- A workstation running macOS, Linux, or WSL2

---

## Table of Contents

1. [AWS Account & IAM Setup](#1-aws-account--iam-setup)
   - [Option A — Single account with separate roles](#option-a--single-account-with-separate-roles)
   - [Option B — Three separate accounts](#option-b--three-separate-accounts)
   - [TerraformDeployRole — exact policy](#terraformdeployrole--exact-policy)
   - [Trust relationship — how Jenkins assumes the role](#trust-relationship--how-jenkins-assumes-the-role)
2. [ACM Certificate Setup](#2-acm-certificate-setup)
3. [Route 53 Hosted Zone Setup](#3-route-53-hosted-zone-setup)
4. [Jenkins — Full Installation and Configuration](#4-jenkins--full-installation-and-configuration)
5. [Local Workstation Tools](#5-local-workstation-tools)

---

## 1. AWS Account & IAM Setup

### How Terraform + Jenkins access AWS

The pattern used in this project is **IAM role assumption**:

```
Jenkins agent (EC2 instance)
  has IAM instance role: JenkinsAgentRole
    └─ permission: sts:AssumeRole on TerraformDeployRole-dev/stable/prod

TerraformDeployRole-dev
  └─ permission: create/modify/destroy all resources in the account
  └─ trust: allows JenkinsAgentRole to assume it
```

This means:
- Terraform credentials are **never stored as access keys** — they are temporary STS tokens
- Each environment has its own role → blast radius is contained
- If the Jenkins agent is compromised, the attacker can only assume the roles that trust it

---

### Option A — Single account with separate roles

Use this for learning or cost saving. Create three roles in one account:
- `TerraformDeployRole-dev`
- `TerraformDeployRole-stable`
- `TerraformDeployRole-prod`

Each role has the same policy (shown below) but you can restrict them with resource-level conditions.

### Option B — Three separate accounts (recommended for prod)

Better isolation. Create one `TerraformDeployRole` per account with the same trust pointing to the Jenkins agent's account/role ARN.

---

### TerraformDeployRole — exact policy

Create this as a **customer managed policy** named `TerraformDeployPolicy` and attach it to the role.

This grants the permissions Terraform needs to create all ELK platform resources.  
It is **not** `AdministratorAccess` — it is scoped to the services used by this project.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "EC2Full",
      "Effect": "Allow",
      "Action": [
        "ec2:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "AutoScaling",
      "Effect": "Allow",
      "Action": [
        "autoscaling:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ELB",
      "Effect": "Allow",
      "Action": [
        "elasticloadbalancing:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "IAMRolesAndProfiles",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:ListInstanceProfilesForRole",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:PassRole",
        "iam:TagRole",
        "iam:UntagRole",
        "iam:CreatePolicy",
        "iam:DeletePolicy",
        "iam:CreatePolicyVersion",
        "iam:DeletePolicyVersion",
        "iam:GetPolicy",
        "iam:GetPolicyVersion",
        "iam:ListPolicyVersions",
        "iam:SetDefaultPolicyVersion",
        "iam:ListRoles",
        "iam:UpdateAssumeRolePolicy"
      ],
      "Resource": "*"
    },
    {
      "Sid": "S3Full",
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "KMS",
      "Effect": "Allow",
      "Action": [
        "kms:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SSM",
      "Effect": "Allow",
      "Action": [
        "ssm:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SecretsManager",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudWatch",
      "Effect": "Allow",
      "Action": [
        "logs:*",
        "cloudwatch:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Route53",
      "Effect": "Allow",
      "Action": [
        "route53:*",
        "route53domains:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "ACM",
      "Effect": "Allow",
      "Action": [
        "acm:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "CloudTrail",
      "Effect": "Allow",
      "Action": [
        "cloudtrail:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "WAF",
      "Effect": "Allow",
      "Action": [
        "wafv2:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "Firehose",
      "Effect": "Allow",
      "Action": [
        "firehose:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "DynamoDB",
      "Effect": "Allow",
      "Action": [
        "dynamodb:*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "STSAssumeRoleForPacker",
      "Effect": "Allow",
      "Action": [
        "sts:AssumeRole",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Sid": "SQS",
      "Effect": "Allow",
      "Action": [
        "sqs:*"
      ],
      "Resource": "*"
    }
  ]
}
```

> **Why not just use `AdministratorAccess`?**
> You *can* for a learning environment. The policy above is already broader than strictly needed — it grants `*` on most services. In a mature environment you would scope resource ARNs (e.g., `arn:aws:s3:::acme-elk-*`) to prevent Terraform from touching unrelated infrastructure. For initial setup, this policy is safe and explicit.

---

### Trust relationship — how Jenkins assumes the role

When you create `TerraformDeployRole-dev` in the IAM console, the **Trust Policy** tab controls who can assume it. Replace the values:

- `JENKINS_ACCOUNT_ID` → the AWS account ID where your Jenkins EC2 lives
- `JenkinsAgentRole` → the IAM role attached to your Jenkins EC2 instance (created in [Section 4](#4-jenkins--full-installation-and-configuration))

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "JenkinsTrustDev",
      "Effect": "Allow",
      "Principal": {
        "AWS": "arn:aws:iam::JENKINS_ACCOUNT_ID:role/JenkinsAgentRole"
      },
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": "elk-platform-dev"
        }
      }
    }
  ]
}
```

> **What is `ExternalId`?**  
> It is an optional secret token that prevents the "confused deputy" problem — someone else who knows your role ARN cannot assume it from their Jenkins unless they also know the ExternalId. Use a different value per environment. Store it in Jenkins credentials.

If you use **Option B** (3 separate accounts), you repeat the same trust policy in each account's `TerraformDeployRole`, pointing the principal at the Jenkins account.

---

### Step-by-step: Create the role in AWS Console

1. Open **IAM → Roles → Create role**
2. Select **"AWS account"** as trusted entity type
3. Enter the Jenkins account ID
4. Click **Next**, attach the `TerraformDeployPolicy` you created above
5. Name the role: `TerraformDeployRole-dev`
6. After creation, go to the **Trust relationships** tab and click **Edit trust policy**
7. Paste the trust policy JSON above, replace placeholders, save

Repeat for `-stable` and `-prod`.

---

### Create JenkinsAgentRole (attached to the Jenkins EC2)

This is a separate, **minimal** role. It only needs to call `sts:AssumeRole` on the deploy roles.

**Trust policy** (allows EC2 to use this role):
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

**Permission policy** attached to `JenkinsAgentRole`:
```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeDeployRoles",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::DEV_ACCOUNT_ID:role/TerraformDeployRole-dev",
        "arn:aws:iam::STABLE_ACCOUNT_ID:role/TerraformDeployRole-stable",
        "arn:aws:iam::PROD_ACCOUNT_ID:role/TerraformDeployRole-prod"
      ]
    },
    {
      "Sid": "AllowGetCallerIdentity",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

Attach this role to the Jenkins EC2 **instance profile** when you launch it (see Section 4).

---

## 2. ACM Certificate Setup

The ALB for Kibana requires an HTTPS certificate. ACM (AWS Certificate Manager) provides free, auto-renewing certificates.

### What domain to use

You need a domain you control. For this project, decide on a subdomain like:
```
kibana.elk.yourdomain.com
```

If you don't have a domain, you can:
- Register one cheaply via Route 53 (~$12/yr for a `.com`)
- Use a free subdomain from a service like `nip.io` for testing (not for TLS)

### Steps in AWS Console

1. Open **ACM → Request certificate**
2. Select **"Request a public certificate"**, click Next
3. Enter the domain name: `kibana.elk.yourdomain.com`
   - Add a wildcard too for flexibility: `*.elk.yourdomain.com`
4. Select **DNS validation** (easier to automate than email)
5. Click **Request**
6. ACM shows you a **CNAME record** to add to your DNS. Copy the Name and Value.
7. In **Route 53 → Hosted zones → yourdomain.com → Create record**:
   - Type: CNAME
   - Name: paste the ACM-provided name (e.g. `_abc123.kibana.elk.yourdomain.com`)
   - Value: paste the ACM-provided value (e.g. `_def456.acm-validations.aws.`)
   - TTL: 300
8. Wait 2–5 minutes. ACM will flip to **"Issued"** status automatically.
9. Copy the **Certificate ARN** — it looks like `arn:aws:acm:us-east-1:111111111111:certificate/xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`
10. Paste it into `infra-live/dev/us-east-1/alb/terragrunt.hcl`:
    ```hcl
    acm_certificate_arn = "arn:aws:acm:us-east-1:111111111111:certificate/YOUR-CERT-ARN"
    ```

> **Certificate renewal**: ACM auto-renews as long as the CNAME record remains in DNS. Never delete it.

---

## 3. Route 53 Hosted Zone Setup

Route 53 is used for internal DNS records so that nodes can find each other by hostname (e.g. `es-ingest.elk.internal`) and for the external Kibana URL.

### Create a public hosted zone (for external Kibana URL)

1. Open **Route 53 → Hosted zones → Create hosted zone**
2. Domain name: `yourdomain.com` (or the subdomain you own)
3. Type: **Public hosted zone**
4. Click **Create**
5. Route 53 gives you **4 NS (nameserver) records** — update your domain registrar to point to these nameservers if Route 53 is not already your DNS provider

### Create a private hosted zone (for internal node communication)

1. **Route 53 → Hosted zones → Create hosted zone**
2. Domain name: `elk.internal` (or `elk.yourdomain.internal`)
3. Type: **Private hosted zone**
4. Associate with VPC: select your dev/stable/prod VPC (you'll add more VPCs after they are created by Terraform)
5. Click **Create**

### What records get created

The Terraform modules do not currently create Route 53 records automatically — they output the ALB DNS name that you then add manually, or you can add a `route53` module. Here are the records to create manually after deployment:

| Record | Type | Value | Purpose |
|--------|------|-------|---------|
| `kibana.elk.yourdomain.com` | CNAME | ALB DNS name from Terraform output | Public Kibana access |
| `es-ingest.elk.internal` | A (or CNAME) | Private IP of ingest ASG | Internal shipper routing |

To get the Kibana ALB DNS name after apply:
```bash
cd infra-live/dev/us-east-1/alb
terragrunt output kibana_alb_dns_name
```

Then in Route 53:
1. Go to your **public** hosted zone
2. Create record: `kibana.elk.yourdomain.com` → CNAME → paste the ALB DNS name
3. TTL: 60 seconds (low for easier updates)

---

## 4. Jenkins — Full Installation and Configuration

Jenkins is the CI/CD server that runs the Terraform pipeline. The Jenkins setup for
this project is documented in full detail in its own guide:

### 👉 [docs/jenkins-setup.md](jenkins-setup.md) — Complete Jenkins guide

That guide covers everything from zero, specific to this project:

| What it covers | Why it matters here |
|----------------|---------------------|
| **Architecture diagram** — controller + agent + AWS | Shows exactly how Jenkins talks to AWS without access keys |
| **IAM prerequisite** — `JenkinsAgentRole` creation with exact policy JSON | The instance profile the EC2 must have at launch time |
| **EC2 launch settings** — AMI, instance type, security group rules, storage | Exact values, not "pick a t3" |
| **Security group port table** | Ports 443, 22, 8080 — which source CIDRs, which to remove after Nginx |
| **Java 17 install** | Jenkins will not start without it |
| **Jenkins LTS install** — from the official signed apt repo | Not the outdated OS version |
| **Nginx HTTPS reverse proxy** — with full config block | Puts TLS in front of Jenkins so credentials aren't sent over HTTP |
| **Setup wizard walkthrough** | Initial password, plugin install, admin user, URL |
| **Required plugins table** — 9 plugins with ID and exactly which line in Jenkinsfile uses each | Precise — no trial and error |
| **Terraform 1.7.5, Terragrunt 0.57.0, Packer 1.10.3, AWS CLI v2** — exact pinned install commands | Version-locked to match the pipeline |
| **Verify AWS auth as `jenkins` OS user** | The single most common failure point |
| **Build agent setup** — SSH key generation, agent node registration, label config | The `terraform-agent` label must match the Jenkinsfile |
| **All 5 credential IDs** with exact values | `aws-deploy-role-dev`, `aws-deploy-role-stable`, `aws-deploy-role-prod`, `slack-webhook-elk`, `github-creds` |
| **Pipeline job creation** — SCM settings, branch specifier, Script Path | Exactly how to wire it to this repo's Jenkinsfile |
| **Git webhook vs polling** — how to trigger builds on push | GitHub webhook configuration steps |
| **First build walkthrough** — what to look for in each stage | Including what the AWS Auth stage output should look like |
| **Operational hardening** — signup disabled, backups, log rotation | Production-readiness steps |
| **Troubleshooting** — 6 specific failure scenarios with causes and fixes | Access Denied, SSH failures, state lock, Slack not sending |

---

## 5. Local Workstation Tools

Install these on your development machine for running Terraform/Terragrunt manually (outside Jenkins):

### macOS

```bash
# Homebrew (install if not present)
/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# All tools in one command
brew install terraform terragrunt packer ansible awscli jq openssl

# Verify
terraform version
terragrunt --version
packer version
ansible --version
aws --version
```

### Ubuntu / Debian Linux

```bash
# AWS CLI v2
curl "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
unzip awscliv2.zip && sudo ./aws/install

# Terraform
TF_VERSION="1.7.5"
curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" -o tf.zip
unzip tf.zip && sudo mv terraform /usr/local/bin/

# Terragrunt
TG_VERSION="0.57.0"
sudo curl -fsSL "https://github.com/gruntwork-io/terragrunt/releases/download/v${TG_VERSION}/terragrunt_linux_amd64" \
  -o /usr/local/bin/terragrunt && sudo chmod +x /usr/local/bin/terragrunt

# Packer
PACKER_VERSION="1.10.3"
curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip" -o packer.zip
unzip packer.zip && sudo mv packer /usr/local/bin/

# Ansible
sudo apt-get install -y ansible

# jq
sudo apt-get install -y jq
```

### Configure AWS CLI for your account

```bash
# Method 1: AWS SSO (recommended for human users)
aws configure sso
# Follow the prompts — enter your SSO start URL and account/role

# Method 2: Access keys (for service accounts; not recommended for humans)
aws configure
# Enter Access Key ID, Secret Access Key, default region (us-east-1), output format (json)

# Verify
aws sts get-caller-identity
```

---

## Summary Checklist

Run through this before executing `make bootstrap-state`:

- [ ] AWS account(s) set up
- [ ] `TerraformDeployRole-dev/stable/prod` created with `TerraformDeployPolicy` attached
- [ ] `JenkinsAgentRole` created, instance profile attached to Jenkins EC2
- [ ] Trust relationships set on all deploy roles pointing to `JenkinsAgentRole`
- [ ] Jenkins installed and accessible at `http://<ip>:8080`
- [ ] Required plugins installed (Pipeline, Git, Credentials Binding, AnsiColor, Timestamper, Slack)
- [ ] Terraform + Terragrunt + AWS CLI installed on Jenkins controller/agent
- [ ] Pipeline job created pointing to this repo's `Jenkinsfile`
- [ ] Credentials stored in Jenkins: `aws-deploy-role-dev/stable/prod`, `slack-webhook-elk`
- [ ] ACM certificate issued and ARN noted
- [ ] Route 53 hosted zones created (public + private)
- [ ] Local workstation tools installed and `aws sts get-caller-identity` returns your identity
