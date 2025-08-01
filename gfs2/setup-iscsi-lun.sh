#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# DESCRIÇÃO: Configuração automática de conectividade iSCSI - Versão Silenciosa
# VERSÃO: 3.0 - Configuração Essencial Sem Debug
# AUTOR: sandro.cicero@loonar.cloud
# ============================================================================

set -e

# Variáveis
DEFAULT_TGT_IP="192.168.0.250"
ISCSI_PORT="3260"
MULTIPATH_ALIAS="fc-lun-cluster"

# Cores
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

print_success() { echo -e "${GREEN}✅ $1${NC}"; }
print_warning() { echo -e "${YELLOW}⚠️  $1${NC}"; }
print_error() { echo -e "${RED}❌ $1${NC}"; }

echo "🚀 Configurando iSCSI/Multipath..."

# Informações básicas
HOSTNAME=$(hostname -s)
CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "unknown")

# Verificar pacotes
REQUIRED_PACKAGES=("open-iscsi" "multipath-tools" "lvm2")
MISSING_PACKAGES=()

for package in "${REQUIRED_PACKAGES[@]}"; do
    if ! dpkg -l | grep -q "^ii  $package "; then
        MISSING_PACKAGES+=("$package")
    fi
done

if [[ ${#MISSING_PACKAGES[@]} -gt 0 ]]; then
    echo "Instalando pacotes necessários..."
    sudo apt update -qq
    for package in "${MISSING_PACKAGES[@]}"; do
        sudo apt install -y "$package" >/dev/null 2>&1
    done
fi

# Auto-detectar servidor iSCSI
TARGET_IP=""
NETWORK_BASE=$(echo "$CURRENT_IP" | cut -d'.' -f1-3)
COMMON_SERVER_IPS=(250 253 254 1 10 20 50 100 200)

for ip_suffix in "${COMMON_SERVER_IPS[@]}"; do
    test_ip="$NETWORK_BASE.$ip_suffix"
    if [[ "$test_ip" == "$CURRENT_IP" ]]; then
        continue
    fi
    
    if timeout 3s bash -c "</dev/tcp/$test_ip/$ISCSI_PORT" 2>/dev/null; then
        if timeout 5s sudo iscsiadm -m discovery -t st -p "$test_ip:$ISCSI_PORT" >/dev/null 2>&1; then
            TARGET_IP="$test_ip"
            break
        fi
    fi
done

if [[ -z "$TARGET_IP" ]]; then
    TARGET_IP="$DEFAULT_TGT_IP"
fi

echo "Servidor iSCSI: $TARGET_IP"

# Configurar InitiatorName
INITIATOR_NAME="iqn.2004-10.com.ubuntu:01:$(openssl rand -hex 6):$HOSTNAME"
echo "InitiatorName=$INITIATOR_NAME" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null

# Configurar iSCSI
sudo tee /etc/iscsi/iscsid.conf >/dev/null << 'EOF'
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
node.session.initial_login_retry_max = 8
node.conn[0].iscsi.MaxRecvDataSegmentLength = 262144
node.conn[0].iscsi.MaxXmitDataSegmentLength = 0
discovery.sendtargets.iscsi.MaxRecvDataSegmentLength = 32768
node.session.scan = auto
EOF

# Reiniciar serviços
sudo systemctl enable open-iscsi >/dev/null 2>&1
sudo systemctl restart open-iscsi >/dev/null 2>&1
sudo systemctl enable iscsid >/dev/null 2>&1
sudo systemctl restart iscsid >/dev/null 2>&1
sleep 3

# Discovery e conexão
sudo iscsiadm -m discovery -o delete >/dev/null 2>&1 || true
DISCOVERY_OUTPUT=$(sudo iscsiadm -m discovery -t st -p "$TARGET_IP:$ISCSI_PORT" 2>/dev/null || echo "")

if [[ -z "$DISCOVERY_OUTPUT" ]]; then
    print_error "Falha no discovery de targets iSCSI"
    exit 1
fi

echo "Conectando aos targets..."

# Conectar aos targets
CONNECTED_TARGETS=()
IFS=$'\n' read -d '' -ra DISCOVERY_LINES <<< "$DISCOVERY_OUTPUT" || true

for line in "${DISCOVERY_LINES[@]}"; do
    if [[ -z "${line// }" ]]; then
        continue
    fi
    
    read -ra LINE_PARTS <<< "$line"
    if [[ ${#LINE_PARTS[@]} -lt 2 ]]; then
        continue
    fi
    
    PORTAL="${LINE_PARTS[0]}"
    IQN="${LINE_PARTS[1]}"
    
    if [[ -z "$PORTAL" || -z "$IQN" ]]; then
        continue
    fi
    
    if timeout 15s sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --login >/dev/null 2>&1; then
        CONNECTED_TARGETS+=("$IQN")
    fi
    sleep 2
done

if [[ ${#CONNECTED_TARGETS[@]} -eq 0 ]]; then
    print_error "Nenhum target conectou"
    exit 1
fi

print_success "Conectado a ${#CONNECTED_TARGETS[@]} target(s)"

# Aguardar dispositivos
sleep 15
sudo iscsiadm -m session --rescan >/dev/null 2>&1 || true
sleep 10

# Detectar dispositivos iSCSI
RETRY_COUNT=0
ISCSI_DEVICES=""
while [[ $RETRY_COUNT -lt 5 && -z "$ISCSI_DEVICES" ]]; do
    ISCSI_DEVICES=$(lsscsi 2>/dev/null | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | grep -v '^$' || true)
    if [[ -z "$ISCSI_DEVICES" ]]; then
        ((RETRY_COUNT++))
        sudo iscsiadm -m session --rescan >/dev/null 2>&1 || true
        sleep 10
    fi
done

if [[ -z "$ISCSI_DEVICES" ]]; then
    print_error "Dispositivos iSCSI não detectados"
    exit 1
fi

# Obter WWID
PRIMARY_DEVICE=$(echo "$ISCSI_DEVICES" | head -n1)
WWID=$(sudo /lib/udev/scsi_id -g -u -d "$PRIMARY_DEVICE" 2>/dev/null || echo "")
if [[ -z "$WWID" ]]; then
    WWID=$(sudo multipath -v0 -d "$PRIMARY_DEVICE" 2>/dev/null | head -n1 || echo "")
fi

if [[ -z "$WWID" ]]; then
    print_error "Não foi possível obter WWID"
    exit 1
fi

# Configurar multipath
if [[ -f /etc/multipath.conf ]]; then
    sudo cp /etc/multipath.conf /etc/multipath.conf.backup.$(date +%Y%m%d_%H%M%S)
fi

sudo tee /etc/multipath.conf >/dev/null << EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "^$"
    checker_timeout 60
    max_polling_interval 20
    dev_loss_tmo infinity
    fast_io_fail_tmo 5
    queue_without_daemon no
    flush_on_last_del yes
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^cciss!c[0-9]d[0-9]*"
    devnode "^nvme[0-9]"
    devnode "^sda[0-9]*"
    device {
        vendor "ATA"
    }
    device {
        vendor "QEMU"
        product "QEMU HARDDISK"
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
        rr_min_io 100
        flush_on_last_del yes
        dev_loss_tmo infinity
        fast_io_fail_tmo 5
    }
}

devices {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
        path_grouping_policy multibus
        path_checker tur
        features "0"
        hardware_handler "0"
        prio const
        rr_weight uniform
        rr_min_io 1
        flush_on_last_del yes
        dev_loss_tmo infinity
        fast_io_fail_tmo 5
        no_path_retry queue
    }
}
EOF

# Configurar multipath
sudo systemctl enable multipathd >/dev/null 2>&1
sudo systemctl restart multipathd >/dev/null 2>&1
sleep 10

sudo multipath -F >/dev/null 2>&1 || true
sudo multipath -r >/dev/null 2>&1 || true
sleep 10

# Verificar criação do dispositivo
RETRY_COUNT=0
while [[ $RETRY_COUNT -lt 10 ]]; do
    if [[ -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        break
    fi
    ((RETRY_COUNT++))
    sudo multipath -r >/dev/null 2>&1 || true
    sleep 5
done

if [[ ! -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    print_error "Dispositivo multipath não criado"
    exit 1
fi

# Validação final
SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
if [[ $SESSIONS -eq 0 ]]; then
    print_error "Nenhuma sessão iSCSI ativa"
    exit 1
fi

if [[ ! -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    print_error "Dispositivo não acessível"
    exit 1
fi

# Teste básico
if ! sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 >/dev/null 2>&1; then
    sleep 10
    if ! sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 >/dev/null 2>&1; then
        print_warning "Dispositivo criado mas teste de leitura falhou"
    fi
fi

# Configurar auto-start
sudo systemctl enable open-iscsi >/dev/null 2>&1
sudo systemctl enable multipathd >/dev/null 2>&1

# Resultado final
DEVICE_SIZE=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")

print_success "Configuração concluída!"
echo "📋 Resumo:"
echo "   • Servidor: $TARGET_IP"
echo "   • Targets: ${#CONNECTED_TARGETS[@]}"
echo "   • Dispositivo: /dev/mapper/$MULTIPATH_ALIAS ($DEVICE_SIZE)"
echo "   • Sessões: $SESSIONS"
echo ""
echo "Execute 'sudo ./test-iscsi-lun.sh' para validar"
