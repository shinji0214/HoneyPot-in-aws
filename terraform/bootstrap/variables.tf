variable "project" {
  description = "リソース名・タグの接頭辞。base / honeypot スタックと同じ値にすること"
  type        = string
  default     = "honeypot"
}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "github_repo" {
  description = "Actions を動かす GitHub リポジトリ（owner/name）"
  type        = string
  default     = "shinji0214/HoneyPot-in-aws"
}

variable "github_owner_id" {
  description = "リポジトリオーナーの数値 ID。sub が ID 付き形式（repo:OWNER@ID/REPO@ID:...）で発行される場合に設定。空なら従来形式"
  type        = string
  default     = "30721643"
}

variable "github_repo_id" {
  description = "リポジトリの数値 ID。github_owner_id とセットで使う"
  type        = string
  default     = "1440970522"
}

variable "apply_environment" {
  description = "apply / destroy ジョブが使う GitHub Environment 名（承認者を設定する）"
  type        = string
  default     = "honeypot-apply"
}

variable "create_github_oidc_provider" {
  description = "GitHub Actions の OIDC プロバイダを作るか（アカウントに既にあれば false）"
  type        = bool
  default     = true
}
