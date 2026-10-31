#!/usr/bin/env bash
# CloudWatch Logs（nginx / WAF）を JSON Lines でローカルへ退避する。
# MCP を使わずにファイルで AI に渡す場合や、ロググループ削除前のバックアップ用。
# 使い方: AWS_PROFILE=xxx ./scripts/export-logs.sh [開始(UTC) 例: 2026-10-30T12:00:00Z] [終了]
# 依存: aws CLI v2, jq
set -euo pipefail

REGION="${AWS_REGION:-ap-northeast-1}"
PROJECT="${PROJECT:-honeypot}"
OUT_DIR="${OUT_DIR:-exports/cwlogs}"
# 日付処理は macOS / Linux 共通にするため python3 で行う
to_ms() { python3 -c 'import sys,datetime as d; a=sys.argv[1]; t=d.datetime.now(d.timezone.utc)-d.timedelta(days=7) if a=="" else d.datetime.fromisoformat(a.replace("Z","+00:00")); print(int(t.timestamp()*1000))' "$1"; }
START_MS=$(to_ms "${1:-}")
END_MS=$(python3 -c 'import time; print(int(time.time()*1000))')
[[ -n "${2:-}" ]] && END_MS=$(to_ms "$2")
mkdir -p "$OUT_DIR"

for GROUP in "/${PROJECT}/nginx/access" "/${PROJECT}/nginx/error" "aws-waf-logs-${PROJECT}"; do
  FILE="$OUT_DIR/$(echo "$GROUP" | sed 's#^/##; s#/#_#g').jsonl"
  echo "exporting $GROUP -> $FILE"
  # CLI が nextToken を自動で辿る
  aws logs filter-log-events --region "$REGION" --log-group-name "$GROUP" \
    --start-time "$START_MS" --end-time "$END_MS" --output json \
    | jq -c '.events[] | {timestamp, stream: .logStreamName, message}' > "$FILE"
  echo "  lines: $(wc -l < "$FILE")"
done
