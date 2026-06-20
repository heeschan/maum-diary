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

```text
aws-cli/2.34.16 Python/3.14.3 Darwin/25.3.0 exe/arm64

Terraform v1.15.1
on darwin_arm64

This is ApacheBench, Version 2.3 <$Revision: 1923142 $>

jq-1.7.1-apple
```

Interpretation:

AWS Cli, Terraform, Apache Bench, jq 모두 로컬 환경에 설치되었다.

## 1. Preflight

```bash
# AWS Academy 임시 자격 증명 설정 (터미널에 직접 입력)
export AWS_ACCESS_KEY_ID="<access-key-id>"
export AWS_SECRET_ACCESS_KEY="<secret-access-key>"
export AWS_SESSION_TOKEN="<session-token>"

# 민감한 DB 비밀번호 및 Flask 세션 키 환경 변수 주입
export TF_VAR_db_password="MaumDiary"
export TF_VAR_flask_secret_key="SecretKey"

# 현재 credentials가 정상인지 확인
aws sts get-caller-identity

# 현재 region 확인
aws configure get region
```

Key Output:

```text
{
    "UserId": "AROASKAKSJ6OXIIB5T3HI:user5143782=_________",
    "Account": "158935961501",
    "Arn": "arn:aws:sts::158935961501:assumed-role/voclabs/user5143782=_________"
}

us-east-1
```

Interpretation:

AWS Academy의 임시 자격 증명이 등록되었고, region이 us-east-1임을 확인하였다.

## 2. Init and Format

```bash
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt
```

Key output:

```text
Terraform has been successfully initialized!

main.tf
```

Interpretation:

Terraform의 작업 디렉토리를 초기화하였고, fmt 명령어로 main.tf 코드의 포맷을 일관성 있게 정렬하였다.

## 3. Validate and Plan

```bash
terraform validate
terraform plan -out plan.out
terraform show plan.out
```

Key output:

```text
Success! The configuration is valid.

# aws_autoscaling_group.asg will be created
# aws_autoscaling_policy.cpu_scaling will be created
# aws_db_instance.mysql will be created
# aws_db_subnet_group.rds will be created
# aws_launch_template.app will be created
# aws_lb.alb will be created  
# aws_lb_listener.http will be created  
# aws_lb_target_group.tg will be created  
# aws_s3_bucket.photos will be created  
# aws_security_group.alb will be created  
# aws_security_group.ec2 will be created  
# aws_security_group.rds will be created

Plan: 12 to add, 0 to change, 0 to destroy.
```

Interpretation:

Terraform 코드의 문법이 오류 없이 유효함을 확인하였다. ALB, ASG, RDS, S3 등 리소스가 생성될 것임을 확인하였다.

## 4. Apply

```bash
terraform apply plan.out
terraform output
```

Key output:

```text
Apply complete! Resources: 12 added, 0 changed, 0 destroyed.

Outputs:
alb_dns_name = "http://maum-diary-alb-1844701264.us-east-1.elb.amazonaws.com"
benchmark_url = "http://maum-diary-alb-1844701264.us-east-1.elb.amazonaws.com/bench"
rds_endpoint = "maum-diary-mysql.ca1houlpzljb.us-east-1.rds.amazonaws.com"
s3_bucket_name = "maum-diary-photos-bucket-32224315"

```

Interpretation:

웹 접속을 위한 ALB DNS, 데이터베이스 연결을 위한 RDS 엔드포인트, 이미지 저장을 위한 S3 버킷 이름 등 아키텍처 구성에 필요한 핵심 엔드포인트 정보가 할당됨을 확인하였다.

## 5. Verify App Health and RDS Status 

```bash
# 1. ALB를 통한 애플리케이션 헬스체크 엔드포인트 정상 응답 확인 (200 OK)
curl -s -o /dev/null -w "%{http_code}\n" $(terraform output -raw alb_dns_name)/health

# 2. RDS 속성을 조회하여 PubliclyAccessible 값이 false로 외부 격리되었는지 확인
aws rds describe-db-instances \
  --db-instance-identifier "maum-diary-mysql" \
  --query 'DBInstances[0].{Status:DBInstanceStatus, Endpoint:Endpoint.Address, Public:PubliclyAccessible, Engine:Engine}'
```

