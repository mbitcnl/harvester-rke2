# Harvester RKE2 Deployment

Deze codebase bevat Terraform/Tofu configuraties voor het automatisch uitrollen van een RKE2 Kubernetes cluster op Harvester, inclusief Rancher management.

## Architectuur

De stack bestaat uit de volgende componenten:

- **RKE2 Kubernetes Cluster** - Kubernetes cluster op Harvester VMs
- **Kube-VIP** - Control plane met een Virtual IP (VIP)
- **Rancher** - Voor Kubernetes cluster management


## Vereisten

- Harvester Hyperconverged Infrastructure platform
- `tofu` (OpenTofu) of `terraform` commando-regel tool
- `kubectl` commando-regel tool
- Een domein met DNS recordbeheer
- SSH public key voor authenticatie


## Belangrijke Technische Details

### RKE2 Token

De configuratie maakt gebruik van een twee-staps proces voor het token:
1. Een basis token wordt ingesteld in `terraform.tfvars`
2. Na het opzetten van de eerste master node wordt het volledige token (met CA hash) opgehaald
3. Worker nodes gebruiken automatisch deze token voor veilige authenticatie

### Versie Compatibiliteit

De worker nodes worden ingesteld om exact dezelfde RKE2 versie te gebruiken als de master nodes (v1.26.11+rke2r1). Als je een andere versie wilt gebruiken, pas dan het volgende aan:
- `cloud-init-worker.yaml.tftpl`: Wijzig de `INSTALL_RKE2_VERSION` parameter
- `cloud-init-master.yaml.tftpl`: Wijzig indien nodig de RKE2 versie voor master nodes


## Aan de slag

1. **Clone de repository**

   ```bash
   git clone https://github.com/mbitcnl/harvester-rke2.git
   cd harvester-rke2
   ```

2. **Configuratie aanpassen**

   - Maak `terraform.tfvars` aan op basis van `terraform.tfvars.example`
   - Maak `rancher/terraform.tfvars` aan op basis van `rancher/terraform.tfvars.example`
   - Maak `traefik/terraform.tfvars` aan op basis van `traefik/terraform.tfvars.example`

3. **Volledige deployment uitvoeren**

   ```bash
   ./deploy.sh
   ```

   Het script voert de volgende stappen automatisch uit:
   - Harvester VMs aanmaken
   - RKE2 Kubernetes cluster installeren
   - Kubeconfig ophalen en configureren
   - Rancher management platform installeren
   - Traefik en cert-manager met Let's Encrypt configureren

## Stapsgewijze uitrol (handmatig)

Als je de stappen liever handmatig uitvoert:

### 1. RKE2 Cluster uitrollen

```bash
cd harvester-rke2
tofu init
tofu plan -out=tfplan
tofu apply tfplan
```

### 2. Kubeconfig ophalen

```bash
ssh ubuntu@[MASTER_IP] "sudo cat /etc/rancher/rke2/rke2.yaml" > rke2.yaml
# Bewerk rke2.yaml om 127.0.0.1 te vervangen door het VIP adres
```

### 3. Rancher installeren

```bash
cd rancher
tofu init
tofu plan -out=tfplan-rancher
tofu apply tfplan-rancher
```

### 4. Traefik en Cert-Manager installeren

```bash
cd traefik
tofu init
tofu plan -out=tfplan-traefik
tofu apply tfplan-traefik
```

## Toegang tot de omgeving

Na de installatie zijn de volgende URL's beschikbaar:

- **Rancher dashboard**: `https://rancher.example.com`
- **Traefik dashboard**: `https://traefik.example.com` (met BasicAuth beveiliging)

## Onderhoud

### Cluster status controleren

```bash
export KUBECONFIG=rke2.yaml  # of rke2-direct.yaml voor directe toegang
kubectl get nodes -o wide
```

### Certificaten controleren

```bash
kubectl get certificates -A
```

### Kubernetes dashboard

Toegang tot het dashboard is mogelijk via Rancher of direct via kubectl-proxy.

## Beveiliging

- De bootstrap admin credentials voor Rancher moeten direct na de eerste login worden gewijzigd
- SSH sleutels voor VM toegang moeten veilig worden bewaard
- API credentials (zoals OVH) moeten veilig worden opgeslagen en niet worden ingecheckt in de repository

## Problemen oplossen

### Kubernetes API niet bereikbaar

Controleer of kube-vip correct draait en het VIP adres bereikbaar is:

```bash
ssh ubuntu@[MASTER_IP] "sudo crictl ps | grep kube-vip"
ping [VIP_ADDRESS]
```

### Worker nodes registreren niet of zijn Unavailable

1. **Token probleem**: Controleer of het juiste token wordt gebruikt met de CA hash
   ```bash
   ssh ubuntu@[WORKER_IP] "sudo cat /etc/rancher/rke2/config.yaml"
   ```
   
2. **Verkeerde RKE2 versie**: Controleer of de workers dezelfde versie gebruiken als de masters
   ```bash
   ssh ubuntu@[WORKER_IP] "sudo /usr/local/bin/rke2 --version"
   ```

3. **Kernel modules**: Controleer of de vereiste kernel modules zijn geladen
   ```bash
   ssh ubuntu@[WORKER_IP] "lsmod | grep -E 'br_netfilter|overlay'"
   ssh ubuntu@[WORKER_IP] "sysctl -a | grep -E 'bridge-nf-call-iptables|ip_forward'"
   ```

4. **Netwerkproblemen**: Controleer of de worker nodes kunnen verbinden met de control plane
   ```bash
   ssh ubuntu@[WORKER_IP] "curl -k https://[VIP_ADDRESS]:9345"
   ```

### Canal CNI problemen (flexvol-driver of install-cni initialisatie problemen)

Als pods met de status "Init:CreateContainerConfigError" worden weergegeven:

1. Controleer de pod status:
   ```bash
   kubectl -n kube-system get pods | grep canal
   kubectl -n kube-system describe pod [canal-pod-naam]
   ```

2. Controleer de worker node logs:
   ```bash
   ssh ubuntu@[WORKER_IP] "sudo journalctl -fu rke2-agent"
   ```

3. Herstart de rke2-agent service na het oplossen van problemen:
   ```bash
   ssh ubuntu@[WORKER_IP] "sudo systemctl restart rke2-agent"
   ```

### Certificaat uitgifte mislukt

Check de cert-manager logs:

```bash
kubectl logs -n cert-manager -l app=cert-manager
```

### Rancher UI niet bereikbaar

Controleer of de ingress correct is geconfigureerd:

```bash
kubectl get ingress -n cattle-system
kubectl describe ingress -n cattle-system
```

## Bijdragen

Pull requests zijn welkom. Voor grote wijzigingen, open eerst een issue om te bespreken wat je wilt veranderen.

## Licentie

[MIT](https://choosealicense.com/licenses/mit/) 