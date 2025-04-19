variable "kubeconfig_path" {
  description = "Pad naar het kubeconfig bestand"
  type        = string
}

variable "rancher_hostname" {
  description = "Hostname voor Rancher UI toegang"
  type        = string
}

variable "rancher_bootstrap_password" {
  description = "Initieel wachtwoord voor admin gebruiker"
  type        = string
  sensitive   = true
}

variable "lets_encrypt_email" {
  description = "Email adres voor Let's Encrypt notificaties"
  type        = string
}

variable "lets_encrypt_environment" {
  description = "Let's Encrypt omgeving (production of staging)"
  type        = string
  default     = "production"
}

# Deze variabele is optioneel en wordt alleen gebruikt als je een specifieke NodePort wilt forceren
variable "rancher_loadbalancer_ip" {
  description = "IP adres voor de Rancher LoadBalancer service"
  type        = string
  default     = "10.10.11.50"  # Standaard VIP voor Rancher
} 