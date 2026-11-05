# Artifact Registry for Backend Docker images
# (APIs are pre-enabled manually at the project level for security)
resource "google_artifact_registry_repository" "docker_repo" {
  project       = var.project_id
  location      = var.region
  repository_id = "agent-containers-${var.environment}"
  description   = "Docker repository for backend services (${var.environment})"
  format        = "DOCKER"
}
