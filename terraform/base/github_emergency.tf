# -----------------------------------------------------------------------------
# スマホから緊急隔離するための GitHub Actions 用 IAM ロール（OIDC）
#   - アクセスキーは発行しない。GitHub の OIDC トークンで一時的に AssumeRole する
#   - 引き受けられるのは指定リポジトリの main ブランチで動くワークフローだけ
#   - できるのは scripts/emergency-isolate.sh に必要な操作だけ（削除系の権限なし）
#   使わない場合は github_repo = "" にすると作られない
# -----------------------------------------------------------------------------
locals {
  github_emergency_enabled = var.github_repo != ""
}

# OIDC プロバイダはアカウントに1つだけ。既にある場合は create_github_oidc_provider = false
resource "aws_iam_openid_connect_provider" "github" {
  count           = local.github_emergency_enabled && var.create_github_oidc_provider ? 1 : 0
  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = ["6938fd4d98bab03faadb97b34396831e3780aea1"] # 現在 AWS 側では検証に使われないが必須項目
}

data "aws_iam_openid_connect_provider" "github" {
  count = local.github_emergency_enabled && !var.create_github_oidc_provider ? 1 : 0
  url   = "https://token.actions.githubusercontent.com"
}

locals {
  github_oidc_provider_arn = !local.github_emergency_enabled ? "" : (
    var.create_github_oidc_provider
    ? aws_iam_openid_connect_provider.github[0].arn
    : data.aws_iam_openid_connect_provider.github[0].arn
  )
}

data "aws_iam_policy_document" "github_emergency_assume" {
  count = local.github_emergency_enabled ? 1 : 0
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [local.github_oidc_provider_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      # リポジトリ名の大文字小文字の違いで引き受けに失敗しないよう IgnoreCase で比較
      test     = "StringEqualsIgnoreCase"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${var.github_repo}:ref:refs/heads/main"]
    }
  }
}

resource "aws_iam_role" "github_emergency" {
  count                = local.github_emergency_enabled ? 1 : 0
  name                 = "${var.project}-github-emergency"
  assume_role_policy   = data.aws_iam_policy_document.github_emergency_assume[0].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "github_emergency" {
  count = local.github_emergency_enabled ? 1 : 0

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

resource "aws_iam_role_policy" "github_emergency" {
  count  = local.github_emergency_enabled ? 1 : 0
  name   = "emergency-isolate"
  role   = aws_iam_role.github_emergency[0].id
  policy = data.aws_iam_policy_document.github_emergency[0].json
}

output "github_emergency_role_arn" {
  description = "GitHub リポジトリの Variables に AWS_EMERGENCY_ROLE_ARN として登録する"
  value       = local.github_emergency_enabled ? aws_iam_role.github_emergency[0].arn : null
}
