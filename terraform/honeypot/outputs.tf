output "alb_dns_name" {
  description = "動作確認用: curl http://<この値>/"
  value       = aws_lb.main.dns_name
}

output "instance_id" {
  description = "Session Manager 接続用: aws ssm start-session --target <この値>"
  value       = aws_instance.web.id
}

output "instance_public_ip" {
  description = "expose_ec2_directly = true の時だけ 80/tcp で到達可能"
  value       = aws_instance.web.public_ip
}

output "web_acl_name" {
  value = aws_wafv2_web_acl.main.name
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "quarantine_security_group_id" {
  description = "緊急隔離用 SG（scripts/emergency-isolate.sh が使う）"
  value       = aws_security_group.quarantine.id
}
