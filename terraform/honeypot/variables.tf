variable "project" {
  description = "リソース名・タグの接頭辞。base スタックと同じ値にすること"
  type        = string
  default     = "honeypot"
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "vpc_cidr" {
  description = "ハニーポット専用VPC。他VPC・オンプレと重複しない値にする"
  type        = string
  default     = "10.100.0.0/16"
}

variable "azs" {
  description = "ALB は2AZ以上のサブネットが必須"
  type        = list(string)
  default     = ["ap-northeast-1a", "ap-northeast-1c"]
}

variable "instance_type" {
  description = "t4g.nano（512MB）。dnf 実行時のメモリ不足対策に user_data で 1GB スワップを作る。不安なら t4g.micro"
  type        = string
  default     = "t4g.nano"
}

variable "waf_count_mode" {
  description = <<-EOT
    true にするとマネージドルールを COUNT（検知のみ）で動かす。
    false（既定）は BLOCK。BLOCK だと遮断されたリクエストは nginx に届かず nginx ログに残らない
    （WAF ログには残る）。「WAFが止めなかったら何が届いたか」を見たい場合は true。
  EOT
  type        = bool
  default     = false
}

variable "expose_ec2_directly" {
  description = <<-EOT
    true にすると EC2 のパブリックIPで 80/tcp をインターネットに直接公開する（WAF/ALB を経由しない経路）。
    GuardDuty の Recon:EC2/PortProbeUnprotectedPort 等は EC2 自体に届く通信で検知されるため、
    false（既定・計画どおり ALB 経由のみ）だと GuardDuty の Finding がほぼ出ない可能性がある。
    22/tcp はどちらの場合も開けない。
  EOT
  type        = bool
  default     = false
}

variable "acm_certificate_arn" {
  description = "HTTPS(443) リスナーを作る場合のみ ACM 証明書 ARN を指定（独自ドメインが必要）。空なら 80 のみ"
  type        = string
  default     = ""
}
