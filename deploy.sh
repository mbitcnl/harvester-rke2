#!/bin/bash
set -e

# Automatisatie script voor RKE2 cluster en Rancher
# Dit script orchestreert het proces van:
# 1. RKE2 Cluster deployment op Harvester
# 2. Kubeconfig ophalen en configureren
# 3. Rancher installeren met Helm

echo "==== RKE2 Cluster & Rancher Deployment Automatisatie ===="
echo

# SSH-agent setup om passphrase maar één keer in te voeren
setup_ssh_agent() {
  local keyfile="$1"
  
  # Controleer of het keyfile bestaat
  if [ ! -f "$keyfile" ]; then
    echo "FOUT: SSH key niet gevonden op $keyfile"
    return 1
  fi
  
  # Start ssh-agent als die nog niet draait
  if [ -z "$SSH_AUTH_SOCK" ]; then
    echo "SSH agent starten..."
    eval $(ssh-agent -s)
    echo "SSH agent gestart met pid $SSH_AGENT_PID"
  else
    echo "Bestaande SSH agent gebruikt (pid: $(echo $SSH_AUTH_SOCK | cut -d. -f2))"
  fi
  
  # Voeg de sleutel toe (interactief)
  echo "SSH key toevoegen aan ssh-agent (voer je passphrase in als gevraagd)..."
  echo "Na deze stap hoef je de passphrase niet meer in te voeren tijdens dit script."
  ssh-add "$keyfile"
  
  # Controleer of het is gelukt
  if ssh-add -l | grep -q "$(ssh-keygen -l -f "$keyfile" | awk '{print $2}')" 2>/dev/null; then
    echo "SSH key succesvol toegevoegd aan ssh-agent."
    return 0
  else
    echo "WAARSCHUWING: SSH key lijkt niet toegevoegd aan ssh-agent. Passphrase kan later opnieuw gevraagd worden."
    return 1
  fi
}

# Configuratie variabelen uit hoofd tfvars halen (aanname dat ze daar staan)
cd "$(dirname "${BASH_SOURCE[0]}")"
CONFIG_FILE="terraform.tfvars"

if [ ! -f "$CONFIG_FILE" ]; then
    echo "Fout: Hoofd configuratiebestand terraform.tfvars niet gevonden in $(pwd)" >&2
    exit 1
fi

# Helper functie om variabele uit tfvars te lezen
get_tfvar() {
    local var_name="$1"
    local value=$(grep "^${var_name}[ ]*=" "$CONFIG_FILE" | cut -d '=' -f2- | cut -d '#' -f1 | tr -d '"' | xargs)
    if [ -z "$value" ]; then
        echo "Fout: Variabele '$var_name' niet gevonden of leeg in $CONFIG_FILE" >&2
        return 1
    fi
    echo "$value"
}

# Dynamisch IPs samenstellen op basis van prefix en count
get_master_ips() {
    local prefix=$(get_tfvar "master_ip_prefix" | cut -d '#' -f1 | xargs)  # Verwijder eventuele commentaren
    local count=$(get_tfvar "master_count")
    local ips=""
    for i in $(seq 1 $count); do
        ips="${ips}${prefix}$((100+i)) "
    done
    echo $ips
}

get_worker_ips() {
    local prefix=$(get_tfvar "worker_ip_prefix" | cut -d '#' -f1 | xargs)  # Verwijder eventuele commentaren
    local count=$(get_tfvar "worker_count")
    local ips=""
    for i in $(seq 1 $count); do
        ips="${ips}${prefix}$((200+i)) "
    done
    echo $ips
}

# Lees benodigde variabelen
MASTER_IPS=$(get_master_ips)
MASTER_IP=$(echo "$MASTER_IPS" | cut -d ' ' -f1) # Neem de eerste master IP
WORKER_IPS=$(get_worker_ips)
WORKER_IP=$(echo "$WORKER_IPS" | cut -d ' ' -f1) # Neem de eerste worker IP
VIP_ADDRESS=$(get_tfvar "control_plane_vip") || VIP_ADDRESS=""
SSH_USER=$(get_tfvar "ssh_username") || exit 1
SSH_KEY_PATH="~/.ssh/hvs_piv"  # Hard-coded pad naar SSH key

SSH_KEY=$(eval echo $SSH_KEY_PATH) # Expand ~ if present

echo "Gelezen configuratie:"
echo "  Master IPs:       $MASTER_IPS"
echo "  Worker IPs:       $WORKER_IPS"
echo "  API VIP:          $VIP_ADDRESS"
echo "  SSH User:         $SSH_USER"
echo "  SSH Key:          $SSH_KEY"
echo

