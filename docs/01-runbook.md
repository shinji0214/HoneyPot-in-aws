# 構築・観測 手順書

所要時間の目安: 事前準備 30分 / 構築 20分 / 動作確認 20分

---

## 0. 事前準備（構築日より前、できれば今夜）

- [ ] **Cost Explorer を有効化**（初回は反映まで最大24時間かかる）: Billing and Cost Management → Cost Explorer → 有効化
- [ ] ルートユーザーに MFA、日常作業は IAM Identity Center（または IAM ユーザー）の管理者プロファイルで行う
- [ ] 手元PCに以下をインストール
  - AWS CLI v2（`aws --version`）
  - Session Manager プラグイン（`session-manager-plugin --version`）
  - Terraform 1.6 以上（`terraform version`）
  - jq、python3、（MCPを使うなら）uv
- [ ] `aws sts get-caller-identity --profile <管理者プロファイル>` が通る
- [ ] GuardDuty が既に有効か確認: `aws guardduty list-detectors --region ap-northeast-1`
  - 何か返ってきたら `terraform/base/terraform.tfvars` で `enable_guardduty = false`
  - 初めて有効化するなら30日間の無料トライアル対象
- [ ] `10.100.0.0/16` が既存VPCと重複していないこと（重複していても接続しないので動作はするが、計画書の「隔離」を明確にするため）

## 1. リポジトリ準備

```bash
git clone https://github.com/shinji0214/HoneyPot-in-aws.git
cd HoneyPot-in-aws
```

**このリポジトリは public。** `terraform.tfvars`（メールアドレス入り）・`*.tfstate`（アカウントIDやリソースID入り）・`exports/`（攻撃者のIPやペイロード入り）は
`.gitignore` 済みなので、`git add -A` する前に `git status` で紛れ込んでいないか確認する習慣をつけること。

`.gitignore` で `*.tfstate` / `*.tfvars` / `exports/` は除外済み。state はローカル保存（1人・短期間のため S3 backend は不要）。
**state ファイルを消すと destroy できなくなる**ので、作業PCを変えない・削除しないこと。

## 2. base スタック（ログ保管・GuardDuty・予算）

```bash
export AWS_PROFILE=<管理者プロファイル>
cd terraform/base
cp terraform.tfvars.example terraform.tfvars   # alert_email を自分のアドレスに
terraform init
terraform plan
terraform apply
```

作られるもの: S3（ALBログ、30日で自動削除）、ロググループ3つ（保持30日）、GuardDuty、GuardDuty 重大度5以上のメール通知、予算（$6.5 ≒ 1,000円、50%/80%/予測100% でメール）

- [ ] スマホ緊急隔離の設定（`github_repo` を tfvars に入れた場合）
  - `terraform output github_emergency_role_arn` の値を、GitHub リポジトリ → Settings → Secrets and variables → Actions → **Variables** に `AWS_EMERGENCY_ROLE_ARN` として登録
  - `.github/workflows/emergency-isolate.yml` を main に push 済みであること（main 以外のブランチからはロールを引き受けられない）
- [ ] 「AWS Notification - Subscription Confirmation」メールの **Confirm subscription** を押す（押さないと GuardDuty 通知が届かない）

## 3. honeypot スタック（VPC / EC2 / ALB / WAF）

```bash
cd ../honeypot
cp terraform.tfvars.example terraform.tfvars   # 必要なら編集（README の「判断ポイント」参照）
terraform init
terraform plan     # 22番ポートのルールが無いことを目視確認
terraform apply
terraform output   # alb_dns_name と instance_id を控える
```

**ここから課金時計スタート。開始時刻をメモ**（48時間後に観測終了）。

## 4. 動作確認（apply の 3〜5 分後）

```bash
ALB=$(terraform output -raw alb_dns_name)
IID=$(terraform output -raw instance_id)
MYIP=$(curl -s https://checkip.amazonaws.com); echo "自分のIP: $MYIP（分析時に除外する）"

curl -i "http://$ALB/"              # 200 It works!
curl -i "http://$ALB/wp-login.php"  # 404（nginx まで届いた）
curl -i "http://$ALB/?q=<script>alert(1)</script>"   # 403（WAF CommonRuleSet が BLOCK）
```

