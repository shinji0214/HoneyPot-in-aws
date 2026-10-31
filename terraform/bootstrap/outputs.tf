# これらの値は GitHub リポジトリの Secrets に登録する（docs/07 の手順2）。
# public リポジトリのログにアカウントIDを出さないため、Variables ではなく Secrets に入れる

output "tf_state_bucket" {
  description = "Secrets: TF_STATE_BUCKET"
  value       = aws_s3_bucket.tfstate.bucket
}

output "plan_role_arn" {
  description = "Secrets: AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Secrets: AWS_APPLY_ROLE_ARN"
  value       = aws_iam_role.apply.arn
}

output "emergency_role_arn" {
  description = "Secrets: AWS_EMERGENCY_ROLE_ARN"
  value       = aws_iam_role.emergency.arn
}
