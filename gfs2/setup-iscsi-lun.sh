#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# DESCRIÇÃO: Configuração automática de conectividade iSCSI com discovery
# VERSÃO: 2.4 - Correção Definitiva de Travamento
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
    printf "\n========================================================================\n"
    printf "%s\n" "$1"
    printf "========================================================================\n\n"
}

print_success() {
    printf "\033[0;32m✅ %s\033[0m\n" "$1"
}

print_warning() {
    printf "\033[1;33m⚠️  %s\033[0m\n" "$1"
}

print_error() {
    printf "\033[0;31m❌ %s\033[0m\n" "$1"
}

print_info() {
    printf "\033[0;34mℹ️  %s\033[0m\n" "$1"
}

error_exit() {
    print_error "$1"
    exit 1
}

# ============================================================================
# SELEÇÃO DO TARGET iSCSI - VERSÃO SIMPLIFICADA E ROBUSTA
# ============================================================================

select_target_ip() {
    printf "\n========================================================================\n"
    printf "🎯 Configuração do Servidor iSCSI Target\n"
    printf "========================================================================\n\n"
    
    printf "Configure o endereço do servidor iSCSI Target:\n\n"
    
    printf "Opções disponíveis:\n\n"
    printf "  1️⃣  Usar endereço padrão: %s\n" "$DEFAULT_TGT_IP"
    printf "      • Recomendado para ambientes de laboratório\n"
    printf "      • Configuração mais rápida\n\n"
    
    printf "  2️⃣  Informar endereço personalizado\n"
    printf "      • Digite o IP específico do seu servidor TGT\n"
    printf "      • Use se seu servidor tem IP diferente do padrão\n\n"
    
    printf "  3️⃣  Auto-detectar na rede local\n"
    printf "      • Busca automática por servidores iSCSI\n"
    printf "      • Útil quando não sabe o IP exato\n\n"
    
    while true; do
        printf "Selecione uma opção [1-3]: "
        read -r choice
        
        case "$choice" in
            1)
                TARGET_IP="$DEFAULT_TGT_IP"
                printf "\n✅ Usando endereço padrão: %s\n" "$TARGET_IP"
                break
                ;;
            2)
                printf "\nDigite o endereço IP do servidor iSCSI: "
                read -r custom_ip
                
                # Validação básica de IP
                if [[ $custom_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                    TARGET_IP="$custom_ip"
                    printf "✅ Usando endereço personalizado: %s\n" "$TARGET_IP"
                    break
                else
                    printf "❌ IP inválido. Formato correto: xxx.xxx.xxx.xxx\n\n"
                fi
                ;;
            3)
                printf "\n🔍 Buscando servidores iSCSI na rede local...\n"
                TARGET_IP=$(auto_detect_servers)
                if [[ -n "$TARGET_IP" ]]; then
                    printf "✅ Servidor detectado: %s\n" "$TARGET_IP"
                    break
                else
                    printf "❌ Nenhum servidor encontrado. Usando padrão: %s\n" "$DEFAULT_TGT_IP"
                    TARGET_IP="$DEFAULT_TGT_IP"
                    break
                fi
                ;;
            *)
                printf "❌ Opção inválida. Digite 1, 2 ou 3.\n\n"
                ;;
        esac
    done
    
    # Testar conectividade
    printf "\n🔍 Testando conectividade com %s...\n" "$TARGET_IP"
    if ping -c 2 "$TARGET_IP" >/dev/null 2>&1; then
        printf "✅ Conectividade confirmada\n"
    else
        printf "⚠️  Aviso: Não foi possível fazer ping para %s\n" "$TARGET_IP"
        printf "Continuar mesmo assim? [s/N]: "
        read -r continue_choice
        if [[ "$continue_choice" != "s" && "$continue_choice" != "S" ]]; then
            printf "Operação cancelada.\n"
            exit 0
        fi
    fi
    
    printf "\n📋 IP do Target configurado: %s\n" "$TARGET_IP"
    printf "Pressione Enter para continuar..."
    read -r
}

