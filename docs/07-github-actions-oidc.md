# GitHub Actions + Terraform + OIDC

環境の作成・削除を GitHub Actions から行う仕組みと、そこで使う OIDC（アクセスキーを使わない AWS 認証）のまとめ。
**学習用ドキュメント**なので、「なぜそうしているか」を中心に書いている。

表記: `<OWNER>/<REPO>` は GitHub のリポジトリ（オーナー名/リポジトリ名）に読み替える。

---

## 1. 全体像

```text
                     ┌──────────────── 手元PC（最初に1回だけ）────────────────┐
                     │ terraform/bootstrap を apply                              │
                     │   ・state 用 S3 バケット                                  │
                     │   ・OIDC プロバイダ（GitHub を信用する、という登録）       │
                     │   ・Actions 用 IAM ロール ×3（plan / apply / emergency）   │
                     └───────────────────────────────────────────────────────────┘

GitHub Actions（Run workflow）
  ├─ Terraform        plan ジョブ ──(plan ロール: 読み取り専用)──▶ plan 結果をサマリーへ
  │                     │
  │                     ▼ Environment「honeypot-apply」で承認待ち（あなたが Approve）
  │                   apply ジョブ ─(apply ロール: 作成・削除)──▶ base / honeypot を apply / destroy
  │                                                                  │
  │                                                     state ───────┴──▶ S3（use_lockfile でロック）
  ├─ Emergency isolate ──(emergency ロール: 隔離・停止だけ)──▶ EC2 を隔離・停止（承認なしで即実行）
  └─ OIDC whoami      ──(plan ロール)──▶ トークンの中身と「誰として入れたか」を表示（学習用）
```

## 2. OIDC とは何か（アクセスキー方式との違い）

### アクセスキー方式（使わない）
IAM ユーザーのアクセスキー（`AKIA...` と秘密鍵）を GitHub Secrets に保存し、Actions がそれで AWS に入る。

- 鍵は**期限なし**。漏れたら気づくまで使われ放題
- 定期的なローテーションが必要
- 「どのリポジトリ・どのブランチから使われたか」を AWS 側で制限できない

### OIDC 方式（今回）
GitHub が**ジョブごとに**「このジョブは <OWNER>/<REPO> の main ブランチで動いています」と書いた
**署名付きの身分証明書（JWT = ID トークン）**を発行する。AWS はその署名と中身を確認して、**1時間だけ有効な一時認証情報**を渡す。

- 保存しておく秘密がない（GitHub Secrets にあるのはロールの ARN だけで、漏れても単体では使えない）
- 認証情報は1時間で失効
- 信頼ポリシーで「どのリポジトリの、どのブランチ / Environment のジョブなら入れるか」を細かく決められる

### 流れ（1回の Run で起きていること）

```text
 ① ジョブ開始（permissions: id-token: write があると、トークンを要求する権利が付く）
 ② configure-aws-credentials が GitHub に ID トークンを要求
      GitHub ──▶ JWT（iss=https://token.actions.githubusercontent.com, aud=sts.amazonaws.com,
                      sub=repo:<OWNER>/<REPO>:ref:refs/heads/main, 有効期限 数分）
 ③ その JWT を付けて AWS STS の AssumeRoleWithWebIdentity を呼ぶ（ロール ARN を指定）
 ④ STS が確認すること
      a. 署名: OIDC プロバイダ（token.actions.githubusercontent.com）の公開鍵で検証 → 本物の GitHub 発行か
      b. 信頼ポリシーの条件: aud が sts.amazonaws.com か / sub が許可した値か
 ⑤ OK なら一時認証情報（AccessKeyId / SecretAccessKey / SessionToken、最大1時間）を返す
 ⑥ 以降の terraform / aws コマンドはその一時認証情報で動く
```

### トークンの主なクレーム（OIDC whoami ワークフローで実物を見られる）

