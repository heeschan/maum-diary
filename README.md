# Final Project: Maum Diary Web Service on AWS (ALB + ASG + RDS + S3, Stateless)

기말 프로젝트인 마음일기 웹 서비스는 Terraform을 사용하여 고가용성과 확장성을 갖춘 클라우드 인프라를 구축한 프로그램입니다.

이전 수업에서 배우고 실습한 ALB, 오토스케일링, RDS 개념을 통합하고, S3와 IAM Role을 사용하여 클라우드 아키텍처를 완성하였습니다.

## Project Objectives

- Terraform을 활용하여 전체 인프라(네트워크, 컴퓨팅, 데이터베이스, 스토리지)를 코드로 프로비저닝한다.
- 서명된 쿠키를 사용하여 서버 메모리에 의존하지 않는 Stateless 세션 로그인을 구현한다.
- 이미지 파일은 S3에, 텍스트 데이터는 RDS에 분리 저장하여 EC2 인스턴스를 Stateless로 유지한다.
- ALB와 ASG(오토스케일링)를 연동하여 Load Balancing 및 자동 확장(Scale-out), 자동 복구(Self-healing)를 수행함을 확인한다.
- 3계층 보안 그룹 분리 및 IAM Role(`LabInstanceProfile`)을 통해 하드코딩된 자격 증명 없이 안전하게 클라우드 리소스를 연결한다. 

## Tech Stack & Frameworks

* **Backend Framework (Flask):** 상태를 서버 로컬 메모리나 디스크에 저장하지 않는 Stateless 아키텍처를 가볍게 구현하기 위해 Python 기반의 Flask를 사용하였습니다. 세션 데이터는 암호화된 쿠키로 클라이언트 측에 위임됩니다.
* **WSGI Production Server (Gunicorn):** Flask의 기본 내장 서버는 동시성 처리에 취약하여 부하 테스트 시 데이터가 오염되거나 병목이 발생할 수 있습니다. ALB를 통한 다중 트래픽 분산과 `ab` 벤치마크 테스트를 수행하기 위해 WSGI 서버인 Gunicorn을 도입했습니다.
* **AWS SDK (Boto3):** 사진 파일을 EC2 디스크가 아닌 S3 버킷으로 오프로딩하기 위해 사용했습니다. 코드 내부에 AWS Access Key를 하드코딩하지 않고, EC2에 부여된 IAM Role(`LabInstanceProfile`)의 임시 자격 증명을 자동으로 상속받아 안전하게 통신하도록 설계했습니다.
* **Database Client (PyMySQL):** EC2 응용 계층에서 프라이빗 서브넷에 격리된 RDS(MySQL) 데이터 계층으로 연결하여 일기 텍스트 데이터를 읽고 쓰기 위해 PyMySQL을 사용했습니다.
* **Process Manager (Systemd):** 오토스케일링에 의해 새로운 EC2 인스턴스가 띄워지거나 장애 복구로 재부팅될 때, 관리자의 개입 없이 프로그램이 백그라운드 데몬으로 자동 구동되는 서버를 구축하기 위해 사용했습니다.
* **IaC & Testing Tools (Terraform, ApacheBench, jq):** 전체 인프라 배포를 코드로 자동화하기 위해 Terraform을 사용했으며, CPU 부하를 발생시켜 Scale-out을 확인하기 위해 ApacheBench(`ab`)를, 터미널 환경에서 AWS CLI의 JSON 반환값을 파싱하여 보안 그룹 격리 등을 검증하기 위해 `jq`를 활용했습니다.

## Created Resources

- 1 Application Load Balancer (ALB) & Target Group
- 1 Auto Scaling Group (ASG) & Launch Template (초기 2대, 최대 4대)
- 1 RDS MySQL DB instance & DB Subnet Group
- 1 S3 Bucket (사진 저장용)
- 3 Security Groups (ALB, EC2, RDS용 격리 설계)

## Architecture

Traffic flow:

- Browser -> ALB (Public HTTP `80`)
- ALB -> ASG EC2 Instances (Private HTTP `80` 라우팅)
- EC2 Maum-Diary -> RDS (Private MySQL `3306`)
- EC2 Maum-Diary -> S3 (HTTPS API via IAM Role)

