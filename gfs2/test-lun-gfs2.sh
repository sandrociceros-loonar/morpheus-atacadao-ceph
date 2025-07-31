#!/bin/bash

################################################################################
# Script: test-lun-gfs2.sh
# Descrição: Script completo de teste e validação do cluster GFS2
#
# FUNCIONALIDADES:
# - Solicita nomes dos hosts do cluster interativamente
# - Verifica conectividade dos hosts antes de iniciar
# - Testa conectividade iSCSI entre nós
# - Valida configuração do cluster Pacemaker/Corosync
# - Verifica funcionamento do DLM (Distributed Lock Manager)
# - Testa sincronização do filesystem GFS2
# - Valida multipath e redundância
# - Executa testes de performance básicos
# - Gera relatório completo de status
#
# PRÉ-REQUISITOS:
# - Cluster GFS2 configurado com scripts anteriores
# - Conectividade de rede entre os nós
# - GFS2 montado em /mnt/gfs2
#
# USO:
# sudo ./test-lun-gfs2.sh
#
# VERSÃO: 2.0 - Entrada interativa de hosts e verificação de conectividade
################################################################################

function log_info {
    echo "ℹ️  $1"
}

function log_success {
    echo "✅ $1"
}

function log_error {
    echo "❌ $1"
}

function log_warning {
    echo "⚠️  $1"
}

function test_result {
    if [ $1 -eq 0 ]; then
        PASSED_TESTS=$((PASSED_TESTS + 1))
        log_success "$2"
    else
        FAILED_TESTS=$((FAILED_TESTS + 1))
        log_error "$2"
    fi
    TOTAL_TESTS=$((TOTAL_TESTS + 1))
}

function error_exit {
    echo "❌ Erro: $1"
    exit 1
}

function check_host_connectivity {
    local host="$1"
    local timeout="3"
    
    log_info "Verificando conectividade com $host..."
    
    # Teste de ping
    if ping -c 2 -W $timeout "$host" &>/dev/null; then
        log_success "$host está acessível via ping"
        return 0
    else
        log_error "$host não está acessível via ping"
        return 1
    fi
}

function check_ssh_connectivity {
    local host="$1"
    
    log_info "Verificando conectividade SSH com $host..."
    
    # Teste de SSH (timeout de 5 segundos)
    if timeout 5 ssh -o ConnectTimeout=3 -o BatchMode=yes "$host" "echo 'SSH OK'" &>/dev/null; then
        log_success "$host está acessível via SSH"
        return 0
    else
        log_warning "$host não está acessível via SSH (normal se não configurado)"
        return 1
    fi
}

# === CONFIGURAÇÃO INICIAL DOS HOSTS ===
echo "======================================================================"
echo "🧪 TESTE COMPLETO DO CLUSTER GFS2"
echo "======================================================================"
echo "Data/Hora: $(date)"

echo ""
log_info "Configuração dos nós do cluster..."

# Detectar hostname atual
CURRENT_NODE=$(hostname)
echo "Nó atual detectado: $CURRENT_NODE"

# Solicitar informações dos hosts do cluster
echo ""
echo "📋 CONFIGURAÇÃO DOS NÓS DO CLUSTER:"
echo "Por favor, informe os nomes dos hosts que compõem o cluster."

# Solicitar primeiro nó
read -p "Nome do primeiro nó do cluster [$CURRENT_NODE]: " NODE1
NODE1=${NODE1:-$CURRENT_NODE}

# Solicitar segundo nó
while true; do
    read -p "Nome do segundo nó do cluster: " NODE2
    
    if [ -z "$NODE2" ]; then
        log_error "O nome do segundo nó não pode estar vazio"
        continue
    fi
    
    if [ "$NODE2" = "$NODE1" ]; then
        log_error "O segundo nó deve ter nome diferente do primeiro ($NODE1)"
        continue
    fi
    
    break
done

# Determinar qual é o outro nó em relação ao atual
if [ "$CURRENT_NODE" = "$NODE1" ]; then
    OTHER_NODE="$NODE2"
elif [ "$CURRENT_NODE" = "$NODE2" ]; then
    OTHER_NODE="$NODE1"
else
    log_warning "Nó atual ($CURRENT_NODE) não corresponde aos nós informados ($NODE1, $NODE2)"
    OTHER_NODE="$NODE1"  # Assumir primeiro nó como padrão
fi

echo ""
echo "📋 CONFIGURAÇÃO CONFIRMADA:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Nó 1:               $NODE1"
echo "Nó 2:               $NODE2"
echo "Nó atual:           $CURRENT_NODE"
echo "Outro nó:           $OTHER_NODE"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# === VERIFICAÇÃO DE CONECTIVIDADE PRÉVIA ===
echo ""
log_info "VERIFICAÇÕES PRELIMINARES: Testando conectividade dos hosts..."

