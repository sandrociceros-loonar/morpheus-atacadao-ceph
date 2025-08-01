#!/bin/bash
# ============================================================================
# SCRIPT: install-lun-prerequisites.sh
# DESCRIÇÃO: Instalação de pré-requisitos para GFS2 Enterprise
#            + validação e auto-instalação de kernel com suporte a DLM
#            + criação de FS GFS2 e montagem automática
# VERSÃO: 2.2 - Enterprise Cluster Ready + DLM auto-fix + mount
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
readonly NODE1_IP="192.168.0.252"
readonly NODE2_IP="192.168.0.251"
readonly NODE1_NAME="fc-test1"
readonly NODE2_NAME="fc-test2"
readonly VG_NAME="vg_cluster"
readonly LV_NAME="lv_gfs2"
readonly MOUNT_POINT="/mnt/gfs2_volume"

# ----------------------------------------------------------------------------
# Detectar papel do nó
detect_node_role() {
  local ip
  ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "")
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
  if ! dpkg -l | grep -q "^ii  linux-generic "; then
    print_warning "Instalando kernel genérico e extras"
    sudo apt update -qq
    sudo apt install -y linux-generic linux-modules-extra-$(uname -r)
    print_success "Kernel instalado; reinicie e execute novamente"
    exit 0
  fi
  print_success "Kernel genérico presente"
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
    dpkg -l | grep -q "^ii  $pkg " && { print_success "$pkg já instalado"; continue; }
    print_info "Instalando $pkg..."
    sudo apt install -y "$pkg" &>/dev/null || error_exit "Falha ao instalar $pkg"
    print_success "$pkg instalado"
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
  sudo pcs resource show dlm-clone &>/dev/null || sudo pcs resource create dlm systemd:dlm op monitor interval=60s on-fail=fence clone interleave=true ordered=true && print_success "DLM criado"
  sudo pcs resource show lvmlockd-clone &>/dev/null || { sudo pcs resource create lvmlockd systemd:lvmlockd op monitor interval=60s on-fail=fence clone interleave=true ordered=true && print_success "lvmlockd criado"; sudo pcs constraint order start dlm-clone then lvmlockd-clone; sudo pcs constraint colocation add lvmlockd-clone with dlm-clone; }
  print_info "Aguardando recursos (60s)"; sleep 60
}

# ----------------------------------------------------------------------------
# 7) Criar e iniciar o cluster
configure_enterprise_cluster() {
  print_header "🏢 Configurando Cluster Enterprise"
  local role=$(detect_node_role)
  [[ "$role" == "unknown" ]] && error_exit "Papel do nó desconhecido"
  if sudo pcs status &>/dev/null; then
    print_warning "Cluster já existe"; sudo pcs status; return
  fi
  if [[ "$role" == "primary" ]]; then
    sudo systemctl enable --now pcsd
    ssh "$NODE2_NAME" "sudo systemctl enable --now pcsd" &>/dev/null && print_success "pcsd ativos"
    sleep 10
    echo "hacluster" | sudo pcs host auth "$NODE1_NAME" "$NODE2_NAME" -u hacluster
    sudo pcs cluster setup "$CLUSTER_NAME" "$NODE1_NAME" addr="$NODE1_IP" "$NODE2_NAME" addr="$NODE2_IP"
    sudo pcs cluster enable --all --now; sleep 30
    configure_cluster_properties
    configure_cluster_resources
    sudo pcs status
  else
    print_info "Aguardando configuração pelo primário..."
    local t=0
    until sudo pcs status &>/dev/null || ((t>=180)); do sleep 10; ((t+=10)); done
    sudo pcs status || error_exit "Cluster não detectado"
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
    [[ -n $(lsblk -dn -o MOUNTPOINT "$real") ]] && continue
    pvs "$real" &>/dev/null && continue
    devices+=("$real"); print_success "Candidate LUN: $real"
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
  local max=30 t=0
  until sudo pcs status | grep -q "dlm.*Started" || ((t>=max)); do sleep 2; ((t+=2)); done
  sudo pcs status | grep -q "dlm.*Started" || error_exit "DLM não iniciou"
  t=0
  until sudo pcs status | grep -q "lvmlockd.*Started" || ((t>=max)); do sleep 2; ((t+=2)); done
  sudo pcs status | grep -q "lvmlockd.*Started" || error_exit "lvmlockd não iniciou"
  local dev=$(detect_available_devices)
  print_info "Usando device: $dev"
  sudo sed -i '/use_lvmlockd/s/0/1/' /etc/lvm/lvm.conf || true

  if ! sudo vgs "$VG_NAME" &>/dev/null; then
    sudo pvcreate -y "$dev"
    sudo vgcreate --shared --locktype dlm "$VG_NAME" "$dev"
    sudo vgchange --lockstart "$VG_NAME"
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
  if ! sudo blkid /dev/$VG_NAME/$LV_NAME | grep -q gfs2; then
    sudo mkfs.gfs2 -p lock_nolock -t "${CLUSTER_NAME}:gfs2" /dev/$VG_NAME/$LV_NAME
    print_success "FS GFS2 criado em /dev/$VG_NAME/$LV_NAME"
  else
    print_info "FS GFS2 já existe em /dev/$VG_NAME/$LV_NAME"
  fi
  grep -q "/dev/$VG_NAME/$LV_NAME" /etc/fstab || \
    echo "/dev/$VG_NAME/$LV_NAME  $MOUNT_POINT  gfs2  defaults  0  0" | sudo tee -a /etc/fstab
  sudo mount "$MOUNT_POINT"
  print_success "Volume montado em $MOUNT_POINT"
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
  print_header "🚀 Iniciando Instalação GFS2 Enterprise + mount"
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
}

# ----------------------------------------------------------------------------
# Execução
case "${1:-}" in
  --help|-h)  echo "Uso: $0 [--help] [--version]"; exit 0 ;;
  --version)  echo "Versão 2.2"; exit 0 ;;
  *)          main ;;
esac