RDS 보안 그룹은 오직 EC2 보안 그룹으로부터의 MySQL 트래픽만 허용하며, `publicly_accessible = false`로 설정되어 외부 인터넷으로부터 격리됩니다. S3 버킷 접근은 코드 내 하드코딩된 키가 아닌 EC2에 부여된 IAM Role을 통해 안전하게 이루어집니다.

## Difference From Assignment #6

Assignment #6에서는 1대의 단일 EC2 인스턴스에 Apache, PHP, WordPress를 설치하고 외부 RDS와 연결했습니다.
이번 기말과제에서는 단일 장애점(SPOF)을 제거하기 위해 **1대의 EC2를 다수의 EC2(ASG)로 대체**하고 그 앞에 **ALB**를 배치했습니다.

단일 서버가 아니기 때문에 웹 서버 내부에 데이터를 저장하면 다른 서버와 동기화되지 않는 문제가 발생합니다. 이를 해결하기 위해 Flask 코드를 Stateless로 설계하였습니다.
- **세션 상태:** 로컬 메모리 대신 클라이언트의 서명된 쿠키를 활용.
- **미디어 파일:** EC2 디스크 대신 S3 버킷으로 오프로딩.
- **웹 서버 구동:** 동시성 처리가 불안정한 개발 서버 대신 `Gunicorn` WSGI 프로덕션 데몬 사용.

## Key Features Added After Assignment #6

단일 EC2 환경에서 ASG/ALB 환경으로 넘어가면서 새롭게 추가되거나 변경된 핵심 설정들은 다음과 같습니다.

### Stateless Session & Secret Key Injection

ALB가 사용자 요청을 A 인스턴스와 B 인스턴스 중 어디로 보내더라도 동일한 로그인 상태를 유지해야 합니다. 
이를 위해 Flask의 서명된 쿠키 세션을 활용하며, 모든 EC2 인스턴스가 동일한 암호화 키를 가지도록 Terraform의 `user-data`를 통해 `SECRET_KEY`를 환경 변수로 주입합니다.

### S3 Integration with IAM Role

사진 업로드를 처리하기 위해 S3 버킷 리소스(`aws_s3_bucket`)가 추가되었습니다.
boto3 라이브러리가 S3에 접근할 때 AWS Access Key를 코드에 삽입하는 현상을 방지하기 위해, Launch Template에 AWS Academy에서 제공하는 `LabInstanceProfile` IAM Role을 연결했습니다. 이를 통해 EC2는 자동으로 임시 자격 증명을 부여받아 S3와 통신합니다.

### 3-Tier Security Group Isolation

Assignment #6에서는 외부에서 EC2로 직접 접근했습니다. 이번 프로젝트에서는 보안 그룹이 3단계로 엄격하게 분리됩니다.

| Security Group | Ingress Rules (허용 정책) |
| --- | --- |
| `alb_sg` | 외부 인터넷(`0.0.0.0/0`)으로부터의 HTTP 80 허용 |
| `ec2_sg` | **오직 `alb_sg`로부터** 들어오는 HTTP 80만 허용 (직접 IP 접근 차단) |
| `rds_sg` | **오직 `ec2_sg`로부터** 들어오는 MySQL 3306만 허용 |

### Target Tracking Auto Scaling

트래픽 폭주 상황을 대비하여 ASG에 CPU 사용률 기반 타깃 트래킹 스케일링 정책(`TargetTrackingScaling`)이 추가되었습니다. 평균 CPU 사용률이 40%를 초과하면 자동으로 인스턴스를 최대 4대까지 확장(=Scale-out)합니다.

## Password & Secret Key Handling

데이터베이스 비밀번호와 Flask 세션 키를 `terraform.tfvars`나 코드 내부에 적지 말고, Terraform 실행 전 터미널 환경 변수로 안전하게 주입해야 합니다:

```bash
export TF_VAR_db_password='MaumDiary!!'
export TF_VAR_flask_secret_key='SecretKey'
```

참고: .gitignore 파일이 구성되어 있어 .tfstate 파일이 GitHub에 올라가는 것을 방지하지만, 로컬의 상태 파일 내에는 여전히 비밀번호가 평문으로 저장되어 있으므로 주의해야 합니다.

