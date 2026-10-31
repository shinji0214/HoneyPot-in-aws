#!/usr/bin/env bash
# 隔離確認と撤収確認を CLI で行う。
#   ./scripts/verify.sh isolation  … 構築直後: VPC が他と繋がっていないこと、22番が開いていないこと
#   ./scripts/verify.sh teardown   … 撤収後: 課金リソースが残っていないこと
set -uo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-honeypot}"
CIDR="${VPC_CIDR:-10.100.0.0/16}"
MODE="${1:-}"
FAIL=0

check() { # $1=説明 $2=結果(空ならOK)
  local r
  r=$(echo "$2" | sed '/^[[:space:]]*$/d; /^None$/d')
  if [[ -z "$r" ]]; then
    echo "  [OK]  $1"
  else
    echo "  [NG]  $1"; echo "$r" | sed 's/^/        /'; FAIL=1
  fi
}

VPC_ID=$(aws ec2 describe-vpcs --region "$REGION" --filters "Name=cidr,Values=$CIDR" "Name=tag:Project,Values=$PROJECT" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null)

case "$MODE" in
isolation)
  echo "VPC: $VPC_ID"
  [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]] && { echo "ハニーポットVPCが見つかりません"; exit 1; }
  check "VPC Peering なし" "$(aws ec2 describe-vpc-peering-connections --region "$REGION" \
    --filters "Name=requester-vpc-info.vpc-id,Values=$VPC_ID" --query 'VpcPeeringConnections[?Status.Code!=`deleted`].VpcPeeringConnectionId' --output text)
$(aws ec2 describe-vpc-peering-connections --region "$REGION" \
    --filters "Name=accepter-vpc-info.vpc-id,Values=$VPC_ID" --query 'VpcPeeringConnections[?Status.Code!=`deleted`].VpcPeeringConnectionId' --output text)"
  check "Transit Gateway アタッチなし" "$(aws ec2 describe-transit-gateway-attachments --region "$REGION" \
    --filters "Name=resource-id,Values=$VPC_ID" --query 'TransitGatewayAttachments[?State!=`deleted`].TransitGatewayAttachmentId' --output text)"
  check "VPN Gateway アタッチなし" "$(aws ec2 describe-vpn-gateways --region "$REGION" \
    --filters "Name=attachment.vpc-id,Values=$VPC_ID" --query 'VpnGateways[?State!=`deleted`].VpnGatewayId' --output text)"
  check "ルートは local と IGW のみ" "$(aws ec2 describe-route-tables --region "$REGION" --filters "Name=vpc-id,Values=$VPC_ID" \
    --query 'RouteTables[].Routes[?GatewayId!=`local` && !starts_with(GatewayId || `x`, `igw-`)].[DestinationCidrBlock,GatewayId,TransitGatewayId,VpcPeeringConnectionId,NatGatewayId]' --output text)"
  check "22/tcp をインターネットに開けている SG なし" "$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=ip-permission.from-port,Values=22" --query 'SecurityGroups[].GroupId' --output text)"
  check "全ポート開放 SG なし" "$(aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=ip-permission.protocol,Values=-1" "Name=ip-permission.cidr,Values=0.0.0.0/0" \
    --query 'SecurityGroups[].GroupId' --output text)"
  ;;
teardown)
  check "honeypot VPC 削除済み" "$([[ "$VPC_ID" != "None" ]] && echo "$VPC_ID")"
  check "EC2 削除済み" "$(aws ec2 describe-instances --region "$REGION" --filters "Name=tag:Project,Values=$PROJECT" \
    "Name=instance-state-name,Values=pending,running,stopping,stopped" --query 'Reservations[].Instances[].InstanceId' --output text)"
  check "孤立 EBS なし（available 状態のボリューム）" "$(aws ec2 describe-volumes --region "$REGION" \
    --filters "Name=status,Values=available" --query 'Volumes[].[VolumeId,Size,CreateTime]' --output text)"
  check "未使用 Elastic IP なし" "$(aws ec2 describe-addresses --region "$REGION" \
    --query 'Addresses[?AssociationId==null].[PublicIp,AllocationId]' --output text)"
  check "ALB 削除済み" "$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[?starts_with(LoadBalancerName, '${PROJECT}')].LoadBalancerName" --output text)"
  check "Target Group 削除済み" "$(aws elbv2 describe-target-groups --region "$REGION" \
    --query "TargetGroups[?starts_with(TargetGroupName, '${PROJECT}')].TargetGroupName" --output text)"
  check "WAF Web ACL 削除済み" "$(aws wafv2 list-web-acls --scope REGIONAL --region "$REGION" \
    --query "WebACLs[?starts_with(Name, '${PROJECT}')].Name" --output text)"
  check "NAT Gateway なし" "$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=state,Values=pending,available" --query 'NatGateways[].NatGatewayId' --output text)"
  check "スナップショット残骸なし（Project タグ）" "$(aws ec2 describe-snapshots --region "$REGION" --owner-ids self \
    --filters "Name=tag:Project,Values=$PROJECT" --query 'Snapshots[].SnapshotId' --output text)"
  echo
  echo "--- 参考: まだ残っている Project=$PROJECT タグ付きリソース（base 撤収前はログ系が残るのが正常）"
  aws resourcegroupstaggingapi get-resources --region "$REGION" --tag-filters "Key=Project,Values=$PROJECT" \
    --query 'ResourceTagMappingList[].ResourceARN' --output text | tr '\t' '\n' | sed 's/^/  /'
  echo "--- 参考: GuardDuty detector"
  aws guardduty list-detectors --region "$REGION" --query 'DetectorIds' --output text | sed 's/^/  /'
  ;;
*)
  echo "usage: $0 isolation|teardown"; exit 2 ;;
esac

echo
[[ $FAIL -eq 0 ]] && echo "すべて OK" || echo "NG があります。上を確認してください"
exit $FAIL
