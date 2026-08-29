# Jenkins on AWS — Complete Installation and Configuration Guide

This guide installs Jenkins from zero on AWS EC2, configures it with the exact
settings required to run the ELK platform pipeline defined in [`Jenkinsfile`](../Jenkinsfile).
Every step is specific to this project — credential IDs, plugin list, job
configuration, and agent setup all match the pipeline exactly.

---

## Table of Contents

1. [Architecture — what you are building](#1-architecture--what-you-are-building)
2. [Before you start — IAM prerequisite](#2-before-you-start--iam-prerequisite)
3. [Launch the Jenkins EC2 instance](#3-launch-the-jenkins-ec2-instance)
4. [Security group rules](#4-security-group-rules)
5. [Install Java 17 and Jenkins](#5-install-java-17-and-jenkins)
6. [Secure Jenkins with HTTPS (recommended)](#6-secure-jenkins-with-https-recommended)
7. [Complete the setup wizard](#7-complete-the-setup-wizard)
8. [Install required plugins](#8-install-required-plugins)
9. [Install Terraform, Terragrunt, Packer, AWS CLI](#9-install-terraform-terragrunt-packer-aws-cli)
10. [Configure the build agent (optional but recommended)](#10-configure-the-build-agent-optional-but-recommended)
11. [Store all credentials in Jenkins](#11-store-all-credentials-in-jenkins)
12. [Create the ELK pipeline job](#12-create-the-elk-pipeline-job)
13. [Configure automatic Git-triggered builds](#13-configure-automatic-git-triggered-builds)
14. [Configure Global Tool settings](#14-configure-global-tool-settings)
15. [Run your first build and verify](#15-run-your-first-build-and-verify)
16. [Operational hardening](#16-operational-hardening)
17. [Troubleshooting](#17-troubleshooting)

---

## 1. Architecture — what you are building

```
Your browser / Git webhook
         │  HTTPS :443
         ▼
┌─────────────────────────────────────────────────────┐
│  Jenkins Controller EC2 (t3.medium, Ubuntu 22.04)   │
│                                                     │
│  ┌──────────────────────────────────────────────┐   │
│  │  Jenkins process (:8080 internally)          │   │
│  │  Nginx reverse proxy (:443 externally)       │   │
│  │  JenkinsAgentRole instance profile           │   │
│  │  Terraform + Terragrunt + Packer + AWS CLI   │   │
│  └──────────────────────────────────────────────┘   │
│                                                     │
│  Attached: JenkinsAgentRole                         │
│  → can assume TerraformDeployRole-dev               │
│  → can assume TerraformDeployRole-stable            │
│  → can assume TerraformDeployRole-prod              │
└─────────────────────────────────────────────────────┘
         │  VPC-internal SSH  (:22)
         ▼
┌────────────────────────────────────┐
│  (Optional) Jenkins Build Agent    │
│  EC2 for Terraform/Packer jobs     │
│  label: terraform-agent            │
└────────────────────────────────────┘
         │
         ▼
   AWS APIs via VPC Endpoints
   (S3, SSM, STS, EC2, ELB, ...)
```

**Why a reverse proxy?**  
Jenkins runs on port 8080 by default. Nginx listens on port 443 (HTTPS), forwards
to Jenkins on 8080, and handles the TLS certificate. This is the production-standard
setup — your browser never talks to port 8080 directly.

---

## 2. Before you start — IAM prerequisite

The Jenkins EC2 needs an IAM instance profile. Create this **before** launching
the EC2 so you can attach it at launch time.

### Create `JenkinsAgentRole`

**Step 1 — In the IAM console, go to Roles → Create role**

- Trusted entity type: **AWS service**
- Use case: **EC2**
- Click **Next**

**Step 2 — Attach permission policy**

Create a new inline policy named `JenkinsAssumeDeployRoles`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "AssumeELKDeployRoles",
      "Effect": "Allow",
      "Action": "sts:AssumeRole",
      "Resource": [
        "arn:aws:iam::DEV_ACCOUNT_ID:role/TerraformDeployRole-dev",
        "arn:aws:iam::STABLE_ACCOUNT_ID:role/TerraformDeployRole-stable",
        "arn:aws:iam::PROD_ACCOUNT_ID:role/TerraformDeployRole-prod"
      ]
    },
    {
      "Sid": "AllowIdentityCheck",
      "Effect": "Allow",
      "Action": "sts:GetCallerIdentity",
      "Resource": "*"
    }
  ]
}
```

> Replace `DEV_ACCOUNT_ID`, `STABLE_ACCOUNT_ID`, `PROD_ACCOUNT_ID` with your real AWS
> account IDs. If you are using a single account for all environments, all three
> values are the same account ID.

Also attach the AWS-managed policy **`AmazonSSMManagedInstanceCore`** — this enables
AWS Systems Manager Session Manager so you can shell into Jenkins without opening
port 22 to the internet (optional but strongly recommended for security).

**Step 3 — Name and create**

- Role name: `JenkinsAgentRole`
- Click **Create role**

**Step 4 — Create instance profile**

If the IAM console did not auto-create an instance profile with the same name,
run this CLI command:
```bash
aws iam create-instance-profile --instance-profile-name JenkinsAgentRole
aws iam add-role-to-instance-profile \
  --instance-profile-name JenkinsAgentRole \
  --role-name JenkinsAgentRole
```

---

## 3. Launch the Jenkins EC2 instance

### In the AWS Console → EC2 → Launch Instance

| Field | Value |
|-------|-------|
| **Name** | `jenkins-controller` |
| **AMI** | Ubuntu Server 22.04 LTS (64-bit x86) — search "ubuntu 22.04" in Community AMIs |
| **Instance type** | `t3.medium` (2 vCPU / 4 GB RAM) — enough for the controller. Scale to `t3.large` if you run builds on the controller too |
| **Key pair** | Create a new key pair named `jenkins-key`, download the `.pem` file, keep it safe |
| **VPC** | Create a small "tools" VPC (e.g. `10.50.0.0/16`) or use your existing dev VPC |
| **Subnet** | Pick a **public** subnet so you can reach the Jenkins UI from your browser |
| **Auto-assign public IP** | **Enable** |
| **Firewall (security group)** | Create new — see Section 4 for exact rules |
| **Storage** | 40 GB gp3, encrypted |
| **IAM instance profile** | Select **`JenkinsAgentRole`** created above |

Click **Launch instance**.

> **Why public subnet?** The Jenkins UI needs to be reachable from your browser.
> A bastion + private subnet works but adds complexity for a tools server.
> Lock down the security group to your IP instead of using a private subnet.

---

## 4. Security group rules

Create a security group named `jenkins-sg` with these inbound rules. Replace
`YOUR_IP` with your actual IP address (visit https://checkip.amazonaws.com/ to find it).

| Type | Protocol | Port | Source | Purpose |
|------|----------|------|--------|---------|
| Custom TCP | TCP | 8080 | `YOUR_IP/32` | Jenkins web UI (HTTP, before Nginx setup) |
| HTTPS | TCP | 443 | `YOUR_IP/32` | Jenkins web UI after Nginx/TLS is configured |
| SSH | TCP | 22 | `YOUR_IP/32` | Initial setup access |
| Custom TCP | TCP | 8080 | `10.0.0.0/8` | Build agent communication (if using private agents) |

**Outbound rules** — leave the default (all traffic allowed). Jenkins needs to:
- Clone your Git repository (port 443 to GitHub/GitLab)
- Download plugins (port 443 to updates.jenkins.io)
- Call AWS APIs via VPC endpoints or internet

---

## 5. Install Java 17 and Jenkins

SSH into the instance with the key pair you downloaded:

```bash
# Fix permissions on the key file first (macOS/Linux)
chmod 400 jenkins-key.pem

# SSH in
ssh -i jenkins-key.pem ubuntu@<PUBLIC_IP_OF_JENKINS_EC2>
```

Run all of the following as your `ubuntu` user (commands use `sudo` where needed):

### 5a. System update

```bash
sudo apt-get update -y
sudo apt-get upgrade -y
sudo apt-get install -y \
  curl wget gnupg2 ca-certificates apt-transport-https \
  software-properties-common unzip jq git
```

### 5b. Java 17

Jenkins requires Java. Install OpenJDK 17:

```bash
sudo apt-get install -y openjdk-17-jdk

# Verify
java -version
# Expected output: openjdk version "17.x.x" ...

# Set JAVA_HOME (Jenkins init script reads this)
echo 'export JAVA_HOME=/usr/lib/jvm/java-17-openjdk-amd64' | sudo tee -a /etc/environment
source /etc/environment
```

### 5c. Jenkins LTS

```bash
# Add the official Jenkins GPG signing key
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | \
  sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

# Add the Jenkins apt repository (LTS = stable releases only)
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" | \
  sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt-get update -y
sudo apt-get install -y jenkins

# Start Jenkins and enable it to start on reboot
sudo systemctl enable jenkins
sudo systemctl start jenkins

# Confirm it is running (should say "active (running)")
sudo systemctl status jenkins
```

### 5d. Get the initial admin password

Jenkins generates a one-time password on first startup:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Copy this value — you will paste it into the browser in Section 7.

---

## 6. Secure Jenkins with HTTPS (recommended)

Running Jenkins on plain HTTP port 8080 is fine for initial testing but exposes
your admin credentials over the network. This section puts Nginx in front of
Jenkins as a TLS-terminating reverse proxy using a self-signed certificate
(or your ACM certificate if you have a domain).

### 6a. Install Nginx

```bash
sudo apt-get install -y nginx
```

### 6b. Generate a self-signed TLS certificate

If you have a real domain pointed at this EC2, use a Let's Encrypt certificate
instead (see the note below). For a quick start, a self-signed cert is fine:

```bash
sudo mkdir -p /etc/nginx/ssl
sudo openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout /etc/nginx/ssl/jenkins.key \
  -out /etc/nginx/ssl/jenkins.crt \
  -subj "/CN=jenkins-controller/O=ELK Platform/C=US"
sudo chmod 600 /etc/nginx/ssl/jenkins.key
```

> **Using a real domain?** Point your domain at this EC2's public IP, then run:
> ```bash
> sudo apt-get install -y certbot python3-certbot-nginx
> sudo certbot --nginx -d jenkins.yourdomain.com
> ```
> Certbot auto-renews and reconfigures Nginx. Skip the manual steps below.

### 6c. Write the Nginx configuration

```bash
sudo tee /etc/nginx/sites-available/jenkins > /dev/null <<'EOF'
server {
    listen 80;
    server_name _;
    # Redirect all HTTP to HTTPS
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl;
    server_name _;  # Replace with your domain if you have one

    ssl_certificate     /etc/nginx/ssl/jenkins.crt;
    ssl_certificate_key /etc/nginx/ssl/jenkins.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    # Security headers
    add_header X-Frame-Options           SAMEORIGIN;
    add_header X-Content-Type-Options    nosniff;
    add_header X-XSS-Protection          "1; mode=block";
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains";

    # Jenkins needs this for WebSockets (used by the agent protocol and Blue Ocean)
    location / {
        proxy_pass          http://127.0.0.1:8080;
        proxy_read_timeout  90s;
        proxy_send_timeout  90s;

        proxy_set_header Host               $host;
        proxy_set_header X-Real-IP          $remote_addr;
        proxy_set_header X-Forwarded-For    $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto  $scheme;

        # WebSocket support (for Jenkins agents and Blue Ocean live logs)
        proxy_http_version 1.1;
        proxy_set_header Upgrade    $http_upgrade;
        proxy_set_header Connection "upgrade";

        # Increase buffer sizes to avoid Jenkins timeouts on large pages
        proxy_buffer_size          128k;
        proxy_buffers              4 256k;
        proxy_busy_buffers_size    256k;
    }
}
EOF

# Enable the site, disable the default
sudo ln -s /etc/nginx/sites-available/jenkins /etc/nginx/sites-enabled/
sudo rm -f /etc/nginx/sites-enabled/default

# Test config syntax
sudo nginx -t

# Reload Nginx
sudo systemctl enable nginx
sudo systemctl reload nginx
```

### 6d. Tell Jenkins it is behind a proxy

Jenkins needs to know its own public URL so that URLs in emails and webhooks are correct:

```bash
# Edit Jenkins startup configuration
sudo tee /etc/default/jenkins > /dev/null <<'EOF'
# Jenkins startup configuration
JENKINS_HOME=/var/lib/jenkins
JENKINS_USER=jenkins
JENKINS_GROUP=jenkins
JENKINS_PORT=8080
JAVA_ARGS="-Djava.awt.headless=true"
# Tell Jenkins what its public-facing URL is
JENKINS_ARGS="--httpListenAddress=127.0.0.1 --httpPort=8080"
EOF

sudo systemctl restart jenkins
```

> Setting `--httpListenAddress=127.0.0.1` makes Jenkins only listen on localhost —
> port 8080 is no longer reachable from the network. All traffic goes through Nginx on 443.

Update the security group: **remove** the port 8080 inbound rule — it is no longer needed.
Keep port 443 open to your IP.

---

## 7. Complete the setup wizard

Open your browser and go to:
- HTTP: `http://<JENKINS_PUBLIC_IP>:8080` (if you skipped Section 6)
- HTTPS: `https://<JENKINS_PUBLIC_IP>` (after Section 6; accept the browser warning for self-signed cert)

**Step 1 — Unlock Jenkins**

Paste the initial admin password from Section 5d.

**Step 2 — Install plugins**

Click **"Install suggested plugins"**. This takes 3–5 minutes and installs Git,
Pipeline, Credentials Binding, and other basics automatically.

**Step 3 — Create admin user**

Fill in:
- Username: `admin` (or your preferred username)
- Password: a strong password — store this in your password manager
- Full name: your name
- Email: your email address

Click **Save and Continue**.

**Step 4 — Instance configuration**

Set the Jenkins URL to how you access it:
- With a domain: `https://jenkins.yourdomain.com`
- Without a domain: `https://<JENKINS_PUBLIC_IP>`

Click **Save and Finish → Start using Jenkins**.

---

## 8. Install required plugins

The [`Jenkinsfile`](../Jenkinsfile) in this project uses specific Jenkins features. You need all of
these plugins. Go to **Manage Jenkins → Plugins → Available plugins**, search for each,
check the checkbox, and click **Install**.

| Plugin name (search for this) | ID | What the Jenkinsfile uses it for |
|-------------------------------|-----|----------------------------------|
| Pipeline | `workflow-aggregator` | The `pipeline {}` block — the entire file |
| Git | `git` | `checkout scm` in Stage 1 |
| Credentials Binding | `credentials-binding` | `credentials('aws-deploy-role-dev')` in the `environment` block |
| AnsiColor | `ansicolor` | `ansiColor('xterm')` option — color in console output |
| Timestamper | `timestamper` | `timestamps()` option — adds time to every log line |
| Slack Notification | `slack` | `curl` to Slack webhook (used in approval + post stages) |
| Pipeline Stage View | `pipeline-stage-view` | The visual stage grid on the job page |
| Workspace Cleanup | `ws-cleanup` | `cleanWs()` in the `post { always { } }` block |
| Build Timeout | `build-timeout` | `timeout(time: 2, unit: 'HOURS')` option |
| Email Extension | `email-ext` | `mail(...)` in the `post { failure { } }` block |

After all are checked, click **Install**. On the next screen, check
**"Restart Jenkins when no jobs are running"** and wait.

> **Already installed?** Some of these come with "Install suggested plugins".
> The search will show "Installed" next to their names — skip those.

---

## 9. Install Terraform, Terragrunt, Packer, AWS CLI

SSH back into the Jenkins EC2. Install the exact versions the pipeline expects:

```bash
ssh -i jenkins-key.pem ubuntu@<JENKINS_PUBLIC_IP>
```

### 9a. Terraform 1.7.5

```bash
TF_VERSION="1.7.5"
curl -fsSL "https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip" \
  -o /tmp/terraform.zip
sudo unzip -o /tmp/terraform.zip -d /usr/local/bin/
sudo chmod +x /usr/local/bin/terraform
terraform version
# Expected: Terraform v1.7.5
```

### 9b. Terragrunt 0.57.0

```bash
TG_VERSION="0.57.0"
sudo curl -fsSL \
  "https://github.com/gruntwork-io/terragrunt/releases/download/v${TG_VERSION}/terragrunt_linux_amd64" \
  -o /usr/local/bin/terragrunt
sudo chmod +x /usr/local/bin/terragrunt
terragrunt --version
# Expected: terragrunt version v0.57.0
```

### 9c. Packer 1.10.3

Packer is needed if you run AMI builds from Jenkins (rather than manually):

```bash
PACKER_VERSION="1.10.3"
curl -fsSL "https://releases.hashicorp.com/packer/${PACKER_VERSION}/packer_${PACKER_VERSION}_linux_amd64.zip" \
  -o /tmp/packer.zip
sudo unzip -o /tmp/packer.zip -d /usr/local/bin/
sudo chmod +x /usr/local/bin/packer
packer version
# Expected: Packer v1.10.3
```

### 9d. AWS CLI v2

```bash
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
sudo unzip -o /tmp/awscliv2.zip -d /tmp/
sudo /tmp/aws/install --update
aws --version
# Expected: aws-cli/2.x.x
```

### 9e. tflint (optional but the Lint stage uses it)

```bash
curl -fsSL https://raw.githubusercontent.com/terraform-linters/tflint/master/install_linux.sh | bash
tflint --version
```

### 9f. Make tools available to the Jenkins OS user

All pipeline stages run as the `jenkins` OS user. That user must be able to call
these tools directly:

```bash
# Verify the tools are in /usr/local/bin (already accessible to all users)
ls -la /usr/local/bin/terraform /usr/local/bin/terragrunt /usr/local/bin/packer

# Test as the jenkins user
sudo -u jenkins terraform version
sudo -u jenkins terragrunt --version
sudo -u jenkins packer version
sudo -u jenkins aws --version
```

### 9g. Verify AWS authentication works from Jenkins

```bash
# This should return JenkinsAgentRole, not your personal IAM user
sudo -u jenkins aws sts get-caller-identity
```

Expected output:
```json
{
    "UserId": "AROAXXXXXXXXXXXXXXXXXXXX:i-xxxxxxxxxxxxxxxxx",
    "Account": "111111111111",
    "Arn": "arn:aws:iam::111111111111:assumed-role/JenkinsAgentRole/i-xxxxxxxxxxxxxxxxx"
}
```

If you see your personal IAM user instead of `JenkinsAgentRole`, the instance
profile is not attached. Stop the EC2, attach `JenkinsAgentRole` as the IAM role
in EC2 → Actions → Security → Modify IAM Role, then restart.

---

## 10. Configure the build agent (optional but recommended)

For a small team or learning environment, the controller runs builds itself.
For anything production-facing, add a dedicated build agent so the controller
only schedules jobs and the agent does the actual work (Terraform, Packer, etc.).

### 10a. Launch an agent EC2

| Field | Value |
|-------|-------|
| Name | `jenkins-agent-1` |
| AMI | Ubuntu Server 22.04 LTS |
| Instance type | `t3.large` (Packer builds are CPU-intensive) |
| VPC / subnet | Same VPC as controller, **private** subnet (communicates via SSH) |
| IAM instance profile | `JenkinsAgentRole` (same role) |
| Security group | Allow inbound SSH from the Jenkins controller's private IP only |

### 10b. Prepare the agent OS

SSH into the agent (via bastion or SSM):

```bash
# Create a jenkins OS user (controller connects as this user)
sudo useradd -m -s /bin/bash jenkins

# Create SSH directory
sudo mkdir -p /home/jenkins/.ssh
sudo touch /home/jenkins/.ssh/authorized_keys
sudo chown -R jenkins:jenkins /home/jenkins/.ssh
sudo chmod 700 /home/jenkins/.ssh
sudo chmod 600 /home/jenkins/.ssh/authorized_keys
```

### 10c. Generate an SSH key on the controller and copy to the agent

On the **controller** EC2:

```bash
# Switch to the jenkins OS user
sudo su - jenkins

# Generate SSH key (no passphrase — Jenkins uses it programmatically)
ssh-keygen -t ed25519 -f ~/.ssh/jenkins-agent-key -N ""

# Display the public key
cat ~/.ssh/jenkins-agent-key.pub
```

Copy the output (starts with `ssh-ed25519 ...`).

On the **agent** EC2:

```bash
sudo su - jenkins
echo "PASTE_THE_PUBLIC_KEY_HERE" >> /home/jenkins/.ssh/authorized_keys
```

Test the connection from the controller:
```bash
# On the controller, as the jenkins user
ssh -i ~/.ssh/jenkins-agent-key jenkins@<AGENT_PRIVATE_IP>
# Should log in without a password prompt
```

### 10d. Install tools on the agent

Run the same steps from Section 9 on the agent EC2:
- Java 17
- Terraform 1.7.5
- Terragrunt 0.57.0
- Packer 1.10.3
- AWS CLI v2

### 10e. Register the agent in Jenkins UI

1. Go to **Manage Jenkins → Nodes → New Node**
2. Node name: `terraform-agent-1`
3. Select **Permanent Agent**, click **Create**
4. Fill in:

| Field | Value |
|-------|-------|
| **Description** | `Dedicated build agent for Terraform/Packer` |
| **Number of executors** | `2` |
| **Remote root directory** | `/home/jenkins` |
| **Labels** | `terraform-agent` ← this must match the `agent { label 'terraform-agent' }` line in Jenkinsfile |
| **Usage** | `Only build jobs with label expressions matching this node` |
| **Launch method** | `Launch agents via SSH` |
| **Host** | Private IP of the agent EC2 |
| **Credentials** | Click **Add** (see below) |
| **Host Key Verification Strategy** | `Non verifying Verification Strategy` (or `Known hosts file` after first connect) |

**Adding the SSH credential:**
- In the Credentials dialog: Kind = **SSH Username with private key**
- ID: `jenkins-agent-ssh-key`
- Username: `jenkins`
- Private key: **Enter directly** → paste the contents of `~/.ssh/jenkins-agent-key` (the private key, not `.pub`)
- Click **Add**

5. Click **Save**. Jenkins will immediately try to connect. The node status page
   will show "Agent successfully connected" within ~30 seconds.

---

## 11. Store all credentials in Jenkins

The [`Jenkinsfile`](../Jenkinsfile) references credentials by exact ID. Every credential below
**must** be created exactly as shown — the ID is what the pipeline uses.

Go to **Manage Jenkins → Credentials → System → Global credentials (unrestricted) → Add Credentials**.

### 11a. AWS deploy role ARNs (one per environment)

Create three separate credentials:

| Kind | ID | Secret value | Description |
|------|----|--------------|-------------|
| Secret text | `aws-deploy-role-dev` | `arn:aws:iam::DEV_ACCOUNT_ID:role/TerraformDeployRole-dev` | Dev deploy role |
| Secret text | `aws-deploy-role-stable` | `arn:aws:iam::STABLE_ACCOUNT_ID:role/TerraformDeployRole-stable` | Stable deploy role |
| Secret text | `aws-deploy-role-prod` | `arn:aws:iam::PROD_ACCOUNT_ID:role/TerraformDeployRole-prod` | Prod deploy role |

For each:
1. Kind: **Secret text**
2. Secret: paste the ARN (replace `DEV_ACCOUNT_ID` with your actual account ID)
3. ID: exactly as shown in the table (the pipeline code uses this)
4. Click **Create**

### 11b. Slack webhook URL

1. In Slack, go to **Apps → Incoming Webhooks** (or visit `https://api.slack.com/apps`, create an app, enable Incoming Webhooks)
2. Choose or create a channel — e.g. `#elk-deployments`
3. Copy the webhook URL (format: `https://hooks.slack.com/services/T.../B.../...`)
4. In Jenkins Credentials:
   - Kind: **Secret text**
   - Secret: the full webhook URL
   - ID: `slack-webhook-elk`
   - Click **Create**

### 11c. Git repository credential (if private repo)

If your Git repository is private:

**GitHub with Personal Access Token:**
1. In GitHub: Settings → Developer settings → Personal access tokens → Fine-grained tokens → Generate
2. Permissions needed: `Contents: Read`, `Metadata: Read`
3. In Jenkins Credentials:
   - Kind: **Username with password**
   - Username: your GitHub username
   - Password: the personal access token
   - ID: `github-creds`
   - Click **Create**

**GitLab SSH key:**
- Kind: **SSH Username with private key**
- ID: `gitlab-ssh-key`
- Username: `git`
- Private key: paste your GitLab deploy key private key

### 11d. Verification — all credentials listed

After adding all credentials, go to **Manage Jenkins → Credentials → System → Global credentials**.
You should see:

```
aws-deploy-role-dev      Secret text   (no description shown — just the ID)
aws-deploy-role-stable   Secret text
aws-deploy-role-prod     Secret text
slack-webhook-elk        Secret text
github-creds             Username/password  (if you added it)
jenkins-agent-ssh-key    SSH username with private key  (if you added an agent)
```

---

## 12. Create the ELK pipeline job

### 12a. New item

1. Click **New Item** on the Jenkins dashboard
2. Name: `elk-platform`
3. Select **Pipeline** (not Multibranch for simplicity; use Multibranch when you
   have multiple feature branches)
4. Click **OK**

### 12b. General settings

- ✅ **This project is parameterized** (tick this — the Jenkinsfile has parameters)
   - Jenkins will auto-read them from the Jenkinsfile on first run; leave this unchecked for now and Jenkins will populate them automatically
- ✅ **Do not allow concurrent builds** — tick this. Running two Terraform applies simultaneously against the same state is dangerous.
- **Build Triggers** — configure in Section 13

### 12c. Pipeline definition

Scroll to the **Pipeline** section at the bottom:

- Definition: **Pipeline script from SCM**
- SCM: **Git**
- Repository URL: your repository URL
  - HTTPS: `https://github.com/yourorg/elk-platform.git`
  - SSH: `git@github.com:yourorg/elk-platform.git`
- Credentials: select the Git credential you added in step 11c (or leave blank if public repo)
- Branch Specifier: `*/main` (or `*/master`, or `**` for all branches)
- Script Path: `Jenkinsfile` (this is the default — leave as-is)

Click **Save**.

### 12d. First scan — let Jenkins read the Jenkinsfile

Click **Build Now** (or **Scan Repository** for Multibranch). Jenkins will:
1. Clone your repo
2. Read the `Jenkinsfile`
3. Discover the `parameters {}` block
4. Abort the first build (parameters weren't set yet — this is normal)

After the first scan, click the job again — you will now see **Build with Parameters**
instead of **Build Now**.

---

## 13. Configure automatic Git-triggered builds

Without this, you have to click "Build" manually. With this, every push to `main`
triggers the pipeline automatically.

### Option A — GitHub webhook (recommended)

1. In Jenkins: **Manage Jenkins → System** → find **GitHub** section
   - Click **Add GitHub Server** → give it a name
   - Add a GitHub credential (Personal Access Token with `admin:repo_hook` scope)
   - Click **Test connection** — should say "Credentials verified"
   - Save

2. In GitHub (your repository): **Settings → Webhooks → Add webhook**
   - Payload URL: `https://<JENKINS_URL>/github-webhook/`
   - Content type: `application/json`
   - Events: **Just the push event**
   - Click **Add webhook**

3. In your Jenkins job: **Configure → Build Triggers**
   - ✅ **GitHub hook trigger for GITScm polling**
   - Save

Now every `git push` to main will trigger a build within seconds.

### Option B — Polling (simpler, no webhook needed)

In Jenkins job: **Configure → Build Triggers**:
- ✅ **Poll SCM**
- Schedule: `H/5 * * * *` (checks every 5 minutes)
- Save

This works without any webhook setup but has up to 5-minute delay.

---

## 14. Configure Global Tool settings

These settings tell Jenkins where to find tools when pipeline steps reference them by name.

Go to **Manage Jenkins → Tools**.

### Git

- Git installations: the default (`git`) usually works
- Path to Git executable: leave blank (uses system PATH)

### JDK (if you use the JDK tool in any pipeline)

- Not required for this pipeline — Java is installed directly on the agent/controller

### Terraform (optional — only needed if you use the Terraform Jenkins plugin)

This pipeline calls `terraform` as a shell command directly, so no tool registration
is needed. Skip this section.

---

## 15. Run your first build and verify

### 15a. Trigger a plan-only run

1. Click **elk-platform → Build with Parameters**
2. Set parameters:
   - `ENVIRONMENT`: `dev`
   - `ACTION`: `plan`
   - `MODULE`: `us-east-1/vpc` (start with just one module)
   - `AUTO_APPROVE`: unchecked
   - `ELK_VERSION`: `8.12.2`
3. Click **Build**

### 15b. Watch the stage view

The pipeline page shows each stage as a colored box:

```
Checkout → Tool Setup → Lint & Format → AWS Auth → Validate → Plan → [Approval] → Apply → Smoke Tests
```

For a `plan` action, stages after Plan are skipped automatically.

### 15c. Verify AWS authentication

In the build log, look for the **AWS Auth** stage output:
```
{
    "UserId": "AROAXXXX:i-xxxxxxxxx",
    "Account": "111111111111",
    "Arn": "arn:aws:iam::111111111111:assumed-role/TerraformDeployRole-dev/jenkins-dev-42"
}
```

If you see `TerraformDeployRole-dev` in the ARN, authentication is working correctly.
The pipeline has successfully:
1. Used the `JenkinsAgentRole` instance profile on the EC2
2. Called `sts:AssumeRole` to get temporary credentials for `TerraformDeployRole-dev`
3. Terraform will now operate with those temporary credentials

### 15d. Verify the plan output

In the **Plan** stage, you should see Terraform output ending with:
```
Plan: X to add, 0 to change, 0 to destroy.
```

The plan is also saved as an artifact — click **Artifacts** on the build page to download it.

### 15e. Run a full apply to dev

Once the plan looks correct:
1. **Build with Parameters** again
2. `ENVIRONMENT=dev`, `ACTION=apply`, `MODULE=` (leave blank for all)
3. No approval gate for dev (only stable/prod require manual approval)
4. Watch the **Smoke Tests** stage — it checks cluster health and Kibana status

---

## 16. Operational hardening

After the initial setup is working, apply these hardening steps:

### 16a. Disable signup

Go to **Manage Jenkins → Security**:
- Authorization: **Matrix-based security** (or Role-Based Strategy if you install that plugin)
- Under "Anonymous": remove all permissions
- Under your admin user: grant all permissions
- ✅ Untick **Allow users to sign up**
- Save

### 16b. Enable Content Security Policy headers

Jenkins' default CSP is restrictive but some plugins may loosen it. Leave defaults unless a plugin requires changes.

### 16c. Regular backups

Jenkins state lives in `/var/lib/jenkins`. Back up this directory to S3:

```bash
# Create a backup script
sudo tee /usr/local/bin/backup-jenkins.sh > /dev/null <<'SCRIPT'
#!/bin/bash
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
BACKUP_BUCKET="your-jenkins-backup-bucket"
BACKUP_FILE="/tmp/jenkins-backup-${TIMESTAMP}.tar.gz"

# Stop Jenkins during backup to ensure consistent state (optional — can do hot backup)
# systemctl stop jenkins

tar -czf "$BACKUP_FILE" -C /var/lib jenkins/

aws s3 cp "$BACKUP_FILE" "s3://${BACKUP_BUCKET}/jenkins-backups/${TIMESTAMP}.tar.gz"

rm -f "$BACKUP_FILE"

# systemctl start jenkins
echo "Backup complete: ${TIMESTAMP}"
SCRIPT

sudo chmod +x /usr/local/bin/backup-jenkins.sh

# Add to crontab — daily at 3 AM
echo "0 3 * * * root /usr/local/bin/backup-jenkins.sh >> /var/log/jenkins-backup.log 2>&1" | \
  sudo tee -a /etc/cron.d/jenkins-backup
```

### 16d. Log rotation for Jenkins logs

```bash
sudo tee /etc/logrotate.d/jenkins > /dev/null <<'EOF'
/var/log/jenkins/jenkins.log {
    weekly
    rotate 4
    compress
    delaycompress
    missingok
    notifempty
    copytruncate
}
EOF
```

### 16e. Update Jenkins regularly

```bash
# Jenkins updates are delivered via apt
sudo apt-get update && sudo apt-get install --only-upgrade jenkins
sudo systemctl restart jenkins
```

---

## 17. Troubleshooting

### "Permission denied" when Terraform tries to assume role

```
Error: error configuring Terraform AWS Provider: error validating provider credentials: ...
```

**Cause**: `JenkinsAgentRole` does not have permission to assume `TerraformDeployRole-dev`, or
the trust policy on `TerraformDeployRole-dev` does not include `JenkinsAgentRole`.

**Fix**:
```bash
# Check what role the Jenkins EC2 is using
sudo -u jenkins aws sts get-caller-identity

# Try assuming the deploy role manually
sudo -u jenkins aws sts assume-role \
  --role-arn arn:aws:iam::DEV_ACCOUNT_ID:role/TerraformDeployRole-dev \
  --role-session-name test-session

# If this fails, check:
# 1. JenkinsAgentRole has the sts:AssumeRole permission with the correct Resource ARN
# 2. TerraformDeployRole-dev has a trust policy allowing JenkinsAgentRole as principal
```

### "Host key verification failed" for agent SSH

```
[SSH] ERROR: Connection failed - java.io.IOException: There was a problem ...
```

**Fix**: In the agent node configuration, set  
**Host Key Verification Strategy → Non verifying Verification Strategy**  
then save and reconnect.

### Jenkins UI shows "Please wait while Jenkins is getting ready to work"

Jenkins is starting or reloading plugins. Wait 1–2 minutes and refresh.

### Build stuck at "Waiting for agent"

The `terraform-agent` label is specified in the Jenkinsfile but no connected agent has that label.
Either:
- Connect the agent (check **Manage Jenkins → Nodes** for offline agents)
- Or temporarily change `label 'terraform-agent'` to `any` in the Jenkinsfile to run on the controller

### Slack messages not sending

The pipeline uses raw `curl` to send Slack messages, not the Slack plugin.
Check that the `slack-webhook-elk` credential contains the full `https://hooks.slack.com/...` URL.
Test it manually:
```bash
curl -X POST 'https://hooks.slack.com/services/YOUR/WEBHOOK/PATH' \
  -H 'Content-type: application/json' \
  -d '{"text":"Test from Jenkins"}'
```

### Terraform state lock error

```
Error: Error acquiring the state lock
```

**Fix**: Someone else ran a `plan`/`apply` and it crashed without releasing the lock.

```bash
# Find the lock ID in the error output (a UUID)
# Then force-unlock
cd infra-live/dev/us-east-1/vpc
terragrunt force-unlock LOCK_ID_FROM_ERROR
```

---

## Summary — what you now have

```
EC2 (t3.medium, Ubuntu 22.04)
├── Java 17
├── Jenkins LTS (port 8080, loopback only)
├── Nginx (port 443, TLS, reverse-proxying Jenkins)
├── Terraform 1.7.5
├── Terragrunt 0.57.0
├── Packer 1.10.3
├── AWS CLI v2
├── JenkinsAgentRole instance profile
│    └── sts:AssumeRole → TerraformDeployRole-{dev,stable,prod}
└── Jenkins credentials:
     ├── aws-deploy-role-dev     (TerraformDeployRole-dev ARN)
     ├── aws-deploy-role-stable  (TerraformDeployRole-stable ARN)
     ├── aws-deploy-role-prod    (TerraformDeployRole-prod ARN)
     └── slack-webhook-elk       (Slack Incoming Webhook URL)

Jenkins job: elk-platform
├── Reads Jenkinsfile from your Git repo
├── Parameters: ENVIRONMENT, ACTION, MODULE, AUTO_APPROVE, ELK_VERSION
├── Runs on: terraform-agent label (or controller if no agent configured)
└── Pipeline stages:
     Checkout → Tool Setup → Lint → AWS Auth → Validate → Plan
     → Approval (stable/prod) → Apply → Smoke Tests
```
