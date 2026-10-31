# Terraform の基本（学習メモ）

このリポジトリのコードを読みながら疑問に思ったことをまとめた学習メモ。
例はすべてこのリポジトリの実際のコード。質問が出たら随時追記する。

---

## 1. スタック構成（フォルダ = 1つの設定）

| フォルダ | 役割 | 寿命 | 実行場所 |
|---|---|---|---|
| `terraform/bootstrap/` | 土台。state 用 S3、OIDC プロバイダ、Actions 用ロール3つ | ずっと（最後に手元で destroy） | 手元PC（state もローカル） |
| `terraform/base/` | **ログを受け止めて残す側**。ALB ログ用 S3、ロググループ3つ、GuardDuty、予算、SNS 通知 | 分析が終わるまで。ほぼ無料 | Actions |
| `terraform/honeypot/` | **攻撃を受ける側**。VPC、EC2（nginx）、ALB、WAF | 観測の48時間だけ。約200円/日 | Actions |

base と honeypot を分けている理由:

- 観測が終わったら honeypot だけすぐ消して課金を止め、base に残ったログでゆっくり分析できる
- 同じスタックだと、destroy した瞬間にログも消えてしまう
- honeypot は base のロググループや S3 に書き込むので、**作る順は base → honeypot、消す順は honeypot → base**

## 2. ファイルの読み込みルール

- Terraform は**フォルダ内の `*.tf` を全部まとめて1つの設定として読む**。ファイル同士の「呼び出し」や include は書かない
- **ファイル名に意味はない**。`main.tf` も慣習的な名前で、全部1ファイルでも10ファイルに分けても結果は同じ
- サブフォルダの中身は読まれない（だから base と honeypot は別々の設定になる）
- 実行順も書かない。リソース同士の参照から自動で決まる
  （例: `alb.tf` の ALB が `network.tf` の `aws_subnet.public` を参照 → サブネットが先に作られる）

`.tf` 以外のファイルは勝手には読まれない:

| ファイル | 扱い |
|---|---|
| `user_data.sh.tftpl` | `ec2.tf` の `templatefile("${path.module}/user_data.sh.tftpl", {...})` で明示的に読み込み、変数を埋めて EC2 の起動スクリプトにする |
| `config/nginx/nginx.conf` など | 同じく `file()` / `templatefile()` で読み込む |
| `terraform.tfvars.example` | 読まれない。変数の書き方の見本 |

## 3. ファイルの分け方

**どのプロジェクトでもほぼ共通のお決まりファイル**（公式スタイルガイドの推奨。名前は慣習で、強制ではない）

| ファイル | 中身 |
|---|---|
| `variables.tf` | 入力（外から渡す値）の定義 |
| `outputs.tf` | 出力（作った後に外へ見せる値） |
| `versions.tf` | Terraform・プロバイダのバージョン、backend（state の置き場所） |
| `main.tf` | リソース本体 |

入力と出力を分けておくと、variables と outputs を見るだけで「このスタックは何を受け取って何を返すか」が分かる。

**リソース本体は AWS の役割ごとに分ける**（honeypot）: `network.tf` / `ec2.tf` / `alb.tf` / `waf.tf`。
「WAF のルールを直したい」→ `waf.tf` だけ見ればいい。base はリソースが少ないので `main.tf` 1つに見出しコメントで区切っている。
目安: 1ファイルが200〜300行を超える、役割の違うものが混ざって探しにくくなったら分ける。

## 4. 名前のルール（宣言と参照の対応表）

| 種類 | 宣言（書く側） | 参照（使う側） | このリポジトリの例 |
|---|---|---|---|
| 入力変数 | `variable "名前" {}` | `var.名前` | `var.log_retention_days` |
| ローカル値 | `locals { 名前 = … }` | `local.名前`（**s が付かない**） | `local.alb_log_bucket` |
| リソース（作る） | `resource "型" "名前" {}` | `型.名前.属性` | `aws_s3_bucket.alb_logs.bucket` |
| データ（既存を読むだけ） | `data "型" "名前" {}` | `data.型.名前.属性` | `data.aws_caller_identity.current.account_id` |
| 出力 | `output "名前" {}` | 中からは参照しない。外で `terraform output 名前` | `alb_log_bucket` |

