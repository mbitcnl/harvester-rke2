variable "harvester_kubeconfig_path" {
  description = "Pad naar het kubeconfig bestand voor Harvester"
  type        = string
}

variable "namespace" {
  description = "Namespace waar de resources worden aangemaakt in Harvester"
  type        = string
  default     = "default"
}

variable "network_name" {
  description = "Naam van het netwerk om te gebruiken in Harvester"
  type        = string
}

variable "network_interface" {
  description = "Naam van de netwerk interface in de VMs"
  type        = string
  default     = "ens2"
}

variable "master_count" {
  description = "Aantal master nodes"
  type        = number
  default     = 3
}

variable "worker_count" {
  description = "Aantal worker nodes"
  type        = number
  default     = 3
}

variable "master_cpu" {
  description = "Aantal CPU cores voor master nodes"
  type        = number
  default     = 2
}

variable "master_memory" {
  description = "Geheugen in MiB voor master nodes"
  type        = number
  default     = 4096
}

variable "master_disk_size" {
  description = "Disk grootte voor master nodes (bijv. '40Gi')"
  type        = string
  default     = "40Gi"
}

variable "worker_cpu" {
  description = "Aantal CPU cores voor worker nodes"
  type        = number
  default     = 4
}

variable "worker_memory" {
  description = "Geheugen in MiB voor worker nodes"
  type        = number
  default     = 8192
}

variable "worker_disk_size" {
  description = "Disk grootte voor worker nodes (bijv. '80Gi')"
  type        = string
  default     = "80Gi"
}

variable "master_ip_prefix" {
  description = "IP prefix voor master nodes"
  type        = string
}

variable "worker_ip_prefix" {
  description = "IP prefix voor worker nodes"
  type        = string
}

variable "netmask" {
  description = "Netmask voor het netwerk (bijv. 255.255.255.0 of 24)"
  type        = string
  default     = "24"
}

variable "gateway" {
  description = "Default gateway voor de VMs"
  type        = string
}

variable "nameserver" {
  description = "DNS server voor de VMs"
  type        = string
}

variable "control_plane_vip" {
  description = "Virtual IP voor de control plane (optioneel)"
  type        = string
  default     = ""
}

variable "ubuntu_image_url" {
  description = "URL naar de Ubuntu cloud image"
  type        = string
  default     = "https://cloud-images.ubuntu.com/releases/22.04/release/ubuntu-22.04-server-cloudimg-amd64.img"
}

variable "ubuntu_image_name" {
  description = "Naam van de Ubuntu image in Harvester"
  type        = string
  default     = "ubuntu-22.04"
}

variable "ubuntu_image_namespace" {
  description = "Namespace waar de Ubuntu image is opgeslagen in Harvester"
  type        = string
  default     = null # Maakt gebruik van de algemene namespace variabele
}

variable "rke2_token" {
  description = "Token voor RKE2 node joining"
  type        = string
  default     = "myveryverystrongpassword"
}

variable "ssh_public_key" {
  description = "SSH public key voor toegang tot de nodes"
  type        = string
}

variable "ssh_username" {
  description = "SSH gebruikersnaam voor toegang tot de nodes"
  type        = string
  default     = "ubuntu"
} 