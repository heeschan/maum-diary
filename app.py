# -*- coding: utf-8 -*-
"""
마음일기 (maum-diary) — 클라우드컴퓨팅 기말과제용 무상태 Flask 서비스

핵심 설계 = STATELESS(무상태):
  - 일기 데이터  -> RDS (로컬 DB 아님)
  - 사진         -> S3  (EC2 디스크 아님)
  - 로그인 세션  -> 서명된 쿠키 (서버 메모리 아님)
이 세 가지 덕분에 "어느 EC2에 붙어도 동일하게 동작" -> 인스턴스는 언제든
죽고 새로 떠도 무방 -> ALB 분산 + ASG 오토스케일링 + HA 가 성립한다.

운영:
  gunicorn -w 4 -b 0.0.0.0:5000 app:app
  (Flask 개발 서버는 동시성 거동이 이상해서 ab 벤치마크 데이터가 망가짐)

환경변수(테라폼 user-data / SSM 으로 주입):
  SECRET_KEY   <- 모든 인스턴스 동일해야 함! 다르면 ALB가 다른 EC2로 보낼 때
                  쿠키 서명 검증이 깨져 로그인이 풀린다 (sticky session 불필요의 근거)
  DB_HOST DB_USER DB_PASSWORD DB_NAME DB_PORT   <- RDS
  S3_BUCKET  AWS_REGION                          <- S3 (자격증명은 EC2 IAM Role)
"""
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

# SECRET_KEY 는 반드시 전 인스턴스 공유 (위 주석 참고). 로컬 개발용 기본값만 둠.
app.secret_key = os.environ.get("SECRET_KEY", "dev-only-change-me")
app.config["MAX_CONTENT_LENGTH"] = 5 * 1024 * 1024  # 업로드 5MB 제한

# ---- 환경변수 설정 ----
DB_HOST = os.environ.get("DB_HOST", "localhost")
DB_USER = os.environ.get("DB_USER", "root")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")
DB_NAME = os.environ.get("DB_NAME", "maumdiary")
DB_PORT = int(os.environ.get("DB_PORT", "3306"))
S3_BUCKET = os.environ.get("S3_BUCKET", "")
AWS_REGION = os.environ.get("AWS_REGION", "ap-northeast-2")

# 고정 질문(자유 추가/삭제 기능은 클라우드와 무관해서 의도적으로 제외)
FIXED_QUESTIONS = [
    "오늘 하루 가장 기억에 남는 감정은 무엇인가요?",
    "스스로 칭찬해주고 싶은 점, 혹은 아쉬웠던 점은 무엇인가요?",
]
ALLOWED_EXT = {"png", "jpg", "jpeg", "gif", "webp"}

# 인스턴스 메타데이터는 인스턴스당 불변 -> 시작 시 1회만 읽어 캐싱
_INSTANCE_INFO = None


# ----------------------------------------------------------------------
# 헬퍼
# ----------------------------------------------------------------------
def get_db():
    """요청마다 RDS 커넥션 생성. 규모가 커지면 풀링이 필요(보고서: 데이터 티어 병목)."""
    return pymysql.connect(
        host=DB_HOST, user=DB_USER, password=DB_PASSWORD,
        database=DB_NAME, port=DB_PORT,
        cursorclass=pymysql.cursors.DictCursor,
        autocommit=True, connect_timeout=5,
    )


def s3():
    # 자격증명은 넘기지 않는다 -> EC2 IAM Role 자동 사용
    return boto3.client("s3", region_name=AWS_REGION)


def allowed(filename):
    return "." in filename and filename.rsplit(".", 1)[1].lower() in ALLOWED_EXT


def upload_to_s3(file):
    """사진을 S3로 오프로딩하고 object key 반환 (버킷은 private 유지)."""
    fname = secure_filename(file.filename)
    key = f"photos/{session['user_id']}/{int(time.time())}_{fname}"
    s3().upload_fileobj(
        file, S3_BUCKET, key,
        ExtraArgs={"ContentType": file.content_type or "application/octet-stream"},
    )
    return key


def presigned_url(key):
    """private 버킷의 사진을 표시하기 위한 임시 URL (1시간)."""
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
    """
    *** MOCK 전용 — 외부 API 호출 없음 ***
    나중에 OpenAI/Gemini 실제 호출로 이 함수 본문만 바꾸면 됨(인프라 영향 없음).
    벤치마크 대상으로는 절대 쓰지 말 것(비용/레이트리밋/응답시간 변동).
    """
    text = (a1 + " " + a2).strip()
    if not text:
        return "오늘은 짧게 기록하셨네요. 그래도 하루를 돌아본 것만으로 충분합니다."
    return ("오늘의 감정을 솔직하게 적어주셨네요. 그 감정을 있는 그대로 인정하는 "
            "것만으로도 마음이 한결 가벼워질 수 있어요. 스스로에게 조금 더 다정해도 "
            "괜찮습니다.")


def instance_info():
    """EC2 메타데이터(IMDSv2)에서 instance-id / AZ 읽기. 로컬에선 더미값."""
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


# ----------------------------------------------------------------------
# 라우트
# ----------------------------------------------------------------------
@app.route("/health")
def health():
    """ALB 타깃그룹 헬스체크용. 의도적으로 가볍게(여기서 DB 찌르면 RDS 한 번
    삐끗할 때 전 인스턴스가 unhealthy 가 됨)."""
    return "OK", 200


@app.route("/bench")
def bench():
    """
    벤치마크용 선택 엔드포인트.
    ASG를 CPU 기준으로 잡을 경우 `ab` 를 여기로 쏘면 CPU가 실제로 움직인다.
    (ALB RequestCountPerTarget 기준이면 아무 GET 경로나 쏴도 스케일아웃됨)
        예) ab -n 5000 -c 100 http://<ALB-DNS>/bench?work=50000
    """
    n = int(request.args.get("work", "20000"))
    x = 0
    for i in range(n):
        x += i * i
    return f"done {x} @ {instance_info()['instance_id']}", 200


@app.route("/init-db")
def init_db():
    """최초 1회 호출하여 테이블 생성(idempotent)."""
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
    """닉네임 + 4자리 PIN. 없는 닉네임이면 새로 만들고, 있으면 PIN 검증.
    user_id 는 서명된 쿠키 세션에만 저장 -> 무상태 유지."""
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
    want_ai = request.form.get("want_ai") == "on"   # 일기 전체 단위 체크박스 1개

    photo_key = None
    file = request.files.get("photo")
    if file and file.filename and allowed(file.filename) and S3_BUCKET:
        photo_key = upload_to_s3(file)              # -> S3 오프로딩

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
    # 로컬 테스트용. 운영은 gunicorn 사용.
    app.run(host="0.0.0.0", port=5000)
