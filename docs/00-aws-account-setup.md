# AWS アカウントの初期設定（Windows）

docs/01 の手順に入る前に、1回だけ行う準備。所要時間の目安は 60〜90 分。
AWS アカウント（ルートユーザーでログインできる状態）があることが前提。

方針: **アクセスキー（長期の鍵）は作らない。**
手元PCは IAM Identity Center の一時認証情報、GitHub Actions は OIDC の一時認証情報で AWS を操作する。

```text
ルートユーザー      … 初期設定と請求まわりだけ。普段は使わない（MFA 必須）
Identity Center の
  管理者ユーザー    … 手元PCからの bootstrap apply、コンソール学習、ログ分析に使う（MFA 必須）
GitHub Actions      … OIDC で honeypot-gha-* ロールを一時的に借りる（docs/07）
```

---

## A. ルートユーザーでやること（コンソール）

- [ ] **MFA を設定する**: 右上のアカウント名 → セキュリティ認証情報 → 多要素認証（MFA）→ MFA デバイスの割り当て
  - スマホの認証アプリ（Google Authenticator / Microsoft Authenticator など）で OK
- [ ] **ルートのアクセスキーが無いことを確認する**: 同じ画面の「アクセスキー」が空であること。あれば削除
- [ ] **IAM ユーザー／ロールに請求情報へのアクセスを許可する**: 右上のアカウント名 → アカウント →
  「IAM ユーザーおよびロールによる請求情報へのアクセス」→ 編集 → 有効化
  - これをしないと、管理者ユーザーでも Cost Explorer・Budgets・請求書が見られない
- [ ] **代替連絡先（セキュリティ）を登録する**: 同じ「アカウント」画面 → 代替連絡先 → セキュリティ に普段見るメールアドレス
  - AWS からの Abuse 通知（docs/05）がここにも届く
- [ ] **Cost Explorer を有効化する**: Billing and Cost Management → Cost Explorer → 有効化（初回は反映まで最大24時間）

## B. IAM Identity Center で管理者ユーザーを作る（コンソール、ルートユーザーで）

IAM ユーザー＋アクセスキーではなく Identity Center を使う理由: ログインごとに数時間で切れる一時認証情報が発行され、
PC にずっと有効な鍵が残らないため（OIDC と同じ考え方）。

1. [ ] リージョンを **アジアパシフィック（東京）** に切り替える
2. [ ] サービス検索で **IAM Identity Center** → **有効にする**
   - 「AWS Organizations で有効にする」を選ぶ（組織が自動で作られ、このアカウントが管理アカウントになる。追加料金なし）
   - ⚠️ **マルチリージョン（追加リージョンへのレプリケーション）は選ばない。暗号化は「AWS 所有キー」のまま。**
     有効化の流れでそのまま進むと、カスタマー管理の KMS キー（マルチリージョン、月額課金）と大阪などへのレプリカが作られる。
     個人の検証では不要。
   - 間違えて有効にした場合の戻し方（この順番で）:
     1. IAM Identity Center → 設定 → 追加したリージョン（例: 大阪）を削除
     2. 設定 → 保管中の暗号化を管理 → **AWS 所有キー** に切り替え
     3. KMS → カスタマー管理型のキー → `mrk-...` を **レプリカ側のリージョンから** 削除スケジュール（7日）→ 東京でも同じキーを削除スケジュール
3. [ ] **ユーザーを追加**: ユーザー → ユーザーを追加
   - ユーザー名: 例 `yamada-admin`、メールアドレス: 自分のアドレス
   - 「パスワードの設定手順が記載された E メールを送信」を選ぶ → 届いたメールから招待を承諾してパスワード設定
4. [ ] **許可セットを作る**: 許可セット → 許可セットを作成 → 事前定義された許可セット → **AdministratorAccess**
   - セッション期間: 4 時間程度（長すぎると漏れた時のリスクが大きい）
5. [ ] **アカウントに割り当てる**: AWS アカウント → 自分のアカウントにチェック → ユーザーまたはグループを割り当て →
   `yamada-admin` → 許可セット `AdministratorAccess`
