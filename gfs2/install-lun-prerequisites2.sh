#!/bin/bash
# ============================================================================
# SCRIPT: install-lun-prerequisites.sh
# DESCRIÇÃO: Instalação de pré-requisitos para GFS2 Enterprise
#            + validação e auto-instalação de kernel com suporte a DLM
#            + criação de FS GFS2 e montagem automática
# VERSÃO: 2.4 - Correção de ordem de criação de recursos
# AUTOR: DevOps Team
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
# Cores para output
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
print_header() { echo -e "\n${BLUE}========================================================================${NC}\n${BLUE}$1${NC}\n${BLUE}========================================================================${NC}\n"; }
print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error()   { echo -e "${RED}❌ $1${NC}"; }
print_info()    { echo -e "${BLUE}ℹ️  $1${NC}"; }
error_exit()    { print_error "$1"; exit 1; }

# ----------------------------------------------------------------------------
# Variáveis do cluster e volume
readonly CLUSTER_NAME="cluster_gfs2"
readonly NODE1_IP="10.113.221.240"
readonly NODE2_IP="10.113.221.241"
readonly NODE1_NAME="srvmvm001a"
readonly NODE2_NAME="srvmvm001b"
readonly VG_NAME="vg_cluster"
readonly LV_NAME="lv_gfs2"
readonly MOUNT_POINT="/mnt/gfs2_volume"

# ----------------------------------------------------------------------------
# Detectar papel do nó
detect_node_role() {
  local ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "")
  [[ "$ip" == "$NODE1_IP" ]] && echo "primary" || ([[ "$ip" == "$NODE2_IP" ]] && echo "secondary" || echo "unknown")
}
get_current_hostname() { hostname -s; }

# ----------------------------------------------------------------------------
# 1) Verificações de pré-requisitos
check_prerequisites() {
  print_header "🔍 Verificando Pré-requisitos do Sistema"
  [[ $EUID -eq 0 ]] && print_warning "Executando como root; preferível usar sudo."
  local other_node=$( [[ "$(detect_node_role)" == "primary" ]] && echo "$NODE2_NAME" || echo "$NODE1_NAME" )
  ping -c2 "$other_node" &>/dev/null || { print_error "Sem conectividade com $other_node"; return 1; }
  print_success "Conectividade com $other_node OK"
  nslookup "$other_node" &>/dev/null || print_warning "DNS pode estar falhando"
  local avail=$(df / | tail -1 | awk '{print $4}')
  (( avail < 1000000 )) && print_warning "Espaço livre insuficiente: ${avail}KB"
  print_success "Pré-requisitos OK"
}

# ----------------------------------------------------------------------------
# 2) Garantir kernel com suporte a DLM
ensure_dlm_kernel_support() {
  print_header "🔍 Verificando suporte do kernel ao DLM"
  if sudo modprobe dlm &>/dev/null && lsmod | grep -q '^dlm'; then
    print_success "Módulo DLM disponível no kernel atual"
  else
    print_warning "Módulo DLM não encontrado; instalando kernel genérico e extras"
    sudo apt update -qq
    sudo apt install -y linux-generic linux-modules-extra-$(uname -r)
    print_success "Kernel genérico instalado; reinicie e execute o script novamente"
    exit 0
  fi
}

# ----------------------------------------------------------------------------
# 3) Validar módulo DLM carregável
check_dlm_module() {
  print_header "🧪 Validando módulo DLM"
  sudo modprobe dlm
  lsmod | grep -q '^dlm' || error_exit "Falha ao carregar dlm"
  print_success "Módulo DLM carregado"
}

# ----------------------------------------------------------------------------
# 4) Instalação de pacotes essenciais
install_packages() {
  print_header "📦 Instalando Pacotes Necessários"
  sudo apt update -qq
  local pkgs=(gfs2-utils corosync pacemaker pcs dlm-controld lvm2-lockd multipath-tools open-iscsi fence-agents resource-agents)
  for pkg in "${pkgs[@]}"; do
    if dpkg -l | grep -q "^ii  $pkg "; then
      print_success "$pkg já instalado"
    else
      print_info "Instalando $pkg..."
      sudo apt install -y "$pkg" &>/dev/null || error_exit "Falha ao instalar $pkg"
      print_success "$pkg instalado"
    fi
  done
  if ! sudo passwd -S hacluster 2>/dev/null | grep -q "P"; then
    echo 'hacluster:hacluster' | sudo chpasswd
    print_success "Senha do hacluster configurada"
  fi
  print_success "Todos pacotes instalados"
}

# ----------------------------------------------------------------------------
# 5) Configurar propriedades do cluster
configure_cluster_properties() {
  print_info "Configurando propriedades do cluster..."
  sudo pcs property set stonith-enabled=false && print_success "STONITH desabilitado"
  sudo pcs property set no-quorum-policy=ignore && print_success "Quorum=ignore"
  sudo pcs property set start-failure-is-fatal=false
  sudo pcs property set symmetric-cluster=true
  sudo pcs property set maintenance-mode=false
  sudo pcs property set enable-startup-probes=true
}

