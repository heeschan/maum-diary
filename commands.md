# Commands Log Template: Maum Diary Infrastructure

## 0. Prerequisites

```bash
# 1. Terraform 설치 (Mac Homebrew 환경 기준)
brew tap hashicorp/tap
brew install hashicorp/tap/terraform

# 2. 부하 테스트용 ApacheBench(ab) 및 JSON 파싱용 도구(jq) 설치
# (Mac의 경우 ab는 기본 내장되어 있으므로 jq만 설치)
brew install jq

# Ubuntu/Debian 환경의 경우 아래 명령어 사용
# sudo apt-get update && sudo apt-get install -y apache2-utils jq

# 3. 필수 도구 정상 설치 및 버전 확인
aws --version
terraform -version
ab -V
jq --version
```

Key Output:

Interpretation:

## 1. Preflight

```bash
# AWS Academy 임시 자격 증명 설정 (터미널에 직접 입력)
export AWS_ACCESS_KEY_ID="본인의_액세스_키"
export AWS_SECRET_ACCESS_KEY="본인의_시크릿_키"
export AWS_SESSION_TOKEN="본인의_세션_토큰"

# 민감한 DB 비밀번호 및 Flask 세션 키 환경 변수 주입
export TF_VAR_db_password="MaumDiary!!"
export TF_VAR_flask_secret_key="SecretKey"

# 주입된 환경 변수 정상 인식 여부 확인
test -n "$AWS_ACCESS_KEY_ID" && echo "AWS_ACCESS_KEY_ID is set"
test -n "$TF_VAR_db_password" && echo "TF_VAR_db_password is set"
test -n "$TF_VAR_flask_secret_key" && echo "TF_VAR_flask_secret_key is set"

# 현재 credentials가 정상인지 확인
aws sts get-caller-identity

# 현재 region 확인
aws configure get region

# Terraform 설치 확인
terraform version
```

Key Output:

Interpretation:

## 2. Init and Format

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt
```

Key output:

Interpretation:

## 3. Validate and Plan

```bash
terraform validate
terraform plan -out plan.out
terraform show plan.out
```

Key output:

Interpretation:

## 4. Apply

```bash
terraform apply plan.out
terraform output
```

Key output:

Interpretation:

## 5. Verify App Health and RDS Status 

```bash
# 1. ALB를 통한 애플리케이션 헬스체크 엔드포인트 정상 응답 확인 (200 OK)
curl -s -o /dev/null -w "%{http_code}\n" $(terraform output -raw alb_dns_name)/health

# 2. RDS 속성 조회: PubliclyAccessible 값이 false로 외부 격리되었는지 확인
aws rds describe-db-instances \
  --db-instance-identifier "maum-diary-mysql" \
  --query 'DBInstances[0].{Status:DBInstanceStatus, Endpoint:Endpoint.Address, Public:PubliclyAccessible, Engine:Engine}'
```

## 6. Verify Security Group Boundary & IAM Role
```bash
# 1. RDS 보안 그룹 확인: 외부(0.0.0.0/0) 개방 없이 EC2 보안 그룹에서의 3306 포트만 허용하는지 검증
# (주의: 터미널 환경에 따라 jq가 없으면 AWS 콘솔 스크린샷으로 대체 가능)
aws ec2 describe-security-groups \
  --filters Name=group-name,Values=*rds-sg* \
  --query 'SecurityGroups[0].IpPermissions'

# 2. EC2 IAM 프로파일 확인: 이전 과제와 달리 S3 접근을 위해 LabInstanceProfile이 정상 부여되었는지 확인
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text
```

## 7. EC2 Internal Verification (executed in AWS EC2 Internal Terminal)

```bash
# 1. Terraform user-data 부트스트랩 로그 확인 (패키지 설치 및 환경 세팅 완료 여부)
sudo tail -n 50 /var/log/app-provisioning.log

# 2. Gunicorn 백엔드 데몬(diary.service) 정상 구동 상태 확인
sudo systemctl status diary

# 3. 환경 변수 파일 확인: RDS 접속 정보와 S3 버킷명, 무상태(Stateless) 세션 키가 코드 외부(.env)에 잘 주입되었는지 확인
sudo cat /var/www/maum-diary/.env
```

Key output:

Interpretation:

## 8. Stateless Load Balancing Verification

```bash
# ALB 주소로 5번 연속 요청을 보내 응답하는 EC2 인스턴스 ID와 AZ가 번갈아 나오는지 확인 (라운드 로빈)
for i in {1..5}; do 
  curl -s $(terraform output -raw alb_dns_name) | grep -E "i-[0-9a-z]+ &middot; us-east-1[a-z]"
done
```

Key output:

Interpretation:

## 9. Fault Tolerance & Self-Healing Verification

```bash
# 1. 현재 실행 중인 EC2 인스턴스들의 ID 목록 확인 (기본 2대가 떠 있어야 함)
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text

# 2. 위 출력 결과 중 인스턴스 ID 하나를 골라 강제 종료 (장애 발생 가정)
# 명령어 예시: aws ec2 terminate-instances --instance-ids i-0abcdef1234567890
aws ec2 terminate-instances --instance-ids <여기에_인스턴스_ID_입력>

# 3. 약 2~3분 대기 후 다시 인스턴스 목록 확인 (ASG가 죽은 인스턴스를 대체하여 다시 2대를 맞췄는지 확인)
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text
```

Key output:

Interpretation:

## 10. Scalability Verification

```bash
# ApacheBench를 이용하여 동시 사용자 50명이 총 1000번의 CPU 부하 엔드포인트 요청 발생
ab -n 1000 -c 50 $(terraform output -raw benchmark_url)?work=50000

# (주의) 위 명령어 실행 후 AWS Console의 CloudWatch 또는 EC2 Auto Scaling Groups 탭에서 
# 트래픽 알람이 울리고 인스턴스가 3대 이상으로 늘어나는(Scale-out) 것을 스크린샷으로 캡처하여 보고서에 첨부할 것.
```

Key output:

Interpretation:

## 11. Cleanup

```bash
terraform destroy
```

Key output:

Interpretation:

## Credential Handling Note

```text
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN은 제출 파일에 넣지 않는다.
TF_VAR_db_master_password도 제출 파일에 넣지 않는다.
terraform.tfvars에는 non-secret 값만 넣는다.
terraform.tfstate는 민감 파일로 취급하고 commit하지 않는다.
```