auto_detect_servers() {
    local current_ip
    current_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "")
    
    if [[ -n "$current_ip" ]]; then
        local network_base
        network_base=$(echo "$current_ip" | cut -d'.' -f1-3)
        
        local common_ips=(1 10 50 100 200 250 254)
        
        for ip_suffix in "${common_ips[@]}"; do
            local test_ip="$network_base.$ip_suffix"
            
            if [[ "$test_ip" != "$current_ip" ]]; then
                printf "   Testando %s... " "$test_ip"
                if timeout 2s bash -c "</dev/tcp/$test_ip/$ISCSI_PORT" 2>/dev/null; then
                    if timeout 3s iscsiadm -m discovery -t st -p "$test_ip:$ISCSI_PORT" >/dev/null 2>&1; then
                        printf "Encontrado!\n"
                        echo "$test_ip"
                        return 0
                    fi
                fi
                printf "Não\n"
            fi
        done
    fi
    
    echo ""
}

# ============================================================================
# DETECÇÃO E CONFIGURAÇÃO DE AMBIENTE
# ============================================================================

detect_node_info() {
    local current_ip
    current_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "unknown")
    
    local hostname
    hostname=$(hostname -s)
    
    printf "📋 Informações do nó:\n"
    printf "   • Hostname: %s\n" "$hostname"
    printf "   • IP: %s\n\n" "$current_ip"
}

check_prerequisites() {
    print_header "🔍 Verificando Pré-requisitos do Sistema"
    
    if [[ $EUID -eq 0 ]]; then
        print_warning "Script executado como root. Recomendado usar sudo."
    fi
    
    # Verificar e instalar pacotes necessários
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
            if sudo apt install -y "$package" >/dev/null 2>&1; then
                print_success "$package instalado com sucesso"
            else
                error_exit "Falha ao instalar $package"
            fi
        done
    else
        print_success "Todos os pacotes necessários estão instalados"
    fi
    
    # Inicializar serviços
    print_info "Verificando serviços iSCSI..."
    sudo systemctl enable open-iscsi >/dev/null 2>&1
    sudo systemctl start open-iscsi >/dev/null 2>&1
    sudo systemctl enable multipath-tools >/dev/null 2>&1
    sudo systemctl start multipath-tools >/dev/null 2>&1
    
    print_success "Pré-requisitos verificados"
}

# ============================================================================
# DISCOVERY E CONEXÃO iSCSI
# ============================================================================

discover_and_connect() {
    local target_ip="$1"
    
    print_header "🔍 Discovery e Conexão iSCSI"
    
    print_info "Descobrindo targets em $target_ip:$ISCSI_PORT..."
    
    # Limpar descobertas anteriores
    sudo iscsiadm -m discovery -o delete >/dev/null 2>&1 || true
    
    # Fazer discovery
    local discovery_output
    if ! discovery_output=$(sudo iscsiadm -m discovery -t st -p "$target_ip:$ISCSI_PORT" 2>/dev/null); then
        error_exit "Falha no discovery de targets iSCSI em $target_ip"
    fi
    
    if [[ -z "$discovery_output" ]]; then
        error_exit "Nenhum target encontrado em $target_ip"
    fi
    
    print_success "Targets descobertos:"
    printf "%s\n\n" "$discovery_output"
    
    # Processar targets descobertos
    local target_count=0
    local selected_target=""
    local targets_array=()
    
    while IFS= read -r line; do
        if [[ -n "$line" ]]; then
            local portal=$(echo "$line" | awk '{print $1}')
            local iqn=$(echo "$line" | awk '{print $2}')
            ((target_count++))
            targets_array+=("$portal|$iqn")
            printf "   %d. Portal: %s\n      IQN: %s\n\n" "$target_count" "$portal" "$iqn"
        fi
    done <<< "$discovery_output"
    
    # Seleção do target
    if [[ $target_count -eq 1 ]]; then
        selected_target="${targets_array[0]}"
        print_info "Selecionando automaticamente o único target disponível"
    else
        while true; do
            printf "Selecione o target desejado [1-%d]: " "$target_count"
            read -r target_choice
            
            if [[ "$target_choice" =~ ^[0-9]+$ ]] && [[ "$target_choice" -ge 1 ]] && [[ "$target_choice" -le $target_count ]]; then
                selected_target="${targets_array[$((target_choice - 1))]}"
                break
            else
                printf "❌ Seleção inválida\n"
            fi
        done
    fi
    
    # Conectar ao target selecionado
    local portal=$(echo "$selected_target" | cut -d'|' -f1)
    local iqn=$(echo "$selected_target" | cut -d'|' -f2)
    
    print_info "Conectando ao target: $iqn"
    
    if sudo iscsiadm -m node -T "$iqn" -p "$portal" --login; then
        print_success "Conexão estabelecida com sucesso"
    else
        error_exit "Falha na conexão com o target"
    fi
    
    # Aguardar detecção de dispositivos
    print_info "Aguardando detecção de dispositivos (10s)..."
    sleep 10
    
    # Verificar dispositivos
    local sessions=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
    print_success "Sessões iSCSI ativas: $sessions"
}