- **「型」**は AWS プロバイダが決めた名前（`aws_s3_bucket` など）で変えられない。**「名前」**は自分で付ける Terraform 内だけの呼び名（AWS 上の名前ではない）
- リソースだけ接頭辞なし。data は `data.` が付く
- **種類が違えば同じ名前でも衝突しない**。`local.alb_log_bucket` と `output "alb_log_bucket"` が同じ名前なのは「同じものを指している」と人間に分かるようにするための慣習で、仕組み上のつながりはない
- `count` を付けたリソースは `[0]` で番号指定が必要（例: `aws_guardduty_detector.main[0].id`）
- 属性名（`.bucket` `.arn` `.id` など）は型ごとに決まっている。Terraform Registry の各リソースのページの「Attribute Reference」に一覧がある

`aws_s3_bucket.alb_logs.bucket` の読み方:

```text
aws_s3_bucket   . alb_logs        . bucket
（リソースの型）  （自分で付けた名前） （属性: 実際のバケット名）
```

## 5. 「変数」に当たるものは3つ（resource は変数ではない）

`resource` は **AWS に実物を作る**宣言で、変数ではない。値を入れておく箱に当たるのは次の3つ。

| | 何のため | 値の決まり方 | 例 |
|---|---|---|---|
| `variable` | **外から受け取る**設定値（関数の引数のようなもの） | 実行時に渡す。渡さなければ `default` | 予算額、インスタンスタイプ、保持日数 |
| `locals` | **中で計算して使い回す**値（関数内のローカル変数） | コードの中で式から決まる。外からは変えられない | `"${var.project}-alb-logs-${local.account_id}"` で組み立てたバケット名 |
| `output` | **外へ見せる**値（関数の戻り値） | リソースの属性などを指名して出す | 作ったロールの ARN |

```hcl
# variable: 外から受け取る（terraform/base/variables.tf）
variable "log_retention_days" {
  type    = number
  default = 30
}

# locals: 中で組み立てる（terraform/base/main.tf）
locals {
  account_id     = data.aws_caller_identity.current.account_id
  alb_log_bucket = "${var.project}-alb-logs-${local.account_id}"
}

# resource: AWS に実物を作る。variable や local を材料に使う
resource "aws_s3_bucket" "alb_logs" {
  bucket = local.alb_log_bucket
}

# output: 作ったものの値を外へ見せる（terraform/base/outputs.tf）
output "alb_log_bucket" {
  value = aws_s3_bucket.alb_logs.bucket
}
```

流れ: **variable（入力）→ locals（加工）→ resource（AWS に作る）→ output（結果を見せる）**

## 6. variable の値の決まり方（優先順位）

上ほど強い。

1. コマンドの `-var log_retention_days=60`
2. 環境変数 `TF_VAR_log_retention_days=60`（Actions はこの方法。`ENABLE_GUARDDUTY` → `TF_VAR_enable_guardduty` など）
3. `terraform.tfvars` / `*.auto.tfvars`（自動で読まれる）、`-var-file=xxx.tfvars`（指定した時だけ）
4. どれも無ければ `default`

- `log_retention_days` はワークフローから渡していないので default の30日。`main.tf` の4か所（S3 の自動削除、ロググループ3つ）で使っていて、1か所変えれば全部揃って変わる
- **default が無い変数**（base の `alert_email` など）は値を渡さないとエラーになる。Actions では Secret から渡している
- ファイル名に意味があるのは `.tfvars` 側だけ（`terraform.tfvars` と `*.auto.tfvars` は自動で読まれる）

## 7. output と state

- output は「main 側で使うもの」ではなく、**作ったリソースの値を外に見せる窓口**。向きは main → 外
- apply 時に AWS から返ってきた結果（ARN、ID など AWS が決める値も含む）は **state**（S3 にある tfstate ファイル）に記録される。
  `terraform output` はその state から読む
- `terraform output -raw 名前` で値だけ取れる（bootstrap の値を GitHub Secrets に登録する時に使った）
- output に書いていない値は `terraform output` には出てこない

## 8. スタック間の値の受け渡し

honeypot は base の output を直接読んでいるわけではない。`terraform/honeypot/versions.tf` で、
**同じ命名規則で名前を組み立て直して `data` で探している**。

```hcl
# terraform/honeypot/versions.tf
data "aws_s3_bucket" "alb_logs" {
  bucket = "${var.project}-alb-logs-${local.account_id}"
}
```

- `data` は「作らずに既存のものを読むだけ」。base が先に存在しないとエラーになる（base → honeypot の順になる理由）
- base と honeypot で `project` の値を揃える必要があるのはこのため

