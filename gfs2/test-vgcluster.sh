#!/bin/bash
# ============================================================================
# SCRIPT: test-vgcluster.sh
# DESCRIÇÃO: Testa bloqueio DLM em /dev/vg_cluster
#            - Carrega módulos e inicia manualmente dlm_controld e lvmlockd
#            - Verifica processos
#            - Exibe logs de processos
#            - Testa vgchange --lockstart e exibe LockType
# USO: sudo ./test-vgcluster.sh
# ============================================================================

set -euo pipefail

VG="vg_cluster"

print_header() {
  echo; echo "=== $1 ==="; echo
}
print_success() { echo "[OK]    $1"; }
print_error()   { echo "[FAIL]  $1"; }

# 1) Carregar e iniciar dlm_controld
print_header "1) Carregando e iniciando dlm_controld"
sudo modprobe dlm
if pgrep -x dlm_controld &>/dev/null; then
  print_success "dlm_controld já em execução"
else
  sudo dlm_controld --syslog
  sleep 2
  pgrep -x dlm_controld &>/dev/null && print_success "dlm_controld iniciado" || { print_error "Falha ao iniciar dlm_controld"; exit 1; }
fi

# 2) Carregar e iniciar lvmlockd
print_header "2) Iniciando lvmlockd"
if pgrep -x lvmlockd &>/dev/null; then
  print_success "lvmlockd já em execução"
else
  sudo lvmlockd --syslog
  sleep 2
  pgrep -x lvmlockd &>/dev/null && print_success "lvmlockd iniciado" || { print_error "Falha ao iniciar lvmlockd"; exit 1; }
fi

# 3) Verificar processos
print_header "3) Verificando processos"
ps -C dlm_controld,lvmlockd -o pid,cmd

# 4) Exibir logs de systemd (últimos 50) de dlm e lvmlockd
print_header "4) Logs do journalctl para dlm_controld e lvmlockd"
journalctl -t dlm_controld -n 50 --no-pager || true
journalctl -t lvmlockd    -n 50 --no-pager || true

# 5) Testar vgchange lockstart
print_header "5) Testando vgchange --lockstart $VG"
if sudo vgchange --lockstart "$VG"; then
  print_success "vgchange --lockstart $VG executado"
else
  print_error "Falha ao executar vgchange --lockstart $VG"
  exit 1
fi

# 6) Exibir LockType do VG
print_header "6) Exibindo LockType do VG"
sudo vgs --all -o vg_name,lock_type

print_header "Teste de vg_cluster concluído"
