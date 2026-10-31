locals {
  # 計画書の3ルールグループ。いずれも追加料金なしの AWS マネージドルール（ルール1個=$1/月 の按分のみ）
  waf_managed_rule_groups = [
    "AWSManagedRulesCommonRuleSet",
    "AWSManagedRulesKnownBadInputsRuleSet",
    "AWSManagedRulesLinuxRuleSet",
  ]
}

resource "aws_wafv2_web_acl" "main" {
  name  = "${local.name}-web-acl"
  scope = "REGIONAL"

  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = local.waf_managed_rule_groups
    content {
      name     = rule.value
      priority = (rule.key + 1) * 10

      override_action {
        dynamic "none" {
          for_each = var.waf_count_mode ? [] : [1]
          content {}
        }
        dynamic "count" {
          for_each = var.waf_count_mode ? [1] : []
          content {}
        }
      }

      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.value
        }
      }

      # Sampled Requests はコンソールで直近3時間分しか見られない。観測中にこまめに確認すること
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.value
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-web-acl"
    sampled_requests_enabled   = true
  }
}

resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "main" {
  resource_arn            = aws_wafv2_web_acl.main.arn
  log_destination_configs = [data.aws_cloudwatch_log_group.waf.arn]
}
