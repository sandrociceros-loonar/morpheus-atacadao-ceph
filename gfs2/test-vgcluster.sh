#!/bin/bash
# ============================================================================
# SCRIPT: test-vgcluster.sh
# DESCRIÇÃO: Testa bloqueio DLM no VG 'vg_cluster' sem depender de serviços systemd
#            - Carrega módulos
#            - Inicia manualmente dlm_controld e lvmlockd em background
#            - Verifica se os processos estão rodando
#            - Exibe logs recentes via journalctl (tags)
#            - Testa vgchange --lockstart e exibe LockType
# USO: sudo ./test-vgcluster.sh
# ============================================================================

set -euo pipefail

VG="vg_cluster"

print_header() { echo; echo "=== $1 ==="; echo; }
print_success() { echo "[OK]    $1"; }
print_error()   { echo "[FAIL]  $1"; }

# 1) Carregar o módulo DLM
print_header "1) Carregando módulo DLM"
sudo modprobe dlm && print_success "Módulo dlm carregado" || { print_error "Falha ao carregar dlm"; exit 1; }

# 2) Iniciar dlm_controld em background
print_header "2) Iniciando dlm_controld"
if pgrep -x dlm_controld >/dev/null; then
  print_success "dlm_controld já em execução"
else
  sudo dlm_controld --syslog &
  sleep 2
  pgrep -x dlm_controld >/dev/null && print_success "dlm_controld iniciado" || { print_error "Falha ao iniciar dlm_controld"; exit 1; }
fi

# 3) Iniciar lvmlockd em background
print_header "3) Iniciando lvmlockd"
if pgrep -x lvmlockd >/dev/null; then
  print_success "lvmlockd já em execução"
else
  sudo lvmlockd --syslog &
  sleep 2
  pgrep -x lvmlockd >/dev/null && print_success "lvmlockd iniciado" || { print_error "Falha ao iniciar lvmlockd"; exit 1; }
fi

# 4) Verificar processos
print_header "4) Verificando processos em execução"
ps -C dlm_controld,lvmlockd -o pid,cmd || print_error "Não conseguiu listar processos"

# 5) Exibir logs via journalctl (últimos 50 entradas)
print_header "5) Logs journalctl (dlm_controld)"
journalctl -t dlm_controld -n 50 --no-pager || print_error "Sem logs para dlm_controld"
print_header "Logs journalctl (lvmlockd)"
journalctl -t lvmlockd    -n 50 --no-pager || print_error "Sem logs para lvmlockd"

# 6) Testar vgchange --lockstart
print_header "6) Testando vgchange --lockstart $VG"
if sudo vgchange --lockstart "$VG"; then
  print_success "vgchange --lockstart $VG executado"
else
  print_error "Falha ao executar vgchange --lockstart $VG"
  exit 1
fi

# 7) Exibir LockType do VG
print_header "7) Exibindo LockType do VG"
sudo vgs --all -o vg_name,lock_type || print_error "Falha ao exibir lock_type"

print_header "Teste de vg_cluster concluído"
