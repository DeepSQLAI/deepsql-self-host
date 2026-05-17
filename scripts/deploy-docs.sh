#!/usr/bin/env bash
# Build and deploy docs.deepsql.ai to S3 + CloudFront.
#
# Requires (one-time AWS setup, not done by this script):
#   - S3 bucket: deepsql-docs-461084093078-us-east-2
#   - CloudFront distribution serving the bucket, with alias docs.deepsql.ai
#   - ACM cert for docs.deepsql.ai in us-east-1
#   - Route53 record: docs.deepsql.ai -> CloudFront distribution
#
# Override defaults via env: DOCS_BUCKET, DOCS_DISTRIBUTION_ID, DOCS_REGION.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOCS_DIR="$(cd "$SCRIPT_DIR/../docs" && pwd)"

DOCS_BUCKET="${DOCS_BUCKET:-deepsql-docs-461084093078-us-east-2}"
DOCS_DISTRIBUTION_ID="${DOCS_DISTRIBUTION_ID:-}"
DOCS_REGION="${DOCS_REGION:-us-east-2}"

if [[ -z "$DOCS_DISTRIBUTION_ID" ]]; then
  echo "Error: DOCS_DISTRIBUTION_ID is not set." >&2
  echo "Export it: export DOCS_DISTRIBUTION_ID=<cloudfront-id>" >&2
  exit 1
fi

echo "==> Building Starlight site"
(cd "$DOCS_DIR" && npm install --silent && npm run build)

if [[ ! -d "$DOCS_DIR/dist" ]]; then
  echo "Error: build output $DOCS_DIR/dist not found." >&2
  exit 1
fi

echo "==> Syncing dist/ to s3://$DOCS_BUCKET"
# Long cache for hashed assets, short cache for HTML/JSON/XML.
aws s3 sync "$DOCS_DIR/dist/" "s3://$DOCS_BUCKET/" \
  --region "$DOCS_REGION" \
  --delete \
  --cache-control "public, max-age=31536000, immutable" \
  --exclude "*.html" \
  --exclude "*.xml" \
  --exclude "*.json" \
  --exclude "*.txt"

aws s3 sync "$DOCS_DIR/dist/" "s3://$DOCS_BUCKET/" \
  --region "$DOCS_REGION" \
  --cache-control "public, max-age=60, must-revalidate" \
  --exclude "*" \
  --include "*.html" \
  --include "*.xml" \
  --include "*.json" \
  --include "*.txt"

echo "==> Invalidating CloudFront distribution $DOCS_DISTRIBUTION_ID"
aws cloudfront create-invalidation \
  --distribution-id "$DOCS_DISTRIBUTION_ID" \
  --paths "/*" \
  --query 'Invalidation.{Id:Id,Status:Status}' \
  --output table

echo "==> Deployed. Live in ~1 minute at https://docs.deepsql.ai"
