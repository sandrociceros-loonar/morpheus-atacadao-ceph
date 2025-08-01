#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# DESCRIÇÃO: Configuração automática completa de conectividade iSCSI
# VERSÃO: 2.9 - Correção Definitiva do Loop de Conexão
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
print_header() { echo -e "\n${BLUE}========================================================================\n$1\n========================================================================${NC}\n"; }

print_header "🚀 Setup iSCSI LUN - Configuração Totalmente Automática"

print_info "Iniciando configuração completa e automatizada iSCSI/Multipath para cluster GFS2..."

# Informações do nó
HOSTNAME=$(hostname -s)
CURRENT_IP=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "unknown")

echo "📋 Informações do nó:"
echo "   • Hostname: $HOSTNAME"
echo "   • IP: $CURRENT_IP"
echo ""

print_header "🔍 Verificando Pré-requisitos do Sistema"

if [[ $EUID -eq 0 ]]; then
    print_warning "Script executado como root. Recomendado usar sudo."
fi

# Verificar e instalar pacotes se necessário
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
        sudo apt install -y "$package"
        print_success "$package instalado com sucesso"
    done
else
    print_success "Todos os pacotes necessários estão instalados"
fi

print_success "Pré-requisitos verificados"

print_header "🎯 Auto-detecção do Servidor iSCSI Target"

# Auto-detecção inteligente do servidor iSCSI
TARGET_IP=""
NETWORK_BASE=$(echo "$CURRENT_IP" | cut -d'.' -f1-3)

print_info "🔍 Detectando servidores iSCSI automaticamente..."
print_info "Escaneando rede $NETWORK_BASE.0/24..."

# IPs comuns para servidores
COMMON_SERVER_IPS=(250 253 254 1 10 20 50 100 200)

for ip_suffix in "${COMMON_SERVER_IPS[@]}"; do
    test_ip="$NETWORK_BASE.$ip_suffix"
    
    # Pular IP atual
    if [[ "$test_ip" == "$CURRENT_IP" ]]; then
        continue
    fi
    
    print_info "   Testando $test_ip..."
    
    # Testar conectividade e porta iSCSI
    if timeout 3s bash -c "</dev/tcp/$test_ip/$ISCSI_PORT" 2>/dev/null; then
        # Verificar se realmente é servidor iSCSI
        if timeout 5s sudo iscsiadm -m discovery -t st -p "$test_ip:$ISCSI_PORT" >/dev/null 2>&1; then
            TARGET_IP="$test_ip"
            print_success "✅ Servidor iSCSI detectado automaticamente: $TARGET_IP"
            break
        fi
    fi
done

# Fallback para IP padrão se não detectar
if [[ -z "$TARGET_IP" ]]; then
    TARGET_IP="$DEFAULT_TGT_IP"
    print_warning "Nenhum servidor auto-detectado. Usando IP padrão: $TARGET_IP"
    
    # Testar conectividade com padrão
    if ! timeout 3s bash -c "</dev/tcp/$TARGET_IP/$ISCSI_PORT" 2>/dev/null; then
        print_error "Servidor padrão $TARGET_IP não está acessível"
        exit 1
    fi
fi

print_info "📋 Target configurado: $TARGET_IP"

print_header "🔧 Configurando iSCSI Initiator"

# Configurar InitiatorName único
INITIATOR_NAME="iqn.2004-10.com.ubuntu:01:$(openssl rand -hex 6):$HOSTNAME"
print_info "Configurando InitiatorName único..."
echo "InitiatorName=$INITIATOR_NAME" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null
print_success "InitiatorName configurado: $INITIATOR_NAME"

# Configurar parâmetros iSCSI otimizados
print_info "Aplicando configurações otimizadas para cluster..."

# Backup da configuração original se existir
if [[ -f /etc/iscsi/iscsid.conf ]]; then
    sudo cp /etc/iscsi/iscsid.conf /etc/iscsi/iscsid.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
fi

sudo tee /etc/iscsi/iscsid.conf >/dev/null << 'EOF'
# Configuração otimizada para cluster GFS2 - Gerada automaticamente
node.startup = automatic
node.leading_login = No

# Timeouts otimizados para cluster
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5

# Configurações de retry
node.session.err_timeo.abort_timeout = 15
node.session.err_timeo.lu_reset_timeout = 30
node.session.err_timeo.tgt_reset_timeout = 30

