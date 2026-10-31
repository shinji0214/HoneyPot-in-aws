# -----------------------------------------------------------------------------
# 隔離VPC
#   Peering / Transit Gateway / VPN / Direct Connect は一切作らない。
#   出口はインターネットゲートウェイのみ。NAT Gateway は高い（48hで約1,000円）ので使わず、
#   EC2 にはパブリックIPを付けて送信のみ許可する（受信は ALB の SG からだけ）。
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

# デフォルトSGは全ルール削除して使わせない
resource "aws_default_security_group" "default" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-default-unused" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.azs)
  vpc_id                  = aws_vpc.main.id
  availability_zone       = var.azs[count.index]
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index + 1) # 10.100.1.0/24, 10.100.2.0/24
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.name}-public-${var.azs[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# -----------------------------------------------------------------------------
# Security Groups
#   ALB: 80(/443) をインターネットに公開
#   EC2: 80 は ALB からのみ。22 は開けない（管理は Session Manager）
#        送信は 443 のみ（dnf / SSM / CloudWatch Logs 用）
# -----------------------------------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${local.name}-alb"
  description = "Honeypot ALB: HTTP/HTTPS from internet"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-alb" }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  count             = var.acm_certificate_arn == "" ? 0 : 1
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_egress_rule" "alb_to_ec2" {
  security_group_id            = aws_security_group.alb.id
  referenced_security_group_id = aws_security_group.ec2.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_security_group" "ec2" {
  name        = "${local.name}-ec2"
  description = "Honeypot EC2: HTTP from ALB only, no SSH"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-ec2" }
}

resource "aws_vpc_security_group_ingress_rule" "ec2_from_alb" {
  security_group_id            = aws_security_group.ec2.id
  referenced_security_group_id = aws_security_group.alb.id
  ip_protocol                  = "tcp"
  from_port                    = 80
  to_port                      = 80
}

resource "aws_vpc_security_group_ingress_rule" "ec2_http_direct" {
  count             = var.expose_ec2_directly ? 1 : 0
  security_group_id = aws_security_group.ec2.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_egress_rule" "ec2_https_out" {
  security_group_id = aws_security_group.ec2.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# -----------------------------------------------------------------------------
# 緊急隔離用 SG（ルールなし = 受信も送信も全て拒否）
#   乗っ取りの疑いがある時に scripts/emergency-isolate.sh で EC2 の SG をこれだけに差し替える
# -----------------------------------------------------------------------------
resource "aws_security_group" "quarantine" {
  name        = "${local.name}-quarantine"
  description = "Emergency isolation: no ingress, no egress"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.name}-quarantine" }
}
