terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "2.11.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.23.0"
    }
  }
}

provider "kubernetes" {
  config_path = var.kubeconfig_path
}

provider "helm" {
  kubernetes {
    config_path = var.kubeconfig_path
  }
}

# Maak de namespaces aan in plaats van bestaande te gebruiken
resource "kubernetes_namespace" "cattle_system" {
  metadata {
    name = "cattle-system"
  }
}

resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

# Installeer cert-manager via Helm
resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name
  version    = "v1.12.0"

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [kubernetes_namespace.cert_manager]
}

# Installeer Rancher via Helm
resource "helm_release" "rancher" {
  name       = "rancher"
  repository = "https://releases.rancher.com/server-charts/latest"
  chart      = "rancher"
  namespace  = kubernetes_namespace.cattle_system.metadata[0].name
  version    = "2.8.2"
  
  # Configuratie om timeouts te voorkomen
  timeout    = 1200  # 20 minuten
  wait       = false  # Niet wachten tot pods draaien
  wait_for_jobs = false
  atomic     = false
  
  set {
    name  = "hostname"
    value = var.rancher_hostname
  }

  set {
    name  = "bootstrapPassword"
    value = var.rancher_bootstrap_password
  }

  # Ingress configuratie
  set {
    name  = "ingress.enabled"
    value = "true"
  }
  
  # Gebruik Rancher's gegenereerde TLS certificaten (self-signed)
  # Dit is prima voor intern gebruik of met externe reverse proxy
  set {
    name  = "ingress.tls.source"
    value = "rancher"
  }

  # Gebruik LoadBalancer service type voor Rancher
  set {
    name  = "service.type"
    value = "LoadBalancer"
  }
  
  # Gebruik specifiek IP adres voor de LoadBalancer
  set {
    name  = "service.loadBalancerIP"
    value = var.rancher_loadbalancer_ip
  }

  # Algemene configuratie
  set {
    name  = "replicas"
    value = "1"  # Start met 1 replica voor snelle setup
  }
  
  # Resource limits verlagen om sneller op te starten
  set {
    name  = "resources.limits.memory"
    value = "1Gi"
  }
  
  set {
    name  = "resources.requests.memory"
    value = "750Mi"
  }

  depends_on = [
    helm_release.cert_manager,
    kubernetes_namespace.cattle_system
  ]
}

# Output the Rancher UI URL
output "rancher_url" {
  value = "Rancher UI is bereikbaar op:\n  - https://${var.rancher_hostname} (na DNS configuratie)\n  - https://${var.rancher_loadbalancer_ip} (direct via IP, voeg dan host entry toe in /etc/hosts)"
}

output "admin_password" {
  value       = var.rancher_bootstrap_password
  sensitive   = true
  description = "Initiële admin wachtwoord (vergeet niet te wijzigen na eerste login)"
} 