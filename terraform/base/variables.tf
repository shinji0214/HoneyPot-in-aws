variable "project" {
  description = "リソース名・タグの接頭辞。honeypot スタックと同じ値にすること"
  type        = string
  default     = "honeypot"
}

variable "region" {
  description = "構築リージョン"
  type        = string
  default     = "ap-northeast-1"
}

variable "log_retention_days" {
  description = "CloudWatch Logs / S3 ログの保持日数"
  type        = number
  default     = 30
}

variable "enable_guardduty" {
  description = "GuardDuty detector を作成するか（既に有効なアカウントでは false）"
  type        = bool
  default     = true
}

variable "budget_usd" {
  description = "月次予算（USD）。1,000円相当"
  type        = number
  default     = 6.5
}

variable "alert_email" {
  description = "予算アラート・GuardDuty 通知の送信先。public リポジトリの Actions ログに出ないよう sensitive にしている"
  type        = string
  sensitive   = true
}

