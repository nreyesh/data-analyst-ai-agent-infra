terraform {
  required_version = ">= 1.5.0"

  # Partial backend configuration:
  # 'bucket' and 'prefix' are injected dynamically per environment (dev vs prod)
  # by the CI/CD pipeline during 'terraform init -backend-config=...'
  backend "gcs" {}
}
