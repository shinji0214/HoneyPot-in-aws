# 撤収チェックリスト

撤収は2段階。**課金の大半（ALB・WAF・パブリックIPv4・EC2）は観測終了直後の段階1で止める。**
ログ・GuardDuty は段階2まで残し、分析・記事化に使う。

> 計画書では「記事作成・分析完了後に撤収」だが、ALB/WAF を1週間残すと1日あたり約200円かかり、
> 予算1,000円を超える。WAF・ALB のコンソール学習は観測中に済ませ、観測終了後すぐ段階1を行う。

---

## 段階1: 観測終了直後（honeypot スタック）

### 1-1. 退避（destroy 前に必ず）
- [ ] 観測終了時刻をメモ: `____-__-__ __:__ UTC`
- [ ] WAF Sampled requests の最後のスクショ（直近3時間分）
- [ ] WAF Overview / Rule metrics（Top rules）のスクショ
- [ ] ALB Monitoring タブ（RequestCount, TargetResponseTime, HTTPCode_Target_*）のスクショ
- [ ] GuardDuty Findings 一覧・詳細のスクショ
- [ ] `./scripts/export-guardduty.sh` → `exports/guardduty/findings.json`
- [ ] `./scripts/export-logs.sh <観測開始UTC> <観測終了UTC>` → `exports/cwlogs/*.jsonl`
- [ ] `./scripts/download-alb-logs.sh` → `exports/alb/alb_access.log`
- [ ] `python3 scripts/alb_logs_to_csv.py exports/alb/alb_access.log > exports/alb/alb_access.csv`
- [ ] Logs Insights の主要クエリ結果を CSV エクスポート（結果画面の Export results）

### 1-2. 削除
Actions → **構築・削除（Terraform）** → Run workflow（`stack: honeypot` / `action: destroy`）→ plan のサマリーで削除対象を確認 → 承認
（スマホからでも可。手元PCからなら `./scripts/tf-init.sh honeypot && terraform -chdir=terraform/honeypot destroy`）
- [ ] destroy 完了（EC2 / EBS / ALB / Listener / Target Group / WAF Web ACL / WAF Logging設定 / SG / IGW / Route Table / Subnet / VPC）

### 1-3. 確認
```bash
./scripts/verify.sh teardown
```
- [ ] EC2 なし（terminated は表示されなくなるまで1時間ほど残るが課金なし）
- [ ] 孤立 EBS（available）なし
- [ ] 未使用 Elastic IP なし（今回 EIP は作っていないが念のため）
- [ ] ALB / Target Group なし
- [ ] WAF Web ACL なし
- [ ] honeypot VPC なし
- [ ] NAT Gateway なし

## 段階2: 分析・記事化の完了後（base スタック）

### 2-1. 最終退避
- [ ] 記事に必要なクエリ結果・スクショが揃っている
- [ ] `exports/` を手元に保存した（S3・ロググループは destroy で中身ごと消える）
- [ ] GuardDuty Findings を再エクスポート（段階1以降に増えた分）

### 2-2. 削除
Actions → **構築・削除（Terraform）** → Run workflow（`stack: base` / `action: destroy`）→ 承認
- [ ] S3 バケット削除（`force_destroy = true` なので中身ごと）
- [ ] ロググループ3つ削除
- [ ] GuardDuty detector 削除（= 無効化。Findings も消える）
- [ ] 予算削除（※Cost Explorer での最終確認後に消したい場合は、先に手元PCで `./scripts/tf-init.sh base && terraform -chdir=terraform/base state rm aws_budgets_budget.honeypot` してから destroy し、後でコンソールから手動削除）

### 2-3. bootstrap の削除（手元PC。base の destroy が終わってから）
state 用バケットを消すと base / honeypot の state も消えるため、必ず最後に行う。
```bash
cd terraform/bootstrap
terraform destroy    # state 用 S3、OIDC プロバイダ（このスタックで作った場合）、Actions 用ロール3つ
```
- [ ] GitHub → Settings → Secrets（`TF_STATE_BUCKET` / `AWS_*_ROLE_ARN` / `ALERT_EMAIL`）と Environment `honeypot-apply` を削除
- [ ] 手元の `terraform/bootstrap/terraform.tfstate` を削除してよい

### 2-4. 確認
- [ ] `./scripts/verify.sh teardown` で参考欄の Project=honeypot タグ付きリソースが空（タグ API の反映は遅れることがある）
- [ ] CloudWatch → ロググループに `/honeypot/*` と `aws-waf-logs-honeypot` が無い
- [ ] IAM ロール `honeypot-ec2` / `honeypot-gha-plan` / `honeypot-gha-apply` / `honeypot-gha-emergency` が無い
- [ ] S3 バケット `honeypot-tfstate-<account>` が無い
- [ ] MCP 用に作った許可セット／ロール `honeypot-analyst` を削除

## 段階3: 2〜3日後の請求確認

- [ ] Cost Explorer → サービス別（日次）で、EC2 / ELB / WAF / CloudWatch / GuardDuty / VPC（パブリックIPv4）の課金が段階1・2の翌日以降 0 になっている
- [ ] 記事用に「サービス別の実費」のスクショ
- [ ] 月末の請求書で最終確認

## 撤収完了条件（計画書より）
- [ ] EC2 削除済み
- [ ] ALB 削除済み
- [ ] WAF 削除済み
- [ ] EBS 残骸なし
- [ ] Elastic IP 残骸なし
- [ ] VPC 削除済み
- [ ] Cost Explorer で不要な課金が発生していない