Key Output:

```text
200

{
    "Status": "available",
    "Endpoint": "maum-diary-mysql.ca1houlpzljb.us-east-1.rds.amazonaws.com",
    "Public": false,
    "Engine": "mysql"
}
```

Interpretation:

ALB를 거쳐 EC2 내부 프로그램으로 향하는 헬스체크 라우팅이 정상 작동하여 HTTP 200 OK 응답을 반환하였다. 또한 RDS MySQL 데이터베이스가 available이며 PubliclyAccessible 속성이 false로 설정되어 외부 인터넷이 직접적으로 접근하는 것을 차단하는 상태임을 확인하였다.

## 6. Verify Security Group Boundary & IAM Role

```bash
# 1. RDS 보안 그룹 확인: 외부(0.0.0.0/0) 개방 없이 EC2 보안 그룹에서의 3306 포트만 허용하는지 검증
aws ec2 describe-security-groups \
  --filters "Name=group-name,Values=*rds-sg*" \
  --query 'SecurityGroups[0].IpPermissions'

# 2. EC2 IAM 프로파일 확인: S3 접근을 위해 LabInstanceProfile이 정상 부여되었는지 확인
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].IamInstanceProfile.Arn' \
  --output text
```

Key Output:

```text
[
    {
        "IpProtocol": "tcp",
        "FromPort": 3306,
        "ToPort": 3306,
        "UserIdGroupPairs": [
            {
                "UserId": "158935961501",
                "GroupId": "sg-0f855c1338f2c87b1"
            }
        ],
        "IpRanges": [],
        "Ipv6Ranges": [],
        "PrefixListIds": []
    }
]

arn:aws:iam::158935961501:instance-profile/LabInstanceProfile
```

Interpretation:

RDS 보안 그룹은 0.0.0.0/0을 통한 외부 접속을 허용하지 않고, 오직 지정된 EC2 보안 그룹에서 들어오는 3306 포트(TCP) 트래픽만 허용하고 있다. 그리고 EC2 인스턴스에 LabInstanceProfile(IAM Role)이 할당되어 S3에 접근할 수 있는 권한을 얻었음을 확인하였다.

## 7. S3 Object Upload Verification

웹 브라우저(ALB 주소)에 접속하여 로그인 후, 사진을 첨부한 일기를 1개 이상 작성한 뒤 아래 명령어를 실행함.

```bash
# S3 버킷 내부를 조회하여 사용자가 업로드한 이미지 파일이 정상적으로 오프로딩되었는지 확인
aws s3 ls s3://$(terraform output -raw s3_bucket_name) --recursive
```

Key Output:

```text
2026-06-20 11:36:14    4954283 photos/1/1781922971_IMG_0837.jpeg
```

Result:
![](./commands-result-ss/07-execution-1-login.png)
![](./commands-result-ss/07-execution-2-write.png)
![](./commands-result-ss/07-execution-3-read.png)

Interpretation:

웹 브라우저를 통해 업로드된 사진이 EC2 인스턴스의 로컬 스토리지가 아닌, 지정된 S3 버킷의 경로에 저장됨을 확인하였다. 이러한 Stateless의 원리로 테스트 후 github에 업로드할 때 /init-db을 매번 하지 않아도 데이터가 db에 기록되지 않은 상태로 업로드된다.

## 8. Stateless Load Balancing Verification

EC2 콘솔의 ALB에서 maum-diary-alb를 선택하고 DNS 이름을 찾아 복사한 뒤 아래 명령어에 붙여넣어 실행함.

```bash
# ALB 주소로 5번 연속 요청을 보내 응답하는 EC2 인스턴스 ID와 AZ가 번갈아 나오는지 확인 (라운드 로빈)
# 명령어 예시: curl -s http://maum-diary-alb-1844701264.us-east-1.elb.amazonaws.com | grep 'class="badge"'
for i in {1..5}; do 
  curl -s http://DNS_이름 | grep 'class="badge"'
done
```

Key output:

```text
  <div class="badge">i-0f24660985f51ab51 · us-east-1b</div>
  <div class="badge">i-0f24660985f51ab51 · us-east-1b</div>
  <div class="badge">i-022ed42060020265e · us-east-1a</div>
  <div class="badge">i-022ed42060020265e · us-east-1a</div>
  <div class="badge">i-0f24660985f51ab51 · us-east-1b</div>
```

Interpretation:

5회의 연속된 접속 요청에 대해 서로 다른 AZ(us-east-1a, us-east-1b)에 위치한 두 개의 EC2 인스턴스가 번갈아 가며 응답하는 Round Robin 방식으로 Load-balancing이 작동하고 있음을 확인하였다.

## 9. Fault Tolerance & Self-Healing Verification

```bash
# 1. 현재 실행 중인 EC2 인스턴스들의 ID 목록 확인 (기본 2대가 떠 있어야 함)
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text

# 2. 위 출력 결과 중 인스턴스 ID 하나를 골라 강제 종료 (장애 발생 가정)
# 명령어 예시: aws ec2 terminate-instances --instance-ids i-022ed42060020265e
aws ec2 terminate-instances --instance-ids 여기에_인스턴스_ID_입력

# 3. 약 2~3분 대기 후 다시 인스턴스 목록 확인 (ASG가 죽은 인스턴스를 대체하여 다시 2대를 맞췄는지 확인)
aws ec2 describe-instances \
  --filters "Name=instance-state-name,Values=running" \
  --query "Reservations[*].Instances[*].InstanceId" \
  --output text
```

Key output:

```text
i-0f24660985f51ab51
i-022ed42060020265e

{
    "TerminatingInstances": [
        {
            "InstanceId": "i-022ed42060020265e",
            "CurrentState": {
                "Code": 32,
                "Name": "shutting-down"
            },
            "PreviousState": {
                "Code": 16,
                "Name": "running"
            }
        }
    ]
}

i-0f24660985f51ab51
i-0908d645d83f88644
```

Interpretation: 

의도적인 장애 상황을 가정하여 실행 중이던 인스턴스 하나(i-022ed42060020265e)를 강제 종료했음에도, ASG가 이를 감지하고 새로운 대체 인스턴스(i-0908d645d83f88644)를 자동으로 프로비저닝하여 목표 용량인 2대로 복구함을 확인하였다. 이로서 오토스케일링 그룹(ASG)의 자동 복구(Self-Healing) 기능을 확인하였다.

## 10. Scalability Verification

```bash
# ApacheBench를 이용하여 동시 사용자 50명이 총 1000번의 CPU 부하 엔드포인트 요청 발생
# 명령어 예시: ab -n 10000 -c 50 -s 120 "http://maum-diary-alb-1844701264.us-east-1.elb.amazonaws.com/bench?work=30000"
ab -n 10000 -c 200 "http://DNS_이름/bench?work=50000"
```

Key output:

```text
Benchmarking maum-diary-alb-1844701264.us-east-1.elb.amazonaws.com (be patient)
Completed 1000 requests
Completed 2000 requests
Completed 3000 requests
Completed 4000 requests
Completed 5000 requests
apr_socket_recv: Operation timed out (60)
Total of 5775 requests completed
```

Result:

![](./commands-result-ss/10-bench-cloudwatch.png)

Interpretation:

ApacheBench로 다수의 동시 접속 트래픽을 유발하여 시스템의 Scale-out을 테스트하였다. t2.micro의 한계로 CloudWatch 경보가 울릴 만큼 부하를 주지 못했지만, CloudWatch로 부하가 발생할 때 CPU 사용률이 증가하는 트래픽 추이를 관측할 수 있었다.

## 11. Cleanup

```bash
terraform destroy
```

Key output:

```text
Destroy complete! Resources: 12 destroyed.
```

Interpretation:

추가 과금 방지를 위해 생성한 12개의 AWS 리소스를 삭제하였다.

## Credential Handling Note

```text
AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY, AWS_SESSION_TOKEN은 제출 파일에 넣지 않는다.
TF_VAR_db_master_password도 제출 파일에 넣지 않는다.
terraform.tfvars에는 non-secret 값만 넣는다.
terraform.tfstate는 민감 파일로 취급하고 commit하지 않는다.
```