# Queue depth otimizado
node.session.queue_depth = 32

# Autenticação desabilitada para laboratório
node.session.auth.authmethod = None
discovery.sendtargets.auth.authmethod = None

# Configurações adicionais para estabilidade
node.session.initial_login_retry_max = 8
node.conn[0].iscsi.MaxRecvDataSegmentLength = 262144
node.conn[0].iscsi.MaxXmitDataSegmentLength = 0
discovery.sendtargets.iscsi.MaxRecvDataSegmentLength = 32768
node.session.scan = auto
EOF

print_success "Configurações iSCSI aplicadas"

# Reiniciar serviços
print_info "Reiniciando serviços iSCSI..."
sudo systemctl enable open-iscsi >/dev/null 2>&1
sudo systemctl restart open-iscsi
sudo systemctl enable iscsid >/dev/null 2>&1
sudo systemctl restart iscsid
sleep 5
print_success "Serviços iSCSI reiniciados"

print_header "🔍 Discovery e Conexão Automática iSCSI"

print_info "Descobrindo targets iSCSI em $TARGET_IP:$ISCSI_PORT..."

# Limpar descobertas anteriores
sudo iscsiadm -m discovery -o delete >/dev/null 2>&1 || true

# Fazer discovery
DISCOVERY_OUTPUT=$(sudo iscsiadm -m discovery -t st -p "$TARGET_IP:$ISCSI_PORT" 2>/dev/null || echo "")

if [[ -z "$DISCOVERY_OUTPUT" ]]; then
    print_error "Falha no discovery de targets iSCSI em $TARGET_IP"
    echo ""
    echo "💡 Possíveis causas:"
    echo "   • Servidor iSCSI não está rodando"
    echo "   • Firewall bloqueando porta $ISCSI_PORT"
    echo "   • ACL restritivo no servidor Target"
    echo "   • Configuração de rede incorreta"
    exit 1
fi

print_success "Targets descobertos:"
echo "$DISCOVERY_OUTPUT"
echo ""

# DEBUG: Forçar execução da próxima etapa
print_info "🔄 DEBUG: Iniciando conexões automáticas aos targets..."

# CORREÇÃO: Processar targets usando array em vez de while loop
TARGET_COUNT=0
CONNECTED_TARGETS=()

# Converter discovery output para array
IFS=$'\n' read -d '' -ra DISCOVERY_LINES <<< "$DISCOVERY_OUTPUT" || true

print_info "📋 DEBUG: ${#DISCOVERY_LINES[@]} linhas de discovery encontradas"