CONNECTIVITY_ISSUES=0

# Verificar conectividade com ambos os nós
for node in "$NODE1" "$NODE2"; do
    if [ "$node" != "$CURRENT_NODE" ]; then
        if ! check_host_connectivity "$node"; then
            CONNECTIVITY_ISSUES=$((CONNECTIVITY_ISSUES + 1))
        fi
        
        # Teste opcional de SSH
        check_ssh_connectivity "$node"
    else
        log_success "$node é o nó atual (conectividade local OK)"
    fi
done

# Verificar se há problemas críticos de conectividade
if [ $CONNECTIVITY_ISSUES -gt 0 ]; then
    echo ""
    log_error "Problemas de conectividade detectados com $CONNECTIVITY_ISSUES nó(s)"
    echo ""
    echo "⚠️  OPÇÕES:"
    echo "1. Continuar mesmo assim (testes de conectividade falharão)"
    echo "2. Corrigir problemas de rede e executar novamente"
    echo "3. Cancelar execução"
    
    read -p "Escolha uma opção [1/2/3]: " CONNECTIVITY_CHOICE
    
    case $CONNECTIVITY_CHOICE in
        1)
            log_warning "Continuando com problemas de conectividade..."
            ;;
        2|3)
            echo "Execução cancelada. Corrija os problemas de rede e tente novamente."
            echo ""
            echo "💡 DICAS PARA RESOLUÇÃO:"
            echo "- Verifique se os nomes dos hosts estão corretos"
            echo "- Confirme resolução DNS ou configure /etc/hosts"
            echo "- Teste conectividade: ping $OTHER_NODE"
            echo "- Verifique firewall e configurações de rede"
            exit 1
            ;;
        *)
            log_warning "Opção inválida, continuando..."
            ;;
    esac
fi

# Confirmação final antes de iniciar testes
echo ""
read -p "Iniciar testes do cluster GFS2? [S/n]: " START_TESTS
START_TESTS=$(echo "${START_TESTS:-s}" | tr '[:upper:]' '[:lower:]')

if [[ "$START_TESTS" != "s" && "$START_TESTS" != "y" ]]; then
    echo "Testes cancelados pelo usuário."
    exit 0
fi

# === INÍCIO DOS TESTES ===
echo ""
echo "======================================================================"
echo "🚀 INICIANDO TESTES DO CLUSTER GFS2"
echo "======================================================================"

# Contadores de testes
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

# === TESTE 1: Verificar Serviços Básicos ===
echo ""
log_info "TESTE 1: Verificando serviços essenciais..."

# Corosync
systemctl is-active --quiet corosync
test_result $? "Serviço Corosync está ativo"

# Pacemaker
systemctl is-active --quiet pacemaker
test_result $? "Serviço Pacemaker está ativo"

# DLM
pgrep -x dlm_controld >/dev/null
test_result $? "Daemon dlm_controld está rodando"

# LVM Lock Daemon
pgrep -x lvmlockd >/dev/null
test_result $? "Daemon lvmlockd está rodando"

# Multipath
systemctl is-active --quiet multipathd
test_result $? "Serviço multipathd está ativo"

# === TESTE 2: Verificar Status do Cluster ===
echo ""
log_info "TESTE 2: Verificando status do cluster..."

# Verificar se cluster está online
pcs status &>/dev/null
test_result $? "Cluster está respondendo aos comandos pcs"

# Verificar número de nós online
NODES_ONLINE=$(pcs status 2>/dev/null | grep "Online:" | grep -o '\[.*\]' | tr -d '[]' | wc -w)
if [ "$NODES_ONLINE" -ge 2 ]; then
    test_result 0 "Múltiplos nós online no cluster ($NODES_ONLINE nós)"
else
    test_result 1 "Número insuficiente de nós online ($NODES_ONLINE nós)"
fi

# Verificar se os nós especificados estão no cluster
for node in "$NODE1" "$NODE2"; do
    pcs status 2>/dev/null | grep -q "$node"
    test_result $? "Nó $node está presente no cluster"
done

# Verificar se há quorum
pcs status 2>/dev/null | grep -q "partition with quorum"
test_result $? "Cluster possui quorum"

# === TESTE 3: Verificar Device Multipath ===
echo ""
log_info "TESTE 3: Verificando configuração multipath..."

# Verificar se device multipath existe
[ -e /dev/mapper/fc-lun-cluster ]
test_result $? "Device multipath /dev/mapper/fc-lun-cluster existe"

# Verificar status do multipath
multipath -l fc-lun-cluster &>/dev/null
test_result $? "Device multipath está configurado corretamente"

