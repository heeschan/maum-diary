# Final Assignment: Maum-Diary by Terraform 3-Tier Architecture Report

## 1) Student Info

- Name: 정희찬
- Student ID: 32224315
- Date (KST): 2026년 6월 20일
- AWS Region: us-east-1

## 2) Objective and Scope

- Objective: Terraform을 활용하여 Maum Diary 프로그램을 위한 고가용성 및 확장성을 갖춘 Web, DB, Storage의 3-Tier Architecture를 구축하고 검증한다.
- Scope: ALB, ASG, RDS(MySQL), S3 버킷을 프로비저닝하고, 사용자 트래픽에 대한 Load Balancing, 장애 시의 Self-Healing, 부하 발생 시의 Scale-out 기능이 존재함을 검증하고 테스트한다.

## 3) Architecture Summary

- Web Tier: ALB를 통한 트래픽 분산, ASG(Min:2, Max:4) 기반의 EC2 인스턴스 (Python Flask Application)
- Database Tier: 1 RDS Instance (MySQL, 프라이빗 서브넷에 배치, `publicly_accessible = false`)
- Storage Tier: 1 S3 Bucket (사용자 업로드 이미지 저장을 통한 Stateless 아키텍처 구현)
- Security Group Design:
  - ALB SG: 외부 인터넷 트래픽(HTTP 80) 허용
  - EC2 SG: 외부 노출 없이, ALB SG로부터 오는 HTTP(80) 트래픽만 허용
  - RDS SG: 외부 노출 없이, EC2 SG로부터 오는 MySQL(3306) 트래픽만 제한적으로 허용
- IAM Role: EC2 인스턴스에 `LabInstanceProfile`을 부여하여 S3 버킷에 안전하게 접근하도록 권한을 위임함

## 4) Implementation Notes (What and Why)

1. **Stateless Architecture Implementation:** 사용자가 업로드한 이미지를 EC2 Local Storage가 아닌 S3 버킷으로 Offloading하여, 인스턴스가 교체되거나 Scale-out 되더라도 Data Consistency를 유지하는 Stateless 환경을 구축했다.
2. **High Availability and Self-Healing:** ASG를 통해 최소 2대의 인스턴스를 여러 AZ에 걸쳐 유지하며, Round Robin 방식의 Load Balancing을 적용했다. 인스턴스 장애(Terminate로 모의 구현) 시 자동으로 새로운 인스턴스를 프로비저닝하여 서비스를 복구하는 Self-Healing을 구현했다.
3. **Dynamic Scaling (Scale-out):** CloudWatch 알람을 연동하여 CPU Utilization이 설정된 Threshold를 초과할 경우, ASG가 자동으로 인스턴스 개수를 늘리도록 Target Tracking Policy를 적용하여 트래픽 부하에 대응했다.
4. **Security Boundary & Credential Management:** RDS의 외부 접근을 차단하고 Security Group 간 참조를 통해 네트워크를 격리하였다. Terraform State 파일(`.tfstate`)과 환경 변수(`.env`)가 Git Repository에 유출되지 않도록 `.gitignore`를 적용하여 보안 원칙을 준수했다.

## 5) Validation Results

- Application Health & RDS Isolation: Yes (ALB를 통한 `/health` 엔드포인트 200 OK 응답 및 RDS `Public: false` 확인)
- S3 Offloading Validation: Yes (웹 브라우저에서 사진 업로드 완료 후, AWS CLI를 통해 S3 버킷 내 객체가 정상 저장됨을 확인)
- Load Balancing Validation: Yes (ALB DNS 주소로 다중 요청 시, 여러 AZ의 EC2 인스턴스 ID가 번갈아 응답함을 확인)
- Self-Healing Validation: Yes (실행 중인 EC2 인스턴스를 강제 종료한 후, ASG에 의해 신규 인스턴스가 자동 복구됨을 확인)
- Auto Scaling (Scale-out) Validation: Yes (ApacheBench(`ab`)를 활용한 부하 테스트 시, CloudWatch CPU 경보가 `In alarm` 상태로 전환됨을 확인)
- Resource cleanup: Yes (`terraform destroy`를 통한 AWS 리소스 정상 삭제 완료)

## 6) Troubleshooting about Code & Scenarios

- user-data.sh에서 두 개의 오류로 인해 ALB DNS가 실행되지 않았고, 3번째 시도만에 ALB DNS에 접속하는 데 성공하였다. 처음엔 어디서부터 다시 실행해야 할지 막막했지만, 생성형 AI에게 물어보면서 오류를 해결하고 terraform init부터 apply의 과정 중 어디서부터 다시 실행해야 하는지, EC2 Instance를 강제 종료시킬지를 배웠고, 어떤 현상은 관리자가 개입해야 하며 어떤 현상은 무시해도 될지를 배웠다. 또한 이미지가 보이지 않고 엑스박스가 생기거나 bash 코드 오류가 나는 등 하나하나 문제가 생길 때마다 원인이 무엇인지 하나하나 추적해가며 해결할 수 있음을 깨달았다.
- ab를 사용한 benchmark 테스트를 진행하고 CloudWatch에서 경보가 울리면서 EC2 인스턴스가 추가되는 과정을 관측하려고 했는데, t2.micro의 한계로 입력 큐에서부터 병목이 생겨 트래픽이 증가되지 않고 정해진 시간이 되어 끝나버렸다.

## 7) Reproducibility Checklist

- [x] 다른 사람이 그대로 실행할 수 있게 설치해야 하는 플러그인과 명령어를 안내하였다.
- [x] Terraform 코드로 ALB, ASG, RDS, S3를 포함한 3-Tier Architecture를 프로비저닝하도록 작성했다.
- [x] DB Master Password 및 Flask Secret Key를 환경 변수로 분리하여 보안을 유지했다.
- [x] S3 접근 권한 부여를 위해 EC2 인스턴스에 적절한 IAM Role(`LabInstanceProfile`)을 매핑했다.
- [x] 구현한 python과 Terraform 코드를 bash로 실행하고 각종 상황 테스트를 하여 배운 개념을 이해했다는 걸 증명하였다.
- [x] 터미널 명령어를 실행한 과정과 무엇을 구현하고 검증했는지를 `commands.md`에 문서화했다.
- [x] `README.md`에 어떤 툴을 써서 했는지, 어떤 인스턴스를 만들었고 어떤 걸 구현했는지 기존 서술 방식을 참고하여 상세하게 기록하였다.

