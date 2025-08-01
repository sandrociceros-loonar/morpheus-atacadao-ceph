#!/bin/bash

# ============================================================================
# SCRIPT: setup-iscsi-lun.sh
# DESCRIÇÃO: Configuração automática de conectividade iSCSI com discovery
# VERSÃO: 2.3 - Correção Definitiva de Interface
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
    printf "\n"
    printf "========================================================================\n"
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
# SELEÇÃO DO TARGET iSCSI - VERSÃO CORRIGIDA
# ============================================================================

prompt_for_target_ip() {
    # Forçar nova linha e limpeza
    printf "\n"
    
    # Header sem dependência de funções externas
    printf "========================================================================\n"
    printf "🎯 Configuração do Servidor iSCSI Target\n"
    printf "========================================================================\n\n"
    
    printf "Configure o endereço do servidor iSCSI Target:\n\n"
    
    # Exibir opções de forma robusta
    printf "Opções disponíveis:\n\n"
    
    printf "  1️⃣  Usar endereço padrão: %s\n" "$DEFAULT_TGT_IP"
    printf "      • Usa IP padrão configurado no script\n"
    printf "      • Recomendado para ambientes de laboratório padrão\n"
    printf "      • Mais rápido - não requer configuração adicional\n"
    printf "      • Adequado se seu servidor TGT está no IP padrão\n\n"
    
    printf "  2️⃣  Informar endereço personalizado\n"
    printf "      • Permite digitar IP específico do seu servidor iSCSI\n"
    printf "      • Use esta opção se seu TGT tem IP diferente do padrão\n"
    printf "      • Inclui validação de formato de IP (xxx.xxx.xxx.xxx)\n"
    printf "      • Exemplo: 192.168.1.100, 10.0.0.50, etc.\n\n"
    
    printf "  3️⃣  Auto-detectar na rede local\n"
    printf "      • Escaneia rede local procurando servidores iSCSI\n"
    printf "      • Detecta automaticamente TGTs disponíveis\n"
    printf "      • Testa conectividade real na porta 3260\n"
    printf "      • Útil quando não sabe o IP exato do servidor\n\n"
    
    # Loop de seleção com validação
    while true; do
        printf "Selecione uma opção [1-3]: "
        read -r choice
        
        case "$choice" in
            1)
                local target_ip="$DEFAULT_TGT_IP"
                printf "\n"
                print_success "Usando endereço padrão: $target_ip"
                break
                ;;
            2)
                printf "\n📝 Digite o endereço IP do servidor iSCSI Target:\n"
                printf "   Formato esperado: xxx.xxx.xxx.xxx\n"
                printf "   Exemplos válidos: 192.168.1.100, 10.0.0.50, 172.16.1.200\n\n"
                
                while true; do
                    printf "IP do servidor iSCSI: "
                    read -r custom_ip
                    
                    # Validar formato básico de IP
                    if [[ $custom_ip =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
                        # Validar ranges válidos (0-255)
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
                            printf "\n"
                            print_success "Usando endereço personalizado: $target_ip"
                            break 2
                        else
                            printf "\n"
                            print_error "Endereço IP inválido. Cada parte deve estar entre 0 e 255"
                            printf "Exemplo correto: 192.168.1.100\n\n"
                        fi
                    else
                        printf "\n"
                        print_error "Formato inválido. Use formato: xxx.xxx.xxx.xxx"
                        printf "Exemplo: 192.168.1.100\n\n"
                    fi
                done
                ;;
            3)
                printf "\n"
                print_info "🔍 Iniciando auto-detecção de servidores iSCSI na rede local..."
                printf "\n"
                
                local detected_targets
                detected_targets=($(auto_detect_iscsi_servers))
                
                if [[ ${#detected_targets[@]} -eq 0 ]]; then
                    printf "\n"
                    print_warning "Nenhum servidor iSCSI detectado na rede local"
                    printf "\n💡 Dicas para resolver:\n"
                    printf "   • Verifique se o servidor TGT está rodando\n"
                    printf "   • Confirme se está na mesma rede\n"
                    printf "   • Tente as opções 1 ou 2 com IP conhecido\n\n"
                    continue
                elif [[ ${#detected_targets[@]} -eq 1 ]]; then
                    local target_ip="${detected_targets[0]}"
                    printf "\n"
                    print_success "Servidor detectado automaticamente: $target_ip"
                    break
                else
                    printf "\n"
                    print_info "Múltiplos servidores iSCSI detectados:"
                    for i in "${!detected_targets[@]}"; do
                        printf "  %d. %s\n" "$((i + 1))" "${detected_targets[i]}"
                    done
                    printf "\n"
                    
                    while true; do
                        printf "Selecione um servidor (número): "
                        read -r server_choice
                        if [[ "$server_choice" =~ ^[0-9]+$ ]] && [[ "$server_choice" -ge 1 ]] && [[ "$server_choice" -le ${#detected_targets[@]} ]]; then
                            local target_ip="${detected_targets[$((server_choice - 1))]}"
                            printf "\n"
                            print_success "Servidor selecionado: $target_ip"
                            break 2
                        else
                            print_error "Seleção inválida. Digite um número entre 1 e ${#detected_targets[@]}"
                        fi
                    done
                fi
                ;;
            *)
                printf "\n"
                print_error "Opção inválida. Selecione 1, 2 ou 3"
                printf "\n💡 Lembre-se:\n"
                printf "   1 = Endereço padrão (%s)\n" "$DEFAULT_TGT_IP"
                printf "   2 = Endereço personalizado\n"
                printf "   3 = Auto-detecção\n\n"
                ;;
        esac
    done
    
    # Testar conectividade antes de prosseguir
    printf "\n"
    print_info "🔍 Testando conectividade com $target_ip..."
    
    if ping -c 2 "$target_ip" &>/dev/null; then
        print_success "Conectividade TCP confirmada com $target_ip"
        
        # Testar se porta iSCSI está acessível
        print_info "Testando porta iSCSI ($ISCSI_PORT)..."
        if timeout 5s bash -c "</dev/tcp/$target_ip/$ISCSI_PORT" &>/dev/null; then
            print_success "Porta iSCSI ($ISCSI_PORT) acessível e funcionando"
        else
            printf "\n"
            print_warning "Porta iSCSI ($ISCSI_PORT) não está acessível"
            printf "\n⚠️  Possíveis problemas:\n"
            printf "   • Servidor iSCSI não está rodando\n"
            printf "   • Firewall bloqueando porta %s\n" "$ISCSI_PORT"
            printf "   • Servidor TGT parado ou com problemas\n\n"
            
            printf "Continuar mesmo assim? [s/N]: "
            read -r continue_anyway
            if [[ "$continue_anyway" != "s" && "$continue_anyway" != "S" ]]; then
                print_info "Operação cancelada pelo usuário"
                printf "💡 Verifique o servidor TGT e tente novamente\n"
                exit 0
            fi
        fi
    else
        printf "\n"
        print_warning "⚠️  Não foi possível conectar com $target_ip"
        printf "\n🔍 Possíveis problemas:\n"
        printf "   • Servidor está offline ou inaccessível\n"
        printf "   • Problema de rede entre os hosts\n"
        printf "   • IP incorreto ou não existe\n\n"
        
        printf "Continuar mesmo assim? [s/N]: "
        read -r continue_anyway
        if [[ "$continue_anyway" != "s" && "$continue_anyway" != "S" ]]; then
            print_info "Operação cancelada pelo usuário"
            printf "💡 Verifique a conectividade e tente novamente\n"
            exit 0
        fi
    fi
    
    # Resumo da configuração
    printf "\n📋 Resumo da Configuração Confirmada:\n"
    printf "   • Servidor iSCSI Target: %s\n" "$target_ip"
    printf "   • Porta de comunicação: %s\n" "$ISCSI_PORT"
    
    # Status da conectividade
    if ping -c 1 "$target_ip" &>/dev/null; then
        printf "   • Conectividade: ✅ OK\n"
    else
        printf "   • Conectividade: ⚠️  Com avisos\n"
    fi
    
    printf "\n"
    printf "Pressione Enter para continuar com a configuração iSCSI..."
    read -r
    
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
        printf "\n"
        
        local detected=()
        
        # Scan básico dos IPs mais comuns para servers
        local common_server_ips=(1 10 20 50 100 200 250 254)
        
        for ip_suffix in "${common_server_ips[@]}"; do
            local test_ip="$network_base.$ip_suffix"
            
            # Pular IP atual
            if [[ "$test_ip" == "$current_ip" ]]; then
                continue
            fi
            
            printf "   🔍 Testando %s... " "$test_ip"
            
            # Testar conectividade e porta iSCSI
            if timeout 2s bash -c "</dev/tcp/$test_ip/$ISCSI_PORT" &>/dev/null; then
                # Verificar se realmente é servidor iSCSI fazendo discovery
                if timeout 5s iscsiadm -m discovery -t st -p "$test_ip:$ISCSI_PORT" &>/dev/null 2>&1; then
                    detected+=("$test_ip")
                    printf "✅ Servidor iSCSI encontrado!\n"
                else
                    printf "⚠️  Porta aberta mas não é iSCSI\n"
                fi
            else
                printf "❌ Não acessível\n"
            fi
        done
        
        printf "\n"
        
        if [[ ${#detected[@]} -eq 0 ]]; then
            print_info "❌ Nenhum servidor iSCSI detectado na rede $network_base.0/24"
        else
            print_success "Detectados ${#detected[@]} servidores iSCSI na rede"
        fi
        
        echo "${detected[@]}"
    else
        print_warning "Não foi possível determinar rede local para auto-detecção"
        printf "\n"
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
    
    printf "📋 Informações do nó detectadas:\n"
    printf "   • Hostname: %s\n" "$hostname"
    printf "   • IP: %s\n" "$current_ip"
    printf "\n"
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
        printf "\n🔍 Possíveis causas do erro:\n"
        printf "   • Servidor iSCSI não está rodando no host %s\n" "$tgt_ip"
        printf "   • Firewall bloqueando porta %s\n" "$ISCSI_PORT"
        printf "   • IP incorreto ou servidor inacessível\n"
        printf "   • ACL restritivo no servidor Target\n"
        printf "   • Configuração de rede incorreta\n\n"
        printf "💡 Sugestões para resolver:\n"
        printf "   • No servidor TGT, execute: sudo systemctl status tgt\n"
        printf "   • Verifique firewall: sudo ufw status\n"
        printf "   • Teste conectividade: ping %s\n" "$tgt_ip"
        printf "   • Verifique ACL: sudo tgtadm --mode target --op show\n"
        return 1
    fi
    
    if [[ -z "$discovery_output" ]]; then
        print_error "Nenhum target iSCSI encontrado em $tgt_ip"
        printf "\nO servidor respondeu mas não tem targets configurados\n"
        return 1
    fi
    
    print_success "Targets iSCSI descobertos com sucesso!"
    printf "\n"
    
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
            
            printf "   %d️⃣  Portal: %s\n" "$target_count" "$portal"
            printf "        IQN: %s\n\n" "$iqn"
        fi
    done <<< "$discovery_output"
    
    # Seleção automática ou manual do target
    if [[ $target_count -eq 1 ]]; then
        selected_target="${targets_info[0]}"
        local iqn=$(echo "$selected_target" | cut -d'|' -f2)
        print_info "✨ Selecionando automaticamente único target disponível:"
        print_success "IQN: $iqn"
    else
        printf "\n"
        print_info "📝 Múltiplos targets encontrados. Selecione o desejado:"
        while true; do
            printf "Selecione o target desejado (número): "
            read -r choice
            
            if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le $target_count ]]; then
                selected_target="${targets_info[$((choice - 1))]}"
                local iqn=$(echo "$selected_target" | cut -d'|' -f2)
                print_success "Target selecionado: $iqn"
                break
            else
                print_error "Seleção inválida. Digite um número entre 1 e $target_count"
            fi
        done
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
    
    print_info "Configurando InitiatorName único para este nó..."
    echo "InitiatorName=$initiator_name" | sudo tee /etc/iscsi/initiatorname.iscsi > /dev/null
    
    print_success "InitiatorName configurado: $initiator_name"
    
    # Configurar parâmetros iSCSI
    print_info "Aplicando configurações otimizadas para cluster GFS2..."
    
    # Backup da configuração original
    sudo cp /etc/iscsi/iscsid.conf /etc/iscsi/iscsid.conf.backup.$(date +%Y%m%d_%H%M%S) 2>/dev/null || true
    
    # Configurações para ambiente de laboratório
    sudo tee /etc/iscsi/iscsid.conf > /dev/null << 'EOF'
# Configuração otimizada para cluster GFS2
# Gerado automaticamente pelo setup-iscsi-lun.sh

# Configurações básicas
node.startup = automatic
node.leading_login = No

# Configurações de timeout otimizadas para cluster
node.session.timeo.replacement_timeout = 120
node.conn[0].timeo.login_timeout = 15
node.conn[0].timeo.logout_timeout = 15
node.conn[0].timeo.noop_out_interval = 5
node.conn[0].timeo.noop_out_timeout = 5

# Configurações de retry para ambiente cluster
node.session.err_timeo.abort_timeout = 15
node.session.err_timeo.lu_reset_timeout = 30
node.session.err_timeo.tgt_reset_timeout = 30

# Queue depth otimizado para storage compartilhado
node.session.queue_depth = 32

# Configurações de autenticação (desabilitada para laboratório)
node.session.auth.authmethod = None
discovery.sendtargets.auth.authmethod = None

# Configurações adicionais para estabilidade
node.session.initial_login_retry_max = 8
node.conn[0].iscsi.MaxRecvDataSegmentLength = 262144
node.conn[0].iscsi.MaxXmitDataSegmentLength = 0
discovery.sendtargets.iscsi.MaxRecvDataSegmentLength = 32768

# Configurações de sessão para cluster
node.session.scan = auto
EOF
    
    print_success "Configurações iSCSI otimizadas aplicadas"
    
    # Reiniciar serviços
    print_info "Reiniciando serviços iSCSI..."
    sudo systemctl restart open-iscsi
    sudo systemctl restart iscsid
    
    sleep 5
    
    # Verificar se serviços estão ativos
    if systemctl is-active --quiet open-iscsi && systemctl is-active --quiet iscsid; then
        print_success "Serviços iSCSI reiniciados com sucesso"
    else
        print_error "Problemas na reinicialização dos serviços iSCSI"
        return 1
    fi
    
    return 0
}

connect_to_target() {
    local target_info="$1"
    local portal=$(echo "$target_info" | cut -d'|' -f1)
    local iqn=$(echo "$target_info" | cut -d'|' -f2)
    
    print_header "🔗 Conectando ao Target iSCSI"
    
    print_info "Estabelecendo conexão com o target:"
    printf "   • Portal: %s\n" "$portal"
    printf "   • IQN: %s\n\n" "$iqn"
    
    # Fazer login no target
    print_info "Executando login iSCSI..."
    if sudo iscsiadm -m node -T "$iqn" -p "$portal" --login; then
        print_success "Conexão iSCSI estabelecida com sucesso"
    else
        print_error "Falha na conexão com o target iSCSI"
        printf "\n💡 Possíveis soluções:\n"
        printf "   • Verificar ACL no servidor: sudo tgtadm --mode target --op show\n"
        printf "   • Verificar se target está ativo\n"
        printf "   • Reiniciar serviços iSCSI e tentar novamente\n"
        return 1
    fi
    
    # Aguardar dispositivos serem detectados
    print_info "⏳ Aguardando detecção de dispositivos de storage (15s)..."
    sleep 15
    
    # Verificar dispositivos detectados
    print_info "🔍 Verificando dispositivos de storage detectados..."
    local devices=$(lsblk -dn | grep disk | grep -v -E "(loop|sr)" || true)
    
    if [[ -n "$devices" ]]; then
        print_success "Dispositivos de storage detectados:"
        echo "$devices" | while read -r device; do
            local size=$(echo "$device" | awk '{print $4}')
            local name=$(echo "$device" | awk '{print $1}')
            printf "   📀 /dev/%s (Tamanho: %s)\n" "$name" "$size"
        done
    else
        print_warning "Nenhum dispositivo novo detectado após conexão"
        print_info "Isso pode ser normal - dispositivos podem aparecer após configuração do multipath"
    fi
    
    printf "\n"
    
    # Verificar sessões iSCSI ativas
    local sessions_count=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
    print_success "Sessões iSCSI ativas: $sessions_count"
    
    return 0
}

# ============================================================================
# CONFIGURAÇÃO MULTIPATH
# ============================================================================

configure_multipath() {
    print_header "🛣️  Configurando Multipath para Storage Compartilhado"
    
    print_info "🔍 Detectando dispositivos iSCSI para multipath..."
    
    # Detectar dispositivos iSCSI
    local iscsi_devices=($(lsscsi | grep -E "(IET|LIO|SCST)" | awk '{print $6}' | grep -v '^$' || true))
    
    if [[ ${#iscsi_devices[@]} -eq 0 ]]; then
        print_error "Nenhum dispositivo iSCSI detectado para configuração multipath"
        printf "\n🔍 Troubleshooting:\n"
        printf "   • Verificar se conexão iSCSI foi estabelecida: sudo iscsiadm -m session\n"
        printf "   • Listar dispositivos SCSI: lsscsi\n"
        printf "   • Verificar logs: sudo journalctl -u open-iscsi -n 20\n"
        return 1
    fi
    
    print_success "Dispositivos iSCSI detectados para multipath:"
    for device in "${iscsi_devices[@]}"; do
        local size=$(lsblk -dn -o SIZE "$device" 2>/dev/null || echo "N/A")
        local model=$(lsscsi | grep "$device" | awk '{print $3}' || echo "Unknown")
        printf "   📀 %s (Tamanho: %s, Modelo: %s)\n" "$device" "$size" "$model"
    done
    
    # Obter WWID para configuração multipath
    local primary_device="${iscsi_devices[0]}"
    local wwid
    
    print_info "📋 Obtendo WWID do dispositivo primário: $primary_device"
    if wwid=$(sudo /lib/udev/scsi_id -g -u -d "$primary_device" 2>/dev/null); then
        print_success "WWID detectado: $wwid"
    else
        print_error "Falha ao obter WWID do dispositivo $primary_device"
        print_info "Tentando método alternativo..."
        if wwid=$(sudo multipath -v0 -d "$primary_device" 2>/dev/null | head -n1); then
            print_success "WWID obtido via multipath: $wwid"
        else
            print_error "Não foi possível obter WWID do dispositivo"
            return 1
        fi
    fi
    
    print_info "⚙️  Gerando configuração multipath otimizada..."
    
    # Backup da configuração existente
    if [[ -f /etc/multipath.conf ]]; then
        sudo cp /etc/multipath.conf /etc/multipath.conf.backup.$(date +%Y%m%d_%H%M%S)
        print_info "Backup da configuração anterior criado"
    fi
    
    # Criar configuração multipath
    sudo tee /etc/multipath.conf > /dev/null << EOF
# Configuração Multipath para Cluster GFS2
# Gerado automaticamente pelo setup-iscsi-lun.sh
# WWID do dispositivo: $wwid

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
        wwid $wwid
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
    
    # Reiniciar e configurar multipath
    print_info "🔄 Configurando e reiniciando serviços multipath..."
    
    sudo systemctl enable multipathd
    sudo systemctl restart multipathd
    
    # Aguardar multipath processar
    sleep 10
    
    # Forçar recriação de mapas multipath
    print_info "🔄 Forçando recriação de mapas multipath..."
    sudo multipath -F  # Flush all maps
    sudo multipath -r  # Reload and recreate maps
    
    sleep 10
    
    # Verificar se alias foi criado
    if ls /dev/mapper/$MULTIPATH_ALIAS &>/dev/null; then
        local device_info=$(sudo multipath -ll $MULTIPATH_ALIAS 2>/dev/null || echo "Informações não disponíveis")
        print_success "🎉 Dispositivo multipath criado: /dev/mapper/$MULTIPATH_ALIAS"
        printf "\n📊 Informações detalhadas do dispositivo multipath:\n"
        echo "$device_info"
        printf "\n"
        
        # Verificar tamanho e acessibilidade
        local device_size=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")
        print_success "Tamanho do dispositivo: $device_size"
        
    else
        print_warning "Dispositivo multipath não foi criado automaticamente"
        print_info "🔄 Tentando criar mapa manualmente..."
        
        # Tentar criar mapa multipath manualmente
        sudo multipath -a "$primary_device"
        sudo multipath -r
        sleep 10
        
        if ls /dev/mapper/$MULTIPATH_ALIAS &>/dev/null; then
            print_success "✅ Dispositivo multipath criado manualmente"
        else
            print_error "❌ Falha na criação do dispositivo multipath"
            printf "\n🔍 Troubleshooting:\n"
            printf "   • Verificar configuração: sudo multipath -t\n"
            printf "   • Ver mapas ativos: sudo multipath -ll\n"
            printf "   • Logs do multipathd: sudo journalctl -u multipathd -n 20\n"
            return 1
        fi
    fi
    
    return 0
}

# ============================================================================
# VALIDAÇÃO E TESTES
# ============================================================================

validate_configuration() {
    print_header "🔍 Validação Final da Configuração"
    
    # Verificar conectividade iSCSI
    print_info "📡 Verificando sessões iSCSI ativas..."
    local iscsi_sessions=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
    
    if [[ $iscsi_sessions -gt 0 ]]; then
        print_success "✅ $iscsi_sessions sessões iSCSI ativas"
        printf "\n📋 Detalhes das sessões:\n"
        sudo iscsiadm -m session | while read -r session; do
            printf "   🔗 %s\n" "$session"
        done
    else
        print_error "❌ Nenhuma sessão iSCSI ativa"
        return 1
    fi
    
    printf "\n"
    
    # Verificar dispositivo multipath
    print_info "🛣️  Verificando dispositivo multipath..."
    
    if [[ -b "/dev/mapper/$MULTIPATH_ALIAS" ]]; then
        local size=$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS")
        print_success "✅ Dispositivo multipath acessível: /dev/mapper/$MULTIPATH_ALIAS ($size)"
        
        # Testar acesso de leitura
        print_info "🧪 Executando teste de acesso ao dispositivo..."
        if sudo dd if="/dev/mapper/$MULTIPATH_ALIAS" of=/dev/null bs=4k count=1 &>/dev/null; then
            print_success "✅ Teste de leitura no dispositivo: SUCESSO"
        else
            print_error "❌ Falha no teste de leitura do dispositivo"
            return 1
        fi
        
    else
        print_error "❌ Dispositivo multipath não está acessível"
        print_info "💡 Verificar se o dispositivo foi criado: ls -la /dev/mapper/"
        return 1
    fi
    
    printf "\n"
    
    # Verificar multipath status detalhado
    print_info "📊 Status detalhado do multipath:"
    if sudo multipath -ll "$MULTIPATH_ALIAS" &>/dev/null; then
        sudo multipath -ll "$MULTIPATH_ALIAS"
        print_success "✅ Status do multipath obtido com sucesso"
    else
        print_warning "⚠️  Não foi possível obter status detalhado do multipath"
        print_info "Dispositivo pode estar funcionando mesmo assim"
    fi
    
    printf "\n"
    
    # Verificar persistência da configuração
    print_info "🔒 Verificando persistência da configuração..."
    
    if systemctl is-enabled --quiet open-iscsi && systemctl is-enabled --quiet multipathd; then
        print_success "✅ Serviços configurados para inicialização automática"
    else
        print_warning "⚠️  Alguns serviços podem não estar configurados para auto-start"
    fi
    
    return 0
}

test_device_performance() {
    print_info "🚀 Executando testes básicos de performance..."
    printf "\n"
    
    local device="/dev/mapper/$MULTIPATH_ALIAS"
    
    # Teste de escrita (pequeno para não impactar dados)
    print_info "📝 Teste de escrita (10MB)..."
    if timeout 30s sudo dd if=/dev/zero of="$device" bs=1M count=10 oflag=direct 2>/tmp/dd_test.log; then
        local write_speed=$(grep -oE '[0-9.]+ [MG]B/s' /tmp/dd_test.log | tail -n1 || echo "N/A")
        print_success "✅ Velocidade de escrita: $write_speed"
    else
        print_warning "⚠️  Teste de escrita não concluído (timeout ou erro)"
    fi
    
    # Teste de leitura
    print_info "📖 Teste de leitura (10MB)..."
    if timeout 30s sudo dd if="$device" of=/dev/null bs=1M count=10 iflag=direct 2>/tmp/dd_test.log; then
        local read_speed=$(grep -oE '[0-9.]+ [MG]B/s' /tmp/dd_test.log | tail -n1 || echo "N/A")
        print_success "✅ Velocidade de leitura: $read_speed"
    else
        print_warning "⚠️  Teste de leitura não concluído (timeout ou erro)"
    fi
    
    # Limpeza
    sudo rm -f /tmp/dd_test.log 2>/dev/null || true
    
    printf "\n💡 Nota: Testes básicos para validação. Performance real pode variar.\n"
}

# ============================================================================
# FUNÇÃO PRINCIPAL
# ============================================================================

main() {
    print_header "🚀 Setup iSCSI LUN - Configuração Automática"
    
    print_info "Iniciando configuração automatizada de conectividade iSCSI/Multipath..."
    print_info "Este script configura storage compartilhado para clusters GFS2"
    printf "\n"
    
    # Detectar informações do nó
    detect_node_info
    
    # Verificar pré-requisitos
    if ! check_prerequisites; then
        error_exit "❌ Falha na verificação de pré-requisitos do sistema"
    fi
    
    # Solicitar endereço do Target ao usuário
    local tgt_ip
    if ! tgt_ip=$(prompt_for_target_ip); then
        error_exit "❌ Falha na configuração do endereço do Target iSCSI"
    fi
    
    # Discovery automático de targets
    local target_info
    if ! target_info=$(discover_iscsi_targets "$tgt_ip"); then
        error_exit "❌ Falha no discovery de targets iSCSI no servidor $tgt_ip"
    fi
    
    # Configurar initiator iSCSI
    if ! configure_iscsi_initiator; then
        error_exit "❌ Falha na configuração do initiator iSCSI"
    fi
    
    # Conectar ao target
    if ! connect_to_target "$target_info"; then
        error_exit "❌ Falha no estabelecimento da conexão com o target iSCSI"
    fi
    
    # Configurar multipath
    if ! configure_multipath; then
        error_exit "❌ Falha na configuração do multipath para storage compartilhado"
    fi
    
    # Validar configuração
    if ! validate_configuration; then
        error_exit "❌ Falha na validação da configuração final"
    fi
    
    # Teste de performance (opcional)
    printf "\n"
    printf "🧪 Executar testes básicos de performance do storage? [s/N]: "
    read -r run_test
    if [[ "$run_test" == "s" || "$run_test" == "S" ]]; then
        test_device_performance
    fi
    
    # Relatório final
    print_header "✅ Configuração iSCSI/Multipath Concluída com Sucesso!"
    
    printf "\n"
    print_success "🎯 Resumo da Configuração Finalizada:"
    
    local target_iqn=$(echo "$target_info" | cut -d'|' -f2)
    printf "\n📋 Detalhes da Configuração:\n"
    printf "   🎯 Target IQN: %s\n" "$target_iqn"
    printf "   🖥️  Servidor iSCSI: %s:%s\n" "$tgt_ip" "$ISCSI_PORT"
    printf "   💾 Dispositivo multipath: /dev/mapper/%s\n" "$MULTIPATH_ALIAS"
    printf "   📏 Tamanho do storage: %s\n" "$(lsblk -dn -o SIZE "/dev/mapper/$MULTIPATH_ALIAS" 2>/dev/null || echo "N/A")"
    printf "   🔄 Status: %s\n" "$(ls /dev/mapper/$MULTIPATH_ALIAS &>/dev/null && echo "✅ Acessível" || echo "❌ Inacessível")"
    
    printf "\n"
    print_success "📋 Próximos Passos para Cluster GFS2:"
    printf "   1️⃣  Execute este script no segundo nó do cluster (fc-test2)\n"
    printf "   2️⃣  Configure cluster Pacemaker/Corosync: install-lun-prerequisites.sh\n"
    printf "   3️⃣  Configure filesystem GFS2: configure-lun-multipath.sh\n"
    printf "   4️⃣  Configure segundo nó: configure-second-node.sh\n"
    printf "   5️⃣  Valide ambiente: test-lun-gfs2.sh\n"
    
    printf "\n"
    print_success "🔧 Comandos Úteis para Administração:"
    printf "   • Verificar sessões iSCSI: sudo iscsiadm -m session\n"
    printf "   • Status do multipath: sudo multipath -ll\n"
    printf "   • Informações do dispositivo: lsblk /dev/mapper/%s\n" "$MULTIPATH_ALIAS"
    printf "   • Logs iSCSI: sudo journalctl -u open-iscsi -n 20\n"
    printf "   • Logs multipath: sudo journalctl -u multipathd -n 20\n"
    
    printf "\n"
    print_success "🎉 Storage iSCSI configurado e pronto para uso em cluster GFS2!"
}

# ============================================================================
# EXECUÇÃO
# ============================================================================

# Verificar argumentos
case "${1:-}" in
    --help|-h)
        printf "Uso: %s\n\n" "$0"
        printf "Configuração automática de conectividade iSCSI com seleção interativa do Target\n\n"
        printf "Funcionalidades:\n"
        printf "  • Prompt interativo detalhado para seleção do servidor iSCSI Target\n"
        printf "  • Opções: endereço padrão, personalizado ou auto-detecção\n"
        printf "  • Discovery automático de targets iSCSI disponíveis\n"
        printf "  • Configuração otimizada do initiator iSCSI para clusters\n"
        printf "  • Estabelecimento de conexão com target selecionado\n"
        printf "  • Configuração de multipath com alias personalizado\n"
        printf "  • Validação completa e testes opcionais de performance\n\n"
        printf "Melhorias na versão 2.3:\n"
        printf "  • Interface completamente corrigida com printf robusto\n"
        printf "  • Exibição garantida de todas as opções e explicações\n"
        printf "  • Correção de problemas de buffering de terminal\n"
        printf "  • Troubleshooting integrado com sugestões específicas\n"
        printf "  • Logs detalhados e relatórios abrangentes\n\n"
        printf "Autor: sandro.cicero@loonar.cloud\n"
        exit 0
        ;;
    --version)
        printf "setup-iscsi-lun.sh versão 2.3 - Correção Definitiva de Interface\n"
        printf "Autor: sandro.cicero@loonar.cloud\n"
        exit 0
        ;;
    *)
        # Execução normal
        main
        ;;
esac
