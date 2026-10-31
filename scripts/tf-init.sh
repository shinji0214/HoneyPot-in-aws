#!/usr/bin/env bash
# 手元PCで base / honeypot スタックを扱う時の terraform init（state は S3 = Actions と共有）。
# 使い方: AWS_PROFILE=xxx ./scripts/tf-init.sh honeypot
#   その後: terraform -chdir=terraform/honeypot output
# 基本の構築・削除は GitHub Actions で行い、手元では output の確認や緊急時の操作に使う。
set -euo pipefail

STACK="${1:?usage: $0 base|honeypot}"
REGION="${AWS_REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-honeypot}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${TF_STATE_BUCKET:-${PROJECT}-tfstate-${ACCOUNT_ID}}"

terraform -chdir="terraform/${STACK}" init -reconfigure \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=${STACK}/terraform.tfstate" \
  -backend-config="region=${REGION}" \
  -backend-config="use_lockfile=true"
