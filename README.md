# AWS ハニーポット（48時間観測）

AWS 上に短期間のハニーポットを構築し、Bot・スキャナ・攻撃トラフィックを観測・分析するための一式。
IaC は Terraform。構築・削除は GitHub Actions から、AWS 認証は OIDC（アクセスキーなし）で行う。

```text
Internet ──▶ AWS WAF ──▶ ALB (80) ──▶ EC2 t4g.nano / AL2023 / nginx（静的ページ + 404）
                │            │                 │
                ▼            ▼                 ▼
        CloudWatch Logs     S3          CloudWatch Logs（CloudWatch Agent）
        aws-waf-logs-*   ALBアクセスログ   /honeypot/nginx/{access,error}

GuardDuty（VPC Flow Logs / DNS / CloudTrail を自動解析） / AWS Budgets（$6.5 ≒ 1,000円）
管理: Session Manager のみ（22/tcp は開けない）
VPC 10.100.0.0/16（Peering / TGW / VPN なし、出口は IGW のみ）
```

## まず読む

| 順 | ファイル | 内容 |
|---|---|---|
| 0 | [docs/00-aws-account-setup.md](docs/00-aws-account-setup.md) | AWS アカウントの初期設定（MFA、Identity Center の管理者ユーザー、Windows のツール） |
| 1 | [docs/01-runbook.md](docs/01-runbook.md) | 事前準備 → 構築 → 動作確認 → 観測中にやること |
| 2 | [docs/02-cost-estimate.md](docs/02-cost-estimate.md) | 費用見積もりと予算の見張り方 |
| 3 | [docs/03-teardown-checklist.md](docs/03-teardown-checklist.md) | 2段階の撤収チェックリスト |
| 4 | [docs/04-mcp-analysis.md](docs/04-mcp-analysis.md) | MCP 接続方法と分析プロンプト集 |
| 5 | [docs/05-aws-policy-check.md](docs/05-aws-policy-check.md) | AWS 規約チェックと観測中の禁止事項・Abuse 対応 |
| 6 | [docs/06-incident-response.md](docs/06-incident-response.md) | 乗っ取り対策（防ぐ・気づく・止める）と緊急隔離の手順 |
| 7 | [docs/07-github-actions-oidc.md](docs/07-github-actions-oidc.md) | GitHub Actions + Terraform + OIDC の仕組みと初期設定 |
| 8 | [docs/08-terraform-basics.md](docs/08-terraform-basics.md) | Terraform の基本（スタック構成、ファイル分け、名前のルール、variable / locals / output）の学習メモ |
| — | [queries/logs-insights.md](queries/logs-insights.md) | Logs Insights クエリ集（nginx / WAF） |

## ディレクトリ

```text
terraform/bootstrap/  土台: state 用 S3 / OIDC プロバイダ / Actions 用ロール ×3          ← 手元PCで最初に1回、最後に destroy
terraform/base/       長期保持側: S3(ALBログ) / ロググループ / GuardDuty(+通知) / Budgets   ← 先に apply、最後に destroy
terraform/honeypot/   観測期間だけ: VPC / EC2 / ALB / WAF                          ← 後に apply、観測後すぐ destroy
config/nginx/         nginx.conf（JSON ログ、実IP復元、全部404）
config/cloudwatch-agent/  CloudWatch Agent 設定（user_data で配置）
queries/              Logs Insights クエリ
.github/workflows/    terraform.yml（plan → 承認 → apply/destroy）、emergency-isolate.yml、oidc-whoami.yml
scripts/              tf-init.sh（手元PCで S3 の state を使う）、GuardDuty / CloudWatch Logs / ALB ログの退避、隔離・撤収の確認
iam/                  MCP 用の読み取り専用 IAM ポリシー
mcp/                  MCP サーバー設定例
```

## なぜスタックを分けたか

計画書では「ログは30日残す」「EC2・ALB・WAF は撤収」。1スタックだと destroy でログも消えるため、
課金の大きい観測環境（honeypot）と、安いログ保管（base）を分けた。
honeypot だけ先に destroy すれば、ログを残したまま課金の大半を止められる。
さらに、Actions から Terraform を動かすための土台（state 用 S3 と IAM ロール）は bootstrap として分け、手元PCで管理する。

## 計画書からの変更・補足（判断ポイント）

1. **EC2 の SG は「ALB からの 80 のみ」**: 計画書の「80/443 許可」は ALB 側に適用。EC2 に直接 80 を開けると WAF を迂回できてしまうため。
2. **443 は既定で無効**: HTTPS には独自ドメイン＋ACM 証明書が必要。ある場合は `acm_certificate_arn` を指定。
3. **GuardDuty の Finding が出にくい可能性**: GuardDuty の Recon/PortProbe 系は EC2 に直接届く通信で検知する。
   EC2 を ALB の裏に隠すと Finding がほぼ出ないかもしれない。成功条件「GuardDuty の Finding を確認」を確実にしたいなら
   `expose_ec2_directly = true`（EC2 のパブリックIPで 80 のみ直接公開、22 は閉じたまま）。
   その場合、直接経路のアクセスは WAF ログに残らず nginx ログだけに残る（`peer_ip` が ALB の 10.100.x.x でなければ直接経路）。
   どちらにするかは構築時に決める。迷ったら false で始め、24時間 Finding が無ければ true にして Actions で `honeypot / apply`（数十秒で反映）。
4. **WAF は BLOCK（既定）**: 遮断したリクエストは nginx に届かない。「WAF が無かったら何が届くか」も見たいなら `waf_count_mode = true`。
5. **NAT Gateway は使わない**: EC2 はパブリックサブネットにパブリックIP付きで置き、送信 443 のみ許可（費用理由は docs/02）。
6. **観測後すぐ honeypot を撤収**: 残すと1日約200円。WAF の Sampled requests は直近3時間しか見られないので、コンソール学習は観測中に。

## 安全上の注意

- 22/tcp はどの SG でも開けない。管理は `aws ssm start-session` のみ
- GuardDuty の重大度5以上はメール通知。乗っ取りが疑われたら `scripts/emergency-isolate.sh`、外出中はスマホから GitHub Actions で即隔離（docs/06）
- nginx は静的ページと 404 だけ。アプリ・脆弱なソフトは置かない
- EC2 の送信は 443 のみ（侵害されても踏み台にしにくい）、IMDSv2 強制、EBS 暗号化
- 取得したログは攻撃者の IP・ペイロードを含む。`exports/` はコミットしない（.gitignore 済み）。記事では IP をマスク
- ログを AI に渡す時はプロンプトインジェクションに注意（docs/04 の前置きを使う）
- AWS アクセスキーは作らない。Actions は OIDC で1時間だけの一時認証情報を使う（docs/07）
- tfstate・tfvars をコミットしない（.gitignore 済み）。public リポジトリなので Actions のログにメール・アカウントIDを出さない工夫をしている（docs/07）

## 動作確認済みの範囲

- `terraform validate` / `terraform fmt -check`: bootstrap・base・honeypot とも成功（Terraform 1.12.2 / AWS provider 5.80）
- `terraform apply` と Actions の実行は未実施（AWS・GitHub 上での実動作は未確認）
