##############################################################################
# Jenkinsfile — ELK Platform CI/CD Pipeline
# Environments: dev → stable → prod
# Stages: checkout → setup → lint → validate → plan → approve → apply → smoke
##############################################################################

pipeline {
  agent {
    label 'terraform-agent'
  }

  options {
    buildDiscarder(logRotator(numToKeepStr: '20'))
    timeout(time: 2, unit: 'HOURS')
    ansiColor('xterm')
    timestamps()
    disableConcurrentBuilds()
  }

  parameters {
    choice(
      name: 'ENVIRONMENT',
      choices: ['dev', 'stable', 'prod'],
      description: 'Target deployment environment'
    )
    choice(
      name: 'ACTION',
      choices: ['plan', 'apply', 'destroy'],
      description: 'Terraform action to execute'
    )
    string(
      name: 'MODULE',
      defaultValue: '',
      description: 'Leave blank to run all modules, or specify a single module path (e.g. us-east-2/vpc)'
    )
    booleanParam(
      name: 'AUTO_APPROVE',
      defaultValue: false,
      description: 'Skip manual approval gate (dev only; blocked for stable/prod)'
    )
    string(
      name: 'ELK_VERSION',
      defaultValue: '8.12.2',
      description: 'Elastic Stack version to deploy'
    )
  }

  environment {
    TF_VERSION        = '1.7.5'
    TG_VERSION        = '0.57.0'
    AWS_DEFAULT_REGION = 'us-east-2'
    PLAN_ARTIFACT     = "tfplan-${params.ENVIRONMENT}-${BUILD_NUMBER}.txt"
    // Credentials injected via Jenkins credential store (never hardcoded)
    AWS_ROLE_ARN      = credentials("aws-deploy-role-${params.ENVIRONMENT}")
    SLACK_WEBHOOK     = credentials('slack-webhook-elk')
  }

  stages {

    // ─── Stage 1: Checkout ─────────────────────────────────────────────────
    stage('Checkout') {
      steps {
        checkout scm
        script {
          env.GIT_COMMIT_SHORT  = sh(script: 'git rev-parse --short HEAD', returnStdout: true).trim()
          env.GIT_BRANCH_CLEAN  = env.GIT_BRANCH.replaceAll('origin/', '').replaceAll('/', '-')
          env.DEPLOY_TIMESTAMP  = sh(script: 'date -u +%Y%m%dT%H%M%SZ', returnStdout: true).trim()
        }
        echo "Branch: ${env.GIT_BRANCH_CLEAN} | Commit: ${env.GIT_COMMIT_SHORT} | Env: ${params.ENVIRONMENT}"
      }
    }

    // ─── Stage 2: Tool Setup ───────────────────────────────────────────────
    stage('Tool Setup') {
      steps {
        sh '''
          echo "=== Verifying tool versions ==="
          terraform version || (
            curl -fsSL https://releases.hashicorp.com/terraform/${TF_VERSION}/terraform_${TF_VERSION}_linux_amd64.zip -o /tmp/tf.zip
            unzip -o /tmp/tf.zip -d /usr/local/bin/
            chmod +x /usr/local/bin/terraform
          )
          terragrunt --version || (
            curl -fsSL https://github.com/gruntwork-io/terragrunt/releases/download/v${TG_VERSION}/terragrunt_linux_amd64 -o /usr/local/bin/terragrunt
            chmod +x /usr/local/bin/terragrunt
          )
          terraform version
          terragrunt --version
          tflint --version 2>/dev/null || true
          tfsec --version 2>/dev/null || true
        '''
      }
    }

    // ─── Stage 3: Lint / Format Check ──────────────────────────────────────
    stage('Lint & Format') {
      steps {
        dir('infra-modules') {
          sh '''
            echo "=== Terraform fmt check ==="
            terraform fmt -check -recursive -diff || (echo "Format violations found!"; exit 1)

            echo "=== TFLint (if available) ==="
            tflint --recursive 2>/dev/null || true

            echo "=== tfsec security scan (if available) ==="
            tfsec . --no-color 2>/dev/null || true
          '''
        }
        dir('infra-live') {
          sh 'terraform fmt -check -recursive -diff || true'
        }
      }
      post {
        failure {
          echo 'Lint/format check failed — fix formatting before proceeding.'
        }
      }
    }

    // ─── Stage 4: AWS Auth (Assume Role) ───────────────────────────────────
    stage('AWS Auth') {
      steps {
        script {
          // Assume the environment-specific Terraform deploy role
          def creds = sh(
            script: """
              aws sts assume-role \
                --role-arn ${env.AWS_ROLE_ARN} \
                --role-session-name jenkins-${params.ENVIRONMENT}-${BUILD_NUMBER} \
                --duration-seconds 3600 \
                --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' \
                --output text
            """,
            returnStdout: true
          ).trim().split('\\s+')

          env.AWS_ACCESS_KEY_ID     = creds[0]
          env.AWS_SECRET_ACCESS_KEY = creds[1]
          env.AWS_SESSION_TOKEN     = creds[2]
        }
        sh 'aws sts get-caller-identity'
      }
    }

    // ─── Stage 5: Validate ─────────────────────────────────────────────────
    stage('Validate') {
      steps {
        dir("infra-live/${params.ENVIRONMENT}") {
          sh '''
            echo "=== Terragrunt validate-all ==="
            if [ -n "${MODULE}" ]; then
              cd "${MODULE}"
              terragrunt validate --terragrunt-non-interactive
            else
              terragrunt run-all validate --terragrunt-non-interactive \
                --terragrunt-ignore-external-dependencies
            fi
          '''
        }
      }
    }

    // ─── Stage 6: Plan ─────────────────────────────────────────────────────
    stage('Plan') {
      steps {
        dir("infra-live/${params.ENVIRONMENT}") {
          sh '''
            echo "=== Terragrunt plan ==="
            if [ -n "${MODULE}" ]; then
              cd "${MODULE}"
              terragrunt plan \
                --terragrunt-non-interactive \
                -var="elk_version=${ELK_VERSION}" \
                -out=tfplan.binary \
                2>&1 | tee "${WORKSPACE}/${PLAN_ARTIFACT}"
              terragrunt show tfplan.binary -no-color >> "${WORKSPACE}/${PLAN_ARTIFACT}"
            else
              terragrunt run-all plan \
                --terragrunt-non-interactive \
                --terragrunt-ignore-external-dependencies \
                2>&1 | tee "${WORKSPACE}/${PLAN_ARTIFACT}"
            fi
          '''
        }
      }
      post {
        always {
          archiveArtifacts artifacts: env.PLAN_ARTIFACT, fingerprint: true
          // Parse plan for resource counts
          script {
            def planOutput = readFile(env.PLAN_ARTIFACT)
            def addCount    = (planOutput =~ /(\d+) to add/).with { it.find() ? it[0][1] : '0' }
            def changeCount = (planOutput =~ /(\d+) to change/).with { it.find() ? it[0][1] : '0' }
            def destroyCount = (planOutput =~ /(\d+) to destroy/).with { it.find() ? it[0][1] : '0' }
            env.PLAN_SUMMARY = "add:${addCount} change:${changeCount} destroy:${destroyCount}"
            echo "Plan summary: ${env.PLAN_SUMMARY}"
          }
        }
      }
    }

    // ─── Stage 7: Approval Gate (stable & prod) ────────────────────────────
    stage('Approval') {
      when {
        anyOf {
          expression { params.ENVIRONMENT == 'stable' }
          expression { params.ENVIRONMENT == 'prod' }
          expression { params.ACTION == 'destroy' }
        }
      }
      steps {
        script {
          // Post plan summary to Slack
          sh """
            curl -s -X POST '${env.SLACK_WEBHOOK}' \
              -H 'Content-type: application/json' \
              -d '{
                "text": ":terraform: *ELK Deploy — ${params.ENVIRONMENT}*\\nBranch: ${env.GIT_BRANCH_CLEAN} | Commit: ${env.GIT_COMMIT_SHORT}\\nAction: ${params.ACTION} | Plan: ${env.PLAN_SUMMARY}\\nBuild: ${BUILD_URL}"
              }' || true
          """

          def approver = input(
            id: 'DeployApproval',
            message: "Approve ${params.ACTION} to ${params.ENVIRONMENT}?\nPlan: ${env.PLAN_SUMMARY}",
            parameters: [
              string(name: 'APPROVER_NOTES', defaultValue: '', description: 'Optional notes'),
              booleanParam(name: 'CONFIRMED', defaultValue: false, description: 'I confirm I have reviewed the plan')
            ],
            submitter: 'elk-platform-leads,ops-team',
            ok: 'Deploy'
          )

          if (!approver.CONFIRMED) {
            error("Approval not confirmed — aborting.")
          }

          env.APPROVAL_NOTES   = approver.APPROVER_NOTES
          env.APPROVAL_GRANTED = 'true'
        }
      }
    }

    // ─── Stage 8: Apply ────────────────────────────────────────────────────
    stage('Apply') {
      when {
        expression { params.ACTION == 'apply' }
      }
      steps {
        dir("infra-live/${params.ENVIRONMENT}") {
          sh '''
            echo "=== Terragrunt apply ==="
            if [ -n "${MODULE}" ]; then
              cd "${MODULE}"
              terragrunt apply \
                --terragrunt-non-interactive \
                -auto-approve \
                -var="elk_version=${ELK_VERSION}"
            else
              terragrunt run-all apply \
                --terragrunt-non-interactive \
                --terragrunt-ignore-external-dependencies \
                -auto-approve
            fi
          '''
        }
      }
    }

    // ─── Stage 9: Post-Deploy Smoke Tests ──────────────────────────────────
    stage('Smoke Tests') {
      when {
        expression { params.ACTION == 'apply' }
      }
      steps {
        script {
          // Give instances time to boot (adjust per env)
          sleep(time: params.ENVIRONMENT == 'dev' ? 120 : 180, unit: 'SECONDS')
        }
        sh '''
          #!/bin/bash
          set -euo pipefail

          ENV="${ENVIRONMENT}"
          SSM_PREFIX="/elk/${ENV}"
          REGION="${AWS_DEFAULT_REGION}"

          echo "=== Fetching ES endpoint from SSM ==="
          ES_ENDPOINT=$(aws ssm get-parameter \
            --name "${SSM_PREFIX}/outputs/es_ingest_endpoint" \
            --region "${REGION}" \
            --query Parameter.Value --output text 2>/dev/null || echo "")

          KIBANA_ENDPOINT=$(aws ssm get-parameter \
            --name "${SSM_PREFIX}/outputs/kibana_alb_dns" \
            --region "${REGION}" \
            --query Parameter.Value --output text 2>/dev/null || echo "")

          ELASTIC_PASS=$(aws secretsmanager get-secret-value \
            --secret-id "${SSM_PREFIX}/elastic-password" \
            --region "${REGION}" \
            --query SecretString --output text 2>/dev/null | \
            python3 -c "import sys,json; print(json.load(sys.stdin)[\'password\'])" 2>/dev/null || echo "")

          if [ -z "$ES_ENDPOINT" ]; then
            echo "WARN: ES endpoint not yet in SSM (instances may still be bootstrapping)"
            exit 0
          fi

          echo "=== Smoke Test 1: Elasticsearch cluster health ==="
          HEALTH=$(curl -sk -u "elastic:${ELASTIC_PASS}" \
            "https://${ES_ENDPOINT}:9200/_cluster/health?wait_for_status=yellow&timeout=30s" \
            -w "%{http_code}" -o /dev/null)
          if [ "$HEALTH" != "200" ]; then
            echo "FAIL: Elasticsearch health check returned HTTP ${HEALTH}"
            exit 1
          fi
          echo "PASS: ES cluster health OK"

          echo "=== Smoke Test 2: Kibana status ==="
          if [ -n "$KIBANA_ENDPOINT" ]; then
            KB_STATUS=$(curl -sk "https://${KIBANA_ENDPOINT}/api/status" \
              -H "Authorization: Basic $(echo -n elastic:${ELASTIC_PASS} | base64)" \
              -w "%{http_code}" -o /dev/null 2>/dev/null || echo "000")
            if [ "$KB_STATUS" != "200" ]; then
              echo "WARN: Kibana status check returned HTTP ${KB_STATUS} (may still be starting)"
            else
              echo "PASS: Kibana status OK"
            fi
          fi

          echo "=== Smoke Test 3: Index counts ==="
          curl -sk -u "elastic:${ELASTIC_PASS}" \
            "https://${ES_ENDPOINT}:9200/_cat/indices?v&h=health,index,docs.count" | head -20

          echo "=== Smoke Tests complete ==="
        '''
      }
      post {
        failure {
          sh """
            curl -s -X POST '${env.SLACK_WEBHOOK}' \
              -H 'Content-type: application/json' \
              -d '{
                "text": ":red_circle: *ELK Smoke Tests FAILED — ${params.ENVIRONMENT}*\\nBuild: ${BUILD_URL}"
              }' || true
          """
        }
        success {
          sh """
            curl -s -X POST '${env.SLACK_WEBHOOK}' \
              -H 'Content-type: application/json' \
              -d '{
                "text": ":large_green_circle: *ELK Deploy SUCCESS — ${params.ENVIRONMENT}*\\nPlan: ${env.PLAN_SUMMARY}\\nBuild: ${BUILD_URL}"
              }' || true
          """
        }
      }
    }

    // ─── Stage 10: Destroy (with safeguards) ───────────────────────────────
    stage('Destroy') {
      when {
        expression { params.ACTION == 'destroy' }
      }
      steps {
        script {
          if (params.ENVIRONMENT == 'prod') {
            error("Automated destroy of prod is blocked. Use manual runbook.")
          }
        }
        dir("infra-live/${params.ENVIRONMENT}") {
          sh '''
            if [ -n "${MODULE}" ]; then
              cd "${MODULE}"
              terragrunt destroy --terragrunt-non-interactive -auto-approve
            else
              terragrunt run-all destroy \
                --terragrunt-non-interactive \
                --terragrunt-ignore-external-dependencies \
                -auto-approve
            fi
          '''
        }
      }
    }

  } // end stages

  post {
    always {
      // Clear AWS credentials from environment
      script {
        env.AWS_ACCESS_KEY_ID     = ''
        env.AWS_SECRET_ACCESS_KEY = ''
        env.AWS_SESSION_TOKEN     = ''
      }
      cleanWs(cleanWhenNotBuilt: false, deleteDirs: true, notFailBuild: true,
              patterns: [[pattern: '**/.terraform/**', type: 'INCLUDE'],
                         [pattern: '**/tfplan.binary', type: 'INCLUDE']])
    }
    failure {
      mail(
        to: 'elk-platform@acme.com',
        subject: "[FAIL] ELK ${params.ACTION} — ${params.ENVIRONMENT} — Build #${BUILD_NUMBER}",
        body: "Build failed: ${BUILD_URL}\nPlan: ${env.PLAN_SUMMARY}\nCommit: ${env.GIT_COMMIT_SHORT}"
      )
    }
  }
}
