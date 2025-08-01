#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# DESCRIÇÃO: Configuração automática de conectividade iSCSI
# VERSÃO: 2.6 - Baseado na Versão Minimalista Funcional
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

print_header "🚀 Setup iSCSI LUN - Configuração Automática"

print_info "Iniciando configuração iSCSI/Multipath para cluster GFS2..."

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

print_header "🎯 Configuração do Servidor iSCSI Target"

echo "Configure o endereço do servidor iSCSI Target:"
echo ""
echo "Opções disponíveis:"
echo ""
echo "  1️⃣  Usar endereço padrão: $DEFAULT_TGT_IP"
echo "      • Recomendado para laboratório padrão"
echo "      • Configuração mais rápida"
echo ""
echo "  2️⃣  Informar endereço personalizado"
echo "      • Digite o IP específico do seu servidor TGT"
echo "      • Use se seu servidor tem IP diferente"
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

print_header "🔧 Configurando iSCSI Initiator"

# Configurar InitiatorName único
INITIATOR_NAME="iqn.2004-10.com.ubuntu:01:$(openssl rand -hex 6):$HOSTNAME"
print_info "Configurando InitiatorName único..."
echo "InitiatorName=$INITIATOR_NAME" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null
print_success "InitiatorName configurado: $INITIATOR_NAME"

# Configurar parâmetros iSCSI otimizados
print_info "Aplicando configurações otimizadas para cluster..."
sudo tee /etc/iscsi/iscsid.conf >/dev/null << 'EOF'
# Configuração otimizada para cluster GFS2
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

# Reiniciar serviços de forma simples (sem redirecionamento complexo)
print_info "Reiniciando serviços iSCSI..."
sudo systemctl restart open-iscsi
sudo systemctl restart iscsid
sleep 3
print_success "Serviços iSCSI reiniciados"

print_header "🔍 Discovery e Conexão iSCSI"

print_info "Descobrindo targets iSCSI em $TARGET_IP:$ISCSI_PORT..."

# Limpar descobertas anteriores
sudo iscsiadm -m discovery -o delete >/dev/null 2>&1 || true

# Fazer discovery
echo ""
print_info "Executando discovery..."
DISCOVERY_OUTPUT=$(sudo iscsiadm -m discovery -t st -p "$TARGET_IP:$ISCSI_PORT" 2>/dev/null || echo "")

if [[ -z "$DISCOVERY_OUTPUT" ]]; then
    print_error "Falha no discovery de targets iSCSI em $TARGET_IP"
    echo ""
    echo "💡 Possíveis causas:"
    echo "   • Servidor iSCSI não está rodando"
    echo "   • Firewall bloqueando porta $ISCSI_PORT"
    echo "   • IP incorreto ou inacessível"
    echo "   • ACL restritivo no servidor Target"
    exit 1
fi

print_success "Targets descobertos:"
echo "$DISCOVERY_OUTPUT"
echo ""

# Processar targets e permitir seleção
TARGETS_ARRAY=()
TARGET_COUNT=0

while IFS= read -r line; do
    if [[ -n "$line" ]]; then
        PORTAL=$(echo "$line" | awk '{print $1}')
        IQN=$(echo "$line" | awk '{print $2}')
        ((TARGET_COUNT++))
        TARGETS_ARRAY+=("$PORTAL|$IQN")
        echo "   $TARGET_COUNT. Portal: $PORTAL"
        echo "      IQN: $IQN"
        echo ""
    fi
done <<< "$DISCOVERY_OUTPUT"

# Seleção do target
if [[ $TARGET_COUNT -eq 1 ]]; then
    SELECTED_TARGET="${TARGETS_ARRAY[0]}"
    print_info "Selecionando automaticamente o único target disponível"
else
    while true; do
        echo -n "Selecione o target desejado [1-$TARGET_COUNT]: "
        read -r target_choice
        
        if [[ "$target_choice" =~ ^[0-9]+$ ]] && [[ "$target_choice" -ge 1 ]] && [[ "$target_choice" -le $TARGET_COUNT ]]; then
            SELECTED_TARGET="${TARGETS_ARRAY[$((target_choice - 1))]}"
            break
        else
            print_error "Seleção inválida. Digite um número entre 1 e $TARGET_COUNT"
        fi
    done
fi

# Conectar ao target selecionado
PORTAL=$(echo "$SELECTED_TARGET" | cut -d'|' -f1)
IQN=$(echo "$SELECTED_TARGET" | cut -d'|' -f2)

print_info "Conectando ao target selecionado:"
echo "   • Portal: $PORTAL"
echo "   • IQN: $IQN"

