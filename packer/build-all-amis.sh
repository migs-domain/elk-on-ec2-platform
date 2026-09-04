#!/usr/bin/env bash
##############################################################################
# build-all-amis.sh — Build all node-role AMIs sequentially or in parallel
# Usage: ./build-all-amis.sh [--parallel] [--region us-east-2] [--version 8.12.2]
##############################################################################
set -euo pipefail

ELK_VERSION="${ELK_VERSION:-8.12.2}"
AWS_REGION="${AWS_REGION:-us-east-2}"
PACKER_VPC_ID="${PACKER_VPC_ID:?Set PACKER_VPC_ID}"
PACKER_SUBNET_ID="${PACKER_SUBNET_ID:?Set PACKER_SUBNET_ID}"
PARALLEL="${1:-}"

ROLES=(es-master es-data es-ingest es-coord kibana logstash app-host)

build_role() {
  local role="$1"
  echo ">>> Building AMI for role: $role"
  packer build \
    -var "node_role=$role" \
    -var "elk_version=$ELK_VERSION" \
    -var "aws_region=$AWS_REGION" \
    -var "vpc_id=$PACKER_VPC_ID" \
    -var "subnet_id=$PACKER_SUBNET_ID" \
    elk-node.pkr.hcl 2>&1 | tee "logs/packer-${role}.log"
  echo ">>> Done: $role"
}

mkdir -p logs

if [ "$PARALLEL" = "--parallel" ]; then
  echo "Building all roles in parallel..."
  for role in "${ROLES[@]}"; do
    build_role "$role" &
  done
  wait
  echo "All parallel builds complete."
else
  for role in "${ROLES[@]}"; do
    build_role "$role"
  done
  echo "All sequential builds complete."
fi

echo "AMI IDs:"
jq -r '.builds[] | "\(.custom_data.NodeRole // "unknown"): \(.artifact_id)"' packer-manifest.json 2>/dev/null || true
