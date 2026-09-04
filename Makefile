##############################################################################
# Makefile — Common development tasks
##############################################################################

ENVIRONMENT  ?= dev
REGION       ?= us-east-2
ELK_VERSION  ?= 8.12.2
NODE_ROLE    ?= es-master

.PHONY: help bootstrap-state build-ami fmt validate plan apply destroy \
        gen-certs setup-rbac verify-snapshot smoke-test

help:
	@echo "ELK Platform on AWS — Makefile targets"
	@echo ""
	@echo "Setup:"
	@echo "  make bootstrap-state ENVIRONMENT=dev"
	@echo "  make gen-certs ENVIRONMENT=dev"
	@echo "  make setup-rbac ENVIRONMENT=dev"
	@echo ""
	@echo "AMI Builds:"
	@echo "  make build-ami NODE_ROLE=es-master"
	@echo "  make build-all-amis"
	@echo ""
	@echo "Terraform:"
	@echo "  make fmt"
	@echo "  make validate ENVIRONMENT=dev"
	@echo "  make plan ENVIRONMENT=dev"
	@echo "  make apply ENVIRONMENT=dev"
	@echo ""
	@echo "Operations:"
	@echo "  make verify-snapshot ENVIRONMENT=dev"
	@echo "  make smoke-test ENVIRONMENT=dev"

# ── Bootstrap ─────────────────────────────────────────────────────────────────
bootstrap-state:
	bash scripts/bootstrap-remote-state.sh $(ENVIRONMENT) $(REGION)

# ── AMI Builds ────────────────────────────────────────────────────────────────
build-ami:
	cd packer && packer build \
		-var "node_role=$(NODE_ROLE)" \
		-var "elk_version=$(ELK_VERSION)" \
		-var "aws_region=$(REGION)" \
		-var "vpc_id=$(PACKER_VPC_ID)" \
		-var "subnet_id=$(PACKER_SUBNET_ID)" \
		elk-node.pkr.hcl

build-all-amis:
	cd packer && PACKER_VPC_ID=$(PACKER_VPC_ID) \
		PACKER_SUBNET_ID=$(PACKER_SUBNET_ID) \
		ELK_VERSION=$(ELK_VERSION) \
		./build-all-amis.sh --parallel

# ── Terraform / Terragrunt ────────────────────────────────────────────────────
fmt:
	terraform fmt -recursive infra-modules/
	terraform fmt -recursive infra-live/

validate:
	cd infra-live/$(ENVIRONMENT)/$(REGION) && \
		terragrunt run-all validate --terragrunt-non-interactive

plan:
	cd infra-live/$(ENVIRONMENT)/$(REGION) && \
		terragrunt run-all plan \
		--terragrunt-non-interactive \
		--terragrunt-ignore-external-dependencies \
		-var="elk_version=$(ELK_VERSION)"

apply:
	cd infra-live/$(ENVIRONMENT)/$(REGION) && \
		terragrunt run-all apply \
		--terragrunt-non-interactive \
		--terragrunt-ignore-external-dependencies \
		-auto-approve

# ── Secrets / TLS ─────────────────────────────────────────────────────────────
gen-certs:
	ENVIRONMENT=$(ENVIRONMENT) \
	SSM_PREFIX=/elk/$(ENVIRONMENT) \
	AWS_REGION=$(REGION) \
	bash scripts/generate-tls-certs.sh

setup-rbac:
	ENVIRONMENT=$(ENVIRONMENT) \
	bash scripts/setup-es-rbac.sh

# ── Operations ────────────────────────────────────────────────────────────────
verify-snapshot:
	ENVIRONMENT=$(ENVIRONMENT) \
	bash scripts/verify-snapshot.sh

smoke-test:
	@echo "Running basic cluster health check..."
	@ES_ENDPOINT=$$(aws ssm get-parameter \
		--name /elk/$(ENVIRONMENT)/outputs/es_ingest_endpoint \
		--region $(REGION) --query Parameter.Value --output text 2>/dev/null || echo ""); \
	if [ -z "$$ES_ENDPOINT" ]; then \
		echo "ES endpoint not found in SSM."; exit 1; \
	fi; \
	curl -sk -u "elastic:$${ELASTIC_PASSWORD}" \
		"https://$$ES_ENDPOINT:9200/_cluster/health?pretty"
