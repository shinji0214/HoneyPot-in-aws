#!/usr/bin/env python3
"""ALB アクセスログ（スペース区切り + ダブルクォート）を CSV に変換する。

使い方: python3 scripts/alb_logs_to_csv.py exports/alb/alb_access.log > exports/alb/alb_access.csv
フィールド定義: https://docs.aws.amazon.com/elasticloadbalancing/latest/application/load-balancer-access-logs.html
"""
import csv
import shlex
import sys

FIELDS = [
    "type", "time", "elb", "client_port", "target_port",
    "request_processing_time", "target_processing_time", "response_processing_time",
    "elb_status_code", "target_status_code", "received_bytes", "sent_bytes",
    "request", "user_agent", "ssl_cipher", "ssl_protocol", "target_group_arn",
    "trace_id", "domain_name", "chosen_cert_arn", "matched_rule_priority",
    "request_creation_time", "actions_executed", "redirect_url", "error_reason",
    "target_port_list", "target_status_code_list", "classification",
    "classification_reason", "conn_trace_id",
]
EXTRA = ["client_ip", "method", "url", "http_version"]


def main(path: str) -> None:
    writer = csv.writer(sys.stdout)
    writer.writerow(FIELDS + EXTRA)
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                parts = shlex.split(line, posix=True)
            except ValueError:
                # 攻撃リクエストで引用符が壊れている行はそのまま捨てずに警告だけ出す
                print(f"skip (parse error): {line[:120]}", file=sys.stderr)
                continue
            row = (parts + [""] * len(FIELDS))[: len(FIELDS)]
            client_ip = row[3].rsplit(":", 1)[0]
            req = row[12].split(" ", 2)
            method, url, version = (req + ["", "", ""])[:3]
            writer.writerow(row + [client_ip, method, url, version])


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(sys.argv[1])