# SSH-agent instellen om passphrase maar één keer in te voeren
setup_ssh_agent "$SSH_KEY"

# Functie om SSH verbinding te testen
function test_ssh_connection {
  local host="$1"
  echo "Testing SSH verbinding met $SSH_USER@$host..."
  
  # Controleer eerst of de host pingbaar is
  if ! ping -c 1 -W 1 "$host" &> /dev/null; then
    echo "Host $host is niet bereikbaar via ping. SSH verbinding niet mogelijk."
    return 1
  fi
  
  # Controleer of SSH key bestaat
  if [ ! -f "$SSH_KEY" ]; then
    echo "SSH key niet gevonden op $SSH_KEY."
    return 1
  fi
  
  # Vereenvoudigde SSH test (gebruikt ssh-agent)
  echo "SSH verbinding testen..."
  if ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no "$SSH_USER@$host" "echo SSH_CONNECTION_SUCCESSFUL" 2>/dev/null | grep -q "SSH_CONNECTION_SUCCESSFUL"; then
    echo "SSH verbinding succesvol!"
    return 0
  else
    echo "SSH verbinding mislukt. Controleer je SSH sleutel en toegang tot de remote server."
    return 1
  fi
}

# Test SSH verbinding voor de master voordat we verder gaan
if ping -c 1 -W 1 "$MASTER_IP" &> /dev/null; then
  echo "Master node is bereikbaar via ping, SSH verbinding testen..."
  if ! test_ssh_connection "$MASTER_IP"; then
    echo "Kan geen SSH verbinding maken met $SSH_USER@$MASTER_IP. Script wordt afgebroken."
    exit 1
  fi
else
  echo "Master node ($MASTER_IP) is nog niet bereikbaar via ping. SSH test wordt overgeslagen."
  echo "We gaan ervan uit dat de VMs nog aangemaakt moeten worden."
fi

# Controleer of de nodes al bestaan
echo "Controleren of de VMs al bestaan..."
MASTER_EXISTS=false
WORKER_EXISTS=false

if ping -c 1 -W 1 "$MASTER_IP" &> /dev/null; then
  echo "Master node is al bereikbaar op $MASTER_IP."
  MASTER_EXISTS=true
else
  echo "Master node is nog niet bereikbaar."
fi

if ping -c 1 -W 1 "$WORKER_IP" &> /dev/null; then
  echo "Worker node is al bereikbaar op $WORKER_IP."
  WORKER_EXISTS=true
else
  echo "Worker node is nog niet bereikbaar."
fi

# Bepaal wat we moeten deployen
FULL_DEPLOYMENT=false
WORKERS_ONLY=false

if [ "$MASTER_EXISTS" = false ] && [ "$WORKER_EXISTS" = false ]; then
  echo "Volgens de ping-test bestaan de nodes nog niet."
  read -p "Wil je toch de deployment stap overslaan (handig als je weet dat de VMs al bestaan maar niet pingbaar zijn)? (j/n): " skip_deployment
  if [[ $skip_deployment == "j" ]]; then
    echo "VM deployment stap wordt overgeslagen op verzoek van de gebruiker."
    # Ga door naar de volgende stap
  else
    echo "Volledige deployment nodig."
    FULL_DEPLOYMENT=true
  fi
elif [ "$MASTER_EXISTS" = true ] && [ "$WORKER_EXISTS" = false ]; then
  echo "Master node bestaat, maar worker nodes niet. Alleen worker nodes deployen."
  WORKERS_ONLY=true
elif [ "$MASTER_EXISTS" = false ] && [ "$WORKER_EXISTS" = true ]; then
  echo "Onverwachte situatie: worker nodes bestaan, maar master node niet. Volledige deployment nodig."
  FULL_DEPLOYMENT=true
else
  echo "Zowel master als worker nodes bestaan al. VM deployment stap wordt overgeslagen."
fi