## Quick Start

```bash
cd maum-diary

# 1. AWS Academy Learner Lab 임시 자격 증명 세팅
export AWS_ACCESS_KEY_ID="<access-key-id>"
export AWS_SECRET_ACCESS_KEY="<secret-access-key>"
export AWS_SESSION_TOKEN="<session-token>"

# 2. 민감한 환경 변수 세팅
export TF_VAR_db_password="MaumDiary!!"
export TF_VAR_flask_secret_key="SecretKey"

# 3. 인프라 프로비저닝
cp terraform.tfvars.example terraform.tfvars
terraform init
terraform fmt
terraform validate
terraform plan -out plan.out
terraform apply plan.out

# 4. 출력값 확인
terraform output
```

브라우저를 열고 생성된 ALB 주소로 접속하여 마음일기 서비스를 시작합니다:

```bash
terraform output -raw alb_dns_name
```

## Verification Scenarios

다음의 여러 가지 시나리오를 터미널 및 콘솔에서 직접 검증할 수 있습니다. (자세한 명령어와 실행 방식은 commands.md 참조)

- 애플리케이션 및 DB 상태 검증 (App Health & RDS Status): ALB의 헬스체크 엔드포인트(/health)가 정상 응답(200 OK)을 반환하는지 확인하고, RDS 인스턴스가 PubliclyAccessible = false 상태로 프라이빗 서브넷에 안전하게 격리되어 기동 중인지 검증합니다.
- 보안 격리 및 권한 검증 (Security Group & IAM Role): RDS 보안 그룹이 외부 인터넷 접근을 완전 차단하고 오직 웹 서버(EC2 SG) 트래픽만 허용하는지 확인합니다. 또한 S3 접근을 위해 Launch Template에 LabInstanceProfile IAM 역할이 정상 바인딩되었는지 검증합니다.
- S3 사진 업로드 및 객체 오프로딩 검증 (S3 Object Upload Verification): 웹 브라우저(ALB 주소)로 서비스에 접속하여 사진을 첨부한 일기를 작성한 후, AWS CLI 명령어를 통해 해당 이미지 객체가 EC2 로컬 디스크가 아닌 AWS S3 버킷 내에 물리적으로 분리 저장(Off-loading)되었음을 확인하여 무상태성의 핵심 요소를 증명합니다.
- 분산 처리 검증 (Stateless Load Balancing): 로드밸런서(ALB) 웹 주소로 연속 트래픽을 송신할 때, 요청이 가용 영역(AZ) A와 B에 배치된 가상 인스턴스들로 라운드 로빈 방식을 통해 균등하게 분산 처리되는지 증명합니다.
- 장애 주입 및 자동 복구 검증 (Fault Tolerance & Self-Healing): 기동 중인 가상 인스턴스 중 하나를 강제 종료(terminate)하여 인위적 장애 상황을 연출한 뒤, 서비스 중단(Downtime) 없이 무중단 운영이 유지되는지 확인하고 ASG가 이를 감지해 자동으로 새로운 서버를 가용 상태로 복구(Self-healing)하는지 증명합니다.
- 오토스케일링 부하 테스트 증명 (Scalability Verification): ApacheBench(ab) 스트레스 도구를 활용해 동시성 대량 가상 요청을 발생시켜 가상 서버의 CPU 부하를 유도하고, CloudWatch 경보와 연동되어 ASG 자원이 동적으로 자동 확장(Scale-out)되는 인프라 탄력성을 최종 증명합니다.

## AWS Academy Notes

- S3 접근을 위해 Launch Template에 반드시 LabInstanceProfile IAM 역할이 포함되어야 합니다.
- ASG와 ALB, RDS가 동시에 생성되므로 프로비저닝에 5~7분 정도 소요될 수 있습니다.
- skip_final_snapshot = true가 설정되어 있어 실습 종료 후 파괴 시 DB 백업을 생성하지 않습니다.
- 예산 낭비를 막기 위해 데모와 검증이 끝나면 즉각적으로 Cleanup을 진행합니다.

## Cleanup

```bash
terraform destroy
```
