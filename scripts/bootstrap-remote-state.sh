##############################################################################
# scripts/bootstrap-remote-state.sh
# Run ONCE before any terragrunt apply to create the S3 state bucket and
# DynamoDB locking table.
##############################################################################
set -euo pipefail

ENVIRONMENT="${1:?Usage: $0 <environment> <region>}"
REGION="${2:-us-east-2}"
ORG_PREFIX="${ORG_PREFIX:-constantine}"
PROJECT="${PROJECT:-elk}"

BUCKET="${ORG_PREFIX}-${PROJECT}-tfstate-${REGION}"
TABLE="${ORG_PREFIX}-${PROJECT}-tf-locks"

echo "=== Bootstrapping Terraform remote state ==="
echo "  Bucket: $BUCKET"
echo "  Table:  $TABLE"
echo "  Region: $REGION"

# Check if bucket exists
if aws s3api head-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null; then
  echo "Bucket $BUCKET already exists — skipping creation."
else
  echo "Creating state bucket..."
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null || \
  aws s3api create-bucket \
    --bucket "$BUCKET" \
    --region "$REGION"  # us-east-2 doesn't need LocationConstraint

  aws s3api put-bucket-versioning \
    --bucket "$BUCKET" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption \
    --bucket "$BUCKET" \
    --server-side-encryption-configuration '{
      "Rules": [{
        "ApplyServerSideEncryptionByDefault": {
          "SSEAlgorithm": "AES256"
        }
      }]
    }'

  aws s3api put-public-access-block \
    --bucket "$BUCKET" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"

  aws s3api put-bucket-lifecycle-configuration \
    --bucket "$BUCKET" \
    --lifecycle-configuration '{
      "Rules": [{
        "ID": "expire-old-state-versions",
        "Status": "Enabled",
        "Filter": {
            "Prefix": ""
        },
        "NoncurrentVersionExpiration": {"NoncurrentDays": 90}
      }]
    }'

  echo "State bucket created and configured."
fi

# DynamoDB locking table
if aws dynamodb describe-table --table-name "$TABLE" --region "$REGION" 2>/dev/null; then
  echo "DynamoDB table $TABLE already exists — skipping."
else
  echo "Creating DynamoDB lock table..."
  aws dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "$REGION" \
    --tags Key=ManagedBy,Value=bootstrap Key=Project,Value="$PROJECT"

  aws dynamodb wait table-exists \
    --table-name "$TABLE" \
    --region "$REGION"

  echo "DynamoDB lock table created."
fi

echo ""
echo "=== Remote state bootstrapped successfully! ==="
echo ""
echo "Update infra-live/terragrunt.hcl remote_state.config with:"
echo "  bucket = \"$BUCKET\""
echo "  dynamodb_table = \"$TABLE\""
echo "  region = \"$REGION\""