# Stap 1: Deploy RKE2 cluster
if [ "$FULL_DEPLOYMENT" = true ]; then
  echo "Stap 1: Volledig RKE2 Cluster deployen op Harvester..."
  cd "$(dirname "$0")"
  tofu init
  tofu plan -out=tfplan
  tofu apply tfplan

  # Wacht tot de nodes beschikbaar zijn
  echo
  echo "Wachten tot de VMs zijn opgestart en bereikbaar zijn..."
  
  # Voeg een functie toe om de ping-check te doen met retry optie
  ping_until_available() {
    local host="$1"
    local max_attempts="$2"
    local wait_time="$3"
    local attempt=1
    
    while [ $attempt -le $max_attempts ]; do
      if ping -c 1 -W 1 "$host" &> /dev/null; then
        echo "Host $host is bereikbaar! Doorgaan met volgende stap."
        return 0
      fi
      echo -n "."
      sleep $wait_time
      attempt=$((attempt+1))
    done
    
    echo
    echo "Timeout bij wachten op bereikbaarheid van $host na $max_attempts pogingen."
    echo "VM kan nog aan het opstarten zijn, of er is een netwerkprobleem."
    
    # Vraag de gebruiker wat te doen
    while true; do
      read -p "Wil je opnieuw proberen (j), doorgaan met het script (d), of afbreken (a)? " choice
      case "$choice" in
        j|J) echo "Opnieuw proberen..."; return 2 ;;
        d|D) echo "Doorgaan zonder bereikbare VMs..."; return 1 ;;
        a|A) echo "Script wordt afgebroken."; exit 1 ;;
        *) echo "Ongeldige keuze, probeer opnieuw." ;;
      esac
    done
  }
  
  # Blijf proberen tot de gebruiker besluit te stoppen
  while true; do
    # Roep de functie direct aan (niet via command substitution)
    ping_until_available "$MASTER_IP" 60 5
    ping_status=$?
    
    if [ $ping_status -eq 0 ]; then
      # VM is bereikbaar, doorgaan
      break
    elif [ $ping_status -eq 1 ]; then
      # Gebruiker kiest om door te gaan zonder bereikbare VM
      echo "Doorgaan zonder wachten op bereikbare VMs. Latere stappen kunnen falen."
      break
    fi
    # Als ping_status 2 is, proberen we opnieuw (blijven in de loop)
    echo "Opnieuw proberen ping check..."
  done
  
  # Wacht extra tijd voor de VM om volledig op te starten
  echo "Wachten tot de VM volledig is opgestart..."
  sleep 30
  
  # Test SSH verbinding opnieuw na het starten van de VMs
  echo "SSH verbinding testen naar de nieuwe VMs..."
  max_retries=5
  retry_count=0
  ssh_successful=false
  
  while [ $retry_count -lt $max_retries ] && [ "$ssh_successful" = false ]; do
    if test_ssh_connection "$MASTER_IP"; then
      ssh_successful=true
      echo "SSH verbinding succesvol!"
    else
      retry_count=$((retry_count+1))
      echo "SSH verbinding mislukt. Poging $retry_count/$max_retries. Opnieuw proberen over 15 seconden..."
      sleep 15
    fi
  done
  
  if [ "$ssh_successful" = false ]; then
    echo "Kan geen SSH verbinding maken met nieuwe VMs na meerdere pogingen."
    echo "Dit kan normaal zijn als de VMs nog aan het opstarten zijn."
    echo "Het script gaat door, maar latere stappen kunnen mislukken als SSH niet werkt."
    echo "Je kunt het script later opnieuw uitvoeren als de VMs volledig zijn opgestart."
  fi
elif [ "$WORKERS_ONLY" = true ]; then
  echo "Stap 1: Alleen worker nodes deployen op Harvester..."
  cd "$(dirname "$0")"
  tofu init
  
  # Alleen de worker VM resource targeten
  echo "Planning en deploying van alleen worker nodes..."
  tofu plan -target=harvester_virtualmachine.worker -out=tfplan-workers
  tofu apply tfplan-workers

  # Wacht tot de worker nodes beschikbaar zijn
  echo
  echo "Wachten tot de worker VMs zijn opgestart en bereikbaar zijn..."
  
  # Gebruik dezelfde functie voor worker nodes
  while true; do
    # Roep de functie direct aan (niet via command substitution)
    ping_until_available "$WORKER_IP" 60 5
    ping_status=$?
    
    if [ $ping_status -eq 0 ]; then
      # VM is bereikbaar, doorgaan
      break
    elif [ $ping_status -eq 1 ]; then
      # Gebruiker kiest om door te gaan zonder bereikbare VM
      echo "Doorgaan zonder wachten op bereikbare worker VMs. Latere stappen kunnen falen."
      break
    fi
    # Als ping_status 2 is, proberen we opnieuw (blijven in de loop)
    echo "Opnieuw proberen ping check voor worker..."
  done
else
  echo "Stap 1: Deployment overgeslagen omdat alle VMs al bestaan."
fi

# Wacht tot de RKE2 services zijn opgestart als we nodes hebben gedeployed
if [ "$FULL_DEPLOYMENT" = true ] || [ "$WORKERS_ONLY" = true ]; then
  echo "Wachten tot de RKE2 services zijn gestart (dit kan enkele minuten duren)..."
  sleep 60