# ----------------------------------------------------------------------------
# 6) Configurar recursos DLM e lvmlockd
configure_cluster_resources() {
  print_info "Configurando recursos DLM e lvmlockd..."
  sleep 15
  
  # Criar recurso DLM
  if ! sudo pcs resource show dlm-clone &>/dev/null; then
    print_info "Criando recurso DLM..."
    sudo pcs resource create dlm systemd:dlm op monitor interval=60s on-fail=fence clone interleave=true ordered=true
    print_success "Recurso DLM criado"
  else
    print_success "Recurso DLM já existe"
  fi
  
  # Criar recurso lvmlockd
  if ! sudo pcs resource show lvmlockd-clone &>/dev/null; then
    print_info "Criando recurso lvmlockd..."
    sudo pcs resource create lvmlockd systemd:lvmlockd op monitor interval=60s on-fail=fence clone interleave=true ordered=true
    print_success "Recurso lvmlockd criado"
    
    # Configurar dependências
    sudo pcs constraint order start dlm-clone then lvmlockd-clone
    sudo pcs constraint colocation add lvmlockd-clone with dlm-clone
    print_success "Dependências configuradas"
  else
    print_success "Recurso lvmlockd já existe"
  fi
  
  print_info "Aguardando recursos ficarem ativos (60s)..."
  sleep 60
}

# ----------------------------------------------------------------------------
# 7) Criar e iniciar o cluster
configure_enterprise_cluster() {
  print_header "🏢 Configurando Cluster Enterprise"
  local role=$(detect_node_role)
  [[ "$role" == "unknown" ]] && error_exit "Papel do nó desconhecido"
  
  if sudo pcs status &>/dev/null; then
    print_warning "Cluster já existe"
    sudo pcs status
    return 0
  fi
  
  if [[ "$role" == "primary" ]]; then
    print_info "Configurando como nó primário..."
    sudo systemctl enable --now pcsd
    
    print_info "Verificando pcsd no nó secundário..."
    ssh "$NODE2_NAME" "sudo systemctl enable --now pcsd" &>/dev/null && print_success "pcsd ativo em ambos nós"
    sleep 10
    
    print_info "Autenticando nós..."
    echo "hacluster" | sudo pcs host auth "$NODE1_NAME" "$NODE2_NAME" -u hacluster
    
    print_info "Criando cluster..."
    sudo pcs cluster setup "$CLUSTER_NAME" "$NODE1_NAME" addr="$NODE1_IP" "$NODE2_NAME" addr="$NODE2_IP"
    
    print_info "Iniciando cluster..."
    sudo pcs cluster enable --all
    sudo pcs cluster start --all
    sleep 30
    
    configure_cluster_properties
    configure_cluster_resources
    
    print_info "Status do cluster:"
    sudo pcs status
  else
    print_info "Aguardando configuração pelo nó primário..."
    local t=0
    until sudo pcs status &>/dev/null || ((t>=180)); do 
      echo "Aguardando... ${t}s"
      sleep 10
      ((t+=10))
    done
    sudo pcs status || error_exit "Cluster não detectado após timeout"
  fi
}

