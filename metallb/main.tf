terraform {
  required_providers {
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.11"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.23"
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

# Namespace aanmaken voor MetalLB
resource "kubernetes_namespace" "metallb_namespace" {
  metadata {
    name = var.metallb_namespace
    # Optioneel: labels toevoegen
    # labels = {
    #   "pod-security.kubernetes.io/enforce" = "privileged"
    #   "pod-security.kubernetes.io/audit" = "privileged"
    #   "pod-security.kubernetes.io/warn" = "privileged"
    # }
  }
}

# MetalLB installeren via Helm, INCLUSIEF configuratie
resource "helm_release" "metallb" {
  name       = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  namespace  = kubernetes_namespace.metallb_namespace.metadata[0].name
  version    = "0.14.5" 
  timeout    = 600 # Verhoogde timeout voor zekerheid
  wait       = true
  wait_for_jobs = true # Wacht ook op eventuele jobs
  atomic     = true # Rol terug bij fouten
  # skip_crds = false # Standaard, Helm beheert CRDs nu

  # Configuratie direct meegeven via Helm values
  values = [
    <<-EOT
    # CRDs worden beheerd door de Helm chart zelf
    crds:
      enabled: true
      
    # IPAddressPool configuratie
    ipAddressPools:
    - name: default-pool
      addresses:
      - ${var.metallb_ip_range}
      # Optioneel: autoAssign: false als je IPs handmatig wilt toewijzen
      # autoAssign: true
      
    # L2Advertisement configuratie
    l2Advertisements:
    - name: default-l2
      ipAddressPools:
      - default-pool # Verwijst naar de pool hierboven
    EOT
  ]

  depends_on = [
    kubernetes_namespace.metallb_namespace
  ]
}

# Controleer de MetalLB configuratie na installatie
resource "null_resource" "check_metallb_config" {
  depends_on = [
    helm_release.metallb # Wacht tot Helm klaar is
  ]

  provisioner "local-exec" {
    command = <<-EOT
      export KUBECONFIG=${var.kubeconfig_path}
      echo "Wachten voor synchronisatie na Helm installatie..."
      sleep 15
      echo "\nMetalLB Configuratie Controle:"
      echo "-----------------------------"
      echo "Namespace: ${var.metallb_namespace}"
      echo "Pods Status:"
      kubectl get pods -n ${var.metallb_namespace} -o wide
      echo "\nIPAddressPool Status (aangemaakt via Helm):"
      # Controleer of de CRD bestaat en de resource is aangemaakt
      kubectl get crd ipaddresspools.metallb.io || echo "IPAddressPool CRD niet gevonden!"
      kubectl get ipaddresspool -n ${var.metallb_namespace} default-pool -o yaml || echo "IPAddressPool 'default-pool' niet gevonden!"
      echo "\nL2Advertisement Status (aangemaakt via Helm):"
      kubectl get crd l2advertisements.metallb.io || echo "L2Advertisement CRD niet gevonden!"
      kubectl get l2advertisement -n ${var.metallb_namespace} default-l2 -o yaml || echo "L2Advertisement 'default-l2' niet gevonden!"
      echo "\nMetalLB is geconfigureerd met IP bereik: ${var.metallb_ip_range}"
    EOT
  }
  
  # Zorg dat deze check opnieuw runt als de Helm release verandert
  triggers = {
    helm_release_id = helm_release.metallb.id
  }
}

# Output om de status te bevestigen
output "metallb_status" {
  description = "Status van de MetalLB installatie."
  value       = "MetalLB geïnstalleerd en geconfigureerd via Helm in namespace '${var.metallb_namespace}' met IP-bereik '${var.metallb_ip_range}'. Controleer de output van 'check_metallb_config' voor details."
} 