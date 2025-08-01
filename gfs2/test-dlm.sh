#!/bin/bash
# ============================================================================
# SCRIPT: test-dlm.sh
# DESCRIÇÃO: Testa a funcionalidade do Distributed Lock Manager (DLM)
#            - Carrega o módulo DLM
#            - Lista lockspaces (não-fatal)
#            - Cria recurso Pacemaker de teste (substitui se já existir)
#            - Usa dlm_tool para verificar lockspace
#            - Remove recurso após o teste
# USO: sudo ./test-dlm.sh
# ============================================================================

set -euo pipefail

print_header() { echo; echo "=== $1 ==="; echo; }
print_success() { echo "[OK]    $1"; }
print_warning() { echo "[WARN]  $1"; }
print_error()   { echo "[FAIL]  $1"; }

# 1) Carregar módulo DLM
print_header "1) Carregando módulo DLM"
sudo modprobe dlm && print_success "Módulo DLM carregado" || { print_error "Falha ao carregar módulo DLM"; exit 1; }

# 2) Listar lockspaces existentes (não-fatal)
print_header "2) Listando lockspaces (dlm_tool)"
if command -v dlm_tool &>/dev/null; then
  if sudo dlm_tool dump; then
    print_success "dlm_tool dump OK"
  else
    print_warning "Nenhum lockspace presente (estado inicial)"
  fi
else
  print_error "dlm_tool não encontrado; instale pacote dlm-utils"
fi

# 3) Criar recurso DLM no Pacemaker (sobrescrever se existir)
print_header "3) Criando recurso Pacemaker 'test-dlm'"
if sudo pcs resource show test-dlm &>/dev/null; then
  print_warning "Recurso 'test-dlm' já existe; removendo anterior"
  sudo pcs resource delete test-dlm --quiet || true
  # Aguardar remoção
  for i in {1..6}; do
    if ! sudo pcs resource show test-dlm &>/dev/null; then
      print_success "Recurso 'test-dlm' removido"
      break
    fi
    sleep 2
  done
fi

# Recriar recurso
if sudo pcs resource create test-dlm systemd:dlm \
      op monitor interval=10s on-fail=restart; then
  print_success "Recurso 'test-dlm' criado"
else
  print_error "Falha ao criar recurso 'test-dlm'"
  exit 1
fi

# 4) Aguardar recurso ficar ativo
print_header "4) Aguardando recurso 'test-dlm' ficar 'Started'"
for i in {1..6}; do
  if sudo pcs status | grep -q "test-dlm.*Started"; then
    print_success "Recurso 'test-dlm' está Started"
    break
  else
    sleep 5
  fi
  if [[ $i -eq 6 ]]; then
    print_error "Recurso 'test-dlm' não iniciou após 30s"
    sudo pcs resource delete test-dlm || true
    exit 1
  fi
done

# 5) Criar e testar lockspace via dlm_tool
print_header "5) Criando e testando lockspace via dlm_tool"
LOCKNAME="testlock_$(hostname)-$$"
if sudo dlm_tool create_lockspace "$LOCKNAME"; then
  print_success "Lockspace '$LOCKNAME' criado"
  if sudo dlm_tool lockspace_info "$LOCKNAME"; then
    print_success "Lockspace '$LOCKNAME' verificado"
  else
    print_error "Falha ao verificar lockspace '$LOCKNAME'"
  fi
  if sudo dlm_tool delete_lockspace "$LOCKNAME"; then
    print_success "Lockspace '$LOCKNAME' removido"
  else
    print_error "Falha ao remover lockspace '$LOCKNAME'"
  fi
else
  print_error "Falha ao criar lockspace '$LOCKNAME'"
fi

# 6) Remover recurso de teste
print_header "6) Removendo recurso Pacemaker 'test-dlm'"
if sudo pcs resource delete test-dlm; then
  print_success "Recurso 'test-dlm' removido"
else
  print_error "Falha ao remover recurso 'test-dlm'"
fi

print_header "Teste DLM concluído"
