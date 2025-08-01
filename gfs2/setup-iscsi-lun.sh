#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# VERSÃO: CORRIGIDA - Função de teste adequada
# AUTOR: sandro.cicero@loonar.cloud
# ============================================================================

set -e

# Variáveis
DEFAULT_TGT_IP="192.168.0.250"
MULTIPATH_ALIAS="fc-lun-cluster"

echo "Configurando iSCSI/Multipath - Versão Corrigida..."

# Função para aguardar iscsid
wait_for_iscsid() {
    echo "Aguardando iscsid estar completamente operacional..."
    local max_attempts=15
    local attempt=1
    
    while [[ $attempt -le $max_attempts ]]; do
        # Verifica se os serviços estão ativos
        if systemctl is-active --quiet iscsid; then
            # Verifica se há processos iscsid rodando
            if pgrep -f "iscsid" > /dev/null; then
                # Verifica se o socket está respondendo ou se já há conexões estabelecidas
                if sudo iscsiadm -m session > /dev/null 2>&1 || sudo iscsiadm -m discovery --version > /dev/null 2>&1; then
                    echo "✅ iscsid está operacional (tentativa $attempt)"
                    return 0
                fi
            fi
        fi
        
        echo "Aguardando iscsid... ($attempt/$max_attempts)"
        sleep 5
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
node.startup = automatic
node.session.auth.authmethod = CHAP
node.session.auth.authmethod = None
node.session.timeo.replacement_timeout = 120
node.conn.timeo.login_timeout = 15
node.conn.timeo.logout_timeout = 15
node.session.initial_login_retry_max = 8
EOF

# Iniciar serviços iSCSI
echo "Iniciando serviços iSCSI..."
sudo systemctl enable iscsid open-iscsi
sudo systemctl stop iscsid open-iscsi >/dev/null 2>&1 || true
sudo systemctl daemon-reload
sudo systemctl start iscsid
sudo systemctl start open-iscsi
sleep 5

# Aguardar iscsid com teste corrigido
if ! wait_for_iscsid; then
    echo "ERRO: iscsid não ficou operacional"
    echo "Status do serviço:"
    systemctl status iscsid --no-pager
    exit 1
fi

# Fazer discovery
echo "Descobrindo targets..."
DISCOVERY=$(sudo iscsiadm -m discovery -t st -p "$TARGET_IP:3260" 2>/dev/null || echo "")

if [[ -z "$DISCOVERY" ]]; then
    echo "ERRO: Nenhum target encontrado"
    exit 1
fi

echo "Targets encontrados:"
echo "$DISCOVERY"

# Temporariamente desativa o set -e
set +e

# Conectar aos targets
echo "Conectando aos targets..."
CONNECTED=0
FAILED=0

while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    
    PORTAL=$(echo "$line" | awk '{print $1}')
    IQN=$(echo "$line" | awk '{print $2}')
    
    [[ -z "$PORTAL" || -z "$IQN" ]] && continue
    
    echo "Conectando a $IQN..."
    
    # Remove configuração antiga com mais cuidado
    if sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" -u >/dev/null 2>&1; then
        echo "Desconectado do target existente"
    fi
    if sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --op=delete >/dev/null 2>&1; then
        echo "Removida configuração antiga"
    fi
    
    # Configura o nó com verificação de erros
    if ! sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --op=new; then
        echo "❌ Falha ao criar novo nó"
        ((FAILED++))
        continue
    fi
    
    # Configura parâmetros do nó
    sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --op=update -n node.startup -v automatic
    sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --op=update -n node.session.auth.authmethod -v None
    sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --op=update -n node.session.timeo.replacement_timeout -v 120
    
    # Tenta conectar com retry
    LOGIN_SUCCESS=0
    for attempt in {1..3}; do
        if sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --login; then
            echo "✅ Conectado a $IQN (tentativa $attempt)"
            ((CONNECTED++))
            LOGIN_SUCCESS=1
            break
        else
            echo "Tentativa $attempt falhou, aguardando antes de tentar novamente..."
            sleep 5
        fi
    done
    
    if [ $LOGIN_SUCCESS -eq 0 ]; then
        echo "❌ Falha ao conectar a $IQN após 3 tentativas"
        echo "Detalhes do nó:"
        sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --op=show
        ((FAILED++))
    fi
    
    sleep 2
done <<< "$DISCOVERY"

# Reativa o set -e
set -e

# Verifica resultado total
echo "Resumo das conexões:"
echo "✅ Conexões bem sucedidas: $CONNECTED"
echo "❌ Conexões com falha: $FAILED"

# Verificar conexões
SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
if [[ $SESSIONS -eq 0 ]]; then
    echo "ERRO: Nenhuma sessão estabelecida"
    
    # Debug adicional
    echo "Status do iscsid:"
    systemctl status iscsid --no-pager
    echo "Teste de comunicação:"
    sudo iscsiadm -m iface
    exit 1
fi

echo "✅ $SESSIONS sessões iSCSI ativas"

# Aguardar dispositivos
echo "Aguardando dispositivos SCSI..."
sleep 15
sudo iscsiadm -m session --rescan 2>/dev/null || true
sleep 10

# Detectar dispositivos
echo "Estado atual das sessões iSCSI:"
sudo iscsiadm -m session -P 3

DEVICES=""
for i in {1..10}; do
    echo "Tentativa $i de detectar dispositivos..."
    echo "Output do lsscsi:"
    lsscsi
    
    # Procura por discos PROXMOX FC-SIM ou qualquer outro disco conectado via iSCSI
    DEVICES=$(lsscsi | grep -E "disk.*PROXMOX.*FC-SIM|disk.*IET" | awk '{print $NF}' | grep "^/dev" | head -1)
    
    if [[ -n "$DEVICES" && -b "$DEVICES" ]]; then
        echo "Dispositivo encontrado: $DEVICES"
        break
    fi
    
    echo "Tentando rescan dos dispositivos..."
    sudo iscsiadm -m session --rescan >/dev/null 2>&1 || true
    sudo iscsiadm -m node --rescan >/dev/null 2>&1 || true
    sleep 5
done

if [[ -z "$DEVICES" || ! -b "$DEVICES" ]]; then
    echo "ERRO: Nenhum dispositivo válido detectado"
    echo "Sessões: $SESSIONS"
    echo "Dispositivos SCSI:"
    lsscsi
    echo "Estado das sessões iSCSI:"
    sudo iscsiadm -m session -P 3
    echo "Estado dos nós iSCSI:"
    sudo iscsiadm -m node -P 1
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

# Criar configuração mais simples primeiro
sudo tee /etc/multipath.conf >/dev/null <<EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
    path_selector "round-robin 0"
    path_grouping_policy multibus
    failback immediate
    rr_weight uniform
    no_path_retry fail
}

blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^cciss.*"
}

devices {
    device {
        vendor "PROXMOX|IET"
        product ".*"
        path_checker tur
        path_selector "round-robin 0"
        path_grouping_policy group_by_prio
        failback immediate
        prio alua
        hardware_handler "1 alua"
        rr_weight uniform
        rr_min_io 100
    }
}

multipaths {
    multipath {
        wwid $WWID
        alias $MULTIPATH_ALIAS
    }
}
EOF

# Debug do estado atual
echo "Estado atual do multipath antes de reiniciar:"
sudo multipath -ll
sudo multipathd show paths
echo "Configuração do multipath:"
sudo multipathd show config

# Inicializar multipath
echo "Reiniciando serviço multipath..."
sudo systemctl stop multipathd
sudo multipath -F    # Limpa todos os mapas
sudo rm -f /etc/multipath/bindings   # Remove bindings antigos
sudo systemctl start multipathd
sudo systemctl enable multipathd

echo "Aguardando serviço multipath iniciar..."
sleep 5

echo "Verificando estado do serviço multipathd:"
sudo systemctl status multipathd

echo "Rescaneando dispositivos..."
sudo multipath -v3 -R   # Rescan verbose
sleep 5

echo "Criando mapa para o dispositivo..."
sudo multipath -v3 -a /dev/sdb   # Adiciona dispositivo específico
sleep 5

echo "Status do multipath:"
sudo multipath -ll

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
    echo "Debug:"
    echo "  Sessões: $(sudo iscsiadm -m session | wc -l)"
    echo "  Multipath: $(sudo multipath -ll | wc -l)"
    echo "  /dev/mapper: $(ls /dev/mapper/)"
    exit 1
fi
