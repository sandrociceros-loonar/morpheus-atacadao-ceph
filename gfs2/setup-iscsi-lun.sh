#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# VERSÃO: DEFINITIVA - Resolve Race Condition
# AUTOR: sandro.cicero@loonar.cloud
# ============================================================================

set -e

# Variáveis
DEFAULT_TGT_IP="192.168.0.250"
MULTIPATH_ALIAS="fc-lun-cluster"

echo "Configurando iSCSI/Multipath - Versão Definitiva..."

# Função para aguardar iscsid estar pronto
wait_for_iscsid() {
    echo "Aguardando iscsid estar completamente operacional..."
    local max_attempts=30
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        # Testar se iscsiadm consegue se comunicar com iscsid
        if sudo iscsiadm -m session >/dev/null 2>&1; then
            echo "✅ iscsid está operacional (tentativa $attempt)"
            return 0
        fi
        
        echo "Aguardando iscsid... ($attempt/$max_attempts)"
        sleep 2
        ((attempt++))
    done
    
    echo "❌ ERRO: iscsid não ficou operacional após $max_attempts tentativas"
    return 1
}

# Limpar estado anterior
echo "Limpando estado iSCSI anterior..."
sudo systemctl stop open-iscsi || true
sudo systemctl stop iscsid || true
sudo pkill -f iscsid || true
sleep 3

# Informações básicas
HOSTNAME=$(hostname -s)
CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "unknown")
echo "Sistema: $HOSTNAME ($CURRENT_IP)"

# Instalar pacotes se necessário
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
        TARGET_IP="$test_ip"
        break
    fi
done
[[ -z "$TARGET_IP" ]] && TARGET_IP="$DEFAULT_TGT_IP"
echo "Servidor iSCSI: $TARGET_IP"

# Configurar InitiatorName
INITIATOR="iqn.2004-10.com.ubuntu:01:$(openssl rand -hex 4):$HOSTNAME"
echo "InitiatorName=$INITIATOR" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null

# Configuração básica do iSCSI
sudo tee /etc/iscsi/iscsid.conf >/dev/null <<EOF
node.startup = manual
node.session.auth.authmethod = None
discovery.sendtargets.auth.authmethod = None
node.conn.timeo.login_timeout = 15
node.session.timeo.replacement_timeout = 120
EOF

# CORREÇÃO CRÍTICA: Iniciar iscsid e aguardar estar pronto
echo "Iniciando iscsid..."
sudo systemctl enable iscsid
sudo systemctl start iscsid

# AGUARDAR iscsid estar completamente operacional
if ! wait_for_iscsid; then
    echo "ERRO: iscsid não ficou operacional"
    exit 1
fi

# Agora que iscsid está pronto, fazer discovery
echo "Descobrindo targets..."
DISCOVERY=$(sudo iscsiadm -m discovery -t st -p "$TARGET_IP:3260" 2>/dev/null || echo "")

if [[ -z "$DISCOVERY" ]]; then
    echo "ERRO: Nenhum target encontrado"
    exit 1
fi

echo "Targets encontrados:"
echo "$DISCOVERY"

# Conectar aos targets COM iscsid operacional
echo "Conectando aos targets..."
CONNECTED=0

echo "$DISCOVERY" | while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    PORTAL=$(echo "$line" | awk '{print $1}')
    IQN=$(echo "$line" | awk '{print $2}')
    
    [[ -z "$PORTAL" || -z "$IQN" ]] && continue
    
    echo "Conectando a $IQN..."
    
    # Tentar conexão com retry
    local retry=0
    while [[ $retry -lt 3 ]]; do
        if sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --login 2>/dev/null; then
            echo "✅ Conectado a $IQN"
            ((CONNECTED++))
            break
        else
            ((retry++))
            echo "Tentativa $retry/3 falhou, aguardando..."
            sleep 3
        fi
    done
done

# Verificar conexões
SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
if [[ $SESSIONS -eq 0 ]]; then
    echo "ERRO: Nenhuma sessão estabelecida"
    exit 1
fi

echo "✅ $SESSIONS sessões iSCSI ativas"

# Aguardar dispositivos
echo "Aguardando dispositivos SCSI..."
sleep 15
sudo iscsiadm -m session --rescan 2>/dev/null || true
sleep 10

# Detectar dispositivos
DEVICES=""
for i in {1..10}; do
    DEVICES=$(lsscsi 2>/dev/null | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | head -1)
    [[ -n "$DEVICES" ]] && break
    echo "Aguardando dispositivos... ($i/10)"
    sleep 5
done

if [[ -z "$DEVICES" ]]; then
    echo "ERRO: Nenhum dispositivo detectado"
    echo "Sessões: $SESSIONS"
    lsscsi
    exit 1
fi

echo "✅ Dispositivo: $DEVICES"

# Obter WWID
WWID=$(sudo /lib/udev/scsi_id -g -u -d "$DEVICES" 2>/dev/null)
if [[ -z "$WWID" ]]; then
    echo "ERRO: Falha ao obter WWID"
    exit 1
fi
echo "✅ WWID: $WWID"

# Configurar multipath
echo "Configurando multipath..."
[[ -f /etc/multipath.conf ]] && sudo cp /etc/multipath.conf /etc/multipath.conf.backup

sudo tee /etc/multipath.conf >/dev/null <<EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
}
multipaths {
    multipath {
        wwid $WWID
        alias $MULTIPATH_ALIAS
    }
}
devices {
    device {
        vendor "IET"
        product "VIRTUAL-DISK"
        path_checker tur
    }
}
EOF

# Inicializar multipath
sudo systemctl enable multipathd
sudo systemctl restart multipathd
sleep 10
sudo multipath -r
sleep 10

# Verificar dispositivo final
for i in {1..15}; do
    if [[ -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        break
    fi
    echo "Criando dispositivo multipath... ($i/15)"
    sudo multipath -r
    sleep 3
done

# Resultado final
if [[ -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    SIZE=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS")
    
    echo ""
    echo "🎉 SUCESSO TOTAL!"
    echo "=================="
    echo "Dispositivo: /dev/mapper/$MULTIPATH_ALIAS ($SIZE)"
    echo "Sessões: $SESSIONS"
    echo "Servidor: $TARGET_IP"
    echo "WWID: $WWID"
    echo ""
    
    # Teste final
    if sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 >/dev/null 2>&1; then
        echo "✅ Teste de I/O: SUCESSO"
    fi
    
    echo ""
    echo "✅ Configuração iSCSI/Multipath CONCLUÍDA!"
    
else
    echo "❌ ERRO: Dispositivo multipath não foi criado"
    echo "Sessões: $(sudo iscsiadm -m session | wc -l)"
    echo "Multipath: $(sudo multipath -ll | wc -l)"
    exit 1
fi
