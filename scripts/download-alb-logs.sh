#!/usr/bin/env bash
# S3 の ALB アクセスログをローカルへ取得して展開する。
# 使い方: AWS_PROFILE=xxx ./scripts/download-alb-logs.sh
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-honeypot}"
OUT_DIR="${OUT_DIR:-exports/alb}"
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${PROJECT}-alb-logs-${ACCOUNT_ID}"

mkdir -p "$OUT_DIR/raw"
aws s3 sync "s3://${BUCKET}/alb/AWSLogs/${ACCOUNT_ID}/elasticloadbalancing/${REGION}/" "$OUT_DIR/raw/" --region "$REGION"

# 1ファイルにまとめる（時刻順）
find "$OUT_DIR/raw" -name '*.log.gz' -print0 | sort -z | xargs -0 gzip -dc > "$OUT_DIR/alb_access.log"
echo "lines: $(wc -l < "$OUT_DIR/alb_access.log")"
echo "次: python3 scripts/alb_logs_to_csv.py $OUT_DIR/alb_access.log > $OUT_DIR/alb_access.csv"