| クレーム | 例 | 意味 |
|---|---|---|
| `iss` | `https://token.actions.githubusercontent.com` | 発行者。AWS の OIDC プロバイダの URL と一致する必要がある |
| `aud` | `sts.amazonaws.com` | 宛先。信頼ポリシーで固定 |
| `sub` | `repo:<OWNER>/<REPO>:ref:refs/heads/main` | **誰か**。信頼ポリシーの一番大事な条件 |
| `sub`（Environment 使用時） | `repo:<OWNER>/<REPO>:environment:honeypot-apply` | ジョブに `environment:` を書くと sub がこの形に変わる |
| `ref` / `event_name` / `actor` | `refs/heads/main` / `workflow_dispatch` / `<OWNER>` | 参考情報 |

## 3. ロールの分け方（最小権限）

| ロール | 引き受けられるジョブ（sub） | 権限 | 用途 |
|---|---|---|---|
| `honeypot-gha-plan` | main ブランチのワークフロー | `ReadOnlyAccess` | plan、OIDC whoami |
| `honeypot-gha-apply` | Environment `honeypot-apply` のジョブだけ | base / honeypot を作る・消すのに必要な分だけ（下記） | apply / destroy |
| `honeypot-gha-emergency` | main ブランチのワークフロー | `Project=honeypot` の EC2 の隔離・停止、スナップショット | 緊急隔離（承認なしで即実行したいので apply と分離） |

**apply ロールで工夫している点**
- EC2 / ELB / WAF / Logs / GuardDuty / SNS / EventBridge は `aws:RequestedRegion = ap-northeast-1` のときだけ
- IAM は「`honeypot-ec2` ロールを作る」「付けられるのは SSM と CloudWatch Agent の2つの AWS 管理ポリシーだけ」に限定
  → 管理者権限のロールを作って乗っ取る、という**権限昇格ができない**
- S3 は state バケットと ALB ログバケットだけ

**なぜ承認（Environment）を挟むのか**
apply ロールは強い権限を持つので、「main のワークフローなら誰でも」ではなく「承認された apply ジョブだけ」が使えるようにしている。
sub が `environment:honeypot-apply` になるのは、その Environment の保護ルール（承認者・main ブランチ限定）を通過したジョブだけ。

## 4. state を S3 に置く理由

- 手元PCに state があると、Actions からは destroy できない（何を作ったか分からない）
- S3 に置けば Actions と手元PCで同じ state を使える。スマホから destroy まで完結する
- ロックは Terraform 1.10 からの `use_lockfile = true`（S3 上に `.tflock` を置く）。以前必要だった DynamoDB は不要
- バケットはバージョニング有効。state を壊しても前の版に戻せる
- bootstrap スタック自身の state は手元PC（state を置く場所を作るスタックの state は、まだ存在しない場所には置けないため）

## 5. public リポジトリでの注意

このリポジトリは public なので、**Actions のログとジョブサマリーは誰でも見られる**。

| 気にすること | 対策 |
|---|---|
| メールアドレス | Secret `ALERT_EMAIL` で渡し、Terraform 変数も `sensitive = true`（plan に `(sensitive value)` と出る） |
| アカウントID | `mask-aws-account-id: true` でログを伏せ字。サマリーには sed で `************` に置換してから書く |
| ロール ARN・バケット名 | アカウントIDを含むので Variables ではなく Secrets に入れる |
| plan ファイル | Artifact は第三者もダウンロードできるため受け渡さない。apply ジョブで改めて plan して適用 |
| 第三者が勝手に実行 | `workflow_dispatch` は書き込み権限のある人しか実行できない。fork からの PR には OIDC トークンが発行されない |
| 第三者の PR で悪意あるワークフロー | `pull_request_target` は使わない。PR を自動で plan する設定も入れていない |

それでも気になる場合は、リポジトリを private にしても全て同じように動く（Actions の無料枠は private だと月2,000分）。

## 6. アクションのロックファイル（actions.lock）

