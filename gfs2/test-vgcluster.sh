#!/bin/bash
# ============================================================================
# SCRIPT: test-vgcluster.sh
# DESCRIÇÃO: Testa o bloqueio DLM no VG 'vg_cluster'
#            - Inicia e habilita o serviço correto de lockd (lvm2-lockd ou lvmlockd)
#            - Verifica status do serviço
#            - Exibe logs recentes
#            - Testa vgchange --lockstart e exibe LockType
# USO: sudo ./test-vgcluster.sh
# ============================================================================

set -euo pipefail

VG="vg_cluster"
SERVICES=(lvm2-lockd lvmlockd)

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

# 1) Encontrar e iniciar serviço de lockd
print_header "1) Iniciando serviço de lockd"
LOCKD_SERVICE=""
for svc in "${SERVICES[@]}"; do
  if systemctl list-unit-files | grep -q "^${svc}.service"; then
    LOCKD_SERVICE="${svc}.service"
    break
  fi
done

if [[ -z "$LOCKD_SERVICE" ]]; then
  print_error "Nenhum serviço de lockd encontrado (lvm2-lockd.service ou lvmlockd.service)"
  exit 1
fi

sudo systemctl enable --now "$LOCKD_SERVICE" \
  && print_success "$LOCKD_SERVICE habilitado e iniciado" \
  || { print_error "Falha ao iniciar $LOCKD_SERVICE"; exit 1; }

# 2) Verificar status
print_header "2) Status de $LOCKD_SERVICE"
systemctl status "$LOCKD_SERVICE" --no-pager -n0 || print_error "Serviço não ativo"

# 3) Logs recentes
print_header "3) Logs do journalctl para $LOCKD_SERVICE"
journalctl -u "$LOCKD_SERVICE" -n 50 --no-pager

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
