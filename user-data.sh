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
mkdir -p /var/www/maum-diary/templates
cd /var/www/maum-diary

# 3. 요구사항 기반의 인라인 소스코드 배치 기법 활용 (GitHub 장애 전파 리스크 격리)
cat << 'EOF' > app.py
# -*- coding: utf-8 -*-
import os
import time
import urllib.request
import pymysql
import boto3
from flask import (Flask, request, session, redirect, url_for,
                   render_template, flash, get_flashed_messages)
from werkzeug.security import generate_password_hash, check_password_hash
from werkzeug.utils import secure_filename

app = Flask(__name__)

app.secret_key = os.environ.get("SECRET_KEY", "dev-only-change-me")
app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024

DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_USER = os.environ.get("DB_USER", "root")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "maumdiary")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
S3_BUCKET = os.environ.get("S3_BUCKET", "")
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")

FIXED_QUESTIONS = [
    "오늘 하루 가장 기억에 남는 감정은 무엇인가요?",
    "스스로 칭찬해주고 싶은 점, 혹은 아쉬웠던 점은 무엇인가요?",
]
ALLOWED_EXT = {"png", "jpg", "jpeg", "gif", "webp"}
_INSTANCE_INFO = None

def get_db():
    return pymysql.connect(
        host=DB_HOST, user=DB_USER, password=DB_PASSWORD,
        database=DB_NAME, port=DB_PORT,
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True, connect_timeout=5,
    )

def s3():
    return boto3.client("s3", region_name=AWS_REGION)