# ----------------------------------------------------------------------------
# 8) Detectar LUNs e configurar LVM cluster-aware
detect_available_devices() {
  print_header "💾 Detectando LUNs"
  local devices=() seen=()
  for p in /dev/mapper/* /dev/disk/by-id/wwn-* /dev/disk/by-path/*-lun-* /dev/sd[b-z]; do
    [[ -b $p ]] || continue
    local real=$(readlink -f "$p")
    [[ " ${seen[*]} " == *" $real "* ]] && continue
    seen+=("$real")
    [[ -n $(lsblk -dn -o MOUNTPOINT "$real" 2>/dev/null) ]] && continue
    pvs "$real" &>/dev/null && continue
    devices+=("$real")
    print_success "LUN candidato: $real"
  done
  [[ ${#devices[@]} -gt 0 ]] || error_exit "Nenhum LUN detectado"
  if [[ ${#devices[@]} -eq 1 ]]; then
    echo "${devices[0]}"
  else
    print_info "Selecione LUN (número):"
    local i=1
    for d in "${devices[@]}"; do echo "  $i) $d"; ((i++)); done
    read -rp "> " c
    [[ $c =~ ^[0-9]+$ && c -ge 1 && c -le ${#devices[@]} ]] || error_exit "Seleção inválida"
    echo "${devices[$c-1]}"
  fi
}

configure_lvm_cluster() {
  print_header "⚙️  Configurando LVM Cluster-aware"
  
  # Verificar se recursos existem primeiro
  if ! sudo pcs resource show dlm-clone &>/dev/null; then
    print_error "Recurso DLM não existe. Execute primeiro a configuração do cluster."
    return 1
  fi
  
  if ! sudo pcs resource show lvmlockd-clone &>/dev/null; then
    print_error "Recurso lvmlockd não existe. Execute primeiro a configuração do cluster."
    return 1
  fi
  
  # Aguardar DLM iniciar
  print_info "Aguardando DLM ficar ativo..."
  local max=60 t=0
  until sudo pcs status | grep -q "dlm.*Started" || ((t>=max)); do 
    echo -n "."
    sleep 2
    ((t+=2))
  done
  echo ""
  sudo pcs status | grep -q "dlm.*Started" || error_exit "DLM não iniciou após ${max}s"
  print_success "DLM ativo"
  
  # Aguardar lvmlockd iniciar
  print_info "Aguardando lvmlockd ficar ativo..."
  t=0
  until sudo pcs status | grep -q "lvmlockd.*Started" || ((t>=max)); do 
    echo -n "."
    sleep 2
    ((t+=2))
  done
  echo ""
  sudo pcs status | grep -q "lvmlockd.*Started" || error_exit "lvmlockd não iniciou após ${max}s"
  print_success "lvmlockd ativo"
  
  local dev=$(detect_available_devices)
  print_info "Usando device: $dev"
  
  # Configurar lvm.conf
  sudo sed -i '/use_lvmlockd/s/0/1/' /etc/lvm/lvm.conf || true
  
  if ! sudo vgs "$VG_NAME" &>/dev/null; then
    print_info "Criando Physical Volume..."
    sudo pvcreate -y "$dev"
    
    print_info "Criando Volume Group cluster-aware..."
    sudo vgcreate --shared --locktype dlm "$VG_NAME" "$dev"
    
    print_info "Iniciando locks..."
    sudo vgchange --lockstart "$VG_NAME"
    
    print_info "Criando Logical Volume..."
    sudo lvcreate -n "$LV_NAME" -l100%FREE "$VG_NAME"
  fi
  
  sudo vgchange -ay "$VG_NAME"
  print_success "LVM configurado: /dev/$VG_NAME/$LV_NAME"
}

# ----------------------------------------------------------------------------
# 9) Criar FS GFS2 e montar
create_and_mount_gfs2() {
  print_header "🗂️  Criando FS GFS2 e Montando"
  sudo mkdir -p "$MOUNT_POINT"
  
  if ! sudo blkid /dev/$VG_NAME/$LV_NAME 2>/dev/null | grep -q gfs2; then
    print_info "Criando filesystem GFS2..."
    sudo mkfs.gfs2 -p lock_nolock -t "${CLUSTER_NAME}:gfs2" /dev/$VG_NAME/$LV_NAME
    print_success "FS GFS2 criado em /dev/$VG_NAME/$LV_NAME"
  else
    print_info "FS GFS2 já existe em /dev/$VG_NAME/$LV_NAME"
  fi
  
  if ! grep -q "/dev/$VG_NAME/$LV_NAME" /etc/fstab; then
    echo "/dev/$VG_NAME/$LV_NAME  $MOUNT_POINT  gfs2  defaults  0  0" | sudo tee -a /etc/fstab
    print_success "Entrada adicionada ao /etc/fstab"
  fi
  
  if ! mountpoint -q "$MOUNT_POINT"; then
    sudo mount "$MOUNT_POINT"
    print_success "Volume montado em $MOUNT_POINT"
  else
    print_info "Volume já montado em $MOUNT_POINT"
  fi
}

# ----------------------------------------------------------------------------
# 10) Configurar corosync.conf
configure_corosync() {
  print_header "🔧 Configurando corosync.conf"
  local f=/etc/corosync/corosync.conf
  [[ -f $f ]] || error_exit "$f não encontrado"
  sudo cp "$f" "$f.backup.$(date +%F_%T)"
  sudo tee "$f" >/dev/null <<EOF
totem {
  version: 2
  secauth: on
  cluster_name: $CLUSTER_NAME
  transport: udpu
}
nodelist {
  node { ring0_addr: $NODE1_NAME; nodeid: 1 }
  node { ring0_addr: $NODE2_NAME; nodeid: 2 }
}
quorum {
  provider: corosync_votequorum
  two_node: 1
}
EOF
  print_success "corosync.conf atualizado"
}

# ----------------------------------------------------------------------------
# Fluxo principal
main() {
  print_header "🚀 Iniciando Instalação GFS2 Enterprise + Mount"
  print_info "Nó: $(get_current_hostname) | IP: $(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}')"
  
  check_prerequisites
  ensure_dlm_kernel_support
  check_dlm_module
  install_packages
  configure_enterprise_cluster
  configure_lvm_cluster
  create_and_mount_gfs2
  configure_corosync
  
  print_header "✅ Instalação Concluída com Sucesso!"
  print_success "Volume GFS2 montado em $MOUNT_POINT"
  print_info "Execute 'df -h $MOUNT_POINT' para verificar"
}

# ----------------------------------------------------------------------------
# Execução
case "${1:-}" in
  --help|-h)  echo "Uso: $0 [--help] [--version]" && exit 0 ;;
  --version)  echo "Versão 2.4" && exit 0 ;;
  *)          main ;;
esac
