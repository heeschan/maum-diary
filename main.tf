# ----------------------------------------------------
# 1. AWS 데이터 소스 및 로컬 변수 정의 (VPC & Subnet 추출)
# ----------------------------------------------------
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_subnet" "default" {
  for_each = toset(data.aws_subnets.default.ids)
  id       = each.value
}

data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  subnets_by_az = {
    for _, subnet in data.aws_subnet.default :
    subnet.availability_zone => subnet.id...
  }
  selected_azs        = slice(sort(keys(local.subnets_by_az)), 0, 2)
  selected_subnet_ids = [for az in local.selected_azs : sort(local.subnets_by_az[az])[0]]

  common_tags = {
    Project = "Maum-Diary-Web-Service"
    Course  = "cloud-computing-aws"
  }
}

# ----------------------------------------------------
# 2. 보안 그룹 (Security Group) 분리 설계
# ----------------------------------------------------
resource "aws_security_group" "alb" {
  name        = "${var.name_prefix}-alb-sg"
  description = "Allow public HTTP traffic to Load Balancer"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "ec2" {
  name        = "${var.name_prefix}-ec2-sg"
  description = "Allow traffic exclusively from ALB"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "rds" {
  name        = "${var.name_prefix}-rds-sg"
  description = "Allow MySQL connectivity from App tier EC2 instances"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.ec2.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ----------------------------------------------------
# 3. 데이터 스토리지 인프라 구성 (S3 & RDS)
# ----------------------------------------------------
resource "aws_s3_bucket" "photos" {
  bucket        = "${var.name_prefix}-photos-bucket-32224315" # 고유한 버킷명 보장용 학번 부여
  force_destroy = true
  tags          = local.common_tags
}

resource "aws_db_subnet_group" "rds" {
  name       = "${var.name_prefix}-db-subnet-group"
  subnet_ids = local.selected_subnet_ids
  tags       = local.common_tags
}

resource "aws_db_instance" "mysql" {
  identifier             = "${var.name_prefix}-mysql"
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.4.8"
  instance_class         = "db.t3.micro"
  db_name                = var.db_name
  username               = var.db_username
  password               = var.db_password
  db_subnet_group_name   = aws_db_subnet_group.rds.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  publicly_accessible    = false
  skip_final_snapshot    = true
  deletion_protection    = false
  tags                   = local.common_tags
}

# ----------------------------------------------------
# 4. 고가용성 컴퓨팅 계층 구성 (ALB & ASG)
# ----------------------------------------------------
resource "aws_lb" "alb" {
  name               = "${var.name_prefix}-alb"
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.selected_subnet_ids
  tags               = local.common_tags
}

resource "aws_lb_target_group" "tg" {
  name     = "${var.name_prefix}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id

  health_check {
    path                = "/health" # 애플리케이션의 경량 헬스체크 엔드포인트 바인딩
    protocol            = "HTTP"
    port                = "80"
    interval            = 15
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}

resource "aws_launch_template" "app" {
  name_prefix   = "${var.name_prefix}-lt-"
  image_id      = data.aws_ssm_parameter.al2023_ami.value
  instance_type = "t3.micro"

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.ec2.id]
  }

  # AWS Academy 사전 차단 우회 정책: 제공되는 권한 만능 키 적용
  iam_instance_profile {
    name = "LabInstanceProfile"
  }

  # Flask 무상태 기동을 위한 필수 메타데이터 주입 템플릿 처리
  user_data = base64encode(templatefile("${path.module}/user-data.sh", {
    db_host          = aws_db_instance.mysql.address
    db_port          = aws_db_instance.mysql.port
    db_name          = var.db_name
    db_user          = var.db_username
    db_password      = var.db_password
    s3_bucket        = aws_s3_bucket.photos.id
    flask_secret_key = var.flask_secret_key
  }))

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_autoscaling_group" "asg" {
  name_prefix = "${var.name_prefix}-asg-"
  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
  vpc_zone_identifier = local.selected_subnet_ids
  target_group_arns   = [aws_lb_target_group.tg.arn]

  min_size         = 1
  max_size         = 4
  desired_capacity = 2 # 최초 로드밸런싱 데모 증명을 위해 인스턴스 2개 기동

  health_check_type         = "ELB"
  health_check_grace_period = 180

  lifecycle {
    create_before_destroy = true
  }
}

# ----------------------------------------------------
# 5. 오토스케일링 트래킹 정책 (ab 부하 테스트 가점 연계)
# ----------------------------------------------------
resource "aws_autoscaling_policy" "cpu_scaling" {
  name                   = "${var.name_prefix}-cpu-target-tracking"
  autoscaling_group_name = aws_autoscaling_group.asg.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 40.0 # ab 테스트 시 스케일아웃이 즉각적으로 트리거될 수 있도록 타깃 최적화 임계치 설정
  }
}