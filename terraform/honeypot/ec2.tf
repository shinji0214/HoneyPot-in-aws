data "aws_ssm_parameter" "al2023_arm64" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# -----------------------------------------------------------------------------
# IAM: Session Manager と CloudWatch Agent に必要な権限のみ
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name}-ec2"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy_attachment" "cwagent" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-ec2"
  role = aws_iam_role.ec2.name
}

# -----------------------------------------------------------------------------
# EC2
# -----------------------------------------------------------------------------
resource "aws_instance" "web" {
  ami                    = data.aws_ssm_parameter.al2023_arm64.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.ec2.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # 送信（dnf / SSM / CloudWatch Logs）のためだけのパブリックIP。受信は SG で ALB からのみ
  associate_public_ip_address = true

  metadata_options {
    http_tokens                 = "required" # IMDSv2 強制
    http_put_response_hop_limit = 1
    http_endpoint               = "enabled"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 8
    encrypted             = true
    delete_on_termination = true # 孤立EBSを残さない
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    nginx_conf = file("${path.module}/../../config/nginx/nginx.conf")
    cwagent_json = templatefile("${path.module}/../../config/cloudwatch-agent/config.json.tftpl", {
      access_log_group = data.aws_cloudwatch_log_group.nginx_access.name
      error_log_group  = data.aws_cloudwatch_log_group.nginx_error.name
    })
  })
  user_data_replace_on_change = true

  tags = { Name = "${local.name}-web" }
}
