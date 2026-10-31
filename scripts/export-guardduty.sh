#!/usr/bin/env bash
# GuardDuty Findings を JSON でローカルへ退避する。
# detector を削除すると Findings も消えるため、base スタックの destroy 前に必ず実行する。
# 使い方: AWS_PROFILE=xxx ./scripts/export-guardduty.sh
# 依存: aws CLI v2, jq
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
OUT_DIR="${OUT_DIR:-exports/guardduty}"
mkdir -p "$OUT_DIR/chunks"

DETECTOR_ID=$(aws guardduty list-detectors --region "$REGION" --query 'DetectorIds[0]' --output text)
if [[ -z "$DETECTOR_ID" || "$DETECTOR_ID" == "None" ]]; then
  echo "GuardDuty detector が見つかりません" >&2
  exit 1
fi
echo "detector: $DETECTOR_ID"

aws guardduty list-findings --region "$REGION" --detector-id "$DETECTOR_ID" \
  --query 'FindingIds' --output text | tr '\t' '\n' | sed '/^$/d' > "$OUT_DIR/finding_ids.txt"
COUNT=$(wc -l < "$OUT_DIR/finding_ids.txt")
echo "findings: $COUNT"
[[ "$COUNT" -eq 0 ]] && { echo "Finding がありません（コンソールの『サンプル結果の生成』で学習用サンプルは作れます）"; exit 0; }

# get-findings は1回50件まで
rm -f "$OUT_DIR"/chunks/*.json
split -l 50 "$OUT_DIR/finding_ids.txt" "$OUT_DIR/chunks/ids_"
for f in "$OUT_DIR"/chunks/ids_*; do
  # shellcheck disable=SC2046
  aws guardduty get-findings --region "$REGION" --detector-id "$DETECTOR_ID" \
    --finding-ids $(cat "$f") --output json > "$f.json"
done

jq -s '[.[].Findings[]]' "$OUT_DIR"/chunks/*.json > "$OUT_DIR/findings.json"

# 一覧（種別・重大度・件数・攻撃元IP）を TSV で
jq -r '
  ["type","severity","count","first_seen","last_seen","resource","remote_ip","remote_country","sample"],
  (.[] | [
    .Type, .Severity, .Service.Count, .Service.EventFirstSeen, .Service.EventLastSeen,
    .Resource.ResourceType,
    (.Service.Action.NetworkConnectionAction.RemoteIpDetails.IpAddressV4
      // (.Service.Action.PortProbeAction.PortProbeDetails[0].RemoteIpDetails.IpAddressV4) // ""),
    (.Service.Action.NetworkConnectionAction.RemoteIpDetails.Country.CountryName
      // (.Service.Action.PortProbeAction.PortProbeDetails[0].RemoteIpDetails.Country.CountryName) // ""),
    (.Service.AdditionalInfo.Sample // false)
  ]) | @tsv' "$OUT_DIR/findings.json" > "$OUT_DIR/findings_summary.tsv"

echo "保存しました: $OUT_DIR/findings.json, $OUT_DIR/findings_summary.tsv"
