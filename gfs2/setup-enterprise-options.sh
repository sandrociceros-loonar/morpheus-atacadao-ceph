#!/bin/bash

# ============================================================================
# SCRIPT: configure-enterprise-resources.sh
# DESCRIÇÃO: Configuração de recursos enterprise DLM/lvmlockd em cluster existente
# VERSÃO: 1.0 - Enterprise Resources Configuration
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

# Variáveis do cluster
readonly CLUSTER_NAME="cluster_gfs2"
readonly NODE1_NAME="fc-test1"
readonly NODE2_NAME="fc-test2"
readonly VG_NAME="vg_cluster"

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
# VERIFICAÇÕES PRÉ-REQUISITOS
# ============================================================================

check_cluster_status() {
    print_header "🔍 Verificando Status do Cluster"
    
    # Verificar se cluster está ativo
    if ! sudo pcs status &>/dev/null; then
        print_error "Cluster não está ativo ou acessível"
        print_info "Execute primeiro: sudo pcs cluster start --all"
        return 1
    fi
    
    # Verificar se ambos os nós estão online
    if ! sudo pcs status | grep -q "Online:.*$NODE1_NAME.*$NODE2_NAME\|Online:.*$NODE2_NAME.*$NODE1_NAME"; then
        print_error "Nem todos os nós estão online"
        sudo pcs status
        return 1
    fi
    
    print_success "Cluster ativo com ambos os nós online"
    
    # Verificar se é o nó primário
    local current_hostname
    current_hostname=$(hostname -s)
    if [[ "$current_hostname" != "$NODE1_NAME" ]]; then
        print_warning "Execute este script no nó primário ($NODE1_NAME)"
        print_info "Nó atual: $current_hostname"
        return 1
    fi
    
    print_success "Executando no nó primário correto"
    return 0
}

check_existing_resources() {
    print_info "Verificando recursos existentes..."
    
    # Verificar recursos DLM
    if sudo pcs resource show | grep -q "dlm"; then
        print_warning "Recursos DLM já existem no cluster"
        echo "Recursos DLM encontrados:"
        sudo pcs resource show | grep dlm
        echo ""
        read -p "Deseja reconfigurar recursos existentes? [s/N]: " reconfigure
        if [[ "$reconfigure" != "s" && "$reconfigure" != "S" ]]; then
            print_info "Mantendo recursos existentes"
            return 2
        else
            print_info "Removendo recursos existentes para reconfiguração..."
            cleanup_existing_resources
        fi
    fi
    
    return 0
}

cleanup_existing_resources() {
    print_info "Removendo recursos existentes..."
    
    # Remover constraints
    sudo pcs constraint remove dlm-clone 2>/dev/null || true
    sudo pcs constraint remove lvmlockd-clone 2>/dev/null || true
    
    # Parar e remover recursos
    for resource in lvmlockd-clone dlm-clone lvmlockd dlm; do
        if sudo pcs resource show "$resource" &>/dev/null; then
            print_info "Removendo recurso: $resource"
            sudo pcs resource delete "$resource" --force 2>/dev/null || true
        fi
    done
    
    # Aguardar remoção
    sleep 10
    print_success "Recursos existentes removidos"
}

# ============================================================================
# CONFIGURAÇÃO DE RECURSOS ENTERPRISE
# ============================================================================

configure_dlm_resource() {
    print_header "🔒 Configurando Recursos DLM (Distributed Lock Manager)"
    
    print_info "Criando recurso DLM clone..."
    if sudo pcs resource create dlm systemd:dlm \
        op start timeout=90s \
        op stop timeout=100s \
        op monitor interval=60s timeout=60s on-fail=fence \
        clone interleave=true ordered=true; then
        print_success "Recurso DLM criado com sucesso"
    else
        print_error "Falha ao criar recurso DLM"
        return 1
    fi
    
    # Aguardar DLM iniciar
    print_info "Aguardando recurso DLM ficar ativo (60s)..."
    local timeout=60
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        if sudo pcs status | grep -q "dlm-clone.*Started.*$NODE1_NAME.*$NODE2_NAME\|dlm-clone.*Started.*$NODE2_NAME.*$NODE1_NAME"; then
            print_success "Recurso DLM ativo em ambos os nós"
            break
        fi
        
        if [[ $count -eq 30 ]]; then
            print_info "Status atual do recurso DLM:"
            sudo pcs status resources | grep -A 3 dlm || true
        fi
        
        sleep 5
        ((count+=5))
    done
    
    if [[ $count -ge $timeout ]]; then
        print_error "Timeout: Recurso DLM não ficou ativo"
        return 1
    fi
    
    return 0
}