## 9. 作ったリソースをコード内で「変数みたいに」参照できる

`resource "型" "名前" {}` で作ったものは、同じフォルダのコードから `型.名前.属性` で値を参照できる。
（同じフォルダで作っていないもの＝別スタックや手で作ったものは `data` で探して読む）

例: `terraform/bootstrap/main.tf` の state 用バケット

```hcl
resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket
}

# 同じバケットの設定（対象指定に .id を使う）
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  ...
}

# apply ロールに「このバケットだけ読み書き可」を許可するポリシー（.arn を使う）
resources = [aws_s3_bucket.tfstate.arn]

# outputs.tf でバケット名を外に出す（.bucket を使う）
output "tf_state_bucket" {
  value = aws_s3_bucket.tfstate.bucket
}
```

- plan の時点ではまだ AWS に無いので、ARN などは `(known after apply)` と表示される。
  apply で作られて AWS が値を返した瞬間に確定し、それを参照している後続のリソースに自動で流し込まれる
- この参照があるので Terraform は「バケット → それを参照するポリシー」の順に作ると自動で判断する（実行順を書かなくていい理由）
- 確定した値は state に保存されるので、次回以降の plan / output でも使える

## 10. data は「作らないけど値は欲しいもの」を問い合わせる

`data` は、このコードでは作らないものを探して読み取る仕組み。読むだけなので apply / destroy しても AWS 側には何も起きない。

| 何を聞くか | このリポジトリの例 | 取れる値 |
|---|---|---|
| 自分（今の認証情報）の情報 | `data "aws_caller_identity" "current" {}` | `account_id`。PC の `aws sts get-caller-identity` と同じ。条件不要なので `{}` が空 |
| AWS 側の情報 | `data "aws_elb_service_account" "main" {}` | ALB がログを書き込む AWS 側のアカウント（S3 バケットポリシーで許可する相手） |
| AWS が用意しているもの | `data "aws_ssm_parameter" "al2023_arm64"` | 最新の Amazon Linux 2023 の AMI ID |
| 別スタックで作ったもの | honeypot の `data "aws_s3_bucket" "alb_logs"` など | base で作ったバケット・ロググループ |

- `aws_caller_identity` のおかげで、コードにアカウントIDを直接書かずに済む（public リポジトリでも安心、別アカウントでもそのまま動く）
- 例外: `data "aws_iam_policy_document"` は AWS に問い合わせない。HCL で書いたポリシーを JSON に変換するだけの道具

## 11. 変数を使った条件分岐（論理式）

純粋な変数に当たるのは `variable` と `locals`。ただし**一度決まったら変わらない値**で、プログラムのように途中で代入し直すことはできない。
Terraform には `if` 文がないので、**条件演算子 `条件 ? 真の値 : 偽の値`** を使う。

**ON/OFF スイッチ: `count` を 0 か 1 にする（定番）**

```hcl
# terraform/honeypot/network.tf
resource "aws_vpc_security_group_ingress_rule" "ec2_http_direct" {
  count = var.expose_ec2_directly ? 1 : 0   # true なら1個作る、false なら作らない
  ...
}

# terraform/base/main.tf（GuardDuty も同じ）
resource "aws_guardduty_detector" "main" {
  count = var.enable_guardduty ? 1 : 0
  ...
}
```

`count` を付けたリソースは配列になるので、参照は `[0]` を付ける。作らない場合もあるので参照側にも条件が要る:

```hcl
# terraform/base/outputs.tf
value = var.enable_guardduty ? aws_guardduty_detector.main[0].id : null
```

**文字列の比較**

```hcl
# terraform/honeypot/alb.tf
count = var.acm_certificate_arn == "" ? 0 : 1   # 証明書が指定されていれば HTTPS リスナーを作る
```

**locals で組み立て＋分岐**（OIDC の sub）

```hcl
# terraform/bootstrap/main.tf
sub_repo = (var.github_owner_id != "" && var.github_repo_id != ""
  ? "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repo_id}"
: "repo:${var.github_repo}")
```

**数だけ作る**

```hcl
# terraform/honeypot/network.tf
count = length(var.azs)   # 指定した AZ の数だけサブネットを作る
```

使える演算子: `==` `!=` `>` `<` `>=` `<=`、`&&`（かつ）`||`（または）`!`（否定）、`+ - * /`。
文字列の中に値を埋め込むのは `"${var.project}-alb-logs"`。
