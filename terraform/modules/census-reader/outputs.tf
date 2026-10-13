output "role_arn" {
  description = "ARN the census CLI assumes"
  value       = aws_iam_role.census_reader.arn
}
