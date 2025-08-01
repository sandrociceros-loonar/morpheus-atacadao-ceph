#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# DESCRIÇÃO: Configuração automática de conectividade iSCSI
# VERSÃO: 2.5 - Versão Minimalista e Robusta
# AUTOR: sandro.cicero@loonar.cloud
# ============================================================================

set -e

# Variáveis
DEFAULT_TGT_IP="192.168.0.250"
ISCSI_PORT="3260"
MULTIPATH_ALIAS="fc-lun-cluster"

# Cores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }
print_info() { echo -e "${BLUE}ℹ️  $1${NC}"; }

echo ""
echo "========================================================================"
echo "🚀 Setup iSCSI LUN - Configuração Automática"
echo "========================================================================"
echo ""

print_info "Iniciando configuração iSCSI/Multipath..."

# Informações do nó
HOSTNAME=$(hostname -s)
CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "unknown")

echo "📋 Informações do nó:"
echo "   • Hostname: $HOSTNAME"
echo "   • IP: $CURRENT_IP"
echo ""

echo "========================================================================"
echo "🔍 Verificando Pré-requisitos do Sistema"
echo "========================================================================"
echo ""

if [[ $EUID -eq 0 ]]; then
    print_warning "Script executado como root. Recomendado usar sudo."
fi

# Verificar e instalar pacotes
REQUIRED_PACKAGES=("open-iscsi" "multipath-tools" "lvm2")
MISSING_PACKAGES=()

for package in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $package "; then
        MISSING_PACKAGES+=("$package")
    fi
done

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    print_warning "Pacotes ausentes: ${MISSING_PACKAGES[*]}"
    print_info "Instalando pacotes necessários..."
    
    sudo apt update -qq
    for package in "${MISSING_PACKAGES[@]}"; do
        print_info "Instalando $package..."
        if sudo apt install -y "$package" >/dev/null 2>&1; then
            print_success "$package instalado com sucesso"
        else
            print_error "Falha ao instalar $package"
            exit 1
        fi
    done
else
    print_success "Todos os pacotes necessários estão instalados"
fi

print_info "Verificando serviços iSCSI..."
sudo systemctl enable open-iscsi >/dev/null 2>&1
sudo systemctl start open-iscsi >/dev/null 2>&1
sudo systemctl enable multipath-tools >/dev/null 2>&1
sudo systemctl start multipath-tools >/dev/null 2>&1

print_success "Pré-requisitos verificados"

# DEBUG: Forçar execução da próxima etapa
echo ""
echo "🔄 DEBUG: Prosseguindo para configuração do Target..."
echo ""

echo "========================================================================"
echo "🎯 Configuração do Servidor iSCSI Target"
echo "========================================================================"
echo ""

echo "Configure o endereço do servidor iSCSI Target:"
echo ""
echo "Opções disponíveis:"
echo ""
echo "  1️⃣  Usar endereço padrão: $DEFAULT_TGT_IP"
echo "      • Recomendado para laboratório"
echo "      • Configuração mais rápida"
echo ""
echo "  2️⃣  Informar endereço personalizado"
echo "      • Digite o IP do seu servidor TGT"
echo ""