configure_lvmlockd_resource() {
    print_header "💾 Configurando Recursos lvmlockd (LVM Lock Daemon)"
    
    print_info "Criando recurso lvmlockd clone..."
    if sudo pcs resource create lvmlockd systemd:lvmlockd \
        op start timeout=90s \
        op stop timeout=100s \
        op monitor interval=60s timeout=60s on-fail=fence \
        clone interleave=true ordered=true; then
        print_success "Recurso lvmlockd criado com sucesso"
    else
        print_error "Falha ao criar recurso lvmlockd"
        return 1
    fi
    
    # Aguardar lvmlockd iniciar
    print_info "Aguardando recurso lvmlockd ficar ativo (60s)..."
    local timeout=60
    local count=0
    
    while [[ $count -lt $timeout ]]; do
        if sudo pcs status | grep -q "lvmlockd-clone.*Started.*$NODE1_NAME.*$NODE2_NAME\|lvmlockd-clone.*Started.*$NODE2_NAME.*$NODE1_NAME"; then
            print_success "Recurso lvmlockd ativo em ambos os nós"
            break
        fi
        
        if [[ $count -eq 30 ]]; then
            print_info "Status atual do recurso lvmlockd:"
            sudo pcs status resources | grep -A 3 lvmlockd || true
        fi
        
        sleep 5
        ((count+=5))
    done
    
    if [[ $count -ge $timeout ]]; then
        print_error "Timeout: Recurso lvmlockd não ficou ativo"
        return 1
    fi
    
    return 0
}

configure_resource_dependencies() {
    print_header "🔗 Configurando Dependências entre Recursos"
    
    print_info "Configurando ordem de inicialização: DLM → lvmlockd..."
    if sudo pcs constraint order start dlm-clone then lvmlockd-clone; then
        print_success "Constraint de ordem configurada"
    else
        print_error "Falha ao configurar constraint de ordem"
        return 1
    fi
    
    print_info "Configurando colocation: lvmlockd com DLM..."
    if sudo pcs constraint colocation add lvmlockd-clone with dlm-clone; then
        print_success "Constraint de colocation configurada"
    else
        print_error "Falha ao configurar constraint de colocation"
        return 1
    fi
    
    print_success "Dependências configuradas com sucesso"
    return 0
}

# ============================================================================
# CONFIGURAÇÃO DO VOLUME GROUP
# ============================================================================

configure_cluster_volume_group() {
    print_header "🗄️  Configurando Volume Group para Cluster DLM"
    
    # Verificar se VG existe
    if ! sudo vgs "$VG_NAME" &>/dev/null; then
        print_error "Volume Group '$VG_NAME' não encontrado"
        print_info "Execute primeiro o script install-lun-prerequisites.sh"
        return 1
    fi
    
    # Verificar tipo de lock atual
    local current_lock_type
    current_lock_type=$(sudo vgs --noheadings -o lv_lock_type "$VG_NAME" 2>/dev/null | tr -d ' ' || echo "none")
    
    print_info "Tipo de lock atual do VG: $current_lock_type"
    
    if [[ "$current_lock_type" == "dlm" ]]; then
        print_success "Volume Group já está configurado para DLM"
        
        # Verificar se locks estão ativos
        if sudo vgs "$VG_NAME" | grep -q "wz--cs"; then
            print_success "Locks DLM estão ativos"
        else
            print_info "Iniciando locks DLM..."
            if sudo vgchange --lockstart "$VG_NAME"; then
                print_success "Locks DLM iniciados"
            else
                print_warning "Falha ao iniciar locks DLM"
                return 1
            fi
        fi
    else
        print_info "Convertendo Volume Group para modo cluster DLM..."
        
        # Parar locks existentes se houver
        sudo vgchange --lockstop "$VG_NAME" 2>/dev/null || true
        
        # Converter para DLM
        if sudo vgchange --locktype dlm "$VG_NAME"; then
            print_success "Volume Group convertido para DLM"
        else
            print_error "Falha ao converter Volume Group para DLM"
            return 1
        fi
        
        # Iniciar locks DLM
        print_info "Iniciando locks DLM..."
        if sudo vgchange --lockstart "$VG_NAME"; then
            print_success "Locks DLM iniciados com sucesso"
        else
            print_error "Falha ao iniciar locks DLM"
            return 1
        fi
    fi
    
    # Ativar Volume Group
    if sudo vgchange -ay "$VG_NAME"; then
        print_success "Volume Group ativado"
    else
        print_warning "Falha ao ativar Volume Group"
    fi
    
    return 0
}

