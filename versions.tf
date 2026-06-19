terraform {
  # 최소 Terraform 버전 명시
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

# AWS 프로바이더 설정 (variables.tf의 리전 변수 사용)
provider "aws" {
  region = var.aws_region
}