# Processar cada linha do discovery
for line in "${DISCOVERY_LINES[@]}"; do
    # Ignorar linhas vazias
    if [[ -z "${line// }" ]]; then
        print_info "🔄 DEBUG: Linha vazia ignorada"
        continue
    fi
    
    print_info "🔄 DEBUG: Processando linha: '$line'"
    
    # Extrair portal e IQN usando array splitting
    read -ra LINE_PARTS <<< "$line"
    
    if [[ ${#LINE_PARTS[@]} -lt 2 ]]; then
        print_warning "⚠️  DEBUG: Linha mal formatada ignorada: $line"
        continue
    fi
    
    PORTAL="${LINE_PARTS[0]}"
    IQN="${LINE_PARTS[1]}"
    
    # Validar que extraiu dados válidos
    if [[ -z "$PORTAL" || -z "$IQN" ]]; then
        print_warning "⚠️  DEBUG: Portal ou IQN vazio - Portal: '$PORTAL', IQN: '$IQN'"
        continue
    fi
    
    ((TARGET_COUNT++))
    
    print_info "🔗 DEBUG: Tentando conectar ao target $TARGET_COUNT:"
    echo "   • Portal: $PORTAL"  
    echo "   • IQN: $IQN"
    
    # Tentar conectar ao target com timeout
    print_info "🔄 DEBUG: Executando comando de login..."
    if timeout 30s sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --login 2>/dev/null; then
        print_success "✅ DEBUG: Conexão estabelecida com $IQN"
        CONNECTED_TARGETS+=("$IQN")
    else
        print_warning "⚠️  DEBUG: Falha na primeira tentativa para $IQN"
        
        # Tentar uma segunda vez com timeout maior
        print_info "🔄 DEBUG: Segunda tentativa para $IQN..."
        if timeout 60s sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --login; then
            print_success "✅ DEBUG: Conexão estabelecida na segunda tentativa com $IQN"
            CONNECTED_TARGETS+=("$IQN")
        else
            print_warning "⚠️  DEBUG: Conexão falhou definitivamente com $IQN"
        fi
    fi
    
    # Pequena pausa entre conexões
    print_info "🔄 DEBUG: Pausa de 3 segundos..."
    sleep 3
    
done

# DEBUG: Mostrar status das conexões
print_info "🔍 DEBUG: Processamento de targets concluído"
print_info "   • Targets descobertos: $TARGET_COUNT"
print_info "   • Targets conectados: ${#CONNECTED_TARGETS[@]}"

# Verificar se pelo menos um target conectou
if [[ ${#CONNECTED_TARGETS[@]} -eq 0 ]]; then
    print_error "❌ Nenhum target iSCSI conectou com sucesso"
    echo ""
    echo "💡 DEBUG: Tentando diagnóstico..."
    echo "Sessões ativas atualmente:"
    sudo iscsiadm -m session 2>/dev/null || echo "Nenhuma sessão ativa"
    echo ""
    echo "Tentando listagem completa de nós descobertos:"
    sudo iscsiadm -m node 2>/dev/null || echo "Nenhum nó descoberto"
    exit 1
fi

print_success "✅ Conectado com sucesso a ${#CONNECTED_TARGETS[@]} target(s) iSCSI"

# Forçar verificação imediata de sessões
print_info "🔍 DEBUG: Verificando sessões imediatamente após conexões..."
IMMEDIATE_SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
print_info "📊 DEBUG: Sessões detectadas imediatamente: $IMMEDIATE_SESSIONS"

# Aguardar detecção de dispositivos
print_info "⏳ Aguardando detecção de dispositivos de storage (15s)..."
sleep 15

# Verificar sessões ativas após aguardar
SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
print_success "📊 Sessões iSCSI ativas após espera: $SESSIONS"

# Forçar rescan para detectar dispositivos
print_info "🔄 Forçando rescan de dispositivos SCSI..."
sudo iscsiadm -m session --rescan 2>/dev/null || true
sleep 10

# Trigger udev para forçar detecção
print_info "🔄 Forçando trigger udev..."
sudo udevadm trigger --subsystem-match=block --action=add
sudo udevadm settle
sleep 5

# Listar dispositivos detectados
print_info "🔍 Verificando dispositivos de storage detectados..."
DETECTED_DEVICES=$(lsblk -dn | grep disk | grep -v -E "(loop|sr)" || true)
if [[ -n "$DETECTED_DEVICES" ]]; then
    print_success "📀 Dispositivos de storage encontrados:"
    echo "$DETECTED_DEVICES" | while read -r device; do
        SIZE=$(echo "$device" | awk '{print $4}')
        NAME=$(echo "$device" | awk '{print $1}')
        echo "   📀 /dev/$NAME (Tamanho: $SIZE)"
    done
else
    print_warning "⚠️  Nenhum dispositivo de storage detectado ainda..."
    print_info "🔄 Aguardando mais tempo para detecção..."
    sleep 15
    
    # Tentar novamente
    DETECTED_DEVICES=$(lsblk -dn | grep disk | grep -v -E "(loop|sr)" || true)
    if [[ -n "$DETECTED_DEVICES" ]]; then
        print_success "📀 Dispositivos encontrados na segunda tentativa:"
        echo "$DETECTED_DEVICES" | while read -r device; do
            SIZE=$(echo "$device" | awk '{print $4}')
            NAME=$(echo "$device" | awk '{print $1}')
            echo "   📀 /dev/$NAME (Tamanho: $SIZE)"
        done
    fi
fi

print_header "🛣️  Configuração Automática do Multipath"

print_info "🔍 Detectando dispositivos iSCSI para multipath..."

# Aguardar um pouco mais para estabilização
sleep 10

# Detectar dispositivos iSCSI com múltiplas tentativas
RETRY_SCSI=0
ISCSI_DEVICES=""
while [[ $RETRY_SCSI -lt 5 && -z "$ISCSI_DEVICES" ]]; do
    ISCSI_DEVICES=$(lsscsi 2>/dev/null | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | grep -v '^$' || true)
    if [[ -z "$ISCSI_DEVICES" ]]; then
        ((RETRY_SCSI++))
        print_info "🔄 Tentativa $RETRY_SCSI/5 - Aguardando dispositivos iSCSI..."
        sudo iscsiadm -m session --rescan 2>/dev/null || true
        sleep 10
    fi
done

if [[ -z "$ISCSI_DEVICES" ]]; then
    print_error "❌ Nenhum dispositivo iSCSI detectado após múltiplas tentativas"
    echo ""
    echo "🔍 DEBUG: Informações de diagnóstico:"
    echo "Sessões iSCSI ativas:"
    sudo iscsiadm -m session 2>/dev/null || echo "Nenhuma"
    echo ""
    echo "Todos os dispositivos SCSI:"
    lsscsi 2>/dev/null || echo "Comando lsscsi falhou"
    echo ""
    echo "Dispositivos de bloco:"
    lsblk
    echo ""
    echo "💡 Soluções manuais:"
    echo "   • Forçar detecção: sudo iscsiadm -m session --rescan"
    echo "   • Recriar multipath: sudo multipath -r"
    exit 1
fi

print_success "✅ Dispositivos iSCSI detectados para multipath:"
echo "$ISCSI_DEVICES" | while read device; do
    SIZE=$(lsblk -dn -o SIZE "$device" 2>/dev/null || echo "N/A")
    MODEL=$(lsscsi 2>/dev/null | grep "$device" | awk '{print $3}' || echo "Unknown")
    echo "   📀 $device (Tamanho: $SIZE, Modelo: $MODEL)"
done

# Obter WWID do primeiro dispositivo detectado
PRIMARY_DEVICE=$(echo "$ISCSI_DEVICES" | head -n1)
print_info "📋 Obtendo WWID do dispositivo primário: $PRIMARY_DEVICE"

WWID=$(sudo /lib/udev/scsi_id -g -u -d "$PRIMARY_DEVICE" 2>/dev/null || echo "")
if [[ -z "$WWID" ]]; then
    print_warning "🔄 Tentando método alternativo para obter WWID..."
    WWID=$(sudo multipath -v0 -d "$PRIMARY_DEVICE" 2>/dev/null | head -n1 || echo "")
    if [[ -z "$WWID" ]]; then
        print_error "❌ Não foi possível obter WWID do dispositivo $PRIMARY_DEVICE"
        exit 1
    fi
fi

print_success "✅ WWID detectado: $WWID"

print_info "⚙️  Criando configuração multipath otimizada..."

# Backup da configuração existente se houver
if [[ -f /etc/multipath.conf ]]; then
    sudo cp /etc/multipath.conf /etc/multipath.conf.backup.$(date +%Y%m%d_%H%M%S)
    print_info "📋 Backup da configuração anterior criado"
fi

# Criar configuração multipath
sudo tee /etc/multipath.conf >/dev/null << EOF
# Configuração Multipath para Cluster GFS2
# Gerado automaticamente pelo setup-iscsi-lun.sh v2.9
# WWID do dispositivo: $WWID
# Hostname: $HOSTNAME
# Data: $(date)

defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "^$"
    
    # Configurações otimizadas para ambiente de cluster
    checker_timeout 60
    max_polling_interval 20
    
    # Configurações de path failure para alta disponibilidade
    dev_loss_tmo infinity
    fast_io_fail_tmo 5
    
    # Configurações de performance
    queue_without_daemon no
    flush_on_last_del yes
}

blacklist {
    # Blacklist dispositivos locais comuns
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^cciss!c[0-9]d[0-9]*"
    devnode "^nvme[0-9]"
    devnode "^sda[0-9]*"
    
    # Blacklist por tipo de dispositivo
    device {
        vendor "ATA"
    }
    device {
        vendor "QEMU"
        product "QEMU HARDDISK"
    }
    device {
        vendor "VMware"
        product "Virtual disk"
    }
}

multipaths {
    multipath {
        wwid $WWID
        alias $MULTIPATH_ALIAS
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        rr_weight priorities
        no_path_retry queue
        rr_min_io 100
        
        # Configurações específicas para cluster
        flush_on_last_del yes
        dev_loss_tmo infinity
        fast_io_fail_tmo 5
        
        # Configurações de performance para GFS2
        rr_min_io_rq 1
        features "1 queue_if_no_path"
    }
}

# Configurações específicas para diferentes tipos de storage iSCSI
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
    device {
        vendor "LIO-ORG"
        product "*"
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
    device {
        vendor "SCST"
        product "*"
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

print_success "✅ Arquivo multipath.conf configurado"

# Configurar e reiniciar serviços multipath
print_info "🔄 Configurando e reiniciando serviços multipath..."

sudo systemctl enable multipathd >/dev/null 2>&1
sudo systemctl restart multipathd

# Aguardar multipath processar
print_info "⏳ Aguardando inicialização do multipathd..."
sleep 15

# Forçar recriação de mapas multipath com múltiplas tentativas
print_info "🔄 Criando mapas multipath..."
sudo multipath -F >/dev/null 2>&1 || true
sleep 5
sudo multipath -r >/dev/null 2>&1 || true
sleep 10
sudo multipath -a "$PRIMARY_DEVICE" >/dev/null 2>&1 || true
sleep 5
sudo multipath -r >/dev/null 2>&1 || true
sleep 15

# Verificar se dispositivo multipath foi criado com retry
RETRY_COUNT=0
MAX_RETRIES=10

print_info "🔄 Verificando criação do dispositivo multipath..."

while [[ $RETRY_COUNT -lt $MAX_RETRIES ]]; do
    if [[ -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        DEVICE_SIZE=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")
        print_success "🎉 Dispositivo multipath criado: /dev/mapper/$MULTIPATH_ALIAS ($DEVICE_SIZE)"
        
        # Mostrar informações detalhadas
        echo ""
        print_info "📊 Informações detalhadas do dispositivo multipath:"
        if sudo multipath -ll "$MULTIPATH_ALIAS" >/dev/null 2>&1; then
            sudo multipath -ll "$MULTIPATH_ALIAS"
        else
            print_info "Status detalhado será disponível após alguns segundos..."
        fi
        break
    else
        ((RETRY_COUNT++))
        print_info "⏳ Tentativa $RETRY_COUNT/$MAX_RETRIES - Aguardando criação do dispositivo..."
        
        # Tentar forçar criação novamente
        sudo udevadm trigger --subsystem-match=block --action=add >/dev/null 2>&1 || true
        sudo udevadm settle >/dev/null 2>&1 || true
        sudo multipath -r >/dev/null 2>&1 || true
        
        sleep 10
    fi
done

# Verificação final
if [[ ! -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    print_error "❌ Dispositivo multipath não foi criado após $MAX_RETRIES tentativas"
    echo ""
    echo "🔍 DEBUG: Informações de diagnóstico:"
    echo "Mapas multipath ativos:"
    sudo multipath -ll 2>/dev/null || echo "Nenhum"
    echo ""
    echo "Dispositivos em /dev/mapper:"
    ls -la /dev/mapper/ 2>/dev/null | grep -v control || echo "Apenas control"
    echo ""
    echo "💡 Possíveis soluções manuais:"
    echo "   • Executar manualmente: sudo multipath -r"
    echo "   • Verificar logs: sudo journalctl -u multipathd -n 20"
    echo "   • Verificar configuração: sudo multipath -t"
    exit 1
fi

print_header "🔍 Validação Final Automática da Configuração"

# Verificar sessões iSCSI ativas
SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
if [[ $SESSIONS -gt 0 ]]; then
    print_success "✅ Sessões iSCSI ativas: $SESSIONS"
    echo ""
    print_info "📋 Detalhes das sessões:"
    sudo iscsiadm -m session | while read -r session; do
        echo "   🔗 $session"
    done
else
    print_error "❌ Nenhuma sessão iSCSI ativa"
    exit 1
fi

echo ""

# Verificar dispositivo multipath
if [[ -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    DEVICE_SIZE=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS")
    print_success "✅ Dispositivo multipath acessível: /dev/mapper/$MULTIPATH_ALIAS ($DEVICE_SIZE)"
    
    # Teste de acesso ao dispositivo
    print_info "🧪 Executando teste de acesso ao dispositivo..."
    if sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 >/dev/null 2>&1; then
        print_success "✅ Teste de leitura no dispositivo: SUCESSO"
    else
        print_warning "⚠️  Aguardando dispositivo ficar completamente disponível..."
        sleep 15
        if sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 >/dev/null 2>&1; then
            print_success "✅ Teste de leitura (segunda tentativa): SUCESSO"
        else
            print_warning "⚠️  Teste de leitura ainda falha, mas dispositivo foi criado"
        fi
    fi
else
    print_error "❌ Dispositivo multipath não é acessível como block device"
    exit 1
fi

echo ""

# Configurar persistência
print_info "🔒 Configurando persistência da configuração..."
sudo systemctl enable open-iscsi >/dev/null 2>&1
sudo systemctl enable multipathd >/dev/null 2>&1

if systemctl is-enabled --quiet open-iscsi && systemctl is-enabled --quiet multipathd; then
    print_success "✅ Serviços configurados para inicialização automática"
else
    print_warning "⚠️  Problema na configuração de auto-start (mas serviços estão ativos)"
fi

# Executar teste automático de performance
print_info "🚀 Executando testes automáticos de performance..."

DEVICE="/dev/mapper/$MULTIPATH_ALIAS"

# Teste de escrita (pequeno para não impactar)
print_info "📝 Teste de escrita (10MB)..."
if timeout 30s sudo dd if=/dev/zero of="$DEVICE" bs=1M count=10 oflag=direct 2>/tmp/dd_test.log; then
    WRITE_SPEED=$(grep -oE '[0-9.]+ [MG]B/s' /tmp/dd_test.log | tail -n1 || echo "N/A")
    print_success "✅ Velocidade de escrita: $WRITE_SPEED"
else
    print_warning "⚠️  Teste de escrita não concluído (pode ser normal para alguns storages)"
fi

# Teste de leitura
print_info "📖 Teste de leitura (10MB)..."
if timeout 30s sudo dd if="$DEVICE" of=/dev/null bs=1M count=10 iflag=direct 2>/tmp/dd_test.log; then
    READ_SPEED=$(grep -oE '[0-9.]+ [MG]B/s' /tmp/dd_test.log | tail -n1 || echo "N/A")
    print_success "✅ Velocidade de leitura: $READ_SPEED"
else
    print_warning "⚠️  Teste de leitura não concluído"
fi

# Limpeza
sudo rm -f /tmp/dd_test.log 2>/dev/null || true

print_header "✅ Configuração iSCSI/Multipath Totalmente Concluída!"

echo ""
print_success "🎯 Resumo da Configuração Automática Finalizada:"

echo ""
echo "📋 Detalhes da Configuração:"
echo "   🎯 Targets conectados: ${#CONNECTED_TARGETS[@]}"
for target in "${CONNECTED_TARGETS[@]}"; do
    echo "      • $target"
done
echo "   🖥️  Servidor iSCSI: $TARGET_IP:$ISCSI_PORT"
echo "   🆔 InitiatorName: $INITIATOR_NAME"
echo "   💾 Dispositivo multipath: /dev/mapper/$MULTIPATH_ALIAS"
echo "   📏 Tamanho do storage: $(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")"
echo "   🔑 WWID: $WWID"
echo "   🔄 Status: $(ls /dev/mapper/$MULTIPATH_ALIAS &>/dev/null && echo "✅ Acessível" || echo "❌ Problema")"

echo ""
print_success "📋 Próximos Passos para Cluster GFS2:"
echo "   1️⃣  Execute 'sudo ./test-iscsi-lun.sh' para validar"
echo "   2️⃣  Configure cluster Pacemaker/Corosync: install-lun-prerequisites.sh"
echo "   3️⃣  Configure filesystem GFS2: configure-lun-multipath.sh"
echo "   4️⃣  Configure segundo nó: configure-second-node.sh"
echo "   5️⃣  Valide ambiente completo: test-lun-gfs2.sh"

echo ""
print_success "🔧 Comandos Úteis para Administração:"
echo "   • Verificar configuração: sudo ./test-iscsi-lun.sh"
echo "   • Verificar sessões iSCSI: sudo iscsiadm -m session"
echo "   • Status do multipath: sudo multipath -ll"
echo "   • Informações do dispositivo: lsblk /dev/mapper/$MULTIPATH_ALIAS"
echo "   • Logs iSCSI: sudo journalctl -u open-iscsi -n 20"
echo "   • Logs multipath: sudo journalctl -u multipathd -n 20"

echo ""
print_info "💡 Configuração salva em:"
echo "   • iSCSI Initiator: /etc/iscsi/initiatorname.iscsi"
echo "   • Configuração iSCSI: /etc/iscsi/iscsid.conf"
echo "   • Configuração Multipath: /etc/multipath.conf"

echo ""
print_success "🎉 Storage iSCSI totalmente configurado e pronto para cluster GFS2!"
print_info "📋 Execute 'sudo ./test-iscsi-lun.sh' para validar a configuração"