fi

# Stap 2: Haal kubeconfig op
echo
echo "Stap 2: Kubeconfig ophalen en configureren..."

# Haal de kubeconfig op via SSH
echo "Kubeconfig ophalen van master node..."
echo "Uitvoeren: ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no \"$SSH_USER@$MASTER_IP\" \"sudo cat /etc/rancher/rke2/rke2.yaml\""

# We proberen maximaal 5 keer om de kubeconfig op te halen
max_retries=5
retry_count=0
kubeconfig_success=false

while [ $retry_count -lt $max_retries ] && [ "$kubeconfig_success" = false ]; do
  ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no "$SSH_USER@$MASTER_IP" "sudo cat /etc/rancher/rke2/rke2.yaml" > rke2.yaml 2>/dev/null
  
  if [ $? -eq 0 ] && [ -s rke2.yaml ]; then
    kubeconfig_success=true
    echo "Kubeconfig succesvol opgehaald!"
  else
    rm -f rke2.yaml 2>/dev/null
    retry_count=$((retry_count+1))
    if [ $retry_count -lt $max_retries ]; then
      echo "Poging $retry_count/$max_retries mislukt. Opnieuw proberen over 30 seconden..."
      sleep 30
    fi
  fi
done

if [ "$kubeconfig_success" = false ]; then
  echo "Kon kubeconfig niet ophalen na meerdere pogingen."
  echo "Dit kan normaal zijn als RKE2 nog aan het installeren is."
  
  # Vraag de gebruiker wat te doen
  while true; do
    read -p "Wil je opnieuw proberen (j), doorgaan zonder kubeconfig (d), of afbreken (a)? " choice
    case "$choice" in
      j|J) 
        echo "Opnieuw proberen om kubeconfig op te halen..."
        retry_count=0
        while [ $retry_count -lt 5 ] && [ "$kubeconfig_success" = false ]; do
          echo "Poging $((retry_count+1))/5..."
          ssh -o ConnectTimeout=15 -o StrictHostKeyChecking=no "$SSH_USER@$MASTER_IP" "sudo cat /etc/rancher/rke2/rke2.yaml" > rke2.yaml 2>/dev/null
          
          if [ $? -eq 0 ] && [ -s rke2.yaml ]; then
            kubeconfig_success=true
            echo "Kubeconfig succesvol opgehaald!"
            break
          else
            rm -f rke2.yaml 2>/dev/null
            retry_count=$((retry_count+1))
            [ $retry_count -lt 5 ] && sleep 30
          fi
        done
        
        if [ "$kubeconfig_success" = true ]; then
          break # Uit de keuzeloop gaan als we succes hebben
        else
          echo "Kon kubeconfig nog steeds niet ophalen."
          # Blijf in de keuzeloop om opnieuw te vragen
        fi
        ;;
      d|D) 
        echo "Doorgaan zonder kubeconfig. Verdere stappen die kubeconfig nodig hebben zullen falen."
        echo "Je kunt later handmatig het kubeconfig bestand ophalen met:"
        echo "  ssh $SSH_USER@$MASTER_IP \"sudo cat /etc/rancher/rke2/rke2.yaml\" > rke2.yaml"
        echo "  sed -i \"s/127.0.0.1/$VIP_ADDRESS/g\" rke2.yaml"
        exit 0
        ;;
      a|A) 
        echo "Script wordt afgebroken. Probeer het later opnieuw als de cluster volledig is opgestart."
        exit 1
        ;;
      *) echo "Ongeldige keuze, probeer opnieuw." ;;
    esac
  done
fi

# Vervang 127.0.0.1 door het VIP adres
echo "Kubeconfig aanpassen om VIP te gebruiken..."
sed -i "s/127.0.0.1/$VIP_ADDRESS/g" rke2.yaml

# Maak een directe versie van de kubeconfig voor onmiddellijke toegang
cp rke2.yaml rke2-direct.yaml
sed -i "s/$VIP_ADDRESS/$MASTER_IP/g" rke2-direct.yaml

# Controleer of kubectl geïnstalleerd is
if ! command -v kubectl &> /dev/null; then
  echo "kubectl is niet geïnstalleerd. Installeer kubectl eerst."
  echo "Bijvoorbeeld met: curl -LO https://dl.k8s.io/release/stable.txt && curl -LO \"https://dl.k8s.io/release/\$(cat stable.txt)/bin/linux/amd64/kubectl\" && chmod +x kubectl && sudo mv kubectl /usr/local/bin/"
  exit 1
fi