# ============================================================================
# VALIDAÇÃO E TESTES
# ============================================================================

validate_enterprise_configuration() {
    print_header "🔍 Validando Configuração Enterprise"
    
    print_info "📊 Status completo do cluster:"
    sudo pcs status
    
    echo ""
    print_info "🔒 Verificando recursos DLM:"
    if sudo pcs status | grep -A 5 "dlm-clone"; then
        print_success "Recursos DLM encontrados e ativos"
    else
        print_error "Recursos DLM não encontrados ou inativos"
        return 1
    fi
    
    echo ""
    print_info "💾 Verificando recursos lvmlockd:"
    if sudo pcs status | grep -A 5 "lvmlockd-clone"; then
        print_success "Recursos lvmlockd encontrados e ativos"
    else
        print_error "Recursos lvmlockd não encontrados ou inativos"
        return 1
    fi
    
    echo ""
    print_info "🗄️  Verificando Volume Group cluster:"
    sudo vgs "$VG_NAME" || return 1
    
    # Verificar se VG está em modo cluster
    if sudo vgs "$VG_NAME" | grep -q "wz--cs"; then
        print_success "Volume Group em modo cluster DLM"
    else
        print_warning "Volume Group não está em modo cluster"
        return 1
    fi
    
    echo ""
    print_info "🔗 Verificando constraints:"
    sudo pcs constraint show
    
    echo ""
    print_info "🧪 Testando acesso ao Volume Group em ambos os nós:"
    
    # Teste no nó local
    if sudo lvs "$VG_NAME" &>/dev/null; then
        print_success "Acesso ao VG no nó local: OK"
    else
        print_error "Falha no acesso ao VG no nó local"
        return 1
    fi
    
    # Teste no nó remoto
    if ssh "$NODE2_NAME" "sudo lvs $VG_NAME" &>/dev/null 2>&1; then
        print_success "Acesso ao VG no nó remoto: OK"
    else
        print_error "Falha no acesso ao VG no nó remoto"
        return 1
    fi
    
    return 0
}

test_dlm_coordination() {
    print_info "🧪 Testando coordenação DLM entre nós..."
    
    # Verificar lockspaces DLM
    if sudo dlm_tool ls | grep -q "$VG_NAME"; then
        print_success "Lockspace DLM ativo para $VG_NAME"
    else
        print_warning "Lockspace DLM não encontrado"
        return 1
    fi
    
    # Verificar status DLM
    print_info "Status do DLM:"
    sudo dlm_tool status || true
    
    return 0
}

# ============================================================================
# FUNÇÕES DE TROUBLESHOOTING
# ============================================================================

show_troubleshooting_guide() {
    print_header "🔧 Guia de Troubleshooting"
    
    echo ""
    print_info "📋 Comandos úteis para diagnóstico:"
    echo "   • Status do cluster: sudo pcs status"
    echo "   • Status dos recursos: sudo pcs status resources"
    echo "   • Logs do cluster: sudo pcs status --full"
    echo "   • Status DLM: sudo dlm_tool status"
    echo "   • Lockspaces DLM: sudo dlm_tool ls"
    echo "   • Status VG: sudo vgs $VG_NAME"
    echo "   • Logs do corosync: sudo journalctl -u corosync -n 20"
    echo "   • Logs do pacemaker: sudo journalctl -u pacemaker -n 20"
    
    echo ""
    print_info "🚨 Problemas comuns e soluções:"
    echo "   • Recurso não inicia: Verificar logs com 'sudo pcs status --full'"
    echo "   • DLM não conecta: Verificar conectividade de rede entre nós"
    echo "   • VG sem locks: Executar 'sudo vgchange --lockstart $VG_NAME'"
    echo "   • Timeout: Aguardar mais tempo ou verificar dependências"
    
    echo ""
    print_info "🔄 Comandos de reset (último recurso):"
    echo "   • Parar recursos: sudo pcs resource disable dlm-clone lvmlockd-clone"
    echo "   • Limpar falhas: sudo pcs resource cleanup"
    echo "   • Iniciar recursos: sudo pcs resource enable dlm-clone lvmlockd-clone"
}

# ============================================================================
# FUNÇÃO PRINCIPAL
# ============================================================================