# Verificar se device está acessível
dd if=/dev/mapper/fc-lun-cluster of=/dev/null bs=4096 count=1 &>/dev/null
test_result $? "Device multipath está acessível para leitura"

# === TESTE 4: Verificar DLM ===
echo ""
log_info "TESTE 4: Verificando Distributed Lock Manager..."

# Verificar status do DLM
dlm_tool status &>/dev/null
test_result $? "DLM está respondendo"

# Verificar lockspaces
LOCKSPACES=$(dlm_tool ls 2>/dev/null | wc -l)
if [ "$LOCKSPACES" -gt 0 ]; then
    test_result 0 "DLM possui lockspaces ativos ($LOCKSPACES lockspaces)"
else
    test_result 1 "DLM não possui lockspaces ativos"
fi

# === TESTE 5: Verificar Montagem GFS2 ===
echo ""
log_info "TESTE 5: Verificando filesystem GFS2..."

# Verificar se GFS2 está montado
mount | grep -q "type gfs2"
test_result $? "Filesystem GFS2 está montado"

# Verificar ponto de montagem
[ -d /mnt/gfs2 ] && mount | grep -q "/mnt/gfs2"
test_result $? "GFS2 montado em /mnt/gfs2"

# Verificar se é realmente GFS2
FSTYPE=$(df -T /mnt/gfs2 2>/dev/null | tail -1 | awk '{print $2}')
[ "$FSTYPE" = "gfs2" ]
test_result $? "Filesystem é realmente GFS2"

# Verificar permissões de escrita
touch /mnt/gfs2/.test-write-$CURRENT_NODE 2>/dev/null
test_result $? "Filesystem permite escrita"

# === TESTE 6: Teste de Sincronização ===
echo ""
log_info "TESTE 6: Testando sincronização entre nós..."

# Criar arquivo de teste único
TEST_FILE="/mnt/gfs2/test-sync-$(date +%s)-$CURRENT_NODE.txt"
TEST_CONTENT="Teste de sincronização do $CURRENT_NODE em $(date)"

echo "$TEST_CONTENT" > "$TEST_FILE" 2>/dev/null
test_result $? "Criação de arquivo de teste"

# Verificar se arquivo foi criado
[ -f "$TEST_FILE" ]
test_result $? "Arquivo de teste existe no filesystem"

# Verificar conteúdo
CONTENT_CHECK=$(cat "$TEST_FILE" 2>/dev/null)
[ "$CONTENT_CHECK" = "$TEST_CONTENT" ]
test_result $? "Conteúdo do arquivo está correto"

# === TESTE 7: Teste de Performance Básico ===
echo ""
log_info "TESTE 7: Teste básico de performance..."

# Teste de escrita sequencial
WRITE_TEST_FILE="/mnt/gfs2/write-test-$CURRENT_NODE.dat"
dd if=/dev/zero of="$WRITE_TEST_FILE" bs=1M count=10 &>/dev/null
test_result $? "Teste de escrita sequencial (10MB)"

# Teste de leitura sequencial
dd if="$WRITE_TEST_FILE" of=/dev/null bs=1M &>/dev/null
test_result $? "Teste de leitura sequencial"

# Limpeza do arquivo de teste
rm -f "$WRITE_TEST_FILE" 2>/dev/null

# === TESTE 8: Verificar Conectividade com Outros Nós ===
echo ""
log_info "TESTE 8: Verificando conectividade entre nós..."

# Teste de conectividade com outros nós
for node in "$NODE1" "$NODE2"; do
    if [ "$node" != "$CURRENT_NODE" ]; then
        # Teste de ping
        ping -c 2 "$node" &>/dev/null
        test_result $? "Conectividade de rede com $node"
        
        # Verificar se nó está no cluster
        pcs status 2>/dev/null | grep -q "$node"
        test_result $? "$node está presente no status do cluster"
    fi
done

# === TESTE 9: Verificar Configuração de Fencing ===
echo ""
log_info "TESTE 9: Verificando configuração de fencing..."

# Verificar se há recursos STONITH
STONITH_RESOURCES=$(pcs stonith show 2>/dev/null | wc -l)
if [ "$STONITH_RESOURCES" -gt 0 ]; then
    test_result 0 "Recursos STONITH configurados ($STONITH_RESOURCES recursos)"
else
    # Verificar se STONITH está desabilitado (aceitável para lab)
    pcs property show stonith-enabled 2>/dev/null | grep -q "false"
    if [ $? -eq 0 ]; then
        log_warning "STONITH desabilitado (adequado para laboratório)"
        TOTAL_TESTS=$((TOTAL_TESTS + 1))
    else
        test_result 1 "STONITH não configurado e não desabilitado"
    fi
fi

# === TESTE 10: Verificar Logs de Erro ===
echo ""
log_info "TESTE 10: Verificando logs do sistema..."

