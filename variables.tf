variable "aws_region" {
  description = "AWS 리전 설정"
  type        = string
  default     = "us-east-1"
}

variable "name_prefix" {
  description = "리소스 이름 명명을 위한 접두사"
  type        = string
  default     = "maum-diary"
}

variable "db_name" {
  description = "RDS MySQL 데이터베이스 이름"
  type        = string
  default     = "diarydb"
}

variable "db_username" {
  description = "RDS 마스터 사용자 계정명"
  type        = string
  default     = "diaryadmin"
}

variable "db_password" {
  description = "RDS 마스터 암호 (터미널에서 TF_VAR_db_password로 주입)"
  type        = string
  sensitive   = true
}

variable "flask_secret_key" {
  description = "Flask의 Stateless 세션 쿠키 서명 키 (터미널에서 TF_VAR_flask_secret_key로 주입)"
  type        = string
  sensitive   = true
}