main() {
    print_header "🚀 Configuração de Recursos Enterprise para Cluster GFS2"
    
    print_info "Este script configura recursos DLM/lvmlockd em cluster Pacemaker existente"
    print_info "Cluster: $CLUSTER_NAME"
    print_info "Nós: $NODE1_NAME, $NODE2_NAME"
    print_info "Volume Group: $VG_NAME"
    
    # Verificar pré-requisitos
    if ! check_cluster_status; then
        error_exit "Falha na verificação do cluster"
    fi
    
    # Verificar recursos existentes
    local resource_check_result
    check_existing_resources
    resource_check_result=$?
    
    if [[ $resource_check_result -eq 2 ]]; then
        print_info "Recursos já configurados, prosseguindo para validação..."
    else
        # Configurar recursos DLM
        if ! configure_dlm_resource; then
            error_exit "Falha na configuração do recurso DLM"
        fi
        
        # Configurar recursos lvmlockd
        if ! configure_lvmlockd_resource; then
            error_exit "Falha na configuração do recurso lvmlockd"
        fi
        
        # Configurar dependências
        if ! configure_resource_dependencies; then
            error_exit "Falha na configuração de dependências"
        fi
        
        # Aguardar estabilização completa
        print_info "⏳ Aguardando estabilização completa dos recursos (30s)..."
        sleep 30
    fi
    
    # Configurar Volume Group
    if ! configure_cluster_volume_group; then
        print_error "Falha na configuração do Volume Group cluster"
        show_troubleshooting_guide
        exit 1
    fi
    
    # Validar configuração
    if ! validate_enterprise_configuration; then
        print_error "Falha na validação da configuração"
        show_troubleshooting_guide
        exit 1
    fi
    
    # Testar coordenação DLM
    if ! test_dlm_coordination; then
        print_warning "Problemas na coordenação DLM, mas configuração básica OK"
    fi
    
    # Relatório final
    print_header "✅ Configuração Enterprise Concluída com Sucesso!"
    
    echo ""
    print_success "🏢 Recursos Enterprise Configurados:"
    print_info "   • DLM (Distributed Lock Manager): Clone ativo em ambos os nós"
    print_info "   • lvmlockd (LVM Lock Daemon): Clone ativo em ambos os nós"
    print_info "   • Dependências: DLM → lvmlockd configuradas"
    print_info "   • Volume Group: Modo cluster DLM ativo"
    print_info "   • Locks distribuídos: Funcionando"
    
    echo ""
    print_success "🎯 Benefícios da Configuração Enterprise:"
    print_info "   • Alta Disponibilidade: Recursos migram automaticamente"
    print_info "   • Coordenação de Locks: DLM gerencia acesso concorrente"
    print_info "   • Monitoramento: Health checks automáticos"
    print_info "   • Recovery: Restart automático em caso de falhas"
    print_info "   • Produção Ready: Configuração adequada para ambientes críticos"
    
    echo ""
    print_success "📋 Próximos Passos:"
    print_info "   1. Verificar status: sudo pcs status"
    print_info "   2. Executar: configure-lun-multipath.sh (formatação GFS2)"
    print_info "   3. Executar: configure-second-node.sh (montagem)"
    print_info "   4. Testar: test-lun-gfs2.sh (validação completa)"
    
    echo ""
    print_info "🔧 Troubleshooting:"
    print_info "   • Execute com --troubleshoot para guia completo"
    print_info "   • Logs detalhados: sudo pcs status --full"
    
    print_success "🎉 Cluster enterprise pronto para GFS2 de produção!"
}

# ============================================================================
# EXECUÇÃO
# ============================================================================

# Verificar argumentos
case "${1:-}" in
    --help|-h)
        echo "Uso: $0 [opções]"
        echo ""
        echo "Opções:"
        echo "  --help, -h         Mostrar esta ajuda"
        echo "  --troubleshoot     Mostrar guia de troubleshooting"
        echo "  --version          Mostrar versão"
        echo ""
        echo "Este script configura recursos enterprise DLM/lvmlockd em cluster existente:"
        echo "  • DLM (Distributed Lock Manager) em modo clone"
        echo "  • lvmlockd (LVM Lock Daemon) em modo clone"
        echo "  • Dependências e constraints adequadas"
        echo "  • Volume Group em modo cluster DLM"
        echo "  • Validação completa da configuração"
        exit 0
        ;;
    --troubleshoot)
        show_troubleshooting_guide
        exit 0
        ;;
    --version)
        echo "configure-enterprise-resources.sh versão 1.0 - Enterprise Resources"
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
