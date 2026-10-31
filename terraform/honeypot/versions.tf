# =============================================================================
# honeypot スタック（観測期間だけ存在する側）
#   VPC / EC2 / ALB / WAF。課金の大半はここなので、観測とコンソール学習が終わったら
#   base より先にこちらを destroy する。
#   前提: terraform/base を先に apply 済みであること（S3 バケットとロググループを参照する）
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
      Stack     = "honeypot"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  name       = var.project
}

# base スタックが作ったリソースを名前で参照する
data "aws_s3_bucket" "alb_logs" {
  bucket = "${var.project}-alb-logs-${local.account_id}"
}

data "aws_cloudwatch_log_group" "nginx_access" {
  name = "/${var.project}/nginx/access"
}

data "aws_cloudwatch_log_group" "nginx_error" {
  name = "/${var.project}/nginx/error"
}

data "aws_cloudwatch_log_group" "waf" {
  name = "aws-waf-logs-${var.project}"
}
