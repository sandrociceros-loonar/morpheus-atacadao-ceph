#!/bin/bash
# ============================================================================
# SCRIPT: collect-dlm-logs.sh
# DESCRIÇÃO: Coleta logs e informações de diagnóstico de DLM e lvmlockd
#            - Status de serviços
#            - Logs do systemd (journalctl)
#            - Saída de comandos de diagnóstico (dlm_tool, vgdisplay, pvs)
#            - Informa local dos arquivos gerados
# USO: sudo ./collect-dlm-logs.sh
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
LOG_DIR="./dlm_lvmlockd_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"

echo "Coletando logs em: $LOG_DIR"
echo

# 1) Status dos serviços DLM e lvmlockd
echo "==> 1) Status dos serviços" | tee "$LOG_DIR/01_services_status.txt"
systemctl status dlm-controld >> "$LOG_DIR/01_services_status.txt" 2>&1
systemctl status lvmlockd >> "$LOG_DIR/01_services_status.txt" 2>&1
echo

# 2) Logs recentes do journal (últimos 100 registros) para DLM e lvmlockd
echo "==> 2) Logs do journalctl (últimos 100) para dlm-controld" | tee "$LOG_DIR/02_journal_dlm.txt"
journalctl -u dlm-controld -n 100 --no-pager >> "$LOG_DIR/02_journal_dlm.txt" 2>&1
echo

echo "==> Logs do journalctl (últimos 100) para lvmlockd" | tee "$LOG_DIR/03_journal_lvmlockd.txt"
journalctl -u lvmlockd -n 100 --no-pager >> "$LOG_DIR/03_journal_lvmlockd.txt" 2>&1
echo

# 3) Saída de dlm_tool
if command -v dlm_tool &>/dev/null; then
  echo "==> 3) Saída de dlm_tool dump" | tee "$LOG_DIR/04_dlm_tool_dump.txt"
  dlm_tool dump >> "$LOG_DIR/04_dlm_tool_dump.txt" 2>&1 || true
else
  echo "dlm_tool não instalado" | tee "$LOG_DIR/04_dlm_tool_dump.txt"
fi
echo

# 4) Verificar lockspaces via sysfs
echo "==> 4) Conteúdo de /sys/kernel/config/dlm/cluster/spaces" | tee "$LOG_DIR/05_sysfs_lockspaces.txt"
if [[ -d /sys/kernel/config/dlm/cluster/spaces ]]; then
  ls -lR /sys/kernel/config/dlm/cluster/spaces >> "$LOG_DIR/05_sysfs_lockspaces.txt" 2>&1 || true
else
  echo "/sys/kernel/config/dlm/cluster/spaces não existe" >> "$LOG_DIR/05_sysfs_lockspaces.txt"
fi
echo

# 5) Informações de LVM e lvmlockd
echo "==> 5) Saída de vgdisplay e lvmdump" | tee "$LOG_DIR/06_vgdisplay.txt"
vgdisplay >> "$LOG_DIR/06_vgdisplay.txt" 2>&1 || true
echo

echo "==> Saída de pvs com lock_type" | tee "$LOG_DIR/07_pvs_locktype.txt"
pvs -o+lvmlockd >> "$LOG_DIR/07_pvs_locktype.txt" 2>&1 || true
echo

# 6) Logs de kernel relacionados a dlm e lvmlockd (últimos 200 linhas)
echo "==> 6) Logs de kernel para 'dlm' e 'lvmlockd'" | tee "$LOG_DIR/08_dmesg.txt"
dmesg | grep -Ei 'dlm|lvmlockd' | tail -n 200 >> "$LOG_DIR/08_dmesg.txt" 2>&1 || true
echo

# 7) Status do cluster (pcs status)
echo "==> 7) Status do cluster Pacemaker" | tee "$LOG_DIR/09_pcs_status.txt"
pcs status >> "$LOG_DIR/09_pcs_status.txt" 2>&1 || true
echo

# 8) Coletar versões dos pacotes relevantes
echo "==> 8) Versões dos pacotes" | tee "$LOG_DIR/10_versions.txt"
dpkg -l | grep -E 'dlm-controld|lvm2|corosync|pacemaker' >> "$LOG_DIR/10_versions.txt" 2>&1
echo

echo "Coleta de logs concluída. Arquivos disponíveis em: $LOG_DIR"