if sudo iscsiadm -m node -T "$IQN" -p "$PORTAL" --login; then
    print_success "Conexão iSCSI estabelecida com sucesso"
else
    print_error "Falha na conexão com o target"
    echo ""
    echo "💡 Possíveis soluções:"
    echo "   • Verificar ACL no servidor: sudo tgtadm --mode target --op show"
    echo "   • Verificar se target está ativo"
    echo "   • Reiniciar serviços iSCSI e tentar novamente"
    exit 1
fi

# Aguardar detecção de dispositivos
print_info "⏳ Aguardando detecção de dispositivos de storage (15s)..."
sleep 15

# Verificar sessões ativas
SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
print_success "Sessões iSCSI ativas: $SESSIONS"

# Listar dispositivos detectados
print_info "🔍 Dispositivos de storage detectados:"
lsblk -dn | grep disk | grep -v -E "(loop|sr)" | while read -r device; do
    SIZE=$(echo "$device" | awk '{print $4}')
    NAME=$(echo "$device" | awk '{print $1}')
    echo "   📀 /dev/$NAME (Tamanho: $SIZE)"
done

print_header "🛣️  Configurando Multipath"

print_info "🔍 Detectando dispositivos iSCSI para multipath..."

# Detectar dispositivos iSCSI
ISCSI_DEVICES=$(lsscsi | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | grep -v '^$' || true)

if [[ -z "$ISCSI_DEVICES" ]]; then
    print_error "Nenhum dispositivo iSCSI detectado para configuração multipath"
    echo ""
    echo "🔍 Troubleshooting:"
    echo "   • Verificar se conexão iSCSI foi estabelecida: sudo iscsiadm -m session"
    echo "   • Listar dispositivos SCSI: lsscsi"
    echo "   • Verificar logs: sudo journalctl -u open-iscsi -n 20"
    exit 1
fi

print_success "Dispositivos iSCSI detectados para multipath:"
echo "$ISCSI_DEVICES" | while read device; do
    SIZE=$(lsblk -dn -o SIZE "$device" 2>/dev/null || echo "N/A")
    MODEL=$(lsscsi | grep "$device" | awk '{print $3}' || echo "Unknown")
    echo "   📀 $device (Tamanho: $SIZE, Modelo: $MODEL)"
done

# Obter WWID do primeiro dispositivo
PRIMARY_DEVICE=$(echo "$ISCSI_DEVICES" | head -n1)
print_info "📋 Obtendo WWID do dispositivo primário: $PRIMARY_DEVICE"

WWID=$(sudo /lib/udev/scsi_id -g -u -d "$PRIMARY_DEVICE" 2>/dev/null || echo "")
if [[ -z "$WWID" ]]; then
    print_error "Falha ao obter WWID do dispositivo $PRIMARY_DEVICE"
    exit 1
fi

print_success "WWID detectado: $WWID"

print_info "⚙️  Criando configuração multipath otimizada..."

# Backup da configuração existente se houver
if [[ -f /etc/multipath.conf ]]; then
    sudo cp /etc/multipath.conf /etc/multipath.conf.backup.$(date +%Y%m%d_%H%M%S)
    print_info "Backup da configuração anterior criado"
fi

# Criar configuração multipath
sudo tee /etc/multipath.conf >/dev/null << EOF
# Configuração Multipath para Cluster GFS2
# Gerado automaticamente pelo setup-iscsi-lun.sh
# WWID do dispositivo: $WWID

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
    
    # Blacklist por tipo de dispositivo
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
        rr_weight priorities
        no_path_retry queue
        rr_min_io 100
        
        # Configurações específicas para cluster
        flush_on_last_del yes
        dev_loss_tmo infinity
        fast_io_fail_tmo 5
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
    }
}
EOF

print_success "Arquivo multipath.conf configurado"

# Configurar e reiniciar serviços multipath
print_info "🔄 Configurando e reiniciando serviços multipath..."

sudo systemctl enable multipathd
sudo systemctl restart multipathd

# Aguardar multipath processar
sleep 10

# Forçar recriação de mapas multipath
print_info "🔄 Forçando recriação de mapas multipath..."
sudo multipath -F >/dev/null 2>&1  # Flush all maps
sudo multipath -r >/dev/null 2>&1  # Reload and recreate maps

sleep 10

