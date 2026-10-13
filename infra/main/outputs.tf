output "frontend_public_ip" {
  description = "Public IP of instance A (vote, result, bastion)."
  value       = aws_instance.this["frontend"].public_ip
}

output "backend_private_ip" {
  description = "Private IP of instance B (Redis, worker)."
  value       = aws_instance.this["backend"].private_ip
}

output "db_private_ip" {
  description = "Private IP of instance C (Postgres)."
  value       = aws_instance.this["db"].private_ip
}

output "vote_url" {
  value = "http://${aws_instance.this["frontend"].public_ip}/"
}

output "result_url" {
  value = "http://${aws_instance.this["frontend"].public_ip}:8080/"
}
