# =============================================================================
# base スタック（長期保持側）
#   - ALBアクセスログ用 S3 バケット（30日で自動削除）
#   - CloudWatch Logs ロググループ（nginx / WAF、保持30日）
#   - GuardDuty
#   - AWS Budgets（予算アラート）
#
# 観測環境（honeypot スタック）を先に destroy しても、ログはここに残る。
# 分析・記事化が終わったら最後にこのスタックを destroy する。
# =============================================================================

terraform {
  # use_lockfile（S3 だけで state ロック）を使うため 1.10 以上
  required_version = ">= 1.10.0"

  # state は bootstrap スタックで作る S3 バケットに置く（Actions と手元PCで共有するため）。
  # bucket / key / region は init 時に -backend-config で渡す（docs/07 参照）
  backend "s3" {}

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
      Stack     = "base"
    }
  }
}

data "aws_caller_identity" "current" {}
data "aws_elb_service_account" "main" {}

locals {
  account_id     = data.aws_caller_identity.current.account_id
  alb_log_bucket = "${var.project}-alb-logs-${local.account_id}"
}

# -----------------------------------------------------------------------------
# S3: ALB アクセスログ
# -----------------------------------------------------------------------------
resource "aws_s3_bucket" "alb_logs" {
  bucket = local.alb_log_bucket
  # 最終撤収で中身ごと消せるようにする（消したくない時はローカルへ退避してから destroy）
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "alb_logs" {
  bucket                  = aws_s3_bucket.alb_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# ALB アクセスログは SSE-S3 (AES256) のみ対応（SSE-KMS 不可）
resource "aws_s3_bucket_server_side_encryption_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "alb_logs" {
  bucket = aws_s3_bucket.alb_logs.id
  rule {
    id     = "expire-after-retention"
    status = "Enabled"
    filter {}
    expiration {
      days = var.log_retention_days
    }
    noncurrent_version_expiration {
      noncurrent_days = 1
    }
  }
}

data "aws_iam_policy_document" "alb_logs" {
  # 東京など2022年8月以前からあるリージョンは ELB のリージョン別アカウントに書き込み権限を与える
  statement {
    sid       = "AllowELBRegionalAccount"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "AWS"
      identifiers = [data.aws_elb_service_account.main.arn]
    }
  }

  # 新しいリージョン向けのサービスプリンシパル方式（併記しても害はない）
  statement {
    sid       = "AllowELBLogDelivery"
    effect    = "Allow"
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.alb_logs.arn}/alb/AWSLogs/${local.account_id}/*"]
    principals {
      type        = "Service"
      identifiers = ["logdelivery.elasticloadbalancing.amazonaws.com"]
    }
  }

  statement {
    sid     = "DenyInsecureTransport"
    effect  = "Deny"
    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.alb_logs.arn,
      "${aws_s3_bucket.alb_logs.arn}/*",
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

resource "aws_s3_bucket_policy" "alb_logs" {
  bucket     = aws_s3_bucket.alb_logs.id
  policy     = data.aws_iam_policy_document.alb_logs.json
  depends_on = [aws_s3_bucket_public_access_block.alb_logs]
}

# -----------------------------------------------------------------------------
# CloudWatch Logs
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "nginx_access" {
  name              = "/${var.project}/nginx/access"
  retention_in_days = var.log_retention_days
}

resource "aws_cloudwatch_log_group" "nginx_error" {
  name              = "/${var.project}/nginx/error"
  retention_in_days = var.log_retention_days
}

# WAF のログ出力先ロググループ名は "aws-waf-logs-" で始まる必要がある
resource "aws_cloudwatch_log_group" "waf" {
  name              = "aws-waf-logs-${var.project}"
  retention_in_days = var.log_retention_days
}

# WAF -> CloudWatch Logs 配信用のリソースポリシー
data "aws_iam_policy_document" "waf_logs" {
  statement {
    effect    = "Allow"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.waf.arn}:*"]
    principals {
      type        = "Service"
      identifiers = ["delivery.logs.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:logs:${var.region}:${local.account_id}:*"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "waf_logs" {
  policy_name     = "${var.project}-waf-logs"
  policy_document = data.aws_iam_policy_document.waf_logs.json
}

# -----------------------------------------------------------------------------
# GuardDuty
#   既にアカウントで有効化済みなら enable_guardduty = false にする（二重作成でエラーになるため）
#   ※ detector を削除すると Findings も消える。撤収前に scripts/export-guardduty.sh で退避すること
# -----------------------------------------------------------------------------
resource "aws_guardduty_detector" "main" {
  count                        = var.enable_guardduty ? 1 : 0
  enable                       = true
  finding_publishing_frequency = "FIFTEEN_MINUTES"
}

# 今回は EC2 のネットワーク系 Finding（Recon / PortProbe / UnauthorizedAccess）が目的なので、
# 基本機能（VPC Flow Logs / DNS / CloudTrail 解析）以外の保護プランは無効化して課金と雑音を抑える
resource "aws_guardduty_detector_feature" "disabled" {
  for_each = var.enable_guardduty ? toset([
    "S3_DATA_EVENTS",
    "EKS_AUDIT_LOGS",
    "EBS_MALWARE_PROTECTION",
    "RDS_LOGIN_EVENTS",
    "LAMBDA_NETWORK_LOGS",
    "RUNTIME_MONITORING",
  ]) : toset([])

  detector_id = aws_guardduty_detector.main[0].id
  name        = each.value
  status      = "DISABLED"
}

# -----------------------------------------------------------------------------
# AWS Budgets
#   アカウント全体の当月コストを対象にする（タグでの絞り込みはコスト配分タグの有効化に
#   最大24時間かかり、構築当日に間に合わないため）
#   ※ Budgets の金額は USD。1,000円 ≒ var.budget_usd（既定 6.5USD）
#   ※ 請求データの反映は数時間〜1日遅れる。アラートは「止める合図」であり「自動停止」ではない
# -----------------------------------------------------------------------------
resource "aws_budgets_budget" "honeypot" {
  name         = "${var.project}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 50
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.alert_email]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.alert_email]
  }
}

# -----------------------------------------------------------------------------
# 乗っ取り検知の通知: GuardDuty の重大度 5 以上（Medium の上半分〜High）をメールで通知
#   外から届くだけの Recon:EC2/PortProbeUnprotectedPort 等は Low（2前後）なので通知されない。
#   Backdoor:EC2/* や CryptoCurrency:EC2/* など「EC2 から外へ」の Finding は High（8前後）で通知される。
#   ※ apply 後に届く「AWS Notification - Subscription Confirmation」メールのリンクを押すまで通知は届かない
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "security_alerts" {
  name = "${var.project}-security-alerts"
}

resource "aws_sns_topic_subscription" "security_alerts_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

data "aws_iam_policy_document" "security_alerts" {
  statement {
    actions   = ["sns:Publish"]
    resources = [aws_sns_topic.security_alerts.arn]
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }
    condition {
      test     = "ArnEquals"
      variable = "aws:SourceArn"
      values   = [aws_cloudwatch_event_rule.guardduty_high.arn]
    }
  }
}

resource "aws_sns_topic_policy" "security_alerts" {
  arn    = aws_sns_topic.security_alerts.arn
  policy = data.aws_iam_policy_document.security_alerts.json
}

resource "aws_cloudwatch_event_rule" "guardduty_high" {
  name        = "${var.project}-guardduty-severity5plus"
  description = "GuardDuty findings with severity >= 5"
  event_pattern = jsonencode({
    source        = ["aws.guardduty"]
    "detail-type" = ["GuardDuty Finding"]
    detail = {
      severity = [{ numeric = [">=", 5] }]
    }
  })
}

resource "aws_cloudwatch_event_target" "guardduty_high_sns" {
  rule      = aws_cloudwatch_event_rule.guardduty_high.name
  target_id = "sns"
  arn       = aws_sns_topic.security_alerts.arn
  input_transformer {
    input_paths = {
      type     = "$.detail.type"
      severity = "$.detail.severity"
      title    = "$.detail.title"
      resource = "$.detail.resource.resourceType"
      region   = "$.region"
    }
    input_template = "\"[honeypot] GuardDuty severity <severity>: <type> / <title> (resource: <resource>, region: <region>)。乗っ取りの疑いがあれば scripts/emergency-isolate.sh を実行し、docs/06-incident-response.md に従うこと\""
  }
}