# ============================================================================
# CONFIGURAÇÃO iSCSI INITIATOR
# ============================================================================

configure_initiator() {
    print_header "🔧 Configurando iSCSI Initiator"
    
    # Gerar InitiatorName único
    local hostname=$(hostname -s)
    local initiator_name="iqn.2004-10.com.ubuntu:01:$(openssl rand -hex 6):$hostname"
    
    print_info "Configurando InitiatorName único..."
    echo "InitiatorName=$initiator_name" | sudo tee /etc/iscsi/initiatorname.iscsi >/dev/null
    print_success "InitiatorName: $initiator_name"
    
    # Configurar parâmetros iSCSI
    print_info "Aplicando configurações otimizadas..."
    
    sudo tee /etc/iscsi/iscsid.conf >/dev/null << 'EOF'
# Configuração otimizada para cluster GFS2
node.startup = automatic
node.leading_login = No

# Timeouts otimizados
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

# Autenticação desabilitada
node.session.auth.authmethod = None
discovery.sendtargets.auth.authmethod = None
EOF
    
    print_success "Configurações aplicadas"
    
    # Reiniciar serviços
    print_info "Reiniciando serviços iSCSI..."
    sudo systemctl restart open-iscsi
    sudo systemctl restart iscsid
    sleep 3
    
    print_success "Serviços reiniciados"
}

# ============================================================================
# CONFIGURAÇÃO MULTIPATH
# ============================================================================

