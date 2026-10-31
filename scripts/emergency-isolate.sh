#!/usr/bin/env bash
# 乗っ取りの疑いがある時の緊急隔離。docs/06-incident-response.md の手順1。
#   1) EC2 の SG を「ルールなし」の隔離用 SG だけに差し替え（新規の送受信を遮断）
#   2) ALB のターゲットから外す
#   3) 調査用に EBS スナップショットを取る（不要なら SNAPSHOT=0）
#   4) EC2 を停止（既存の通信も確実に切る）
# 使い方: AWS_PROFILE=xxx ./scripts/emergency-isolate.sh
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-honeypot}"
SNAPSHOT="${SNAPSHOT:-1}"

IID=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=${PROJECT}-web" "Name=instance-state-name,Values=running,stopped" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
QSG=$(aws ec2 describe-security-groups --region "$REGION" \
  --filters "Name=group-name,Values=${PROJECT}-quarantine" --query 'SecurityGroups[0].GroupId' --output text)
TG=$(aws elbv2 describe-target-groups --region "$REGION" --names "${PROJECT}-web" \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
echo "instance=$IID quarantine_sg=$QSG"
[[ "$IID" == "None" || "$QSG" == "None" ]] && { echo "対象が見つかりません" >&2; exit 1; }

echo "[1/4] SG を隔離用に差し替え"
aws ec2 modify-instance-attribute --region "$REGION" --instance-id "$IID" --groups "$QSG"

echo "[2/4] ALB ターゲットから外す"
aws elbv2 deregister-targets --region "$REGION" --target-group-arn "$TG" --targets "Id=$IID" || true

if [[ "$SNAPSHOT" == "1" ]]; then
  echo "[3/4] EBS スナップショット取得（調査用。撤収時に削除すること）"
  VOL=$(aws ec2 describe-instances --region "$REGION" --instance-ids "$IID" \
    --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
  aws ec2 create-snapshot --region "$REGION" --volume-id "$VOL" \
    --description "${PROJECT} incident $(date -u +%Y%m%dT%H%M%SZ)" \
    --tag-specifications "ResourceType=snapshot,Tags=[{Key=Project,Value=${PROJECT}},{Key=Purpose,Value=incident}]" \
    --query SnapshotId --output text
fi

echo "[4/4] EC2 停止"
aws ec2 stop-instances --region "$REGION" --instance-ids "$IID" --query 'StoppingInstances[0].CurrentState.Name' --output text

echo
echo "隔離完了。次: GuardDuty の Finding を記録 → exports を退避 → terraform destroy（docs/06 手順2以降）"
