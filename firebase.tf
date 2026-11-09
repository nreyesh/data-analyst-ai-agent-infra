# ==============================================================================
# Firebase & Identity Platform Authentication Infrastructure
# ==============================================================================

# 1. Enable Core Firebase & Identity Toolkit APIs
resource "google_project_service" "identitytoolkit" {
  project            = var.project_id
  service            = "identitytoolkit.googleapis.com"
  disable_on_destroy = false
}

resource "google_project_service" "firebase" {
  project            = var.project_id
  service            = "firebase.googleapis.com"
  disable_on_destroy = false
}

# 2. Link Firebase Capabilities to the Google Cloud Project
resource "google_firebase_project" "default" {
  provider = google-beta
  project  = var.project_id

  depends_on = [
    google_project_service.firebase,
    google_project_service.identitytoolkit
  ]
}

# 3. Configure Authentication: Email/Password & Authorized Domains
# Enforces strict origin checking and password requirement for tenant security
resource "google_identity_platform_config" "auth_config" {
  provider = google-beta
  project  = var.project_id

  # Enable Email & Password authentication provider
  sign_in {
    email {
      enabled           = true
      password_required = true
    }
    anonymous {
      enabled = false
    }
  }

  # Strict Authorized Domains whitelist (prevents unauthorized redirect / sign-in origins)
  authorized_domains = [
    "localhost",
    "${var.project_id}.firebaseapp.com",
    "${var.project_id}.web.app"
  ]

  depends_on = [
    google_firebase_project.default
  ]
}

# 4. Register a Web App under Firebase to acquire the client-side API configuration
resource "google_firebase_web_app" "front_app" {
  provider     = google-beta
  project      = var.project_id
  display_name = "Building Analytics Web (${var.environment})"

  depends_on = [
    google_firebase_project.default
  ]
}

data "google_firebase_web_app_config" "front_app_config" {
  provider   = google-beta
  project    = var.project_id
  web_app_id = google_firebase_web_app.front_app.app_id
}

# 5. Store Firebase Web API Key in Secret Manager for automated frontend consumption
resource "google_secret_manager_secret" "firebase_api_key" {
  secret_id = "building-analytics-firebase-api-key-${var.environment}"
  project   = var.project_id

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret_version" "firebase_api_key_val" {
  secret      = google_secret_manager_secret.firebase_api_key.id
  secret_data = data.google_firebase_web_app_config.front_app_config.api_key
}
