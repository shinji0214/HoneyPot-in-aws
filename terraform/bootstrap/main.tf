# =============================================================================
# bootstrap スタック（最初に1回だけ、手元PCから管理者権限で apply する）
#
#   GitHub Actions から Terraform を動かすための「土台」を作る:
#     - Terraform state 用 S3 バケット（base / honeypot の state をここに置く）
#     - GitHub Actions の OIDC プロバイダ（アクセスキーの代わり）
#     - Actions が引き受ける IAM ロール 3 つ
#         plan      : 読み取り専用。plan と OIDC 動作確認用。main ブランチのワークフローのみ
#         apply     : 構築・削除。GitHub Environment「honeypot-apply」（承認必須）のジョブのみ
#         emergency : EC2 の隔離・停止だけ。main ブランチのワークフローのみ（承認なしで即実行）
#
#   このスタック自身の state は手元PC（terraform.tfstate、.gitignore 済み）に置く。
#   「state を置くバケット」を作るスタックの state はそのバケットに置けない（鶏と卵）ため。
#   撤収の最後に手元PCから destroy する。
# =============================================================================

terraform {
  required_version = ">= 1.10.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.70"
    }
  }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Stack     = "bootstrap"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id   = data.aws_caller_identity.current.account_id
  state_bucket = "${var.project}-tfstate-${local.account_id}"
  oidc_host    = "token.actions.githubusercontent.com"

  # OIDC トークンの sub クレーム（どのリポジトリ・どのブランチ/環境のジョブか）
  #   従来形式: repo:OWNER/REPO:ref:refs/heads/main
  #   ID 付き形式: repo:OWNER@OWNER_ID/REPO@REPO_ID:ref:refs/heads/main
  #     GitHub がオーナー・リポジトリの不変 ID を sub に含めて発行する形式。リポジトリを消して同名で
  #     作り直されても ID が変わるので、乗っ取られた同名リポジトリからはロールを引き受けられない。
  #   実際にどちらで発行されているかは OIDC whoami ワークフローの sub 表示で確認できる
  github_owner = split("/", var.github_repo)[0]
  github_name  = split("/", var.github_repo)[1]
  sub_repo = (var.github_owner_id != "" && var.github_repo_id != ""
    ? "repo:${local.github_owner}@${var.github_owner_id}/${local.github_name}@${var.github_repo_id}"
  : "repo:${var.github_repo}")

  sub_main_branch = "${local.sub_repo}:ref:refs/heads/main"
  sub_apply_env   = "${local.sub_repo}:environment:${var.apply_environment}"
}

