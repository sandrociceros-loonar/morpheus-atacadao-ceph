#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# DESCRIÇÃO: Configuração automática de conectividade iSCSI com discovery
# VERSÃO: 2.1 - Discovery Automático com Seleção de Target IP
# AUTOR: sandro.cicero@loonar.cloud
# ============================================================================

# Configurações globais
set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Variáveis padrão
readonly DEFAULT_TGT_IP="192.168.0.250"
readonly ISCSI_PORT="3260"
readonly MULTIPATH_ALIAS="fc-lun-cluster"

# ============================================================================
# FUNÇÕES AUXILIARES
# ============================================================================

print_header() {
    echo -e "\n${BLUE}========================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}========================================================================${NC}\n"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠️  $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${BLUE}ℹ️  $1${NC}"
}

error_exit() {
    print_error "$1"
    exit 1
}

# ============================================================================
# SELEÇÃO DO TARGET iSCSI
# ============================================================================

prompt_for_target_ip() {
    print_header "🎯 Configuração do Servidor iSCSI Target"
    
    print_info "Configure o endereço do servidor iSCSI Target:"
    echo ""
    
    # Mostrar opções disponíveis
    echo "Opções disponíveis:"
    echo "  1. Usar endereço padrão: $DEFAULT_TGT_IP"
    echo "  2. Informar endereço personalizado"
    echo "  3. Auto-detectar na rede local"
    echo ""
    
    while true; do
        read -p "Selecione uma opção [1-3]: " choice
        
        case "$choice" in
            1)
                local target_ip="$DEFAULT_TGT_IP"
                print_success "Usando endereço padrão: $target_ip"
                break
                ;;
            2)
                echo ""
                while true; do
                    read -p "Digite o endereço IP do servidor iSCSI: " custom_ip
                    
                    # Validar formato básico de IP
                    if [[ $custom_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                        # Validar ranges válidos
                        local valid=true
                        IFS='.' read -ra ADDR <<< "$custom_ip"
                        for i in "${ADDR[@]}"; do
                            if [[ $i -lt 0 ]] || [[ $i -gt 255 ]]; then
                                valid=false
                                break
                            fi
                        done
                        
                        if [[ $valid == true ]]; then
                            local target_ip="$custom_ip"
                            print_success "Usando endereço personalizado: $target_ip"
                            break 2
                        else
                            print_error "Endereço IP inválido. Use formato: xxx.xxx.xxx.xxx"
                        fi
                    else
                        print_error "Formato inválido. Use formato: xxx.xxx.xxx.xxx"
                    fi
                done
                ;;
            3)
                print_info "🔍 Auto-detectando servidores iSCSI na rede local..."
                local detected_targets=($(auto_detect_iscsi_servers))
                
                if [[ ${#detected_targets[@]} -eq 0 ]]; then
                    print_warning "Nenhum servidor iSCSI detectado na rede local"
                    print_info "Tente a opção 1 ou 2"
                    continue
                elif [[ ${#detected_targets[@]} -eq 1 ]]; then
                    local target_ip="${detected_targets[0]}"
                    print_success "Servidor detectado automaticamente: $target_ip"
                    break
                else
                    echo ""
                    print_info "Múltiplos servidores iSCSI detectados:"
                    for i in "${!detected_targets[@]}"; do
                        echo "  $((i + 1)). ${detected_targets[i]}"
                    done
                    echo ""
                    
                    while true; do
                        read -p "Selecione um servidor (número): " server_choice
                        if [[ "$server_choice" =~ ^[0-9]+$ ]] && [[ "$server_choice" -ge 1 ]] && [[ "$server_choice" -le ${#detected_targets[@]} ]]; then
                            local target_ip="${detected_targets[$((server_choice - 1))]}"
                            print_success "Servidor selecionado: $target_ip"
                            break 2
                        else
                            print_error "Seleção inválida"
                        fi
                    done
                fi
                ;;
            *)
                print_error "Opção inválida. Selecione 1, 2 ou 3"
                ;;
        esac
    done
    
    # Confirmar conectividade antes de prosseguir
    print_info "Testando conectividade com $target_ip..."
    
    if ping -c 2 "$target_ip" &>/dev/null; then
        print_success "Conectividade confirmada com $target_ip"
        
        # Testar se porta iSCSI está acessível
        if timeout 5s bash -c "</dev/tcp/$target_ip/$ISCSI_PORT" &>/dev/null; then
            print_success "Porta iSCSI ($ISCSI_PORT) acessível"
        else
            print_warning "Porta iSCSI ($ISCSI_PORT) não está acessível"
            echo ""
            read -p "Continuar mesmo assim? [s/N]: " continue_anyway
            if [[ "$continue_anyway" != "s" && "$continue_anyway" != "S" ]]; then
                print_info "Operação cancelada pelo usuário"
                exit 0
            fi
        fi
    else
        print_warning "Não foi possível conectar com $target_ip"
        echo ""
        read -p "Continuar mesmo assim? [s/N]: " continue_anyway
        if [[ "$continue_anyway" != "s" && "$continue_anyway" != "S" ]]; then
            print_info "Operação cancelada pelo usuário"
            exit 0
        fi
    fi
    
    echo ""
    print_info "📋 Configuração confirmada:"
    print_info "   • Servidor iSCSI Target: $target_ip"
    print_info "   • Porta: $ISCSI_PORT"
    echo ""
    
    read -p "Pressione Enter para continuar com a configuração..."
    
    echo "$target_ip"
}

auto_detect_iscsi_servers() {
    local network_base
    local current_ip
    
    # Obter IP atual e calcular rede base
    current_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "")
    
    if [[ -n "$current_ip" ]]; then
        # Extrair os primeiros 3 octetos para scan da rede
        network_base=$(echo "$current_ip" | cut -d'.' -f1-3)
        
        print_info "Escaneando rede $network_base.0/24 por servidores iSCSI..."
        
        local detected=()
        
        # Scan básico dos IPs mais comuns para servers
        local common_server_ips=(1 10 20 50 100 200 250 254)
        
        for ip_suffix in "${common_server_ips[@]}"; do
            local test_ip="$network_base.$ip_suffix"
            
            # Pular IP atual
            if [[ "$test_ip" == "$current_ip" ]]; then
                continue
            fi
            
            # Testar conectividade e porta iSCSI
            if timeout 2s bash -c "</dev/tcp/$test_ip/$ISCSI_PORT" &>/dev/null; then
                # Verificar se realmente é servidor iSCSI fazendo discovery
                if timeout 5s iscsiadm -m discovery -t st -p "$test_ip:$ISCSI_PORT" &>/dev/null; then
                    detected+=("$test_ip")
                    print_info "   ✅ Servidor iSCSI encontrado: $test_ip"
                fi
            fi
        done
        
        if [[ ${#detected[@]} -eq 0 ]]; then
            print_info "   ❌ Nenhum servidor iSCSI detectado na rede local"
        fi
        
        echo "${detected[@]}"
    else
        print_warning "Não foi possível determinar rede local para auto-detecção"
        echo ""
    fi
}

# ============================================================================
# DETECÇÃO E CONFIGURAÇÃO DE AMBIENTE
# ============================================================================

detect_node_info() {
    local current_ip
    current_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "unknown")
    
    local hostname
    hostname=$(hostname -s)
    
    echo "📋 Informações do nó detectadas:"
    echo "   • Hostname: $hostname"
    echo "   • IP: $current_ip"
    echo ""
}

check_prerequisites() {
    print_header "🔍 Verificando Pré-requisitos do Sistema"
    
    # Verificar se é executado como root ou com sudo
    if [[ $EUID -eq 0 ]]; then
        print_warning "Script executado como root. Recomendado usar sudo."
    fi
    
    # Verificar pacotes necessários
    local required_packages=("open-iscsi" "multipath-tools" "lvm2")
    local missing_packages=()
    
    for package in "${required_packages[@]}"; do
        if ! dpkg -l | grep -q "^ii  $package "; then
            missing_packages+=("$package")
        fi
    done
    
    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        print_warning "Pacotes ausentes: ${missing_packages[*]}"
        print_info "Instalando pacotes necessários..."
        
        sudo apt update -qq
        for package in "${missing_packages[@]}"; do
            print_info "Instalando $package..."
            if sudo apt install -y "$package" &>/dev/null; then
                print_success "$package instalado com sucesso"
            else
                error_exit "Falha ao instalar $package"
            fi
        done
    else
        print_success "Todos os pacotes necessários estão instalados"
    fi
    
    # Verificar serviços
    print_info "Verificando serviços iSCSI..."
    sudo systemctl enable open-iscsi &>/dev/null
    sudo systemctl start open-iscsi &>/dev/null
    
    sudo systemctl enable multipath-tools &>/dev/null
    sudo systemctl start multipath-tools &>/dev/null
    
    print_success "Pré-requisitos verificados"
    return 0
}

# ============================================================================
# DISCOVERY AUTOMÁTICO DE TARGETS iSCSI
# ============================================================================

discover_iscsi_targets() {
    local tgt_ip="$1"
    
    print_header "🔍 Discovery Automático de Targets iSCSI"
    
    print_info "Descobrindo targets iSCSI disponíveis em $tgt_ip:$ISCSI_PORT..."
    
    # Limpar descobertas anteriores
    sudo iscsiadm -m discovery -o delete 2>/dev/null || true
    
    # Discovery dos targets disponíveis
    local discovery_output
    if ! discovery_output=$(sudo iscsiadm -m discovery -t st -p "$tgt_ip:$ISCSI_PORT" 2>/dev/null); then
        print_error "Falha no discovery de targets iSCSI"
        print_info "Possíveis causas:"
        echo "   • Servidor iSCSI não está rodando"
        echo "   • Firewall bloqueando porta $ISCSI_PORT"
        echo "   • IP incorreto: $tgt_ip"
        echo "   • ACL restritivo no servidor Target"
        return 1
    fi
    
    if [[ -z "$discovery_output" ]]; then
        print_error "Nenhum target iSCSI encontrado em $tgt_ip"
        return 1
    fi
    
    print_success "Targets iSCSI descobertos:"
    echo ""
    
    local target_count=0
    local selected_target=""
    local targets_info=()
    
    # Processar output do discovery
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local portal=$(echo "$line" | awk '{print $1}')
            local iqn=$(echo "$line" | awk '{print $2}')
            
            ((target_count++))
            targets_info+=("$portal|$iqn")
            
            echo "   $target_count. Portal: $portal"
            echo "      IQN: $iqn"
            echo ""
        fi
    done <<< "$discovery_output"
    
    # Seleção automática ou manual do target
    if [[ $target_count -eq 1 ]]; then
        selected_target="${targets_info[0]}"
        local iqn=$(echo "$selected_target" | cut -d'|' -f2)
        print_info "Selecionando automaticamente único target disponível:"
        print_success "IQN: $iqn"
    else
        echo ""
        read -p "Selecione o target desejado (número): " choice
        
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $target_count ]]; then
            selected_target="${targets_info[$((choice - 1))]}"
            local iqn=$(echo "$selected_target" | cut -d'|' -f2)
            print_success "Target selecionado: $iqn"
        else
            print_error "Seleção inválida"
            return 1
        fi
    fi
    
    # Retornar informações do target selecionado
    echo "$selected_target"
    return 0
}

# ============================================================================
# CONFIGURAÇÃO iSCSI
# ============================================================================

configure_iscsi_initiator() {
    print_header "🔧 Configurando iSCSI Initiator"
    
    # Gerar InitiatorName único baseado no hostname
    local hostname=$(hostname -s)
    local initiator_name="iqn.2004-10.com.ubuntu:01:$(openssl rand -hex 6):$hostname"
    
    print_info "Configurando InitiatorName..."
    echo "InitiatorName=$initiator_name" | sudo tee /etc/iscsi/initiatorname.iscsi > /dev/null
    
    print_success "InitiatorName configurado: $initiator_name"
    
    # Configurar parâmetros iSCSI
    print_info "Configurando parâmetros iSCSI..."
    
    # Configurações para ambiente de laboratório
    sudo tee /etc/iscsi/iscsid.conf > /dev/null << 'EOF'
# Configuração otimizada para cluster GFS2
node.startup = automatic
node.leading_login = No

# Configurações de timeout
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5

# Configurações de retry
node.session.err_timeo.abort_timeout = 15
node.session.err_timeo.lu_reset_timeout = 30
node.session.err_timeo.tgt_reset_timeout = 30

# Queue depth
node.session.queue_depth = 32

# Configurações de autenticação (desabilitada para laboratório)
node.session.auth.authmethod = None
discovery.sendtargets.auth.authmethod = None
EOF
    
    print_success "Configurações iSCSI aplicadas"
    
    # Reiniciar serviços
    print_info "Reiniciando serviços iSCSI..."
    sudo systemctl restart open-iscsi
    sudo systemctl restart iscsid
    
    sleep 3
    
    print_success "Serviços iSCSI reiniciados"
    return 0
}

connect_to_target() {
    local target_info="$1"
    local portal=$(echo "$target_info" | cut -d'|' -f1)
    local iqn=$(echo "$target_info" | cut -d'|' -f2)
    
    print_header "🔗 Conectando ao Target iSCSI"
    
    print_info "Conectando ao target:"
    echo "   • Portal: $portal"
    echo "   • IQN: $iqn"
    
    # Fazer login no target
    if sudo iscsiadm -m node -T "$iqn" -p "$portal" --login; then
        print_success "Conexão estabelecida com sucesso"
    else
        print_error "Falha na conexão com o target"
        return 1
    fi
    
    # Aguardar dispositivos serem detectados
    print_info "Aguardando detecção de dispositivos (10s)..."
    sleep 10
    
    # Verificar dispositivos detectados
    local devices=$(lsblk -dn | grep disk | grep -v -E "(loop|sr)" || true)
    if [[ -n "$devices" ]]; then
        print_success "Dispositivos detectados:"
        echo "$devices" | while read -r device; do
            echo "   • $device"
        done
    else
        print_warning "Nenhum dispositivo novo detectado"
    fi
    
    return 0
}

# ============================================================================
# CONFIGURAÇÃO MULTIPATH
# ============================================================================

configure_multipath() {
    print_header "🛣️  Configurando Multipath"
    
    print_info "Verificando dispositivos iSCSI..."
    
    # Detectar dispositivos iSCSI
    local iscsi_devices=($(lsscsi | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | grep -v '^$' || true))
    
    if [[ ${#iscsi_devices[@]} -eq 0 ]]; then
        print_error "Nenhum dispositivo iSCSI detectado"
        print_info "Verifique se a conexão iSCSI foi estabelecida corretamente"
        return 1
    fi
    
    print_success "Dispositivos iSCSI detectados:"
    for device in "${iscsi_devices[@]}"; do
        local size=$(lsblk -dn -o SIZE "$device" 2>/dev/null || echo "N/A")
        echo "   • $device (Tamanho: $size)"
    done
    
    # Obter WWID para configuração multipath
    local primary_device="${iscsi_devices[0]}"
    local wwid
    if wwid=$(sudo /lib/udev/scsi_id -g -u -d "$primary_device" 2>/dev/null); then
        print_success "WWID detectado: $wwid"
    else
        print_error "Falha ao obter WWID do dispositivo"
        return 1
    fi
    
    print_info "Configurando multipath.conf..."
    
    # Criar configuração multipath
    sudo tee /etc/multipath.conf > /dev/null << EOF
# Configuração Multipath para Cluster GFS2
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "^$"
    
    # Configurações para ambiente de cluster
    checker_timeout 60
    max_polling_interval 20
    
    # Configurações de path failure
    dev_loss_tmo infinity
    fast_io_fail_tmo 5
}

blacklist {
    # Blacklist dispositivos locais comuns
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^cciss!c[0-9]d[0-9]*"
    
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
        wwid $wwid
        alias $MULTIPATH_ALIAS
        path_grouping_policy multibus
        path_checker tur
        failback immediate
        rr_weight priorities
        no_path_retry queue
        rr_min_io 100
    }
}

# Configurações específicas para iSCSI
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
}
EOF
    
    print_success "multipath.conf configurado"
    
    # Reiniciar e configurar multipath
    print_info "Configurando serviço multipath..."
    
    sudo systemctl enable multipathd
    sudo systemctl restart multipathd
    
    # Aguardar multipath processar
    sleep 5
    
    # Forçar recriação de mapas
    sudo multipath -F
    sudo multipath -r
    
    sleep 5
    
    # Verificar se alias foi criado
    if ls /dev/mapper/$MULTIPATH_ALIAS &>/dev/null; then
        local device_info=$(sudo multipath -ll $MULTIPATH_ALIAS 2>/dev/null || echo "Informação não disponível")
        print_success "Dispositivo multipath criado: /dev/mapper/$MULTIPATH_ALIAS"
        echo ""
        print_info "Informações do dispositivo multipath:"
        echo "$device_info"
    else
        print_error "Falha ao criar dispositivo multipath"
        print_info "Tentando criar manualmente..."
        
        # Tentar criar mapa multipath manualmente
        sudo multipath -a "$primary_device"
        sudo multipath -r
        sleep 5
        
        if ls /dev/mapper/$MULTIPATH_ALIAS &>/dev/null; then
            print_success "Dispositivo multipath criado manualmente"
        else
            print_error "Falha na criação do dispositivo multipath"
            return 1
        fi
    fi
    
    return 0
}

# ============================================================================
# VALIDAÇÃO E TESTES
# ============================================================================

validate_configuration() {
    print_header "🔍 Validando Configuração iSCSI/Multipath"
    
    # Verificar conectividade iSCSI
    print_info "Verificando sessões iSCSI ativas..."
    local iscsi_sessions=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
    
    if [[ $iscsi_sessions -gt 0 ]]; then
        print_success "$iscsi_sessions sessões iSCSI ativas"
        sudo iscsiadm -m session | while read -r session; do
            echo "   • $session"
        done
    else
        print_error "Nenhuma sessão iSCSI ativa"
        return 1
    fi
    
    echo ""
    
    # Verificar dispositivo multipath
    print_info "Verificando dispositivo multipath..."
    
    if [[ -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        local size=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS")
        print_success "Dispositivo multipath acessível: /dev/mapper/$MULTIPATH_ALIAS ($size)"
        
        # Testar acesso de leitura
        if sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 &>/dev/null; then
            print_success "Teste de leitura no dispositivo: OK"
        else
            print_error "Falha no teste de leitura do dispositivo"
            return 1
        fi
        
    else
        print_error "Dispositivo multipath não está acessível"
        return 1
    fi
    
    echo ""
    
    # Verificar multipath status
    print_info "Status detalhado do multipath:"
    sudo multipath -ll "$MULTIPATH_ALIAS" 2>/dev/null || {
        print_warning "Não foi possível obter status detalhado do multipath"
    }
    
    return 0
}

test_device_performance() {
    print_info "Executando teste básico de performance..."
    
    local test_file="/tmp/iscsi_performance_test"
    local device="/dev/mapper/$MULTIPATH_ALIAS"
    
    # Teste de escrita (pequeno para não impactar)
    if timeout 30s sudo dd if=/dev/zero of="$device" bs=1M count=10 oflag=direct 2>/tmp/dd_test.log; then
        local write_speed=$(grep -oE '[0-9.]+ [MG]B/s' /tmp/dd_test.log | tail -n1)
        print_success "Teste de escrita: $write_speed"
    else
        print_warning "Teste de escrita não concluído"
    fi
    
    # Teste de leitura
    if timeout 30s sudo dd if="$device" of=/dev/null bs=1M count=10 iflag=direct 2>/tmp/dd_test.log; then
        local read_speed=$(grep -oE '[0-9.]+ [MG]B/s' /tmp/dd_test.log | tail -n1)
        print_success "Teste de leitura: $read_speed"
    else
        print_warning "Teste de leitura não concluído"
    fi
    
    # Limpeza
    sudo rm -f /tmp/dd_test.log "$test_file" 2>/dev/null || true
}

# ============================================================================
# FUNÇÃO PRINCIPAL
# ============================================================================

main() {
    print_header "🚀 Setup iSCSI LUN - Configuração Automática"
    
    print_info "Iniciando configuração iSCSI/Multipath..."
    
    # Detectar informações do nó
    detect_node_info
    
    # Verificar pré-requisitos
    if ! check_prerequisites; then
        error_exit "Falha na verificação de pré-requisitos"
    fi
    
    # Solicitar endereço do Target ao usuário
    local tgt_ip
    if ! tgt_ip=$(prompt_for_target_ip); then
        error_exit "Falha na configuração do endereço do Target"
    fi
    
    # Discovery automático de targets
    local target_info
    if ! target_info=$(discover_iscsi_targets "$tgt_ip"); then
        error_exit "Falha no discovery de targets iSCSI"
    fi
    
    # Configurar initiator iSCSI
    if ! configure_iscsi_initiator; then
        error_exit "Falha na configuração do initiator iSCSI"
    fi
    
    # Conectar ao target
    if ! connect_to_target "$target_info"; then
        error_exit "Falha na conexão com o target iSCSI"
    fi
    
    # Configurar multipath
    if ! configure_multipath; then
        error_exit "Falha na configuração do multipath"
    fi
    
    # Validar configuração
    if ! validate_configuration; then
        error_exit "Falha na validação da configuração"
    fi
    
    # Teste de performance (opcional)
    read -p "Executar teste básico de performance? [s/N]: " run_test
    if [[ "$run_test" == "s" || "$run_test" == "S" ]]; then
        test_device_performance
    fi
    
    # Relatório final
    print_header "✅ Configuração iSCSI/Multipath Concluída"
    
    echo ""
    print_success "🎯 Resumo da Configuração:"
    
    local target_iqn=$(echo "$target_info" | cut -d'|' -f2)
    print_info "   • Target IQN: $target_iqn"
    print_info "   • Servidor: $tgt_ip:$ISCSI_PORT"
    print_info "   • Dispositivo multipath: /dev/mapper/$MULTIPATH_ALIAS"
    print_info "   • Tamanho: $(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")"
    
    echo ""
    print_success "📋 Próximos Passos:"
    print_info "   1. Execute este script no outro nó do cluster"
    print_info "   2. Configure cluster Pacemaker/Corosync"
    print_info "   3. Execute: install-lun-prerequisites.sh"
    print_info "   4. Configure GFS2 com: configure-lun-multipath.sh"
    
    echo ""
    print_info "🔧 Comandos úteis:"
    print_info "   • Verificar sessões: sudo iscsiadm -m session"
    print_info "   • Status multipath: sudo multipath -ll"
    print_info "   • Dispositivo: ls -la /dev/mapper/$MULTIPATH_ALIAS"
    
    print_success "🎉 Setup iSCSI concluído com sucesso!"
}

# ============================================================================
# EXECUÇÃO
# ============================================================================

# Verificar argumentos
case "${1:-}" in
    --help|-h)
        echo "Uso: $0"
        echo ""
        echo "Configuração automática de conectividade iSCSI com seleção interativa do Target"
        echo ""
        echo "Este script:"
        echo "  • Solicita ao usuário o endereço do servidor iSCSI Target"
        echo "  • Oferece opções: endereço padrão, personalizado ou auto-detecção"
        echo "  • Descobre automaticamente targets iSCSI disponíveis"
        echo "  • Configura initiator iSCSI com parâmetros otimizados"
        echo "  • Estabelece conexão com o target selecionado"
        echo "  • Configura multipath com alias personalizado"
        echo "  • Valida configuração e testa acesso ao dispositivo"
        echo ""
        echo "Melhorias na versão 2.1:"
        echo "  • Prompt interativo para seleção do Target IP"
        echo "  • Auto-detecção de servidores iSCSI na rede"
        echo "  • Validação de IP e conectividade antes de prosseguir"
        exit 0
        ;;
    --version)
        echo "setup-iscsi-lun.sh versão 2.1 - Discovery com Seleção de Target IP"
        exit 0
        ;;
    *)
        # Execução normal
        main
        ;;
esac
