terraform {
  required_providers {
    harvester = {
      source  = "harvester/harvester"
      version = "0.6.6"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "2.23.0"
    }
  }
}

locals {
  operation_timeout = "10m"
  
  # Gebruik de talos_image_namespace indien opgegeven, anders de algemene namespace
  image_namespace = var.ubuntu_image_namespace != null ? var.ubuntu_image_namespace : var.namespace
  
  # Network data voor master nodes
  master_network_config = [
    for i in range(var.master_count) : templatefile("${path.module}/network-config.yaml.tftpl", {
      ip_address   = "${var.master_ip_prefix}${i + 101}"
      netmask      = var.netmask
      gateway      = var.gateway
      dns_server   = var.nameserver
      interface    = var.network_interface
    })
  ]
  
  # Network data voor worker nodes
  worker_network_config = [
    for i in range(var.worker_count) : templatefile("${path.module}/network-config.yaml.tftpl", {
      ip_address   = "${var.worker_ip_prefix}${i + 201}"
      netmask      = var.netmask
      gateway      = var.gateway
      dns_server   = var.nameserver
      interface    = var.network_interface
    })
  ]
  
  master_node_cloud_init = [
    for i in range(var.master_count) : templatefile("${path.module}/cloud-init-master.yaml.tftpl", {
      hostname     = "rke2-master-${i}"
      ip_address   = "${var.master_ip_prefix}${i + 101}" 
      netmask      = var.netmask
      gateway      = var.gateway
      dns_server   = var.nameserver
      rke2_token   = var.rke2_token
      server_url   = var.control_plane_vip != "" ? "https://${var.control_plane_vip}:9345" : ""
      is_first     = i == 0 ? true : false
      vip          = var.control_plane_vip
      vip_interface = var.network_interface
      ssh_public_key = var.ssh_public_key
    })
  ]
  
  # Ophalen van het volledige node-token met CA hash
  # Dit wordt uitgevoerd nadat de eerste master node is aangemaakt
  get_full_token = {
    master_id = harvester_virtualmachine.master[0].id
  }
  
  # Lezen van het volledige token bestand (gebruikt door worker nodes)
  node_token = {
    depends_on = [null_resource.get_full_token]
    filename   = "${path.module}/node-token.txt"
  }
  
  # Gebruik het volledige token als het beschikbaar is, anders gebruik de basis token
  full_token = fileexists("${path.module}/node-token.txt") ? trimspace(file("${path.module}/node-token.txt")) : var.rke2_token
  
  worker_node_cloud_init = [
    for i in range(var.worker_count) : templatefile("${path.module}/cloud-init-worker.yaml.tftpl", {
      hostname     = "rke2-worker-${i}"
      ip_address   = "${var.worker_ip_prefix}${i + 201}"
      netmask      = var.netmask 
      gateway      = var.gateway
      dns_server   = var.nameserver
      rke2_token   = data.local_file.node_token.content
      server_url   = var.control_plane_vip != "" ? "https://${var.control_plane_vip}:9345" : "https://${var.master_ip_prefix}101:9345"
      ssh_public_key = var.ssh_public_key
      vip_interface = var.network_interface
    })
  ]
}

provider "harvester" {
  kubeconfig = var.harvester_kubeconfig_path
}

provider "kubernetes" {
  config_path = var.harvester_kubeconfig_path
}

# Maak Kubernetes secrets voor de cloud-init configuratie
resource "kubernetes_secret" "master_cloud_init" {
  count = var.master_count
  
  metadata {
    name      = "rke2-master-${count.index}"
    namespace = var.namespace
  }

  data = {
    "userdata" = local.master_node_cloud_init[count.index]
    "networkdata" = local.master_network_config[count.index]
  }
}

resource "kubernetes_secret" "worker_cloud_init" {
  count = var.worker_count
  
  metadata {
    name      = "rke2-worker-${count.index}"
    namespace = var.namespace
  }

  data = {
    "userdata" = local.worker_node_cloud_init[count.index]
    "networkdata" = local.worker_network_config[count.index]
  }
}

# Maak een image van de Ubuntu Cloud Image
resource "harvester_image" "ubuntu" {
  name         = var.ubuntu_image_name
  namespace    = local.image_namespace
  display_name = "Ubuntu 22.04 LTS"
  source_type  = "download"
  url          = var.ubuntu_image_url
  
  lifecycle {
    ignore_changes = [
      storage_class_name
    ]
  }
}

# Maak Master nodes
resource "harvester_virtualmachine" "master" {
  count = var.master_count

  name                 = "rke2-master-${count.index}"
  namespace            = var.namespace
  description          = "RKE2 Control Plane Node ${count.index}"
  restart_after_update = true

  tags = {
    role = "master"
  }

  cpu    = var.master_cpu
  memory = "${var.master_memory}Mi"

  run_strategy = "RerunOnFailure"
  hostname     = "rke2-master-${count.index}"

  network_interface {
    name           = "default"
    model          = "virtio"
    network_name   = "${var.namespace}/${var.network_name}"
    wait_for_lease = false
  }

  disk {
    name       = "rootdisk"
    type       = "disk"
    size       = var.master_disk_size
    bus        = "virtio"
    boot_order = 1

    image       = harvester_image.ubuntu.id
    auto_delete = true
  }

  cloudinit {
    user_data_secret_name = kubernetes_secret.master_cloud_init[count.index].metadata[0].name
  }
  
  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      network_interface,
      run_strategy,
      disk
    ]
  }
}