# -----------------------------------------------------------------------------
# Terraform state 用 S3 バケット
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket
  # 撤収の最後に bootstrap を destroy する時、中身（旧バージョン含む）ごと消せるようにする
  force_destroy = true
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled" # state を壊した時に前のバージョンへ戻せるように
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "tfstate" {
  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.tfstate.arn,
      "${aws_s3_bucket.tfstate.arn}/*",
    ]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "tfstate" {
  bucket     = aws_s3_bucket.tfstate.id
  policy     = data.aws_iam_policy_document.tfstate.json
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# -----------------------------------------------------------------------------
# GitHub Actions OIDC プロバイダ
#   「token.actions.githubusercontent.com が署名したトークンを信用する」という AWS 側の登録。
#   アカウントに1つだけ作れる。既にあれば create_github_oidc_provider = false
# -----------------------------------------------------------------------------
resource "aws_iam_openid_connect_provider" "github" {
  count          = var.create_github_oidc_provider ? 1 : 0
  url            = "https://${local.oidc_host}"
  client_id_list = ["sts.amazonaws.com"]
  # 現在 AWS は GitHub の証明書を独自に検証しておりこの値は使われないが、API 上は必須
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

data "aws_iam_openid_connect_provider" "github" {
  count = var.create_github_oidc_provider ? 0 : 1
  url   = "https://${local.oidc_host}"
}

locals {
  oidc_provider_arn = var.create_github_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : data.aws_iam_openid_connect_provider.github[0].arn
}

# 信頼ポリシー（誰がこのロールを引き受けられるか）を sub ごとに作る関数代わり
data "aws_iam_policy_document" "trust" {
  for_each = {
    plan      = local.sub_main_branch
    apply     = local.sub_apply_env
    emergency = local.sub_main_branch
  }

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }
    # aud: このトークンは AWS STS 向けに発行されたものか
    condition {
      test     = "StringEquals"
      variable = "${local.oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }
    # sub: どのリポジトリの、どのブランチ / Environment のジョブか。
    # リポジトリ名の大文字小文字の違いで失敗しないよう IgnoreCase で比較
    condition {
      test     = "StringEqualsIgnoreCase"
      variable = "${local.oidc_host}:sub"
      values   = [each.value]
    }
  }
}

# -----------------------------------------------------------------------------
# plan ロール: 読み取り専用
# -----------------------------------------------------------------------------
resource "aws_iam_role" "plan" {
  name                 = "${var.project}-gha-plan"
  description          = "GitHub Actions: terraform plan (read only)"
  assume_role_policy   = data.aws_iam_policy_document.trust["plan"].json
  max_session_duration = 3600
}

# terraform plan は全リソースの現状を読むので AWS 管理の ReadOnlyAccess を使う。
# ※ ReadOnlyAccess はアカウント内の S3 オブジェクト等も読める。このアカウントを
#   ハニーポット専用（他の機密データなし）で使う前提。気になる場合は docs/07 の「発展」参照
resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# -----------------------------------------------------------------------------
# apply ロール: base / honeypot スタックの作成・削除に必要な権限
# -----------------------------------------------------------------------------
resource "aws_iam_role" "apply" {
  name                 = "${var.project}-gha-apply"
  description          = "GitHub Actions: terraform apply/destroy for honeypot stacks (environment-gated)"
  assume_role_policy   = data.aws_iam_policy_document.trust["apply"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "apply" {
  # state の読み書き（ロックファイル *.tflock を含む）
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.tfstate.arn]
  }
  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.tfstate.arn}/*"]
  }

  # 東京リージョンでだけ使えるサービス群（他リージョンでは何も作れない）
  statement {
    sid = "RegionalServices"
    actions = [
      "ec2:*",
      "elasticloadbalancing:*",
      "wafv2:*",
      "logs:*",
      "guardduty:*",
      "sns:*",
      "events:*",
      "ssm:GetParameter",
      "ssm:GetParameters",
    ]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "aws:RequestedRegion"
      values   = [var.region]
    }
  }

  # ALB ログ用バケットだけ操作できる
  statement {
    sid       = "AlbLogBucket"
    actions   = ["s3:*"]
    resources = ["arn:aws:s3:::${var.project}-alb-logs-${local.account_id}", "arn:aws:s3:::${var.project}-alb-logs-${local.account_id}/*"]
  }
  statement {
    sid       = "S3ListForProvider"
    actions   = ["s3:ListAllMyBuckets", "s3:GetBucketLocation"]
    resources = ["*"]
  }

  # Budgets はグローバルサービス
  statement {
    sid       = "Budgets"
    actions   = ["budgets:*"]
    resources = ["arn:aws:budgets::${local.account_id}:budget/${var.project}-*"]
  }
  statement {
    sid       = "BudgetsRead"
    actions   = ["budgets:ViewBudget", "budgets:DescribeBudgets", "budgets:ListTagsForResource"]
    resources = ["*"]
  }

  # IAM: 権限昇格を防ぐため、作れるのは honeypot-* のロールだけ、付けられるのは決め打ちの2ポリシーだけ
  statement {
    sid = "HoneypotRolesOnly"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:TagRole", "iam:UntagRole",
      "iam:UpdateRole", "iam:UpdateAssumeRolePolicy",
      "iam:ListRolePolicies", "iam:ListAttachedRolePolicies", "iam:ListInstanceProfilesForRole",
    ]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-ec2"]
  }
  statement {
    sid       = "AttachOnlyApprovedPolicies"
    actions   = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-ec2"]
    condition {
      test     = "ArnEquals"
      variable = "iam:PolicyARN"
      values = [
        "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
        "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy",
      ]
    }
  }
  statement {
    sid = "InstanceProfile"
    actions = [
      "iam:CreateInstanceProfile", "iam:DeleteInstanceProfile", "iam:GetInstanceProfile",
      "iam:AddRoleToInstanceProfile", "iam:RemoveRoleFromInstanceProfile",
      "iam:TagInstanceProfile", "iam:UntagInstanceProfile",
    ]
    resources = ["arn:aws:iam::${local.account_id}:instance-profile/${var.project}-ec2"]
  }
  statement {
    sid       = "PassEc2RoleToEc2Only"
    actions   = ["iam:PassRole"]
    resources = ["arn:aws:iam::${local.account_id}:role/${var.project}-ec2"]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com"]
    }
  }
  statement {
    sid       = "ReadPolicies"
    actions   = ["iam:GetPolicy", "iam:GetPolicyVersion"]
    resources = ["*"]
  }
  # 初めて ALB / GuardDuty / WAF を使うアカウントではサービスリンクロールが自動作成される
  statement {
    sid       = "ServiceLinkedRoles"
    actions   = ["iam:CreateServiceLinkedRole"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "iam:AWSServiceName"
      values = [
        "elasticloadbalancing.amazonaws.com",
        "guardduty.amazonaws.com",
        "malware-protection.guardduty.amazonaws.com",
        "wafv2.amazonaws.com",
      ]
    }
  }
}

resource "aws_iam_role_policy" "apply" {
  name   = "honeypot-stacks"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply.json
}

# -----------------------------------------------------------------------------
# emergency ロール: EC2 の隔離・停止だけ（削除はできない）
# -----------------------------------------------------------------------------
resource "aws_iam_role" "emergency" {
  name                 = "${var.project}-gha-emergency"
  description          = "GitHub Actions: isolate and stop honeypot EC2 only"
  assume_role_policy   = data.aws_iam_policy_document.trust["emergency"].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "emergency" {
  statement {
    sid = "Describe"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeSecurityGroups",
      "elasticloadbalancing:DescribeTargetGroups",
    ]
    resources = ["*"]
  }

  # Project=honeypot タグの付いたインスタンス・SG に対してのみ SG 差し替えと停止を許可
  statement {
    sid     = "IsolateAndStopHoneypotOnly"
    actions = ["ec2:ModifyInstanceAttribute", "ec2:StopInstances"]
    resources = [
      "arn:aws:ec2:${var.region}:${local.account_id}:instance/*",
      "arn:aws:ec2:${var.region}:${local.account_id}:security-group/*",
    ]
    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Project"
      values   = [var.project]
    }
  }

  statement {
    sid       = "DeregisterFromHoneypotTargetGroup"
    actions   = ["elasticloadbalancing:DeregisterTargets"]
    resources = ["arn:aws:elasticloadbalancing:${var.region}:${local.account_id}:targetgroup/${var.project}-web/*"]
  }

  statement {
    sid     = "ForensicSnapshot"
    actions = ["ec2:CreateSnapshot"]
    resources = [
      "arn:aws:ec2:${var.region}:${local.account_id}:volume/*",
      "arn:aws:ec2:${var.region}::snapshot/*",
    ]
  }

  statement {
    sid       = "TagSnapshotOnCreate"
    actions   = ["ec2:CreateTags"]
    resources = ["arn:aws:ec2:${var.region}::snapshot/*"]
    condition {
      test     = "StringEquals"
      variable = "ec2:CreateAction"
      values   = ["CreateSnapshot"]
    }
  }
}

resource "aws_iam_role_policy" "emergency" {
  name   = "emergency-isolate"
  role   = aws_iam_role.emergency.id
  policy = data.aws_iam_policy_document.emergency.json
}
