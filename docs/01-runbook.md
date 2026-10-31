# 構築・観測 手順書

所要時間の目安: 事前準備 30分 / bootstrap と GitHub 設定 30分 / 構築 20分 / 動作確認 20分

---

## 0. 事前準備（構築日より前、できれば今夜）

AWS アカウントの初期設定（ルートの MFA、請求情報へのアクセス許可、Identity Center の管理者ユーザー、手元PCのツールと
`aws configure sso`）は [docs/00-aws-account-setup.md](00-aws-account-setup.md) にまとめてある。まずそれを終わらせる。

- [ ] docs/00 の A〜C が完了し、`aws sts get-caller-identity --profile honeypot-admin` が通る
- [ ] Cost Explorer を有効化済み（docs/00 の A。初回は反映まで最大24時間かかる）
- [ ] GuardDuty が既に有効か確認: `aws guardduty list-detectors --region ap-northeast-1`
  - 何か返ってきたら、GitHub の Variables で `ENABLE_GUARDDUTY = false`（手順2）
  - 初めて有効化するなら30日間の無料トライアル対象
- [ ] `10.100.0.0/16` が既存VPCと重複していないこと（重複していても接続しないので動作はするが、計画書の「隔離」を明確にするため）

## 1. リポジトリ準備

```bash
git clone https://github.com/<OWNER>/<REPO>.git   # <OWNER>/<REPO> は自分のリポジトリに読み替え
cd <REPO>
```

**このリポジトリは public。** Actions のログも誰でも見られる。メールアドレスは Secret と `sensitive` 変数で、
アカウントIDは `mask-aws-account-id` と伏せ字処理でログに出ないようにしてある（docs/07）。
手元の `*.tfstate`・`*.tfvars`・`exports/` は `.gitignore` 済みだが、`git add -A` の前に `git status` で確認する習慣をつけること。

## 2. bootstrap と GitHub の設定（最初に1回だけ。手元PCで）

構築・削除は GitHub Actions + OIDC で行う。その土台（state 用 S3、OIDC プロバイダ、Actions 用ロール3つ）だけは手元PCから作る。
仕組みの説明は [docs/07-github-actions-oidc.md](07-github-actions-oidc.md)。

```bash
export AWS_PROFILE=honeypot-admin     # PowerShell なら $env:AWS_PROFILE = "honeypot-admin"
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
  - gh で登録する場合（PowerShell、`terraform/bootstrap` の中で実行）。**パイプ（`|`）は使わない**（BOM が付いて値が壊れる）
    ```powershell
    gh secret set TF_STATE_BUCKET        --body (terraform output -raw tf_state_bucket)
    gh secret set AWS_PLAN_ROLE_ARN      --body (terraform output -raw plan_role_arn)
    gh secret set AWS_APPLY_ROLE_ARN     --body (terraform output -raw apply_role_arn)
    gh secret set AWS_EMERGENCY_ROLE_ARN --body (terraform output -raw emergency_role_arn)
    gh secret set ALERT_EMAIL            # 対話でメールアドレスを入力
    ```
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

  > 📝 **学習メモ: Environment は何のため？**
  > 目的は「**AWS に変更を加える（apply / destroy）ジョブは、自分が承認ボタンを押すまで動かないようにする**」こと。
  >
  > - **Environment**: GitHub Actions の「デプロイ先」の名前と、そこに入るためのルールのセット。
  >   terraform.yml の apply ジョブに `environment: honeypot-apply` と書いてあるので、このジョブは必ずこのルールを通る
  > - **Required reviewers**: ジョブが「承認待ち」で止まり、承認者が Approve するまで AWS に触らない。
  >   plan の結果を見てから作成・削除を判断できるので、誤操作や意図しない変更を防げる（スマホの GitHub アプリからも承認可）
  > - **main ブランチ限定**: 作業中のブランチや外部からの PR のコードでは apply ジョブが動けない。main に入ったコードだけが AWS を変更できる
  >
  > **AWS 側とのつながり**: このルールを通ったジョブだけ、OIDC トークンの sub が `…:environment:honeypot-apply` になる。
  > AWS の apply ロール（変更権限あり）はこの sub のトークンしか受け付けない（terraform/bootstrap の信頼ポリシー）。
  > つまり「GitHub 側の承認」と「AWS 側の権限」が sub でつながっていて、承認を通らないジョブはワークフローを書き換えても書き込み権限を得られない。
  > plan ロール（読み取り専用）は承認なしで使える。詳しくは docs/07
- [ ] **Actions → 接続確認（OIDC whoami） → Run workflow** が成功し、`sub` と `assumed-role/honeypot-gha-plan/...` が表示される（docs/07 の学習ポイント）

## 2.5 リハーサル（本番の前に1回）

本番の48時間観測を始める前に、**3つのワークフロー（構築・削除 / 接続確認 / 緊急隔離）がすべて動くこと**を確認する。
特に緊急隔離は、本当に必要な時に動かないと困るので必ず通しておく。

所要 1〜2時間。費用は honeypot を動かしている間だけで 10〜20円程度。

| # | やること | 参照 | 確認ポイント |
|---|---|---|---|
| 1 | `base` を plan → apply（承認）。通知メールの Confirm subscription を押す | 3章 1〜2 | base は本番でもそのまま使う |
| 2 | `honeypot` を plan → apply（承認） | 3章 3〜4 | plan に 22番ポートのルールが無いこと |
| 3 | 動作確認 | 4章 | curl で 200 / 404 / WAF の 403、CloudWatch Logs にログが届く |
| 4 | **スマホから**緊急隔離を実行（confirm: `ISOLATE`、snapshot: **オフ**） | 4章の「予行演習」 | EC2 が「停止済み」、ALB のターゲットから外れている |
| 5 | `honeypot` を destroy（承認） | 6章 | 削除ワークフローの確認。base は残す |
| 6 | 本番: `honeypot` を apply し直す → **ここから48時間** | 3章 3〜4 | 攻撃前のきれいな状態から観測を始める |

- 4 で隔離した EC2 は元に戻さず、5 で消して 6 で作り直す（隔離後に戻すより手間が少なく、本番を新品の状態から始められる）
- 4 で snapshot をオフにするのは、スナップショットは Terraform 管理外で destroy しても消えないため（本番で使った場合は撤収時に手で削除）
- 隔離後の destroy は、EC2 の削除完了を待ってから隔離用 SG を消すので時間がかかる。まれに SG の削除がタイムアウトでエラーになったら、destroy をもう一度実行する

**リハーサルで分かったこと（2026-10-31）**

- OIDC whoami が `Not authorized to perform sts:AssumeRoleWithWebIdentity` で失敗 → sub が ID 付き形式だった。bootstrap を修正して再 apply（docs/07）
- base の plan が `InvalidBucketName`（バケット名の先頭に `\ufeff`）で失敗 → Windows PowerShell で `terraform output | gh secret set` とパイプで渡すと BOM が付く。
  `gh secret set 名前 --body (terraform output -raw 名前)` で登録し直して解決
- Actions のログに `Node.js 20 is deprecated` の警告 → 動作には影響なし。観測後に Dependabot の更新 PR で最新化する

## 3. 構築（GitHub Actions）

Actions → **構築・削除（Terraform）** → Run workflow で、次の順に実行する。

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
  - Actions → 緊急隔離（Emergency isolate） → Run workflow（confirm: `ISOLATE`、snapshot: オフ）→ 成功し EC2 が「停止済み」になる
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