ワークフローが使う外部のアクション（`actions/checkout` など）は、タグ（`v4.4.0` など）で指定している。
タグは後から別のコミットに付け替えられるので、アクションの作者のアカウントが乗っ取られると、
**同じタグのまま中身が悪意あるコードに差し替わる**ことがある（2025年の tj-actions/changed-files 事件がこの手口）。
今回のワークフローは AWS の権限（OIDC トークン）を扱うので、ここを固定しておく価値が高い。

`.github/workflows/actions.lock` は、各タグが**どのコミットを指していたか**を記録したファイル。
GitHub はこのファイルに書かれたコミットのコードだけを実行する。タグが付け替えられても、ロックしたコミットのまま動く。

| やること | コマンド（手元PC。GitHub CLI と拡張 `github/gh-actions-lock` が必要） |
|---|---|
| アクションを追加・削除した | `gh actions-lock` |
| アクションのバージョンを上げた / タグの付け替えを取り込む | `gh actions-lock --relock`（差分のコミットIDを確認してからコミット） |
| ロックしたコミットが消えた | `gh actions-lock --relock --accept-moved` |

- `gh actions-lock` はワークフロー内の `@v4` のような曖昧な指定を `@v4.4.0` のような正確なバージョンに書き換える
- 生成されたファイルは手で編集しない
- リポジトリ設定の **Require lockfile** を有効にすると、ロックファイルに無いアクションは実行されなくなる
- 2026年10月に一般提供された新しい機能。オプションは `gh actions-lock --help` で確認する

## 7. 初期設定（手順書 docs/01 の手順2と同じ）

1. 手元PCで `terraform/bootstrap` を apply
2. GitHub Secrets に `TF_STATE_BUCKET` / `AWS_PLAN_ROLE_ARN` / `AWS_APPLY_ROLE_ARN` / `AWS_EMERGENCY_ROLE_ARN` / `ALERT_EMAIL`
3. Environment `honeypot-apply` を作り、Required reviewers に自分、Deployment branches を `main` のみに
4. **OIDC whoami** を実行して動作確認

## 8. うまくいかない時

| エラー | 原因と確認 |
|---|---|
| `Not authorized to perform sts:AssumeRoleWithWebIdentity` | 信頼ポリシーの sub と実際の sub が違う。OIDC whoami の `sub` 表示と、bootstrap の `github_repo` / `apply_environment` を見比べる。main 以外のブランチから実行していないか |
| `Could not load credentials from any providers` | ワークフローに `permissions: id-token: write` が無い / Secrets 名の打ち間違い |
| `No OpenIDConnect provider found` | OIDC プロバイダが無い。bootstrap を `create_github_oidc_provider = true` で apply |
| `AccessDenied ... iam:CreateRole` など | apply ロールの権限不足。エラーに出たアクションを `terraform/bootstrap/main.tf` の apply ポリシーに追加して、手元PCで bootstrap を再 apply |
| ワークフローが lockfile 関連のエラーで失敗する | ワークフローの `uses:` を変えたのに actions.lock を更新していない。手元で `gh actions-lock` を実行してコミット |
| `Error acquiring the state lock` | 別の実行が動いている、または中断で `.tflock` が残った。他に動いていないことを確認してから、手元PCで `terraform -chdir=terraform/<stack> force-unlock <ID>` |

## 9. 発展（今回はやらないが学習ネタとして）

- **CloudTrail で見る**: CloudTrail → イベント履歴で `AssumeRoleWithWebIdentity` を検索すると、どのトークン（sub）でいつ入ったかが記録されている。記事ネタになる
- **plan ロールを絞る**: `ReadOnlyAccess` は S3 の中身なども読める。このアカウントに他のデータがあるなら、Terraform が実際に呼ぶ Describe/Get/List だけに絞る（IAM Access Analyzer のポリシー生成で、CloudTrail から必要な権限を洗い出せる）
- **PR で自動 plan**: `pull_request` で plan を走らせ、結果を PR コメントに出す。fork からの PR には OIDC トークンが出ないので安全側に倒れるが、public リポジトリではログ公開の扱いに注意
- **Permissions Boundary**: apply ロールが作るロールに境界ポリシーを強制し、権限昇格対策をさらに堅くする