6. [ ] **MFA を必須にする**: 設定 → 認証 → 多要素認証 → 設定 → 「サインインのたびに」＋「MFA デバイスを登録するよう求める」
7. [ ] **AWS アクセスポータルの URL を控える**: 設定 → 「AWS アクセスポータルの URL」（`https://d-xxxxxxxxxx.awsapps.com/start` の形）
8. [ ] ブラウザのシークレットウィンドウでポータル URL を開き、`yamada-admin` でログイン（MFA 登録）→ アカウント → AdministratorAccess → コンソールが開けば OK

以降、**コンソール作業もこのポータルから入る**。ルートユーザーは請求の最終確認以外では使わない。

## C. 手元PC（Windows）の準備

PowerShell で実行する。インストール後は PowerShell を開き直す（PATH の読み込み直し）。

```powershell
winget install --id Amazon.AWSCLI -e
winget install --id Amazon.SessionManagerPlugin -e
winget install --id Hashicorp.Terraform -e
winget install --id jqlang.jq -e
winget install --id Python.Python.3.12 -e
# Git（Git Bash を含む）と GitHub CLI は導入済み
```

確認:
```powershell
aws --version
session-manager-plugin --version
terraform version      # 1.10 以上
```

### AWS CLI に SSO（Identity Center）のプロファイルを作る

```powershell
aws configure sso
```
聞かれる内容:

| 質問 | 入力 |
|---|---|
| SSO session name | `honeypot` |
| SSO start URL | B-7 で控えたポータル URL |
| SSO region | `ap-northeast-1` |
| SSO registration scopes | そのまま Enter |
| （ブラウザが開く） | `yamada-admin` でログインして「許可」 |
| アカウント／ロール | 自分のアカウント / `AdministratorAccess` |
| Default client Region | `ap-northeast-1` |
| CLI default output format | `json` |
| Profile name | `honeypot-admin` |

確認:
```powershell
$env:AWS_PROFILE = "honeypot-admin"
aws sts get-caller-identity
```
`Arn` に `assumed-role/AWSReservedSSO_AdministratorAccess_.../yamada-admin` と出れば OK。

**次回以降**: 認証が切れたら `aws sso login --profile honeypot-admin`。PowerShell を開くたびに `$env:AWS_PROFILE = "honeypot-admin"` を設定する。

## D. 確認（docs/01 の事前準備の続き）

```powershell
aws guardduty list-detectors --region ap-northeast-1   # 空なら GuardDuty は未使用（30日無料トライアル対象）
aws ec2 describe-vpcs --region ap-northeast-1 --query "Vpcs[].CidrBlock"   # 10.100.0.0/16 と重ならないこと
```

## Windows で作業する時の注意

- `scripts/*.sh` は bash 用。**Git Bash**（Git for Windows に同梱、スタートメニューから起動）で実行する
  - Git Bash でも `export AWS_PROFILE=honeypot-admin` を設定してから実行
  - `scripts/emergency-isolate.sh` など一部は GitHub Actions からも実行できる
- `terraform` と `aws` コマンドは PowerShell・Git Bash どちらでも動く
- docs 内の `./scripts/xxx.sh` は Git Bash で、`terraform -chdir=...` はどちらでも可

## よくあるつまずき

| 症状 | 対処 |
|---|---|
| `aws configure sso` でブラウザが開かない | 表示された URL とコードを手でブラウザに入力する |
| `The SSO session associated with this profile has expired` | `aws sso login --profile honeypot-admin` |
| Cost Explorer / Budgets が「アクセス拒否」 | A の「IAM ユーザー／ロールに請求情報へのアクセスを許可」をルートで実施 |
| 大阪など別リージョンの Identity Center 画面に「有効にする」ボタンと「東京で設定されています」が出る | 正常。押さずに東京へ切り替える |
| Identity Center の有効化ボタンが無い | すでに別リージョンで有効化済みの可能性。リージョンを切り替えて探す（1アカウントで1リージョンのみ） |