# Verificar se dispositivo multipath foi criado
if [[ -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
    DEVICE_SIZE=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")
    print_success "🎉 Dispositivo multipath criado: /dev/mapper/$MULTIPATH_ALIAS ($DEVICE_SIZE)"
    
    # Mostrar informações detalhadas
    echo ""
    print_info "📊 Informações detalhadas do dispositivo multipath:"
    sudo multipath -ll "$MULTIPATH_ALIAS" 2>/dev/null || echo "Status detalhado não disponível"
    
else
    print_warning "Dispositivo multipath não foi criado automaticamente"
    print_info "🔄 Tentando criar mapa manualmente..."
    
    # Tentar criar mapa multipath manualmente
    sudo multipath -a "$PRIMARY_DEVICE" >/dev/null 2>&1
    sudo multipath -r >/dev/null 2>&1
    sleep 10
    
    if [[ -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        print_success "✅ Dispositivo multipath criado manualmente"
    else
        print_error "❌ Falha na criação do dispositivo multipath"
        echo ""
        echo "🔍 Troubleshooting:"
        echo "   • Verificar configuração: sudo multipath -t"
        echo "   • Ver mapas ativos: sudo multipath -ll"
        echo "   • Logs do multipathd: sudo journalctl -u multipathd -n 20"
        exit 1
    fi
fi

print_header "🔍 Validação Final da Configuração"

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
        print_error "❌ Falha no teste de leitura do dispositivo"
        exit 1
    fi
    
else
    print_error "❌ Dispositivo multipath não está acessível"
    echo "💡 Verificar se o dispositivo foi criado: ls -la /dev/mapper/"
    exit 1
fi

echo ""

# Verificar se serviços estão configurados para auto-start
print_info "🔒 Verificando persistência da configuração..."

if systemctl is-enabled --quiet open-iscsi && systemctl is-enabled --quiet multipathd; then
    print_success "✅ Serviços configurados para inicialização automática"
else
    print_warning "⚠️  Configurando serviços para auto-start..."
    sudo systemctl enable open-iscsi
    sudo systemctl enable multipathd
    print_success "✅ Auto-start configurado"
fi

# Teste de performance opcional
echo ""
echo -n "🧪 Executar testes básicos de performance do storage? [s/N]: "
read -r run_test

if [[ "$run_test" == "s" || "$run_test" == "S" ]]; then
    print_info "🚀 Executando testes básicos de performance..."
    echo ""
    
    DEVICE="/dev/mapper/$MULTIPATH_ALIAS"
    
    # Teste de escrita (pequeno para não impactar)
    print_info "📝 Teste de escrita (10MB)..."
    if timeout 30s sudo dd if=/dev/zero of="$DEVICE" bs=1M count=10 oflag=direct 2>/tmp/dd_test.log; then
        WRITE_SPEED=$(grep -oE '[0-9.]+ [MG]B/s' /tmp/dd_test.log | tail -n1 || echo "N/A")
        print_success "✅ Velocidade de escrita: $WRITE_SPEED"
    else
        print_warning "⚠️  Teste de escrita não concluído"
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
    echo ""
    print_info "💡 Nota: Testes básicos para validação. Performance real pode variar."
fi

print_header "✅ Configuração iSCSI/Multipath Concluída com Sucesso!"

echo ""
print_success "🎯 Resumo da Configuração Finalizada:"

echo ""
echo "📋 Detalhes da Configuração:"
echo "   🎯 Target IQN: $IQN"
echo "   🖥️  Servidor iSCSI: $TARGET_IP:$ISCSI_PORT"
echo "   💾 Dispositivo multipath: /dev/mapper/$MULTIPATH_ALIAS"
echo "   📏 Tamanho do storage: $(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")"
echo "   🔄 Status: $(ls /dev/mapper/$MULTIPATH_ALIAS &>/dev/null && echo "✅ Acessível" || echo "❌ Inacessível")"

echo ""
print_success "📋 Próximos Passos para Cluster GFS2:"
echo "   1️⃣  Execute este script no segundo nó do cluster (fc-test2)"
echo "   2️⃣  Configure cluster Pacemaker/Corosync: install-lun-prerequisites.sh"
echo "   3️⃣  Configure filesystem GFS2: configure-lun-multipath.sh"
echo "   4️⃣  Configure segundo nó: configure-second-node.sh"
echo "   5️⃣  Valide ambiente: test-lun-gfs2.sh"

echo ""
print_success "🔧 Comandos Úteis para Administração:"
echo "   • Verificar sessões iSCSI: sudo iscsiadm -m session"
echo "   • Status do multipath: sudo multipath -ll"
echo "   • Informações do dispositivo: lsblk /dev/mapper/$MULTIPATH_ALIAS"
echo "   • Logs iSCSI: sudo journalctl -u open-iscsi -n 20"
echo "   • Logs multipath: sudo journalctl -u multipathd -n 20"

echo ""
print_success "🎉 Storage iSCSI configurado e pronto para uso em cluster GFS2!"