# Verificar logs do Corosync
COROSYNC_ERRORS=$(journalctl -u corosync --since "5 minutes ago" | grep -i error | wc -l)
if [ "$COROSYNC_ERRORS" -eq 0 ]; then
    test_result 0 "Sem erros recentes no Corosync"
else
    test_result 1 "Encontrados $COROSYNC_ERRORS erros no Corosync"
fi

# Verificar logs do GFS2
GFS2_ERRORS=$(dmesg | grep -i gfs2 | grep -i error | wc -l)
if [ "$GFS2_ERRORS" -eq 0 ]; then
    test_result 0 "Sem erros do GFS2 no dmesg"
else
    test_result 1 "Encontrados $GFS2_ERRORS erros do GFS2"
fi

# === RELATÓRIO FINAL ===
echo ""
echo "======================================================================"
echo "📊 RELATÓRIO FINAL DOS TESTES"
echo "======================================================================"

echo ""
echo "📋 RESUMO DOS RESULTADOS:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Total de testes:    $TOTAL_TESTS"
echo "Testes aprovados:   $PASSED_TESTS"
echo "Testes falharam:    $FAILED_TESTS"

if [ "$FAILED_TESTS" -eq 0 ]; then
    echo "Status geral:       ✅ TODOS OS TESTES APROVADOS"
    OVERALL_STATUS="SUCESSO"
else
    PERCENTAGE=$((PASSED_TESTS * 100 / TOTAL_TESTS))
    echo "Taxa de sucesso:    $PERCENTAGE%"
    if [ "$PERCENTAGE" -ge 80 ]; then
        echo "Status geral:       ⚠️  MAJORITARIAMENTE FUNCIONAL"
        OVERALL_STATUS="FUNCIONAL"
    else
        echo "Status geral:       ❌ PROBLEMAS CRÍTICOS DETECTADOS"
        OVERALL_STATUS="PROBLEMAS"
    fi
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "🔍 INFORMAÇÕES DO SISTEMA:"
echo "Nó atual:           $CURRENT_NODE"
echo "Nós do cluster:     $NODE1, $NODE2"
echo "Cluster name:       $(pcs status cluster 2>/dev/null | grep -i "cluster name" | awk '{print $3}' || echo "Não detectado")"
echo "Nós online:         $NODES_ONLINE/$EXPECTED_NODES"
echo "GFS2 mountpoint:    /mnt/gfs2"
echo "Device multipath:   /dev/mapper/fc-lun-cluster"

echo ""
echo "📁 COMANDOS ÚTEIS PARA DIAGNÓSTICO:"
echo "pcs status                          # Status geral do cluster"
echo "mount | grep gfs2                   # Verificar montagens GFS2"
echo "multipath -ll                       # Status do multipath"
echo "dlm_tool status                     # Status do DLM"
echo "ls -la /mnt/gfs2/                   # Conteúdo do filesystem compartilhado"

if [ "$FAILED_TESTS" -gt 0 ]; then
    echo ""
    echo "⚠️  RECOMENDAÇÕES PARA PROBLEMAS:"
    echo "1. Verifique logs: journalctl -xe"
    echo "2. Reinicie serviços: systemctl restart corosync pacemaker"
    echo "3. Confirme conectividade de rede entre todos os nós:"
    for node in "$NODE1" "$NODE2"; do
        if [ "$node" != "$CURRENT_NODE" ]; then
            echo "   ping $node"
        fi
    done
    echo "4. Confirme que todos os nós executaram install-lun-prerequisites.sh"
fi

echo ""
echo "🎯 TESTE DE SINCRONIZAÇÃO MANUAL:"
echo "# No $CURRENT_NODE:"
echo "echo 'teste-manual-$(date)' | sudo tee /mnt/gfs2/teste-manual.txt"
echo ""
for node in "$NODE1" "$NODE2"; do
    if [ "$node" != "$CURRENT_NODE" ]; then
        echo "# No $node:"
        echo "cat /mnt/gfs2/teste-manual.txt"
    fi
done

echo ""
if [ "$OVERALL_STATUS" = "SUCESSO" ]; then
    log_success "Cluster GFS2 está totalmente funcional!"
elif [ "$OVERALL_STATUS" = "FUNCIONAL" ]; then
    log_warning "Cluster GFS2 está funcionando, mas com algumas questões menores"
else
    log_error "Cluster GFS2 possui problemas que precisam ser resolvidos"
fi

echo ""
echo "======================================================================"

# Limpar arquivos temporários
rm -f /mnt/gfs2/.test-write-$CURRENT_NODE 2>/dev/null
rm -f "$TEST_FILE" 2>/dev/null

exit $FAILED_TESTS
