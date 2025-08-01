#!/bin/bash

# ============================================================================
# SCRIPT: install-lun-prerequisites.sh
# DESCRIÇÃO: Instalação e configuração de pré-requisitos para GFS2 Enterprise
# VERSÃO: 2.0 - Enterprise Cluster Ready
# AUTOR: DevOps Team
# ============================================================================

# Configurações globais
set -euo pipefail

# Cores para output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

#TODO: solicitar os nomes dos hosts e obter os IPs correspondentes
# Variáveis do cluster
readonly CLUSTER_NAME="cluster_gfs2"
readonly NODE1_IP="10.113.221.240"
readonly NODE2_IP="10.113.221.241"
readonly NODE1_NAME="srvmvm001a"
readonly NODE2_NAME="srvmvm001b"

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
# DETECÇÃO DE AMBIENTE E NÓ
# ============================================================================

detect_node_role() {
    local current_ip
    current_ip=$(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo "unknown")
    
    if [[ "$current_ip" == "$NODE1_IP" ]]; then
        echo "primary"
    elif [[ "$current_ip" == "$NODE2_IP" ]]; then
        echo "secondary"
    else
        echo "unknown"
    fi
}

get_current_hostname() {
    hostname -s
}

# ============================================================================
# VERIFICAÇÕES PRÉ-REQUISITOS
# ============================================================================

check_prerequisites() {
    print_header "🔍 Verificando Pré-requisitos do Sistema"
    
    # Verificar se é executado como root
    if [[ $EUID -eq 0 ]]; then
        print_warning "Script executado como root. Recomendado usar sudo."
    fi
    
    # Verificar conectividade de rede
    local other_node
    if [[ "$(detect_node_role)" == "primary" ]]; then
        other_node="$NODE2_NAME"
    else
        other_node="$NODE1_NAME"
    fi
    
    if ! ping -c 2 "$other_node" &>/dev/null; then
        print_error "Não foi possível conectar com $other_node"
        print_info "Verifique conectividade de rede entre os nós"
        return 1
    fi
    
    print_success "Conectividade com $other_node verificada"
    
    # Verificar resolução DNS
    if ! nslookup "$other_node" &>/dev/null; then
        print_warning "Resolução DNS pode estar comprometida"
        print_info "Verificar entradas em /etc/hosts"
    fi
    
    # Verificar espaço em disco
    local available_space
    available_space=$(df / | tail -1 | awk '{print $4}')
    if [[ $available_space -lt 1000000 ]]; then
        print_warning "Pouco espaço em disco disponível: ${available_space}KB"
    fi
    
    print_success "Pré-requisitos básicos verificados"
    return 0
}

# ============================================================================
# INSTALAÇÃO DE PACOTES
# ============================================================================

install_packages() {
    print_header "📦 Instalando Pacotes Necessários"
    
    # Atualizar repositórios
    print_info "Atualizando repositórios..."
    sudo apt update -qq
    
    # Lista de pacotes essenciais
    local packages=(
        "gfs2-utils"
        "corosync"
        "pacemaker"
        "pcs"
        "dlm-controld"
        "lvm2-lockd"
        "multipath-tools"
        "open-iscsi"
        "fence-agents"
        "resource-agents"
    )
    
    print_info "Instalando pacotes GFS2 e Cluster..."
    for package in "${packages[@]}"; do
        if dpkg -l | grep -q "^ii  $package "; then
            print_success "$package já instalado"
        else
            print_info "Instalando $package..."
            if sudo apt install -y "$package" &>/dev/null; then
                print_success "$package instalado com sucesso"
            else
                print_error "Falha ao instalar $package"
                return 1
            fi
        fi
    done
    
    # Configurar senha do hacluster se necessário
    if ! sudo passwd -S hacluster 2>/dev/null | grep -q "hacluster P"; then
        print_info "Configurando senha do usuário hacluster..."
        echo 'hacluster:hacluster' | sudo chpasswd
        print_success "Senha do hacluster configurada"
    fi
    
    print_success "Todos os pacotes instalados com sucesso"
    return 0
}

# ============================================================================
# CONFIGURAÇÃO DE CLUSTER ENTERPRISE
# ============================================================================
# 
# STONITH (Shoot The Other Node In The Head):
#   - PRODUÇÃO: Obrigatório para isolamento de nós com falha
#   - LABORATÓRIO: Desabilitado (sem dispositivos de fencing)
#   - STAGING: Opcional dependendo da infraestrutura
#
# NO-QUORUM-POLICY:
#   - PRODUÇÃO: 'stop' ou 'freeze' (para em caso de perda de quorum)
#   - LABORATÓRIO: 'ignore' (continua operando para testes)
#   - DOIS NÓS: Sempre 'ignore' (qualquer falha causa perda de quorum)
#
# REFERÊNCIAS:
#   - Red Hat HA-Cluster: https://access.redhat.com/documentation/
#   - Pacemaker Documentation: https://clusterlabs.org/pacemaker/doc/
# ============================================================================

