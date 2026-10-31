output "alb_log_bucket" {
  value = aws_s3_bucket.alb_logs.bucket
}

output "log_groups" {
  value = {
    nginx_access = aws_cloudwatch_log_group.nginx_access.name
    nginx_error  = aws_cloudwatch_log_group.nginx_error.name
    waf          = aws_cloudwatch_log_group.waf.name
  }
}

output "guardduty_detector_id" {
  value = var.enable_guardduty ? aws_guardduty_detector.main[0].id : null
}

output "security_alert_topic_arn" {
  value = aws_sns_topic.security_alerts.arn
}