# Test de verbinding met de directe config
echo "Kubernetes cluster toegang testen met directe IP..."
export KUBECONFIG=$PWD/rke2-direct.yaml

# Wacht tot de API server bereikbaar is
echo "Wachten tot de Kubernetes API server reageert..."
max_attempts=30
attempt=1

while [ $attempt -le $max_attempts ]; do
  if kubectl get nodes &>/dev/null; then
    echo "Kubernetes API server is bereikbaar! Doorgaan met volgende stap."
    break
  fi
  echo -n "."
  sleep 10
  attempt=$((attempt+1))
  
  # Als we het maximale aantal pogingen hebben bereikt, vraag wat te doen
  if [ $attempt -gt $max_attempts ]; then
    echo
    echo "Timeout bij wachten op Kubernetes API server na $max_attempts pogingen."
    
    while true; do
      read -p "Wil je opnieuw proberen (j), handmatig controleren (h), of afbreken (a)? " choice
      case "$choice" in
        j|J) 
          echo "Opnieuw proberen..."
          attempt=1  # Reset de teller om opnieuw te beginnen
          break      # Uit de keuzeloop gaan
          ;;
        h|H) 
          echo "Je kunt handmatig controleren met:"
          echo "  export KUBECONFIG=$PWD/rke2-direct.yaml"
          echo "  kubectl get nodes"
          read -p "Wil je doorgaan met het script? (j/n): " continue_choice
          if [[ $continue_choice == "j" ]]; then
            echo "Doorgaan met het script..."
            break 2  # Uit beide loops breken
          else
            echo "Script wordt afgebroken."
            exit 1
          fi
          ;;
        a|A) 
          echo "Script wordt afgebroken."
          exit 1
          ;;
        *) echo "Ongeldige keuze, probeer opnieuw." ;;
      esac
    done
  fi
done

# Toon de cluster nodes
echo "Kubernetes cluster nodes:"
kubectl get nodes -o wide

# Controleer of Rancher al is geïnstalleerd
RANCHER_INSTALLED=false
if kubectl get namespace cattle-system &>/dev/null; then
  if kubectl get pods -n cattle-system | grep -q "rancher"; then
    echo "Rancher lijkt al geïnstalleerd te zijn in de cattle-system namespace."
    RANCHER_INSTALLED=true
  fi
fi

# Stap 3: Rancher installeren met Helm
echo
echo "Stap 3: Rancher installeren met Helm..."
if [ "$RANCHER_INSTALLED" = false ]; then
  if [ -d "rancher" ]; then
    cd rancher
    echo "Initialiseren en toepassen van Rancher configuratie..."
    tofu init
    if [ ! -f "terraform.tfvars" ]; then
        echo "Waarschuwing: rancher/terraform.tfvars niet gevonden, gebruik defaults."
    fi
    # Vraag of gebruiker door wil gaan met rancher installatie
    read -p "Wil je doorgaan met het installeren van Rancher? (j/n): " continue_rancher
    if [[ $continue_rancher == "j" ]]; then
        tofu apply -auto-approve
        if [ $? -ne 0 ]; then echo "Fout tijdens Rancher installatie (via Terraform)!"; exit 1; fi
        echo "Rancher installatie via Terraform voltooid."
    else
        echo "Rancher installatie overgeslagen op verzoek van de gebruiker."
    fi
    cd ..
  else
    echo "Map 'rancher' niet gevonden. Rancher installatie overgeslagen."
  fi
else
  echo "Rancher installatie overgeslagen omdat het al actief lijkt."
fi

echo
echo "==== Deployment Voltooid ===="
echo "Gebruik de directe kubeconfig voor clusterbeheer:"
echo "  export KUBECONFIG=$PWD/rke2-direct.yaml"
echo "  kubectl get nodes"
echo

# Bepaal waar Rancher bereikbaar zou moeten zijn
RANCHER_HOSTNAME=""
if [ -f "rancher/terraform.tfvars" ]; then
  RANCHER_HOSTNAME=$(grep "^rancher_hostname" rancher/terraform.tfvars | cut -d '=' -f2- | tr -d '"' | tr -d ' ')
fi

echo "Rancher zou bereikbaar moeten zijn op:"
echo "  https://${VIP_ADDRESS} (via het Kubernetes Control Plane VIP)"

if [ -n "$RANCHER_HOSTNAME" ]; then
  echo "  https://${RANCHER_HOSTNAME} (zodra DNS is ingesteld)"
fi

echo
echo "BELANGRIJK: Vergeet niet je firewall te configureren met een reverse proxy voor HTTPS en DNS in te stellen." 