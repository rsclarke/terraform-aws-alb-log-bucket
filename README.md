# terraform-aws-alb-log-bucket

Reusable Terraform module that provisions an S3 bucket for centralised ALB log retention, supporting access logs, connection logs, and health check logs. Enable whichever log types you need on each ALB — the bucket accepts all three with:

- S3 account-regional namespace to prevent bucketsquatting
- SSE-S3 encryption (the only option supported by ALB log delivery)
- Bucket versioning and public access blocking
- Bucket policy allowing `logdelivery.elasticloadbalancing.amazonaws.com` scoped to your AWS Organisation
- Default lifecycle tiers (Standard → Glacier → Deep Archive → expire at 7 years)
- IAM read policy for consuming ALB logs

The bucket is always created in your account's [account-regional namespace](https://aws.amazon.com/blogs/aws/introducing-account-regional-namespaces-for-amazon-s3-general-purpose-buckets/). The full bucket name is constructed as `<bucket_name>-<account_id>-<region>-an`, ensuring only your account can own names with your suffix.

This module is designed for a Log Archive account in an AWS Organisation (typically via AWS Control Tower). ALB logs from any account in the organisation can be delivered to this bucket without enumerating individual account IDs.

## Usage

```hcl
module "alb_logs_bucket" {
  source = "rsclarke/alb-log-bucket/aws"

  bucket_name     = "alb-logs"
  organization_id = "o-abc123xyz"

  # Creates bucket: alb-logs-123456789012-eu-west-2-an
}

# Attach the read policy to roles that need to query ALB logs:
#
# - security team:  attach module.alb_logs_bucket.read_policy_arn
# - audit role:     attach module.alb_logs_bucket.read_policy_arn
# - bucket name:    use module.alb_logs_bucket.bucket_name for the full
#                   computed bucket name
```

## Source-Account ALB Configuration

ALB logging is configured in each source account, not in this module. Use the `bucket_name` output as the target bucket:

```hcl
resource "aws_lb" "this" {
  name               = "my-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = var.subnet_ids

  access_logs {
    bucket  = module.alb_logs_bucket.bucket_name
    enabled = true
  }

  connection_logs {
    bucket  = module.alb_logs_bucket.bucket_name
    enabled = true
  }

  # Health check logs use the same bucket via load balancer attributes:
  #   health_check_logs.s3.enabled = true
  #   health_check_logs.s3.bucket  = module.alb_logs_bucket.bucket_name
}
```

All three log types write to the same path structure under `AWSLogs/`:

```
s3://<bucket>/AWSLogs/<account-id>/elasticloadbalancing/<region>/YYYY/MM/DD/
├── <account>_elasticloadbalancing_<region>_app.<lb-id>_<time>_<ip>_<rand>.log.gz              (access logs)
├── conn_log_<account>_elasticloadbalancing_<region>_app.<lb-id>_<time>_<ip>_<rand>.log.gz     (connection logs)
└── health_check_log_<account>_elasticloadbalancing_<region>_app.<lb-id>_<time>_<ip>_<rand>.log.gz (health check logs)
```

> **Do not set a prefix** (e.g. `access_logs.s3.prefix`) when configuring ALBs. The bucket policy only permits writes under `AWSLogs/`. A prefix would change the path to `<prefix>/AWSLogs/...`, causing delivery to fail.

## Encryption

This module uses SSE-S3 (`AES256`) exclusively. ALB access logs, connection logs, and health check logs only support SSE-S3 — KMS encryption is not available for these log types.

The bucket relies on default encryption configuration rather than SSE header enforcement, because the ALB log delivery service does not send explicit encryption headers.

## Lifecycle And Retention

When `manage_lifecycle = true` (default), the module creates a lifecycle configuration with two rules:

| Rule | Scope | Behaviour |
|------|-------|-----------|
| `alb-logs-retention` | `AWSLogs/` prefix | 90d → Glacier, 365d → Deep Archive, 2555d (7 years) expiry |
| `cleanup` | Entire bucket | Expired delete marker cleanup, noncurrent version expiry at 30d, abort incomplete multipart uploads at 7d |

The 7-year retention covers most compliance frameworks (NIST, PCI-DSS, SOC 2). The lifecycle skips STANDARD_IA because ALB logs produce many small compressed files where the 128 KB minimum object charge makes IA more expensive than Standard.

The `transition_default_minimum_object_size` is set to `varies_by_storage_class`, ensuring small log objects are still transitioned to archival tiers.

Set `manage_lifecycle = false` to manage lifecycle configuration externally via the `bucket_arn` output. This avoids resource conflicts when you need custom retention policies.

## Trust Model

This module scopes log delivery to a single AWS Organisation via the `aws:SourceOrgID` condition. Any account within that organisation can deliver ALB logs to this bucket without additional bucket policy changes.

The exported read IAM policy is bucket-wide (`${bucket}/*`). If you need to restrict read access to specific accounts or prefixes, attach caller-managed path-scoped IAM policies instead of (or in addition to) the module output.

The bucket policy denies all non-TLS requests to protect log data in transit.

## Important Constraints

- **Same region:** The bucket must be in the same AWS Region as the ALBs delivering logs. Deploy this module in each region where you operate ALBs.
- **No prefix:** Do not configure a log prefix on the ALB. The bucket policy restricts writes to `AWSLogs/*` to enforce consistent log paths across the organisation.
- **ALB only:** This module supports Application Load Balancer logs only. Network Load Balancers use a different service principal (`delivery.logs.amazonaws.com`), support SSE-KMS, and require `s3:GetBucketAcl` — use a separate module for NLB logs. Outposts Zones are not supported.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.7 |
| aws | >= 6.37.0 |

## Providers

| Name | Version |
|------|---------|
| aws | >= 6.37.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| bucket_name | Prefix for the S3 bucket name. The account-regional suffix is appended automatically. | `string` | n/a | yes |
| organization_id | AWS Organization ID. Scopes ALB log delivery to accounts within this organization. | `string` | n/a | yes |
| manage_lifecycle | When true, creates a default lifecycle configuration. Set false to manage externally. | `bool` | `true` | no |
| force_destroy | Allow destruction of the bucket even when it contains objects. | `bool` | `false` | no |
| tags | Tags to apply to all resources created by this module. | `map(string)` | `{}` | no |

## Outputs

| Name | Description |
|------|-------------|
| bucket_name | Full name of the S3 bucket (including account-regional suffix) |
| bucket_arn | ARN of the S3 bucket |
| read_policy_arn | ARN of the IAM policy granting read access to ALB logs |
