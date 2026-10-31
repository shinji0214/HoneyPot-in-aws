# 構築・観測 手順書

所要時間の目安: 事前準備 30分 / bootstrap と GitHub 設定 30分 / 構築 20分 / 動作確認 20分

---

## 0. 事前準備（構築日より前、できれば今夜）

- [ ] **Cost Explorer を有効化**（初回は反映まで最大24時間かかる）: Billing and Cost Management → Cost Explorer → 有効化
- [ ] ルートユーザーに MFA、手元PCの作業は IAM Identity Center（または IAM ユーザー）の管理者プロファイルで行う
- [ ] 手元PCに以下をインストール
  - AWS CLI v2（`aws --version`）
  - Session Manager プラグイン（`session-manager-plugin --version`）
  - Terraform 1.10 以上（`terraform version`。S3 だけで state ロックする `use_lockfile` を使うため）
  - jq、python3、（MCPを使うなら）uv
- [ ] `aws sts get-caller-identity --profile <管理者プロファイル>` が通る
- [ ] GuardDuty が既に有効か確認: `aws guardduty list-detectors --region ap-northeast-1`
  - 何か返ってきたら、GitHub の Variables で `ENABLE_GUARDDUTY = false`（手順2）
  - 初めて有効化するなら30日間の無料トライアル対象
- [ ] `10.100.0.0/16` が既存VPCと重複していないこと（重複していても接続しないので動作はするが、計画書の「隔離」を明確にするため）

## 1. リポジトリ準備

```bash
git clone https://github.com/shinji0214/HoneyPot-in-aws.git
cd HoneyPot-in-aws
```

**このリポジトリは public。** Actions のログも誰でも見られる。メールアドレスは Secret と `sensitive` 変数で、
アカウントIDは `mask-aws-account-id` と伏せ字処理でログに出ないようにしてある（docs/07）。
手元の `*.tfstate`・`*.tfvars`・`exports/` は `.gitignore` 済みだが、`git add -A` の前に `git status` で確認する習慣をつけること。

## 2. bootstrap と GitHub の設定（最初に1回だけ。手元PCで）

構築・削除は GitHub Actions + OIDC で行う。その土台（state 用 S3、OIDC プロバイダ、Actions 用ロール3つ）だけは手元PCから作る。
仕組みの説明は [docs/07-github-actions-oidc.md](07-github-actions-oidc.md)。

```bash
export AWS_PROFILE=<管理者プロファイル>
cd terraform/bootstrap
terraform init
terraform apply      # OIDC プロバイダが既にあるアカウントなら -var create_github_oidc_provider=false
terraform output     # 次の4つの値を GitHub に登録する
cd ../..
```

GitHub リポジトリ → Settings で以下を設定する。

- [ ] **Secrets and variables → Actions → Secrets**
  | 名前 | 値 |
  |---|---|
  | `TF_STATE_BUCKET` | output `tf_state_bucket` |
  | `AWS_PLAN_ROLE_ARN` | output `plan_role_arn` |
  | `AWS_APPLY_ROLE_ARN` | output `apply_role_arn` |
  | `AWS_EMERGENCY_ROLE_ARN` | output `emergency_role_arn` |
  | `ALERT_EMAIL` | 予算・GuardDuty 通知を受けるメールアドレス |
- [ ] **Secrets and variables → Actions → Variables**（既定値で良ければ不要）
  | 名前 | 既定 | 意味 |
  |---|---|---|
  | `ENABLE_GUARDDUTY` | `true` | 既に GuardDuty 有効なら `false` |
  | `EXPOSE_EC2_DIRECTLY` | `false` | README「判断ポイント」3 |
  | `WAF_COUNT_MODE` | `false` | README「判断ポイント」4 |
  | `INSTANCE_TYPE` | `t4g.nano` | |
  | `BUDGET_USD` | `6.5` | |
- [ ] **Environments → New environment → `honeypot-apply`**
  - Required reviewers: 自分を追加（apply / destroy の前に承認ボタンが出る。スマホの GitHub アプリからも承認できる）
  - Deployment branches and tags: **Selected branches → `main`** のみ
- [ ] **Actions → OIDC whoami → Run workflow** が成功し、`sub` と `assumed-role/honeypot-gha-plan/...` が表示される（docs/07 の学習ポイント）

## 3. 構築（GitHub Actions）

Actions → **Terraform** → Run workflow で、次の順に実行する。

1. [ ] `stack: base` / `action: plan` → サマリーで作られるものを確認
2. [ ] `stack: base` / `action: apply` → 承認待ちになるので **Review deployments → Approve** → 完了
   - 作られるもの: S3（ALBログ、30日で自動削除）、ロググループ3つ（保持30日）、GuardDuty、GuardDuty 重大度5以上のメール通知、予算（$6.5 ≒ 1,000円）
   - [ ] 「AWS Notification - Subscription Confirmation」メールの **Confirm subscription** を押す（押さないと GuardDuty 通知が届かない）
3. [ ] `stack: honeypot` / `action: plan` → **22番ポートのルールが無いこと**をサマリーで目視確認
4. [ ] `stack: honeypot` / `action: apply` → 承認 → 完了。サマリーの outputs に `alb_dns_name` などが出る

**ここから課金時計スタート。開始時刻をメモ**（48時間後に観測終了）。

手元PCから output を見る・Session Manager に入る場合:

```bash
./scripts/tf-init.sh honeypot
terraform -chdir=terraform/honeypot output
```

## 4. 動作確認（apply の 3〜5 分後）

```bash
./scripts/tf-init.sh honeypot
ALB=$(terraform -chdir=terraform/honeypot output -raw alb_dns_name)
IID=$(terraform -chdir=terraform/honeypot output -raw instance_id)
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
- [ ] 隔離確認: `./scripts/verify.sh isolation` がすべて OK
- [ ] スマホ緊急隔離の予行演習（観測開始前に1回、**スマホから**）
  - Actions → Emergency isolate honeypot → Run workflow（confirm: `ISOLATE`、snapshot: オフ）→ 成功し EC2 が「停止済み」になる
  - 元に戻す: `aws ec2 start-instances --instance-ids $IID`（PC、またはコンソールで「開始」）→ 起動後に Actions「Terraform」で `honeypot / apply`（SG とターゲット登録が元に戻る）→ `curl http://$ALB/` が 200
- [ ] 緊急時の手順 `docs/06-incident-response.md` に目を通し、`scripts/emergency-isolate.sh` の場所を確認しておく
- [ ] 外部から 22 番が開いていない: `nc -vz -w 3 $(terraform -chdir=terraform/honeypot output -raw instance_public_ip) 22` がタイムアウト

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
3. Actions「Terraform」で `honeypot / destroy` → 承認（スマホからでも可）→ ここで課金の大半が止まる
4. `scripts/verify.sh teardown`

## 7. 分析・記事化（1週間以内）

- CloudWatch Logs / S3 / GuardDuty は base スタックに残っているので、Logs Insights・MCP 分析はそのまま続けられる
- `docs/04-mcp-analysis.md` のプロンプトを上から順に
- 終わったら `docs/03-teardown-checklist.md` の「段階2」（base → bootstrap の destroy）
