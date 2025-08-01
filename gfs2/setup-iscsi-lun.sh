#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# VERSÃO: FINAL - Solução Definitiva
# AUTOR: sandro.cicero@loonar.cloud
# ============================================================================

set -e

# Variáveis
DEFAULT_TGT_IP="192.168.0.250"
MULTIPATH_ALIAS="fc-lun-cluster"

echo "Configurando iSCSI/Multipath..."

# Informações básicas do nó
HOSTNAME=$(hostname -s)
CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "unknown")

# Instalar pacotes necessários
for pkg in open-iscsi multipath-tools lvm2; do
    if ! dpkg -l | grep -q "^ii  $pkg "; then
        echo "Instalando $pkg..."
        sudo apt update -qq && sudo apt install -y $pkg >/dev/null 2>&1
    fi
done

# Detectar servidor iSCSI
TARGET_IP=""
NETWORK=$(echo $CURRENT_IP | cut -d. -f1-3)
for ip in 253 250 254 1 10; do
    test_ip="$NETWORK.$ip"
    if [[ "$test_ip" != "$CURRENT_IP" ]] && timeout 2s bash -c "</dev/tcp/$test_ip/3260" 2>/dev/null; then
        if timeout 3s sudo iscsiadm -m discovery -t st -p "$test_ip:3260" >/dev/null 2>&1; then
            TARGET_IP="$test_ip"
            break
        fi
    fi
done

[[ -z "$TARGET_IP" ]] && TARGET_IP="$DEFAULT_TGT_IP"
echo "Servidor iSCSI: $TARGET_IP"

# Configurar InitiatorName
INITIATOR="iqn.2004-10.com.ubuntu:01:$(openssl rand -hex 4):$HOSTNAME"
echo "InitiatorName=$INITIATOR" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null

# Configuração básica do iSCSI
sudo tee /etc/iscsi/iscsid.conf >/dev/null <<EOF
node.startup = automatic
node.session.auth.authmethod = None
discovery.sendtargets.auth.authmethod = None
node.conn.timeo.login_timeout = 15
node.session.timeo.replacement_timeout = 120
node.conn.timeo.logout_timeout = 15
node.conn.timeo.noop_out_interval = 5
node.conn.timeo.noop_out_timeout = 5
node.session.queue_depth = 32
EOF

# Reiniciar serviços iSCSI
sudo systemctl enable --now open-iscsi iscsid >/dev/null 2>&1
sleep 3

# Discovery de targets
echo "Descobrindo targets..."
sudo iscsiadm -m discovery -o delete >/dev/null 2>&1 || true
DISCOVERY=$(sudo iscsiadm -m discovery -t st -p "$TARGET_IP:3260" 2>/dev/null || echo "")

if [[ -z "$DISCOVERY" ]]; then
    echo "ERRO: Nenhum target encontrado em $TARGET_IP"
    exit 1
fi

# Conectar aos targets - MÉTODO SIMPLES E FUNCIONAL
echo "Conectando aos targets..."
CONNECTED=0

# Salvar discovery em arquivo temporário para processamento simples
echo "$DISCOVERY" > /tmp/iscsi_targets.txt

# Processar cada linha do arquivo
while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    # Extrair portal e IQN usando awk
    PORTAL=$(echo "$line" | awk '{print $1}')
    IQN=$(echo "$line" | awk '{print $2}')
    
    [[ -z "$PORTAL" || -z "$IQN" ]] && continue
    
    echo "Conectando a $IQN..."
    if timeout 10s sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --login >/dev/null 2>&1; then
        echo "Conectado a $IQN"
        ((CONNECTED++))
    else
        echo "Falha ao conectar a $IQN"
    fi
    sleep 1
    
done < /tmp/iscsi_targets.txt

# Limpar arquivo temporário
rm -f /tmp/iscsi_targets.txt

if [[ $CONNECTED -eq 0 ]]; then
    echo "ERRO: Nenhum target conectou"
    exit 1
fi

echo "Conectado a $CONNECTED target(s)"

# Aguardar detecção de dispositivos
echo "Aguardando dispositivos..."
sleep 15
sudo iscsiadm -m session --rescan >/dev/null 2>&1 || true
sleep 10

# Detectar dispositivos iSCSI
DEVICES=""
for i in {1..5}; do
    DEVICES=$(lsscsi 2>/dev/null | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | head -1)
    [[ -n "$DEVICES" ]] && break
    echo "Tentativa $i/5 - aguardando dispositivos..."
    sleep 10
done

if [[ -z "$DEVICES" ]]; then
    echo "ERRO: Nenhum dispositivo iSCSI detectado"
    echo "Sessões ativas: $(sudo iscsiadm -m session 2>/dev/null | wc -l)"
    exit 1
fi

echo "Dispositivo detectado: $DEVICES"

# Obter WWID
WWID=$(sudo /lib/udev/scsi_id -g -u -d "$DEVICES" 2>/dev/null || echo "")
if [[ -z "$WWID" ]]; then
    echo "ERRO: Não foi possível obter WWID"
    exit 1
fi

echo "WWID: $WWID"

# Configurar multipath
[[ -f /etc/multipath.conf ]] && sudo cp /etc/multipath.conf /etc/multipath.conf.backup

sudo tee /etc/multipath.conf >/dev/null <<EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
    checker_timeout 60
    dev_loss_tmo infinity
    fast_io_fail_tmo 5
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st|sda)[0-9]*"
    device {
        vendor "ATA"
    }
}

multipaths {
    multipath {
        wwid $WWID
        alias $MULTIPATH_ALIAS
        path_checker tur
        no_path_retry queue
    }
}

devices {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
        path_checker tur
        no_path_retry queue
    }
    device {
        vendor "LIO-ORG"
        product "*"
        path_checker tur
        no_path_retry queue
    }
}
EOF

# Inicializar multipath
echo "Configurando multipath..."
sudo systemctl enable --now multipathd >/dev/null 2>&1
sleep 10

sudo multipath -F >/dev/null 2>&1 || true
sudo multipath -r >/dev/null 2>&1 || true
sleep 10

# Verificar criação do dispositivo
echo "Verificando dispositivo multipath..."
for i in {1..15}; do
    if [[ -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        break
    fi
    echo "Tentativa $i/15 - aguardando criação do dispositivo..."
    sudo multipath -r >/dev/null 2>&1 || true
    sleep 5
done

# Validação final
if [[ -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    SIZE=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")
    SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
    
    echo ""
    echo "✅ SUCESSO: Configuração concluída!"
    echo "   Dispositivo: /dev/mapper/$MULTIPATH_ALIAS ($SIZE)"
    echo "   Sessões iSCSI: $SESSIONS"
    echo "   Servidor: $TARGET_IP"
    echo ""
    echo "Execute 'sudo ./test-iscsi-lun.sh' para validar"
    
    # Teste básico de leitura
    if sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 >/dev/null 2>&1; then
        echo "   Teste de leitura: OK"
    fi
    
else
    echo "ERRO: Dispositivo /dev/mapper/$MULTIPATH_ALIAS não foi criado"
    echo "Debug info:"
    echo "  Mapas multipath: $(sudo multipath -ll 2>/dev/null | wc -l)"
    echo "  Dispositivos /dev/mapper: $(ls /dev/mapper/ | grep -v control | wc -l)"
    exit 1
fi
