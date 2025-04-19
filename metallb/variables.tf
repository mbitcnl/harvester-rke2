variable "kubeconfig_path" {
  description = "Pad naar het kubeconfig bestand voor de Kubernetes provider."
  type        = string
}

variable "metallb_namespace" {
  description = "De Kubernetes namespace waarin MetalLB wordt geïnstalleerd."
  type        = string
  default     = "metallb-system"
}

variable "metallb_ip_range" {
  description = "Het IP-adresbereik dat MetalLB moet beheren (bijv. '10.10.11.50-10.10.11.70')."
  type        = string
  default     = "10.10.11.50-10.10.11.70" # Standaard bereik, pas aan indien nodig
} 