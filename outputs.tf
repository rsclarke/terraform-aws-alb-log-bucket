output "bucket_name" {
  description = "Full name of the S3 bucket (including account-regional suffix)"
  value       = aws_s3_bucket.this.id
}

output "bucket_arn" {
  description = "ARN of the S3 bucket"
  value       = aws_s3_bucket.this.arn
}

output "read_policy_arn" {
  description = "ARN of the IAM policy granting read access to ALB logs"
  value       = aws_iam_policy.read.arn
}
