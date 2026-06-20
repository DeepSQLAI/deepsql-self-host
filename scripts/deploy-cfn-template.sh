#!/usr/bin/env bash
# Publish cloudformation/deepsql-stack.yaml to the public S3 bucket that backs
# the one-click "Launch Stack" link in the docs.
#
# Why a dedicated public bucket (not install.deepsql.ai)?
#   The CloudFormation console only accepts a *native S3 URL* for templateURL
#   (https://<bucket>.s3.<region>.amazonaws.com/...). A CloudFront/custom-domain
#   URL is rejected with "Unsupported URL". The install bucket sits behind
#   CloudFront with Origin Access Control (private to CloudFront), so its objects
#   are not directly readable. This bucket is public-read and holds only the
#   non-sensitive CFN template (AdminPassword is a NoEcho launch parameter, never
#   baked into the template).
#
# Requires (one-time AWS setup, already done — kept here for reference):
#   aws s3api create-bucket --bucket "$CFN_BUCKET" --region "$CFN_REGION" \
#     --create-bucket-configuration LocationConstraint="$CFN_REGION"
#   aws s3api put-public-access-block --bucket "$CFN_BUCKET" \
#     --public-access-block-configuration \
#     BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=false,RestrictPublicBuckets=false
#   aws s3api put-bucket-policy --bucket "$CFN_BUCKET" --policy '{
#     "Version":"2012-10-17","Statement":[{"Sid":"PublicReadCfnTemplates",
#     "Effect":"Allow","Principal":"*","Action":"s3:GetObject",
#     "Resource":"arn:aws:s3:::<bucket>/*"}]}'
#
# Override defaults via env: CFN_BUCKET, CFN_REGION, CFN_KEY.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$(cd "$SCRIPT_DIR/.." && pwd)/cloudformation/deepsql-stack.yaml"

CFN_BUCKET="${CFN_BUCKET:-deepsql-cfn-461084093078-us-east-2}"
CFN_REGION="${CFN_REGION:-us-east-2}"
CFN_KEY="${CFN_KEY:-deepsql-stack.yaml}"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "Error: template not found at $TEMPLATE" >&2
  exit 1
fi

echo "==> Validating template before upload"
aws cloudformation validate-template \
  --template-body "file://$TEMPLATE" \
  --region "$CFN_REGION" \
  --query 'Description' --output text >/dev/null

echo "==> Uploading $TEMPLATE -> s3://$CFN_BUCKET/$CFN_KEY"
aws s3 cp "$TEMPLATE" "s3://$CFN_BUCKET/$CFN_KEY" \
  --region "$CFN_REGION" \
  --content-type "text/yaml" \
  --cache-control "public, max-age=300, must-revalidate"

URL="https://$CFN_BUCKET.s3.$CFN_REGION.amazonaws.com/$CFN_KEY"
echo "==> Verifying public reachability: $URL"
code="$(curl -sS -o /dev/null -w '%{http_code}' "$URL")"
if [[ "$code" != "200" ]]; then
  echo "Error: expected HTTP 200, got $code. Template may not be publicly readable." >&2
  exit 1
fi

echo "==> Published. One-click templateURL:"
echo "    $URL"
