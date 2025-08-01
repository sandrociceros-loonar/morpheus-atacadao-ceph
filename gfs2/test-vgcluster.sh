#!/bin/bash
# ============================================================================
# SCRIPT: test-vgcluster.sh
# DESCRIÇÃO: Testa o bloqueio DLM no VG 'vg_cluster'
#            - Inicia e habilita lvm2-lockd.service
#            - Verifica status do serviço
#            - Exibe logs recentes
#            - Testa vgchange --lockstart e exibe LockType
# USO: sudo ./test-vgcluster.sh
# ============================================================================

set -euo pipefail

VG="vg_cluster"

print_header() {
  echo
  echo "=== $1 ==="
  echo
}

print_success() {
  echo "[OK]    $1"
}

print_error() {
  echo "[FAIL]  $1"
}

# 1) Habilitar e iniciar lvm2-lockd
print_header "1) Habilitando e iniciando lvm2-lockd.service"
if sudo systemctl enable --now lvm2-lockd.service; then
  print_success "lvm2-lockd.service habilitado e iniciado"
else
  print_error "Falha ao iniciar lvm2-lockd.service"
  exit 1
fi

# 2) Verificar status do serviço
print_header "2) Status de lvm2-lockd.service"
sudo systemctl status lvm2-lockd.service --no-pager -n0 || print_error "Serviço não encontrado ou não ativo"

# 3) Exibir logs recentes do serviço
print_header "3) Logs do journalctl para lvm2-lockd.service"
journalctl -u lvm2-lockd.service -n 50 --no-pager

# 4) Testar vgchange lockstart
print_header "4) Testando vgchange --lockstart $VG"
if sudo vgchange --lockstart "$VG"; then
  print_success "vgchange --lockstart $VG executado com sucesso"
else
  print_error "Falha ao executar vgchange --lockstart $VG"
  exit 1
fi

# 5) Exibir LockType do VG
print_header "5) Exibindo LockType do VG"
sudo vgs --all -o vg_name,lock_type

print_header "Teste de vg_cluster concluído"