configure_cluster_properties() {
    print_info "Configurando propriedades do cluster..."
    
    # Configurações essenciais para laboratório/desenvolvimento
    print_info "📋 Aplicando configurações para ambiente de laboratório..."
    
    # STONITH - Desabilitar para laboratório (sem dispositivos de fencing)
    if sudo pcs property set stonith-enabled=false; then
        print_success "STONITH desabilitado (adequado para laboratório)"
    else
        print_warning "Falha ao desabilitar STONITH"
        return 1
    fi
    
    # Quorum Policy - Ignorar para clusters de 2 nós
    if sudo pcs property set no-quorum-policy=ignore; then
        print_success "Política de quorum configurada para 2 nós"
    else
        print_warning "Falha ao configurar política de quorum"
        return 1
    fi
    
    # Configurações adicionais de robustez
    sudo pcs property set start-failure-is-fatal=false    # Não para cluster por falhas
    sudo pcs property set symmetric-cluster=true          # Recursos podem rodar em qualquer nó
    sudo pcs property set maintenance-mode=false          # Garantir modo operacional
    sudo pcs property set enable-startup-probes=true      # Verificações de inicialização
    
    print_success "Propriedades do cluster configuradas com sucesso"
    
    # Verificar configurações aplicadas
    echo ""
    print_info "📊 Propriedades atuais do cluster:"
    sudo pcs property show | grep -E "(stonith-enabled|no-quorum-policy|start-failure-is-fatal)" || true
    
    return 0
}

configure_cluster_resources() {
    print_info "Configurando recursos DLM e lvmlockd..."
    
    # Aguardar cluster estabilizar
    sleep 15
    
    # Configurar recurso DLM
    if ! sudo pcs resource show dlm-clone &>/dev/null; then
        print_info "🔒 Criando recurso DLM..."
        if sudo pcs resource create dlm systemd:dlm \
            op monitor interval=60s on-fail=fence \
            clone interleave=true ordered=true; then
            print_success "Recurso DLM criado"
        else
            print_error "Falha ao criar recurso DLM"
            return 1
        fi
    else
        print_success "Recurso DLM já existe"
    fi
    
    # Configurar recurso lvmlockd
    if ! sudo pcs resource show lvmlockd-clone &>/dev/null; then
        print_info "💾 Criando recurso lvmlockd..."
        if sudo pcs resource create lvmlockd systemd:lvmlockd \
            op monitor interval=60s on-fail=fence \
            clone interleave=true ordered=true; then
            print_success "Recurso lvmlockd criado"
        else
            print_error "Falha ao criar recurso lvmlockd"
            return 1
        fi
    else
        print_success "Recurso lvmlockd já existe"
    fi
    
    # Configurar dependências entre recursos
    print_info "🔗 Configurando dependências de recursos..."
    sudo pcs constraint order start dlm-clone \
        && lvmlockd-clone 2>/dev/null || true
    sudo pcs constraint colocation add lvmlockd-clone with dlm-clone 2>/dev/null || true
    
    print_success "Recursos configurados com sucesso"
    
    # Aguardar recursos ficarem ativos
    print_info "⏳ Aguardando recursos ficarem ativos (60s)..."
    sleep 60
    
    return 0
}