def allowed(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXT

def upload_to_s3(file):
    fname = secure_filename(file.filename)
    key = f"photos/{session['user_id']}/{int(time.time())}_{fname}"
    s3().upload_fileobj(
        file, S3_BUCKET, key,
        ExtraArgs={"ContentType": file.content_type or "application/octet-stream"},
    )
    return key

def presigned_url(key):
    if not key or not S3_BUCKET:
        return None
    try:
        return s3().generate_presigned_url(
            "get_object",
            Params={"Bucket": S3_BUCKET, "Key": key},
            ExpiresIn=3600,
        )
    except Exception:
        return None

def mock_ai_feedback(a1, a2):
    text = (a1 + " " + a2).strip()
    if not text:
        return "오늘은 짧게 기록하셨네요. 그래도 하루를 돌아본 것만으로 충분합니다."
    return ("오늘의 감정을 솔직하게 적어주셨네요. 그 감정을 있는 그대로 인정하는 "
            "것만으로도 마음이 한결 가벼워질 수 있어요. 스스로에게 조금 더 다정해도 "
            "괜찮습니다.")

def instance_info():
    global _INSTANCE_INFO
    if _INSTANCE_INFO is not None:
        return _INSTANCE_INFO
    try:
        token_req = urllib.request.Request(
            "http://169.254.169.254/latest/api/token", method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
        token = urllib.request.urlopen(token_req, timeout=0.3).read().decode()
        hdr = {"X-aws-ec2-metadata-token": token}
        def meta(path):
            r = urllib.request.Request(
                "http://169.254.169.254/latest/meta-data/" + path, headers=hdr)
            return urllib.request.urlopen(r, timeout=0.3).read().decode()
        _INSTANCE_INFO = {"instance_id": meta("instance-id"),
                          "az": meta("placement/availability-zone")}
    except Exception:
        _INSTANCE_INFO = {"instance_id": "local-dev", "az": "local"}
    return _INSTANCE_INFO

@app.route("/health")
def health():
    return "OK", 200

@app.route("/bench")
def bench():
    n = int(request.args.get("work", "20000"))
    x = 0
    for i in range(n):
        x += i * i
    return f"done {x} @ {instance_info()['instance_id']}", 200

@app.route("/init-db")
def init_db():
    conn = get_db()
    with conn.cursor() as cur:
        cur.execute("""
            CREATE TABLE IF NOT EXISTS users (
              id INT AUTO_INCREMENT PRIMARY KEY,
              nickname VARCHAR(50) UNIQUE NOT NULL,
              pin_hash VARCHAR(255) NOT NULL,
              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
            )""")
        cur.execute("""
            CREATE TABLE IF NOT EXISTS entries (
              id INT AUTO_INCREMENT PRIMARY KEY,
              user_id INT NOT NULL,
              answer1 TEXT,
              answer2 TEXT,
              photo_key VARCHAR(512),
              ai_requested BOOLEAN DEFAULT FALSE,
              ai_response TEXT,
              created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
              INDEX (user_id)
            )""")
    conn.close()
    return "DB initialized", 200

@app.route("/")
def home():
    info = instance_info()
    if "user_id" not in session:
        return render_template("index.html", logged_in=False,
                               questions=FIXED_QUESTIONS, instance=info,
                               messages=get_flashed_messages())

    conn = get_db()
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM entries WHERE user_id=%s "
                    "ORDER BY created_at DESC", (session["user_id"],))
        entries = cur.fetchall()
    conn.close()

    for e in entries:
        e["photo_display_url"] = presigned_url(e.get("photo_key"))

    return render_template("index.html", logged_in=True,
                           nickname=session.get("nickname"),
                           entries=entries, questions=FIXED_QUESTIONS,
                           instance=info, messages=get_flashed_messages())

@app.route("/login", methods=["POST"])
def login():
    nickname = (request.form.get("nickname") or "").strip()
    pin = (request.form.get("pin") or "").strip()
    if not nickname or not (pin.isdigit() and len(pin) == 4):
        flash("닉네임과 4자리 숫자 PIN을 입력하세요.")
        return redirect(url_for("home"))

    conn = get_db()
    with conn.cursor() as cur:
        cur.execute("SELECT * FROM users WHERE nickname=%s", (nickname,))
        user = cur.fetchone()
        if user is None:
            cur.execute("INSERT INTO users (nickname, pin_hash) VALUES (%s,%s)",
                        (nickname, generate_password_hash(pin)))
            cur.execute("SELECT * FROM users WHERE nickname=%s", (nickname,))
            user = cur.fetchone()
        elif not check_password_hash(user["pin_hash"], pin):
            conn.close()
            flash("PIN이 일치하지 않습니다.")
            return redirect(url_for("home"))
    conn.close()

    session["user_id"] = user["id"]
    session["nickname"] = user["nickname"]
    return redirect(url_for("home"))

@app.route("/logout")
def logout():
    session.clear()
    return redirect(url_for("home"))

@app.route("/entry", methods=["POST"])
def create_entry():
    if "user_id" not in session:
        return redirect(url_for("home"))

    a1 = (request.form.get("answer1") or "").strip()
    a2 = (request.form.get("answer2") or "").strip()
    want_ai = request.form.get("want_ai") == "on"

    photo_key = None
    file = request.files.get("photo")
    if file and file.filename and allowed(file.filename) and S3_BUCKET:
        photo_key = upload_to_s3(file)

    ai_response = mock_ai_feedback(a1, a2) if want_ai else None

    conn = get_db()
    with conn.cursor() as cur:
        cur.execute(
            """INSERT INTO entries
               (user_id, answer1, answer2, photo_key, ai_requested, ai_response)
               VALUES (%s,%s,%s,%s,%s,%s)""",
            (session["user_id"], a1, a2, photo_key, want_ai, ai_response))
    conn.close()
    return redirect(url_for("home"))

if __name__ == "__main__":
    app.run(host="0.0.0.0", port=5000)
EOF

# 3-2. HTML 템플릿 코드 배치
cat << 'EOF' > templates/index.html
<!DOCTYPE html>
<html lang="ko">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>마음일기</title>
  <style>
    * { box-sizing: border-box; }
    body { font-family: -apple-system, "Segoe UI", sans-serif; max-width: 640px; margin: 0 auto; padding: 24px 16px 80px; background: #f6f5f2; color: #2b2b2b; line-height: 1.6; }
    h1 { font-size: 1.5rem; margin-bottom: 4px; }
    .sub { color: #888; font-size: .9rem; margin-bottom: 24px; }
    .card { background: #fff; border: 1px solid #e6e3dd; border-radius: 12px; padding: 20px; margin-bottom: 16px; }
    label { display: block; font-weight: 600; margin: 14px 0 6px; font-size: .95rem; }
    input[type=text], input[type=password], textarea { width: 100%; padding: 10px 12px; border: 1px solid #d6d2ca; border-radius: 8px; font-size: 1rem; font-family: inherit; background: #fafaf8; }
    textarea { min-height: 80px; resize: vertical; }
    .check { display: flex; align-items: center; gap: 8px; margin: 16px 0; font-size: .95rem; }
    .check input { width: auto; }
    button { background: #3a3a3a; color: #fff; border: none; border-radius: 8px; padding: 11px 18px; font-size: 1rem; cursor: pointer; margin-top: 8px; }
    button:hover { background: #222; }
    .flash { background: #fde9e7; color: #9b3b32; padding: 10px 14px; border-radius: 8px; margin-bottom: 16px; font-size: .9rem; }
    .entry { border-top: 1px solid #eee; padding-top: 14px; margin-top: 14px; }
    .entry:first-of-type { border-top: none; margin-top: 0; padding-top: 0; }
    .entry .date { color: #999; font-size: .8rem; }
    .entry img { max-width: 100%; border-radius: 8px; margin-top: 10px; }
    .ai { background: #eef3ee; border-left: 3px solid #7a9b7a; padding: 10px 14px; border-radius: 6px; margin-top: 10px; font-size: .92rem; color: #3c5c3c; }
    .topbar { display: flex; justify-content: space-between; align-items: center; }
    .ghost { background: none; color: #888; padding: 6px 0; font-size: .85rem; }
    .badge { position: fixed; bottom: 12px; right: 12px; background: #2b2b2b; color: #b9e3b9; font-size: .72rem; font-family: monospace; padding: 6px 10px; border-radius: 6px; opacity: .9; }
    .q { color: #555; font-size: .9rem; }
  </style>
</head>
<body>
  {% if messages %}
    {% for m in messages %}<div class="flash">{{ m }}</div>{% endfor %}
  {% endif %}

  {% if not logged_in %}
    <h1>마음일기</h1>
    <p class="sub">하루의 끝에서 오늘의 감정을 기록해요.</p>
    <div class="card">
      <form action="/login" method="post">
        <label>닉네임</label>
        <input type="text" name="nickname" maxlength="50" placeholder="예: 별빛">
        <label>PIN (숫자 4자리)</label>
        <input type="password" name="pin" inputmode="numeric" maxlength="4" pattern="[0-9]{4}" placeholder="••••">
        <button type="submit">기록 시작하기</button>
      </form>
      <p class="sub" style="margin-top:14px;">처음 입력한 닉네임은 자동 생성됩니다. 같은 닉네임+PIN으로 내 기록을 다시 볼 수 있어요.</p>
    </div>
  {% else %}
    <div class="topbar">
      <h1>{{ nickname }}님의 마음일기</h1>
      <a href="/logout"><button class="ghost" type="button">로그아웃</button></a>
    </div>
    <p class="sub">오늘 하루를 돌아보며 솔직하게 적어보세요.</p>
    <div class="card">
      <form action="/entry" method="post" enctype="multipart/form-data">
        <label>{{ questions[0] }}</label>
        <textarea name="answer1"></textarea>
        <label>{{ questions[1] }}</label>
        <textarea name="answer2"></textarea>
        <label>오늘의 감정 사진 (선택, 1장)</label>
        <input type="file" name="photo" accept="image/*">
        <div class="check">
          <input type="checkbox" name="want_ai" id="want_ai">
          <label for="want_ai" style="margin:0;font-weight:400;">AI에게 말하기 (감정적 지지/제안 받기) — 체크 안 하면 기록만 합니다</label>
        </div>
        <button type="submit">기록하기</button>
      </form>
    </div>
    {% if entries %}
    <div class="card">
      {% for e in entries %}
        <div class="entry">
          <div class="date">{{ e.created_at }}</div>
          {% if e.answer1 %}<p><span class="q">Q. {{ questions[0] }}</span><br>{{ e.answer1 }}</p>{% endif %}
          {% if e.answer2 %}<p><span class="q">Q. {{ questions[1] }}</span><br>{{ e.answer2 }}</p>{% endif %}
          {% if e.photo_display_url %}<img src="{{ e.photo_display_url }}" alt="감정 사진">{% endif %}
          {% if e.ai_response %}<div class="ai">🌿 {{ e.ai_response }}</div>{% endif %}
        </div>
      {% endfor %}
    </div>
    {% else %}
      <p class="sub">아직 기록이 없어요. 첫 마음을 적어보세요.</p>
    {% endif %}
  {% endif %}
  <div class="badge">{{ instance.instance_id }} · {{ instance.az }}</div>
</body>
</html>
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
AWS_REGION="us-east-1"
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