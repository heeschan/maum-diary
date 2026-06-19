output "alb_dns_name" {
  description = "로드밸런서의 전체 퍼블릭 웹 주소 (기말과제 제출용 서비스 메인 주소)"
  value       = "http://${aws_lb.alb.dns_name}"
}

output "benchmark_url" {
  description = "ApacheBench(ab) 부하 테스트 공격 타깃 주소"
  value       = "http://${aws_lb.alb.dns_name}/bench"
}

output "rds_endpoint" {
  description = "프로비저닝된 프라이빗 RDS 내부 호스트 주소"
  value       = aws_db_instance.mysql.address
}

output "s3_bucket_name" {
  description = "일기 사진 업로드 수집용 전용 S3 버킷 명칭"
  value       = aws_s3_bucket.photos.id
}