configure_enterprise_cluster() {
    print_header "🏢 Configurando Cluster Enterprise (Pacemaker/Corosync + DLM)"
    
    local node_role
    node_role=$(detect_node_role)
    
    case "$node_role" in
        "primary")
            print_info "🎯 Detectado como nó PRIMÁRIO ($NODE1_NAME): $NODE1_IP"
            ;;
        "secondary")
            print_info "🎯 Detectado como nó SECUNDÁRIO ($NODE2_NAME): $NODE2_IP"
            ;;
        *)
            print_error "Não foi possível detectar o papel do nó"
            print_info "IPs esperados: $NODE1_IP (primário) ou $NODE2_IP (secundário)"
            return 1
            ;;
    esac
    
    # Verificar se cluster já existe
    if sudo pcs status &>/dev/null; then
        print_warning "Cluster já configurado. Verificando status..."
        sudo pcs status
        return 0
    fi
    
    # Configurar apenas no nó primário
    if [[ "$node_role" == "primary" ]]; then
        print_info "🔧 Configurando cluster no nó primário..."
        
        # Garantir que pcsd está ativo em ambos os nós
        sudo systemctl start pcsd
        sudo systemctl enable pcsd
        
        print_info "Verificando pcsd no nó secundário..."
        if ssh "$NODE2_NAME" "sudo systemctl start pcsd && sudo systemctl enable pcsd" 2>/dev/null; then
            print_success "pcsd ativo em ambos os nós"
        else
            print_error "Não foi possível iniciar pcsd no $NODE2_NAME"
            return 1
        fi
        
        # Aguardar pcsd estabilizar
        sleep 10
        
        # Autenticar nós
        print_info "🔐 Autenticando nós do cluster..."
        if echo "hacluster" | sudo pcs host auth "$NODE1_NAME" "$NODE2_NAME" -u hacluster; then
            print_success "Nós autenticados com sucesso"
        else
            print_error "Falha na autenticação dos nós"
            print_info "💡 Verifique se a senha do hacluster está igual em ambos os nós"
            return 1
        fi
        
        # Criar cluster com IPs específicos
        print_info "🏗️  Criando cluster com IPs reais..."
        if sudo pcs cluster setup "$CLUSTER_NAME" \
            "$NODE1_NAME" addr="$NODE1_IP" \
            "$NODE2_NAME" addr="$NODE2_IP"; then
            print_success "Cluster criado com sucesso"
        else
            print_error "Falha ao criar cluster"
            return 1
        fi
        
        # Iniciar cluster
        print_info "▶️  Iniciando cluster..."
        sudo pcs cluster start --all
        sudo pcs cluster enable --all
        
        # Aguardar cluster estabilizar
        print_info "⏳ Aguardando cluster estabilizar (30s)..."
        sleep 30
        
        # Configurar propriedades do cluster
        if ! configure_cluster_properties; then
            print_error "Falha ao configurar propriedades do cluster"
            return 1
        fi
        
        # Configurar recursos do cluster
        if ! configure_cluster_resources; then
            print_error "Falha ao configurar recursos do cluster"
            return 1
        fi
        
        # Verificar status final
        echo ""
        print_info "📊 Status final do cluster:"
        sudo pcs status
        
        # Validar configuração
        if validate_cluster_configuration; then
            print_success "Cluster configurado com sucesso!"
            print_success "Ambos os nós estão online"
            print_success "Recursos DLM e lvmlockd ativos"
        else
            print_warning "Cluster criado mas verificar status dos nós"
            return 1
        fi
        
    else
        print_info "⏳ Aguardando configuração do cluster pelo nó primário..."
        
        # Aguardar cluster ser configurado pelo nó primário
        local timeout=180
        local count=0
        while ! sudo pcs status &>/dev/null && [[ $count -lt $timeout ]]; do
            echo "   Aguardando cluster... ($count/${timeout}s)"
            sleep 10
            ((count+=10))
        done
        
        if sudo pcs status &>/dev/null; then
            print_success "Cluster detectado! Verificando participação..."
            sudo pcs status
        else
            print_error "Timeout: Cluster não foi detectado após ${timeout}s"
            return 1
        fi
    fi
    
    return 0
}

validate_cluster_configuration() {
    print_info "🔍 Validando configuração do cluster..."
    
    # Verificar STONITH
    local stonith_status
    stonith_status=$(sudo pcs property show stonith-enabled 2>/dev/null | awk '/stonith-enabled/ {print $2}' || echo "unknown")
    if [[ "$stonith_status" == "false" ]]; then
        print_success "STONITH adequadamente desabilitado para laboratório"
    else
        print_warning "STONITH habilitado - verificar dispositivos de fencing"
    fi
    
    # Verificar Quorum Policy
    local quorum_policy
    quorum_policy=$(sudo pcs property show no-quorum-policy 2>/dev/null | awk '/no-quorum-policy/ {print $2}' || echo "unknown")
    if [[ "$quorum_policy" == "ignore" ]]; then
        print_success "Política de quorum adequada para cluster de 2 nós"
    else
        print_warning "Política de quorum pode causar problemas em cluster de 2 nós"
    fi
    
    # Verificar se ambos os nós estão online
    if sudo pcs status | grep -q "Online:.*$NODE1_NAME.*$NODE2_NAME" || sudo pcs status | grep -q "Online:.*$NODE2_NAME.*$NODE1_NAME"; then
        print_success "Ambos os nós estão online"
        return 0
    else
        print_error "Nem todos os nós estão online"
        return 1
    fi
}