- [ ] ターゲットが healthy: EC2 → ターゲットグループ → `honeypot-web` → Targets
- [ ] Session Manager で入れる: `aws ssm start-session --target $IID`
  - 中で `sudo tail -f /var/log/nginx/access.log` → 上の curl が JSON で出ている
  - うまく動かない時は `sudo cat /var/log/cloud-init-output.log`
- [ ] CloudWatch Logs `/honeypot/nginx/access` にログが届いている（数十秒遅れる）
- [ ] CloudWatch Logs `aws-waf-logs-honeypot` に BLOCK のログが届いている（5分程度遅れることがある）
- [ ] S3 `honeypot-alb-logs-<account>/alb/` にログが出始める（5分ごと）
- [ ] 隔離確認: `../../scripts/verify.sh isolation` がすべて OK
- [ ] スマホ緊急隔離の予行演習（観測開始前に1回、**スマホから**）
  - Actions → Emergency isolate honeypot → Run workflow（confirm: `ISOLATE`、snapshot: オフ）→ 成功し EC2 が「停止済み」になる
  - 元に戻す（PC）: `aws ec2 start-instances --instance-ids $IID` → 起動後に `terraform apply`（SG とターゲット登録が元に戻る）→ `curl http://$ALB/` が 200
- [ ] 緊急時の手順 `docs/06-incident-response.md` に目を通し、`scripts/emergency-isolate.sh` の場所を確認しておく
- [ ] 外部から 22 番が開いていない: `nc -vz -w 3 $(terraform output -raw instance_public_ip) 22` がタイムアウト

## 5. 観測中（48時間）にやること

コンソールでしか見られない／後から見られない情報があるので、**観測中にコンソール学習とスクショを済ませる**。

| タイミング | やること | 理由 |
|---|---|---|
| 構築直後 | WAF → Web ACL → Overview / Rules / Logging のスクショ | 構成記録 |
| **3時間ごと目安**（起きている間） | WAF → Sampled requests のスクショ | **Sampled requests は直近3時間分しか見られない** |
| 半日ごと | Logs Insights の主要クエリ（`queries/logs-insights.md` A-2〜A-4, C-1〜C-3）を実行・保存 | 推移を記事に使う |
| 1日1回 | Billing → 請求書 / Budgets で金額確認 | 予算1,000円の監視（Cost Explorer は約24時間遅れ） |
| 1日目夜〜2日目 | GuardDuty → Findings を確認・スクショ | 出始めるまで時間がかかる |
| 2日目 | ALB → Monitoring（RequestCount / TargetResponseTime / HTTPCode_Target_4XX / HTTPCode_ELB_4XX） | ALB 削除後はコンソールから辿りにくい |

GuardDuty の Finding が1件も出ない場合: GuardDuty → 設定 → 「サンプル結果の生成」で学習用サンプルを作れる（`[SAMPLE]` 付き。分析時は除外）。

## 6. 観測終了（48時間後）→ 撤収 1段階目

`docs/03-teardown-checklist.md` の「段階1」に従う。要点:

1. 退避: `scripts/export-guardduty.sh` / `scripts/export-logs.sh` / `scripts/download-alb-logs.sh`
2. 残りのスクショ（WAF / ALB / GuardDuty）
3. `terraform destroy`（honeypot スタック）→ ここで課金の大半が止まる
4. `scripts/verify.sh teardown`

## 7. 分析・記事化（1週間以内）

- CloudWatch Logs / S3 / GuardDuty は base スタックに残っているので、Logs Insights・MCP 分析はそのまま続けられる
- `docs/04-mcp-analysis.md` のプロンプトを上から順に
- 終わったら `docs/03-teardown-checklist.md` の「段階2」（base スタック destroy）
