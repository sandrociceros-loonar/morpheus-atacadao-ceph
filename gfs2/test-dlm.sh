#!/bin/bash
# ============================================================================
# SCRIPT: test-dlm.sh
# DESCRIÇÃO: Testa a funcionalidade do Distributed Lock Manager (DLM)
#            - Carrega o módulo DLM
#            - Cria um recurso Pacemaker temporário
#            - Usa dlm_tool para verificar lockspace
#            - Remove o recurso após o teste
# USO: sudo ./test-dlm.sh
# ============================================================================

set -euo pipefail

print() { echo -e "$1"; }
print_header() { echo; echo "=== $1 ==="; echo; }
print_success() { echo "[OK] $1"; }
print_error() { echo "[FAIL] $1"; }

# 1) Carregar módulo DLM
print_header "1) Carregando módulo DLM"
if sudo modprobe dlm; then
  print_success "Módulo DLM carregado"
else
  print_error "Falha ao carregar módulo DLM"
  exit 1
fi

# 2) Verificar lockspaces existentes
print_header "2) Listando lockspaces (dlm_tool)"
if command -v dlm_tool &>/dev/null; then
  sudo dlm_tool dump
  print_success "dlm_tool executado com sucesso"
else
  print_error "dlm_tool não encontrado (instale dlm-utils)"
fi

# 3) Criar recurso DLM no Pacemaker (temporário)
print_header "3) Criando recurso DLM no Pacemaker"
if sudo pcs resource create test-dlm systemd:dlm op monitor interval=10s on-fail=restart; then
  print_success "Recurso test-dlm criado"
else
  print_error "Falha ao criar recurso test-dlm"
  exit 1
fi

# 4) Aguardar recurso ficar iniciado
print_header "4) Aguardando recurso test-dlm ficar ativo"
for i in {1..6}; do
  if sudo pcs status | grep -q "test-dlm.*Started"; then
    print_success "Recurso test-dlm está Started"
    break
  else
    sleep 5
  fi
  if [[ $i -eq 6 ]]; then
    print_error "Recurso test-dlm não iniciou após 30s"
    sudo pcs resource delete test-dlm || true
    exit 1
  fi
done

# 5) Testar criação de lockspace via dlm_tool
print_header "5) Criando e testando lockspace via dlm_tool"
LOCKNAME="testlock_$(hostname)-$$"
if sudo dlm_tool create