# ============================================================================
# CONFIGURAÇÃO DE STORAGE LVM
# ============================================================================

detect_available_devices() {
    print_header "💾 Detectando Devices de Storage Disponíveis"
    
    local devices=()
    local processed_devices=()
    
    # Função auxiliar para verificar e adicionar device
    check_and_add_device() {
        local device="$1"
        local type="$2"
        local real_device
        
        print_info "Tentando adicionar device: $device (tipo: $type)"
        
        # Resolver link simbólico para o device real
        real_device=$(readlink -f "$device")
        print_info "Device real: $real_device"
        
        # Verificar se já processamos este device
        for processed in "${processed_devices[@]}"; do
            if [[ "$processed" == "$real_device" ]]; then
                print_info "Device já processado anteriormente: $real_device"
                return 0
            fi
        done
        processed_devices+=("$real_device")
        
        # Debug: mostrar device sendo processado
        print_info "Verificando device: $device (real: $real_device)"
        
        if [[ -b "$device" ]]; then
            local size
            size=$(lsblk -dn -o SIZE "$device" 2>/dev/null || echo "N/A")
            local wwn
            wwn=$(lsblk -dn -o WWN "$device" 2>/dev/null || echo "N/A")
            local dm_name
            dm_name=$(readlink -f "$device" 2>/dev/null | xargs basename 2>/dev/null || echo "unknown")
            local mountpoint
            mountpoint=$(lsblk -dn -o MOUNTPOINT "$device" 2>/dev/null || echo "")
            local vendor
            vendor=$(lsblk -dn -o VENDOR "$device" 2>/dev/null | tr -d ' ' || echo "N/A")
            local model
            model=$(lsblk -dn -o MODEL "$device" 2>/dev/null | tr -d ' ' || echo "N/A")
            
            # Verificar se é um device do sistema ou já está em uso
            print_info "Verificando device $device:"
            print_info "  - Mountpoint: '$mountpoint'"
            print_info "  - Size: $size"
            print_info "  - WWN: $wwn"
            print_info "  - Vendor: $vendor"
            print_info "  - Model: $model"
            
            # Verificar se é um device do sistema ou já está em uso como PV
            local is_pv=false
            if pvs "$device" &>/dev/null; then
                is_pv=true
                print_warning "Device $device já em uso como Physical Volume"
            fi
            
            if [[ -z "$mountpoint" ]] && [[ "$is_pv" == "false" ]]; then
                local info="$device - Tamanho: $size"
                [[ "$wwn" != "N/A" ]] && info+=" - WWN: $wwn"
                [[ "$vendor" != "N/A" ]] && info+=" - Vendor: $vendor"
                [[ "$model" != "N/A" ]] && info+=" - Model: $model"
                [[ "$type" == "multipath" ]] && info+=" - DM: $dm_name"
                
                echo "==== DEBUG: Adicionando device ====" >&2
                devices+=("$info")
                echo "Device adicionado ao array: $info" >&2
                echo "Tamanho atual do array: ${#devices[@]}" >&2
                print_success "✅ Device $type adicionado: $info" >&2
            else
                if [[ -n "$mountpoint" ]]; then
                    print_warning "Device $device montado em $mountpoint"
                fi
            fi
        fi
    }
    
    # Procurar por devices multipath
    print_info "Procurando devices multipath..." >&2
    shopt -s nullglob
    
    # Debug: mostrar saída do comando multipath -ll
    print_info "Saída do multipath -ll:" >&2
    sudo multipath -ll >&2
    
    print_info "Conteúdo do /dev/mapper:" >&2
    ls -l /dev/mapper/ >&2
    
    print_info "Procurando devices multipath ativos..."
    
    # Primeiro, procurar o device específico fc-lun-cluster
    if [[ -b "/dev/mapper/fc-lun-cluster" ]]; then
        print_info "🎯 Encontrado device fc-lun-cluster"
        check_and_add_device "/dev/mapper/fc-lun-cluster" "multipath"
    else
        print_warning "Device /dev/mapper/fc-lun-cluster não encontrado como block device"
        
        # Tentar usando o device mapper diretamente
        if [[ -b "/dev/dm-0" ]]; then
            print_info "🔍 Encontrado device /dev/dm-0"
            check_and_add_device "/dev/dm-0" "multipath"
        fi
    fi
    
    # Depois, procurar outros devices multipath
    local mpaths
    mpaths=$(sudo multipath -l)
    print_info "Saída completa do multipath -l:"
    echo "$mpaths"
    
    while IFS= read -r line; do
        # Debug da linha atual
        print_info "Processando linha: $line"
        
        if [[ $line =~ ^([[:alnum:]_-]+)[[:space:]] ]]; then
            local mp_name="${BASH_REMATCH[1]}"
            local mp_device="/dev/mapper/$mp_name"
            
            print_info "Encontrado nome multipath: $mp_name"
            print_info "Verificando device: $mp_device"
            
            if [[ -b "$mp_device" ]]; then
                print_info "Encontrado device multipath ativo: $mp_device"
                check_and_add_device "$mp_device" "multipath"
            else
                print_info "Device $mp_device não existe como block device"
            fi
        fi
    done < <(echo "$mpaths" | grep "^[[:alnum:]_-]" || true)
    
    # Procurar por LUNs em /dev/disk/by-id (especialmente wwn e scsi)
    print_info "Procurando LUNs por WWN e SCSI ID..."
    for device in /dev/disk/by-id/wwn-* /dev/disk/by-id/scsi-*; do
        check_and_add_device "$device" "wwn/scsi"
    done
    
    # Procurar por LUNs em /dev/disk/by-path
    print_info "Procurando LUNs por path..."
    for device in /dev/disk/by-path/*; do
        if [[ "$device" =~ -lun- ]]; then
            check_and_add_device "$device" "path"
        fi
    done
    
    # Procurar por devices físicos adequados (excluir disco do sistema)
    print_info "Procurando devices físicos..."
    for device in /dev/sd[b-z]; do
        check_and_add_device "$device" "physical"
    done
    
    if [[ ${#devices[@]} -eq 0 ]]; then
        print_error "Nenhum device disponível encontrado"
        return 1
    fi
    
    # Debug: mostrar todos os devices encontrados
    echo -e "\n==== DEBUG: Início da lista de devices ====" >&2
    echo "Total de devices encontrados: ${#devices[@]}" >&2
    if [[ ${#devices[@]} -gt 0 ]]; then
        print_info "Devices candidatos detectados:" >&2
        for i in "${!devices[@]}"; do
            echo "$((i + 1)). ${devices[i]}" >&2
        done
    else
        print_warning "Nenhum device na lista devices[]" >&2
    fi
    echo "==== DEBUG: Fim da lista de devices ====" >&2

    # Selecionar device automaticamente ou manualmente
    local selected_device
    if [[ ${#devices[@]} -eq 1 ]]; then
        selected_device=$(echo "${devices[0]}" | awk '{print $1}')
        print_info "Selecionando automaticamente único device: $selected_device"
    else
        echo ""
        read -p "Selecione o device para criar VG compartilhado (número): " choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [[ "$choice" -ge 1 ]] && [[ "$choice" -le ${#devices[@]} ]]; then
            selected_device=$(echo "${devices[$((choice - 1))]}" | awk '{print $1}')
            print_info "Device selecionado: $selected_device"
        else
            print_error "Seleção inválida"
            return 1
        fi
    fi
    
    echo "$selected_device"
    return 0
}

configure_lvm_cluster() {
    print_header "⚙️  Configurando LVM para Cluster"
    
    # Verificar e configurar DLM se necessário
    print_info "Verificando status do DLM..."
    if ! sudo pcs resource show dlm-clone &>/dev/null; then
        print_info "Recurso DLM não encontrado. Criando..."
        if sudo pcs resource create dlm systemd:dlm \
            op monitor interval=60s on-fail=fence \
            clone interleave=true ordered=true; then
            print_success "Recurso DLM criado"
            sleep 10
        else
            print_error "Falha ao criar recurso DLM"
            return 1
        fi
    fi
    
    # Aguardar DLM iniciar
    print_info "Aguardando DLM ficar ativo..."
    local max_wait=30
    local count=0
    while ! sudo pcs status | grep -q "dlm.*Started"; do
        sleep 2
        ((count+=2))
        if [[ $count -ge $max_wait ]]; then
            print_error "Timeout aguardando DLM ficar ativo"
            return 1
        fi
        echo -n "."
    done
    echo ""
    print_success "DLM está ativo"
    
    # Verificar e configurar lvmlockd como recurso do cluster
    print_info "Verificando status do lvmlockd..."
    if ! sudo pcs resource show lvmlockd-clone &>/dev/null; then
        print_info "Configurando lvmlockd como recurso do cluster..."
        if sudo pcs resource create lvmlockd systemd:lvmlockd \
            op monitor interval=60s on-fail=fence \
            clone interleave=true ordered=true; then
            print_success "Recurso lvmlockd criado"
            
            # Configurar dependência com DLM
            sudo pcs constraint order "start dlm-clone then lvmlockd-clone"
            sudo pcs constraint colocation add "lvmlockd-clone with dlm-clone"
            
            sleep 10
        else
            print_error "Falha ao criar recurso lvmlockd"
            return 1
        fi
    fi
    
    # Aguardar lvmlockd iniciar
    print_info "Aguardando lvmlockd ficar ativo..."
    local max_wait=30
    local count=0
    while ! sudo pcs status | grep -q "lvmlockd.*Started"; do
        sleep 2
        ((count+=2))
        if [[ $count -ge $max_wait ]]; then
            print_error "Timeout aguardando lvmlockd ficar ativo"
            return 1
        fi
        echo -n "."
    done
    echo ""
    print_success "lvmlockd está ativo"
    
    # Detectar device disponível
    local selected_device
    if ! selected_device=$(detect_available_devices); then
        print_error "Falha na detecção de devices"
        return 1
    fi
    
    # Configurar LVM para cluster
    print_info "Configurando LVM para uso em cluster..."
    
    # Verificar se lvm.conf está configurado para cluster
    if ! grep -q "use_lvmlockd = 1" /etc/lvm/lvm.conf 2>/dev/null; then
        print_info "Configurando /etc/lvm/lvm.conf para cluster..."
        sudo sed -i 's/use_lvmlockd = 0/use_lvmlockd = 1/' /etc/lvm/lvm.conf 2>/dev/null || true
        sudo sed -i 's/# use_lvmlockd = 1/use_lvmlockd = 1/' /etc/lvm/lvm.conf 2>/dev/null || true
        
        # Se não encontrou a linha, adicionar
        if ! grep -q "use_lvmlockd" /etc/lvm/lvm.conf; then
            sudo sed -i '/global {/a\    use_lvmlockd = 1' /etc/lvm/lvm.conf
        fi
        
        print_success "LVM configurado para cluster"
    else
        print_success "LVM já configurado para cluster"
    fi
    
    # Verificar se Volume Group já existe
    local vg_name="vg_cluster"
    local lv_name="lv_gfs2"
    
    if sudo vgs "$vg_name" &>/dev/null; then
        print_info "Volume Group '$vg_name' já existe"
        
        # Verificar se está em modo cluster
        local lock_type
        lock_type=$(sudo vgs --noheadings -o lock_type "$vg_name" 2>/dev/null | tr -d ' ' || echo "none")
        
        if [[ "$lock_type" != "dlm" ]]; then
            print_warning "Volume Group existente não está em modo cluster"
            print_info "Removendo Volume Group antigo..."
            
            # Desativar e remover VG existente
            sudo vgchange -an "$vg_name" 2>/dev/null || true
            sudo vgremove -f "$vg_name" 2>/dev/null || true
            sudo pvremove -f "$selected_device" 2>/dev/null || true
            
            # Recriar como cluster
            print_info "Recriando Volume Group em modo cluster..."
            
            # Forçar cleanup de locks
            print_info "Limpando locks existentes..."
            sudo vgchange --lockstop "$vg_name" 2>/dev/null || true
            sudo lvmlockctl --stop 2>/dev/null || true
            sudo systemctl restart lvmlockd 2>/dev/null || true
            sleep 5
            
            # Desativar VG primeiro
            print_info "Desativando Volume Group temporariamente..."
            sudo vgchange -an "$vg_name" || true
            
            # Converter para DLM com força
            print_info "Tentando converter para DLM..."
            if sudo vgchange --locktype dlm "$vg_name" --yes; then
                print_success "Volume Group convertido para modo cluster"
            else
                print_error "Falha ao converter Volume Group para modo cluster"
                print_info "Tentando método alternativo..."
                
                # Método alternativo: remover e recriar metadados de lock
                if sudo vgchange --locktype none "$vg_name" && \
                   sudo vgchange --locktype dlm "$vg_name" --yes; then
                    print_success "Volume Group convertido para modo cluster (método alternativo)"
                else
                    print_error "Falha ao converter Volume Group para modo cluster"
                    return 1
                fi
            fi
        fi
        
        # Iniciar locks com retry
        print_info "Iniciando locks do Volume Group..."
        local max_retries=3
        local retry_count=0
        local success=false
        
        while [[ $retry_count -lt $max_retries ]]; do
            if sudo vgchange --lockstart "$vg_name"; then
                print_success "Locks do Volume Group iniciados"
                success=true
                break
            else
                ((retry_count++))
                print_warning "Tentativa $retry_count de $max_retries falhou"
                print_info "Aguardando 5 segundos antes de tentar novamente..."
                sleep 5
                
                # Tentar reiniciar serviços relevantes
                sudo systemctl restart lvmlockd 2>/dev/null || true
                sudo vgchange --lockstop "$vg_name" 2>/dev/null || true
            fi
        done
        
        if [[ "$success" != "true" ]]; then
            print_warning "Falha ao iniciar locks após $max_retries tentativas"
            print_info "Tentando fallback para modo local..."
            # Converter para modo local como fallback
            if sudo vgchange --locktype none "$vg_name" 2>/dev/null; then
                print_warning "Convertido para modo local (sem locks distribuídos)"
            else
                print_error "Falha ao converter para modo local"
                return 1
            fi
        fi
        
        # Ativar Volume Group
        if sudo vgchange -ay "$vg_name"; then
            print_success "Volume Group ativado"
        else
            print_error "Falha ao ativar Volume Group"
            return 1
        fi
        
    else
        print_info "Criando novo Volume Group cluster-aware..."
        
        local device_size
        device_size=$(lsblk -dn -o SIZE "$selected_device" | tr -d ' ')
        print_info "Device selecionado: $selected_device"
        print_info "Tamanho total do device: $device_size"
        print_info "Será usado TODO o espaço disponível para máximo aproveitamento."
        
        echo ""
        read -p "Criar VG '$vg_name' e LV '$lv_name' usando todo o espaço no device $selected_device? [s/N]: " confirm
        if [[ "$confirm" != "s" && "$confirm" != "S" ]]; then
            print_info "Operação cancelada pelo usuário"
            return 1
        fi
        
        # Criar Physical Volume
        if sudo pvcreate -y "$selected_device"; then
            print_success "Physical Volume criado: $selected_device"
        else
            print_error "Falha ao criar Physical Volume"
            return 1
        fi
        
        # Criar Volume Group cluster-aware com DLM desde o início
        print_info "Criando Volume Group com suporte a cluster..."
        if sudo vgcreate --shared --locktype dlm "$vg_name" "$selected_device"; then
            print_success "Volume Group cluster-aware criado: $vg_name"
            
            # Iniciar locks imediatamente
            if sudo vgchange --lockstart "$vg_name"; then
                print_success "Locks iniciados com sucesso"
            else
                print_error "Falha ao iniciar locks"
                return 1
            fi
        else
            print_error "Falha ao criar Volume Group"
            return 1
        fi
        
        # Ativar Volume Group
        sudo vgchange -ay "$vg_name"
        
        # Criar Logical Volume usando todo o espaço
        if sudo lvcreate -l 100%FREE -n "$lv_name" "$vg_name"; then
            print_success "Logical Volume criado: /dev/$vg_name/$lv_name"
        else
            print_error "Falha ao criar Logical Volume"
            return 1
        fi
    fi
    
    # Verificar resultado final
    print_info "📊 Configuração final do LVM:"
    sudo vgs "$vg_name" || true
    sudo lvs "$vg_name" || true
    
    print_success "Configuração de LVM cluster concluída"
    return 0
}

# ============================================================================
# CONFIGURAÇÃO DO ARQUIVO COROSYNC
# ============================================================================

# Configuração do corosync.conf para incluir os nós corretamente
configure_corosync() {
    print_header "🔧 Configurando corosync.conf"

    local corosync_file="/etc/corosync/corosync.conf"

    if [[ ! -f "$corosync_file" ]]; then
        print_error "Arquivo corosync.conf não encontrado em $corosync_file"
        return 1
    fi

    # Backup do arquivo original
    sudo cp "$corosync_file" "${corosync_file}.backup.$(date +%F_%T)"
    print_success "Backup do corosync.conf criado"

    # Adicionando configuração correta
    sudo bash -c "cat > $corosync_file" <<EOF
    totem {
        version: 2
        secauth: on
        cluster_name: $CLUSTER_NAME
        transport: udpu
    }

    nodelist {
        node {
            ring0_addr: $NODE1_NAME
            nodeid: 1
        }
        node {
            ring0_addr: $NODE2_NAME
            nodeid: 2
        }
    }

    quorum {
        provider: corosync_votequorum
        two_node: 1
    }
EOF

    print_success "Arquivo corosync.conf configurado com sucesso"
    return 0
}

# ============================================================================
# FUNÇÃO PRINCIPAL
# ============================================================================

main() {
    print_header "🚀 Instalação de Pré-requisitos GFS2 Enterprise"
    
    print_info "Iniciando configuração para ambiente enterprise..."
    print_info "Nó atual: $(get_current_hostname)"
    print_info "IP detectado: $(ip route get 8.8.8.8 2>/dev/null | awk '/src/ {print $7}' || echo 'N/A')"
    
    # Verificar pré-requisitos
    if ! check_prerequisites; then
        error_exit "Falha na verificação de pré-requisitos"
    fi
    
    # Instalar pacotes necessários
    if ! install_packages; then
        error_exit "Falha na instalação de pacotes"
    fi
    
    # Configurar cluster enterprise
    if ! configure_enterprise_cluster; then
        print_error "Erro na configuração do cluster"
        print_info "💡 Você pode continuar com configuração local, mas perderá recursos enterprise"
        read -p "Continuar com configuração local (sem cluster)? [s/N]: " continue_local
        if [[ "$continue_local" == "s" || "$continue_local" == "S" ]]; then
            print_info "Prosseguindo com configuração local..."
        else
            error_exit "Configuração do cluster falhou"
        fi
    fi
    
    # Configurar storage LVM
    if ! configure_lvm_cluster; then
        error_exit "Falha na configuração de storage LVM"
    fi
    
    # Configurar corosync
    if ! configure_corosync; then
        error_exit "Falha na configuração do corosync"
    fi
    
    # Relatório final
    print_header "✅ Instalação Concluída com Sucesso!"
    
    echo ""
    print_success "🏢 Cluster Enterprise Configurado:"
    print_info "   • Pacemaker/Corosync: Ativo"
    print_info "   • DLM distribuído: Configurado"
    print_info "   • lvmlockd cluster-aware: Ativo"
    print_info "   • Storage compartilhado: Pronto"
    
    echo ""
    print_success "📋 Próximos Passos:"
    print_info "   1. Execute o mesmo script no outro nó"
    print_info "   2. Execute: configure-lun-multipath.sh (formatação GFS2)"
    print_info "   3. Execute: configure-second-node.sh (montagem)"
    print_info "   4. Teste: test-lun-gfs2.sh (validação)"
    
    echo ""
    print_info "📊 Verificação do cluster:"
    sudo pcs status 2>/dev/null || print_warning "Use 'sudo pcs status' para verificar cluster"
    
    print_success "🎉 Ambiente enterprise pronto para GFS2!"
}

# Adicione esta função no início do script
check_dlm_support() {
    print_header "🔍 Verificando Suporte a DLM no Kernel"
    
    # Verificar se módulo DLM existe
    if ! find /lib/modules/$(uname -r) -name "*dlm*" 2>/dev/null | grep -q dlm; then
        print_error "Módulo DLM não encontrado no kernel $(uname -r)"
        print_info "Soluções possíveis:"
        print_info "1. sudo apt install linux-generic linux-modules-extra-$(uname -r)"
        print_info "2. sudo apt install --install-recommends linux-generic-hwe-22.04"
        print_info "3. Reiniciar e usar kernel com suporte completo"
        return 1
    fi
    
    # Tentar carregar módulo DLM
    if ! sudo modprobe dlm 2>/dev/null; then
        print_error "Não foi possível carregar módulo DLM"
        return 1
    fi
    
    print_success "Módulo DLM disponível e carregado"
    return 0
}

# Chame esta função antes de configurar o cluster
if ! check_dlm_support; then
    error_exit "Sistema não tem suporte a DLM. Instale kernel completo primeiro."
fi


# ============================================================================
# EXECUÇÃO
# ============================================================================

# Verificar argumentos
case "${1:-}" in
    --help|-h)
        echo "Uso: $0 [opções]"
        echo ""
        echo "Opções:"
        echo "  --help, -h    Mostrar esta ajuda"
        echo "  --version     Mostrar versão"
        echo ""
        echo "Este script configura um ambiente enterprise para GFS2 com:"
        echo "  • Cluster Pacemaker/Corosync"
        echo "  • DLM distribuído"
        echo "  • lvmlockd cluster-aware"
        echo "  • Storage compartilhado"
        exit 0
        ;;
    --version)
        echo "install-lun-prerequisites.sh versão 2.0 - Enterprise Ready"
        exit 0
        ;;
    "")
        # Execução normal
        main
        ;;
    *)
        error_exit "Argumento inválido: $1. Use --help para ajuda."
        ;;
esac