# Ophalen van het volledige node-token met CA hash
# Dit wordt uitgevoerd nadat de eerste master node is aangemaakt
resource "null_resource" "get_full_token" {
  depends_on = [harvester_virtualmachine.master]
  
  triggers = {
    master_id = harvester_virtualmachine.master[0].id
  }
  
  # Deze provisioner voert een script uit dat wacht tot de master node beschikbaar is,
  # vervolgens het volledige token (inclusief CA hash) ophaalt via SSH.
  provisioner "local-exec" {
    command = <<-EOT
      # Wacht tot SSH beschikbaar is op master
      echo "Wachten tot master node SSH beschikbaar is..."
      until ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${var.ssh_username}@${var.master_ip_prefix}101 'exit' >/dev/null 2>&1; do 
        echo -n "."
        sleep 10
      done
      echo "Master node is bereikbaar via SSH."
      
      # Wacht tot RKE2 server draait en token bestand beschikbaar is
      echo "Wachten tot RKE2 token beschikbaar is..."
      attempts=0
      while ! ssh -o StrictHostKeyChecking=no ${var.ssh_username}@${var.master_ip_prefix}101 'sudo test -f /var/lib/rancher/rke2/server/node-token' >/dev/null 2>&1; do
        echo -n "."
        sleep 10
        attempts=$((attempts+1))
        if [ $attempts -gt 30 ]; then
          echo "Timeout wachten op token bestand."
          exit 1
        fi
      done
      echo "RKE2 server is gestart en token is beschikbaar."
      
      # Haal token op en sla op als bestand
      echo "Node token ophalen..."
      ssh -o StrictHostKeyChecking=no ${var.ssh_username}@${var.master_ip_prefix}101 'sudo cat /var/lib/rancher/rke2/server/node-token' > ${path.module}/node-token.txt
      
      # Controleer of token is opgehaald
      if [ ! -s ${path.module}/node-token.txt ]; then
        echo "Fout: Token bestand is leeg of bestaat niet."
        exit 1
      else
        echo "Token succesvol opgehaald en opgeslagen in node-token.txt"
      fi
    EOT
  }
}

# Lees het volledige token bestand in voor gebruik in worker nodes
data "local_file" "node_token" {
  depends_on = [null_resource.get_full_token]
  filename   = "${path.module}/node-token.txt"
}

# Maak Worker nodes
resource "harvester_virtualmachine" "worker" {
  count = var.worker_count
  depends_on = [data.local_file.node_token]

  name                 = "rke2-worker-${count.index}"
  namespace            = var.namespace
  description          = "RKE2 Worker Node ${count.index}"
  restart_after_update = true

  tags = {
    role = "worker"
  }

  cpu    = var.worker_cpu
  memory = "${var.worker_memory}Mi"

  run_strategy = "RerunOnFailure"
  hostname     = "rke2-worker-${count.index}"

  network_interface {
    name           = "default"
    model          = "virtio"
    network_name   = "${var.namespace}/${var.network_name}"
    wait_for_lease = false
  }

  disk {
    name       = "rootdisk"
    type       = "disk"
    size       = var.worker_disk_size
    bus        = "virtio"
    boot_order = 1

    image       = harvester_image.ubuntu.id
    auto_delete = true
  }

  cloudinit {
    user_data_secret_name = kubernetes_secret.worker_cloud_init[count.index].metadata[0].name
  }
  
  lifecycle {
    create_before_destroy = true
    ignore_changes = [
      network_interface,
      run_strategy,
      disk
    ]
  }
}

# Output om de kubeconfig pad op te halen na het inrichten
resource "null_resource" "get_kubeconfig" {
  depends_on = [harvester_virtualmachine.master]

  # Dit script zal pas na de deployment kunnen worden uitgevoerd
  provisioner "local-exec" {
    command = <<-EOT
      echo "==== RKE2 Cluster Informatie ===="
      echo "Om verbinding te maken met uw RKE2 cluster:"
      echo "1. Maak SSH verbinding met de eerste master node: ssh ${var.ssh_username}@${var.master_ip_prefix}101"
      echo "2. De kubeconfig bevindt zich op: /etc/rancher/rke2/rke2.yaml"
      echo "3. Wijzig 127.0.0.1 in het IP ${var.master_ip_prefix}101 in het bestand om externe toegang te krijgen"
      echo "4. Rancher kan worden geïnstalleerd met: curl -sfL https://get.rancher.io | sh -"
      echo "==== Cluster Endpoints ===="
      echo "Kubernetes API: https://${var.control_plane_vip != "" ? var.control_plane_vip : "${var.master_ip_prefix}101"}:6443"
      echo "RKE2 Join URL: https://${var.control_plane_vip != "" ? var.control_plane_vip : "${var.master_ip_prefix}101"}:9345"
    EOT
  }
}

# Outputs voor toegang tot het cluster
output "master_ips" {
  value = [for i in range(var.master_count) : "${var.master_ip_prefix}${i + 101}"]
  description = "IP adressen van de master nodes"
}

output "worker_ips" {
  value = [for i in range(var.worker_count) : "${var.worker_ip_prefix}${i + 201}"]
  description = "IP adressen van de worker nodes"
}

output "api_endpoint" {
  value = "https://${var.control_plane_vip != "" ? var.control_plane_vip : "${var.master_ip_prefix}101"}:6443"
  description = "Kubernetes API endpoint"
}

output "join_url" {
  value = "https://${var.control_plane_vip != "" ? var.control_plane_vip : "${var.master_ip_prefix}101"}:9345"
  description = "RKE2 Join URL voor extra nodes"
} 