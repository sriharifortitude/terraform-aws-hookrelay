#!/usr/bin/env bash
# Plans examples/complete without an AWS account and writes the plan as
# JSON (default: ./plan.json at the repository root), for tfwarden.
#
# The AWS provider can plan without calling AWS when credential checks are
# skipped and nothing is refreshed. That holds for this example because it
# uses no data source that calls an API: availability zones are listed,
# and aws_region / aws_elb_service_account are answered by the provider
# itself. The settings go in a *_override.tf created here and deleted on
# exit, so they never reach anyone's real configuration.
set -euo pipefail

out="$(cd "$(dirname "$0")/.." && pwd)/${1:-plan.json}"
cd "$(dirname "$0")/../examples/complete"
trap 'rm -f zz_offline_override.tf tfplan' EXIT

cat > zz_offline_override.tf <<'EOF'
provider "aws" {
  region                      = "eu-central-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_requesting_account_id  = true
  skip_metadata_api_check     = true
}
EOF

terraform init -input=false -backend=false > /dev/null
terraform plan -input=false -refresh=false -lock=false -out=tfplan \
  -var 'certificate_arn=arn:aws:acm:eu-central-1:111122223333:certificate/00000000-0000-0000-0000-000000000000' > /dev/null
terraform show -json tfplan > "$out"
echo "wrote $out"