configure_multipath() {
    print_header "🛣️  Configurando Multipath"
    
    print_info "Detectando dispositivos iSCSI..."
    
    # Detectar dispositivos iSCSI
    local iscsi_devices
    iscsi_devices=($(lsscsi | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | grep -v '^$' || true))
    
    if [[ ${#iscsi_devices[@]} -eq 0 ]]; then
        error_exit "Nenhum dispositivo iSCSI detectado"
    fi
    
    print_success "Dispositivos detectados:"
    for device in "${iscsi_devices[@]}"; do
        local size=$(lsblk -dn -o SIZE "$device" 2>/dev/null || echo "N/A")
        printf "   📀 %s (%s)\n" "$device" "$size"
    done
    
    # Obter WWID
    local primary_device="${iscsi_devices[0]}"
    local wwid
    
    print_info "Obtendo WWID do dispositivo $primary_device..."
    if wwid=$(sudo /lib/udev/scsi_id -g -u -d "$primary_device" 2>/dev/null); then
        print_success "WWID: $wwid"
    else
        error_exit "Falha ao obter WWID"
    fi
    
    # Criar configuração multipath
    print_info "Criando configuração multipath..."
    
    sudo tee /etc/multipath.conf >/dev/null << EOF
# Configuração Multipath para Cluster GFS2
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "^$"
    checker_timeout 60
    max_polling_interval 20
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
        no_path_retry queue
        rr_min_io 100
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
    }
}
EOF
    
    print_success "Configuração criada"
    
    # Reiniciar multipath
    print_info "Configurando serviços multipath..."
    sudo systemctl enable multipathd
    sudo systemctl restart multipathd
    
    sleep 5
    
    # Recriar mapas
    sudo multipath -F
    sudo multipath -r
    sleep 5
    
    # Verificar se dispositivo foi criado
    if [[ -e "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        local size=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")
        print_success "Dispositivo criado: /dev/mapper/$MULTIPATH_ALIAS ($size)"
    else
        error_exit "Falha na criação do dispositivo multipath"
    fi
}

# ============================================================================
# VALIDAÇÃO FINAL
# ============================================================================

validate_setup() {
    print_header "🔍 Validação Final"
    
    # Verificar sessões iSCSI
    local sessions=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
    if [[ $sessions -gt 0 ]]; then
        print_success "Sessões iSCSI ativas: $sessions"
    else
        print_error "Nenhuma sessão iSCSI ativa"
        return 1
    fi
    
    # Verificar dispositivo multipath
    if [[ -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        local size=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS")
        print_success "Dispositivo multipath: /dev/mapper/$MULTIPATH_ALIAS ($size)"
        
        # Teste de leitura
        if sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 >/dev/null 2>&1; then
            print_success "Teste de leitura: OK"
        else
            print_error "Falha no teste de leitura"
            return 1
        fi
    else
        print_error "Dispositivo multipath não acessível"
        return 1
    fi
    
    # Verificar multipath status
    print_info "Status do multipath:"
    sudo multipath -ll "$MULTIPATH_ALIAS" 2>/dev/null || print_warning "Status não disponível"
    
    return 0
}

# ============================================================================
# FUNÇÃO PRINCIPAL - SIMPLIFICADA
# ============================================================================

main() {
    print_header "🚀 Setup iSCSI LUN - Configuração Automática"
    
    print_info "Configuração automatizada de storage iSCSI para cluster GFS2"
    printf "\n"
    
    # Detectar informações do nó
    detect_node_info
    
    # Verificar pré-requisitos
    check_prerequisites
    
    # Configurar initiator
    configure_initiator
    
    # Seleção do Target IP
    select_target_ip
    
    # Discovery e conexão
    discover_and_connect "$TARGET_IP"
    
    # Configurar multipath
    configure_multipath
    
    # Validar configuração
    if ! validate_setup; then
        error_exit "❌ Falha na validação da configuração"
    fi
    
    # Relatório final
    print_header "✅ Configuração Concluída com Sucesso!"
    
    printf "\n📋 Resumo da Configuração:\n"
    printf "   • Servidor iSCSI: %s:%s\n" "$TARGET_IP" "$ISCSI_PORT"
    printf "   • Dispositivo multipath: /dev/mapper/%s\n" "$MULTIPATH_ALIAS"
    printf "   • Tamanho: %s\n" "$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")"
    
    printf "\n📋 Próximos Passos:\n"
    printf "   1. Execute este script no segundo nó (fc-test2)\n"
    printf "   2. Configure cluster: install-lun-prerequisites.sh\n"
    printf "   3. Configure GFS2: configure-lun-multipath.sh\n"
    
    print_success "🎉 Storage iSCSI pronto para cluster GFS2!"
}

# ============================================================================
# EXECUÇÃO
# ============================================================================

case "${1:-}" in
    --help|-h)
        printf "Uso: %s\n\n" "$0"
        printf "Configuração automática de conectividade iSCSI para cluster GFS2\n\n"
        printf "Funcionalidades:\n"
        printf "  • Seleção interativa do servidor iSCSI Target\n"
        printf "  • Discovery automático de targets disponíveis\n"
        printf "  • Configuração otimizada do initiator\n"
        printf "  • Configuração de multipath com alias personalizado\n"
        printf "  • Validação completa da configuração\n\n"
        printf "Versão 2.4 - Correção de travamento e interface simplificada\n"
        printf "Autor: sandro.cicero@loonar.cloud\n"
        exit 0
        ;;
    --version)
        printf "setup-iscsi-lun.sh v2.4 - Correção Definitiva\n"
        printf "Autor: sandro.cicero@loonar.cloud\n"
        exit 0
        ;;
    *)
        main
        ;;
esac