while true; do
    echo -n "Selecione uma opção [1-2]: "
    read -r choice
    
    case "$choice" in
        1)
            TARGET_IP="$DEFAULT_TGT_IP"
            print_success "Usando endereço padrão: $TARGET_IP"
            break
            ;;
        2)
            echo -n "Digite o IP do servidor iSCSI: "
            read -r custom_ip
            if [[ $custom_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                TARGET_IP="$custom_ip"
                print_success "Usando endereço personalizado: $TARGET_IP"
                break
            else
                print_error "IP inválido. Use formato: xxx.xxx.xxx.xxx"
            fi
            ;;
        *)
            print_error "Opção inválida. Digite 1 ou 2"
            ;;
    esac
done

echo ""
print_info "🔍 Testando conectividade com $TARGET_IP..."

if ping -c 2 "$TARGET_IP" >/dev/null 2>&1; then
    print_success "Conectividade confirmada"
else
    print_warning "Ping falhou, mas continuando..."
fi

echo ""
echo "📋 IP configurado: $TARGET_IP"
echo -n "Pressione Enter para continuar..."
read -r

echo ""
echo "========================================================================"
echo "🔧 Configurando iSCSI Initiator"
echo "========================================================================"
echo ""

# Configurar InitiatorName
INITIATOR_NAME="iqn.2004-10.com.ubuntu:01:$(openssl rand -hex 6):$HOSTNAME"
print_info "Configurando InitiatorName único..."
echo "InitiatorName=$INITIATOR_NAME" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null
print_success "InitiatorName configurado: $INITIATOR_NAME"

# Configurar iscsid.conf
print_info "Aplicando configurações otimizadas..."
sudo tee /etc/iscsi/iscsid.conf >/dev/null << 'EOF'
# Configuração otimizada para cluster GFS2
node.startup = automatic
node.leading_login = No
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5
node.session.err_timeo.abort_timeout = 15
node.session.err_timeo.lu_reset_timeout = 30
node.session.err_timeo.tgt_reset_timeout = 30
node.session.queue_depth = 32
node.session.auth.authmethod = None
discovery.sendtargets.auth.authmethod = None
EOF

print_success "Configurações aplicadas"

print_info "Reiniciando serviços iSCSI..."
sudo systemctl restart open-iscsi
sudo systemctl restart iscsid
sleep 3
print_success "Serviços reiniciados"

echo ""
echo "========================================================================"
echo "🔍 Discovery e Conexão iSCSI"
echo "========================================================================"
echo ""

print_info "Descobrindo targets em $TARGET_IP:$ISCSI_PORT..."

# Limpar descobertas anteriores
sudo iscsiadm -m discovery -o delete >/dev/null 2>&1 || true

# Fazer discovery
DISCOVERY_OUTPUT=$(sudo iscsiadm -m discovery -t st -p "$TARGET_IP:$ISCSI_PORT" 2>/dev/null || echo "")

if [[ -z "$DISCOVERY_OUTPUT" ]]; then
    print_error "Falha no discovery de targets iSCSI em $TARGET_IP"
    echo ""
    echo "Possíveis causas:"
    echo "• Servidor iSCSI não está rodando"
    echo "• Firewall bloqueando porta $ISCSI_PORT"
    echo "• IP incorreto ou inacessível"
    echo "• ACL restritivo no servidor"
    exit 1
fi

print_success "Targets descobertos:"
echo "$DISCOVERY_OUTPUT"
echo ""

# Processar primeiro target encontrado
FIRST_LINE=$(echo "$DISCOVERY_OUTPUT" | head -n1)
PORTAL=$(echo "$FIRST_LINE" | awk '{print $1}')
IQN=$(echo "$FIRST_LINE" | awk '{print $2}')

print_info "Conectando ao target: $IQN"

if sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --login; then
    print_success "Conexão estabelecida com sucesso"
else
    print_error "Falha na conexão com o target"
    exit 1
fi

print_info "Aguardando detecção de dispositivos (10s)..."
sleep 10

SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
print_success "Sessões iSCSI ativas: $SESSIONS"

echo ""
echo "========================================================================"
echo "🛣️  Configurando Multipath"
echo "========================================================================"
echo ""

print_info "Detectando dispositivos iSCSI..."

# Detectar dispositivos
ISCSI_DEVICES=$(lsscsi | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | grep -v '^$' || true)

if [[ -z "$ISCSI_DEVICES" ]]; then
    print_error "Nenhum dispositivo iSCSI detectado"
    exit 1
fi

print_success "Dispositivos detectados:"
echo "$ISCSI_DEVICES" | while read device; do
    SIZE=$(lsblk -dn -o SIZE "$device" 2>/dev/null || echo "N/A")
    echo "   📀 $device ($SIZE)"
done

# Obter primeiro dispositivo e WWID
PRIMARY_DEVICE=$(echo "$ISCSI_DEVICES" | head -n1)
print_info "Obtendo WWID do dispositivo $PRIMARY_DEVICE..."

WWID=$(sudo /lib/udev/scsi_id -g -u -d "$PRIMARY_DEVICE" 2>/dev/null || echo "")
if [[ -z "$WWID" ]]; then
    print_error "Falha ao obter WWID"
    exit 1
fi

print_success "WWID: $WWID"

print_info "Criando configuração multipath..."

sudo tee /etc/multipath.conf >/dev/null << EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
    checker_timeout 60
    dev_loss_tmo infinity
    fast_io_fail_tmo 5
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^nvme[0-9]"
    device {
        vendor "ATA"
    }
}

multipaths {
    multipath {
        wwid $WWID
        alias $MULTIPATH_ALIAS
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        no_path_retry queue
    }
}

devices {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
        path_grouping_policy multibus
        path_checker tur
    }
}
EOF

print_success "Configuração criada"

print_info "Configurando serviços multipath..."
sudo systemctl enable multipathd >/dev/null 2>&1
sudo systemctl restart multipathd

sleep 5

sudo multipath -F >/dev/null 2>&1
sudo multipath -r >/dev/null 2>&1
sleep 5

if [[ -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    SIZE=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")
    print_success "Dispositivo criado: /dev/mapper/$MULTIPATH_ALIAS ($SIZE)"
else
    print_error "Falha na criação do dispositivo multipath"
    exit 1
fi

echo ""
echo "========================================================================"
echo "🔍 Validação Final"
echo "========================================================================"
echo ""

# Verificar sessões
SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
if [[ $SESSIONS -gt 0 ]]; then
    print_success "Sessões iSCSI ativas: $SESSIONS"
else
    print_error "Nenhuma sessão iSCSI ativa"
    exit 1
fi

# Verificar dispositivo
if [[ -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    SIZE=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS")
    print_success "Dispositivo multipath: /dev/mapper/$MULTIPATH_ALIAS ($SIZE)"
    
    if sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 >/dev/null 2>&1; then
        print_success "Teste de leitura: OK"
    else
        print_error "Falha no teste de leitura"
        exit 1
    fi
else
    print_error "Dispositivo multipath não acessível"
    exit 1
fi

echo ""
echo "========================================================================"
echo "✅ Configuração Concluída com Sucesso!"
echo "========================================================================"
echo ""

echo "📋 Resumo da Configuração:"
echo "   • Servidor iSCSI: $TARGET_IP:$ISCSI_PORT"
echo "   • Target IQN: $IQN"
echo "   • Dispositivo multipath: /dev/mapper/$MULTIPATH_ALIAS"
echo "   • Tamanho: $(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")"
echo ""

echo "📋 Próximos Passos:"
echo "   1. Execute este script no segundo nó (fc-test2)"
echo "   2. Configure cluster: install-lun-prerequisites.sh"
echo "   3. Configure GFS2: configure-lun-multipath.sh"
echo ""

print_success "🎉 Storage iSCSI pronto para cluster GFS2!"
