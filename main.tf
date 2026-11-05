# Enable necessary APIs for our AI Agent ecosystem
resource "google_project_service" "enabled_apis" {
  for_each = toset([
    "run.googleapis.com",              # Cloud Run
    "artifactregistry.googleapis.com", # Artifact Registry (Docker container images)
    "cloudbuild.googleapis.com",       # Cloud Build
    "storage.googleapis.com",          # Cloud Storage
    "aiplatform.googleapis.com",       # Vertex AI
    "bigquery.googleapis.com"          # BigQuery
  ])

  project = var.project_id
  service = each.key

  disable_on_destroy = false
}

# Example environment-specific resource: Artifact Registry Repository for Docker images
resource "google_artifact_registry_repository" "docker_repo" {
  depends_on    = [google_project_service.enabled_apis]
  project       = var.project_id
  location      = var.region
  repository_id = "agent-containers-${var.environment}"
  description   = "Docker repository for agent microservices (${var.environment})"
  format        = "DOCKER"
}
