#!/bin/bash
set -euo pipefail

# 초기 프로비저닝 로깅 파이프라인 생성
exec > >(tee /var/log/app-provisioning.log | logger -t app-user-data -s 2>/dev/console) 2>&1

echo "========================================="
echo "Starting Application Environment Provisioning"
echo "========================================="

# 1. 시스템 업데이트 및 필수 파이썬/컴파일 라이브러리 스택 설치
dnf upgrade -y
dnf install -y python3 python3-pip python3-devel git gcc mariadb105

# 2. 배포 디렉토리 생성 및 권한 위임
mkdir -p /var/www/maum-diary
cd /var/www/maum-diary

# 3. 요구사항 기반의 인라인 소스코드 배치 기법 활용 (GitHub 장애 전파 리스크 격리)
cat << 'EOF' > app.py
# 이 공간에 작성하신 app.py 소스코드를 그대로 집어넣으시면 빌드 타임에 완벽히 동기화됩니다.
EOF

cat << 'EOF' > requirements.tf
flask
boto3
pymysql
gunicorn
cryptography
EOF

# 4. 가상 환경 구성 및 프로덕션 패키지 완전 설치
python3 -m venv venv
source venv/bin/activate
pip install --upgrade pip
pip install -r requirements.tf

# 5. Terraform 데이터 바인딩 기반의 독립형 환경 설정 프로파일 빌드
cat << EOF > .env
DB_HOST="${db_host}"
DB_PORT="${db_port}"
DB_NAME="${db_name}"
DB_USER="${db_user}"
DB_PASSWORD="${db_password}"
S3_BUCKET="${s3_bucket}"
SECRET_KEY="${flask_secret_key}"
EOF

# 6. 인스턴스 전원 안정성 확보를 위한 Systemd 자립형 데몬 서비스 유닛 등록
cat << EOF > /etc/systemd/system/diary.service
[Unit]
Description=Gunicorn production daemon instance for Maum Diary Flask Application
After=network.target

[Service]
User=root
WorkingDirectory=/var/www/maum-diary
EnvironmentFile=/var/www/maum-diary/.env
ExecStart=/var/www/maum-diary/venv/bin/gunicorn --workers 4 --bind 0.0.0.0:80 app:app
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# 7. 의존성 데몬 부팅 및 원격 연결 상태 수렴
systemctl daemon-reload
systemctl enable diary
systemctl start diary

echo "========================================="
echo "Application Provisioning Phase Completed Successfully"
echo "========================================="