#!/bin/bash
# ============================================================================
# SCRIPT: collect-dlm-lvmlockd-logs.sh
# DESCRIÇÃO: Coleta logs e informações de diagnóstico de DLM e lvmlockd
#            - Status de serviços (sem pager)
#            - Logs do journalctl
#            - Saída de comandos de diagnóstico (dlm_tool, vgdisplay, pvs)
#            - Informações em /sys e dmesg
# USO: sudo ./collect-dlm-lvmlockd-logs.sh
# ============================================================================

set -euo pipefail

# ----------------------------------------------------------------------------
LOG_DIR="./dlm_lvmlockd_logs_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$LOG_DIR"
echo "Coletando logs em: $LOG_DIR"
echo

# 1) Status dos serviços DLM e lvmlockd (sem pager)
echo "==> 1) Status dos serviços" | tee "$LOG_DIR/01_services_status.txt"
systemctl status dlm.service --no-pager -n0 >> "$LOG_DIR/01_services_status.txt" 2>&1 || echo "dlm.service não encontrado" >> "$LOG_DIR/01_services_status.txt"
systemctl status lvmlockd.service --no-pager -n0 >> "$LOG_DIR/01_services_status.txt" 2>&1 || echo "lvmlockd.service não encontrado" >> "$LOG_DIR/01_services_status.txt"
echo

# 2) Logs do journalctl (últimos 100 registros) para dlm e lvmlockd
echo "==> 2) Logs do journalctl (dlm.service)" | tee "$LOG_DIR/02_journal_dlm.txt"
journalctl -u dlm.service -n 100 --no-pager >> "$LOG_DIR/02_journal_dlm.txt" 2>&1 || echo "Sem journal para dlm.service" >> "$LOG_DIR/02_journal_dlm.txt"
echo

echo "==> Logs do journalctl (lvmlockd.service)" | tee "$LOG_DIR/03_journal_lvmlockd.txt"
journalctl -u lvmlockd.service -n 100 --no-pager >> "$LOG_DIR/03_journal_lvmlockd.txt" 2>&1 || echo "Sem journal para lvmlockd.service" >> "$LOG_DIR/03_journal_lvmlockd.txt"
echo

# 3) Saída de dlm_tool
echo "==> 3) Saída de dlm_tool dump" | tee "$LOG_DIR/04_dlm_tool_dump.txt"
if command -v dlm_tool &>/dev/null; then
  dlm_tool dump >> "$LOG_DIR/04_dlm_tool_dump.txt" 2>&1 || echo "dlm_tool dump falhou" >> "$LOG_DIR/04_dlm_tool_dump.txt"
else
  echo "dlm_tool não instalado" >> "$LOG_DIR/04_dlm_tool_dump.txt"
fi
echo

# 4) Conteúdo de /sys/kernel/config/dlm/cluster/spaces
echo "==> 4) Conteúdo de /sys/kernel/config/dlm/cluster/spaces" | tee "$LOG_DIR/05_sysfs_lockspaces.txt"
if [[ -d /sys/kernel/config/dlm/cluster/spaces ]]; then
  ls -lR /sys/kernel/config/dlm/cluster/spaces >> "$LOG_DIR/05_sysfs_lockspaces.txt" 2>&1 || true
else
  echo "/sys/kernel/config/dlm/cluster/spaces não existe" >> "$LOG_DIR/05_sysfs_lockspaces.txt"
fi
echo

# 5) Informações de LVM e lvmlockd
echo "==> 5) Saída de vgdisplay" | tee "$LOG_DIR/06_vgdisplay.txt"
vgdisplay >> "$LOG_DIR/06_vgdisplay.txt" 2>&1 || echo "vgdisplay falhou" >> "$LOG_DIR/06_vgdisplay.txt"
echo

echo "==> Saída de pvs com lock_type" | tee "$LOG_DIR/07_pvs_locktype.txt"
pvs -o+lvmlockd >> "$LOG_DIR/07_pvs_locktype.txt" 2>&1 || echo "pvs falhou" >> "$LOG_DIR/07_pvs_locktype.txt"
echo

# 6) Logs de kernel relacionados a dlm e lvmlockd (últimos 200 linhas)
echo "==> 6) Logs de kernel (dmesg)" | tee "$LOG_DIR/08_dmesg.txt"
dmesg | grep -Ei 'dlm|lvmlockd' | tail -n 200 >> "$LOG_DIR/08_dmesg.txt" 2>&1 || echo "sem entradas em dmesg" >> "$LOG_DIR/08_dmesg.txt"
echo

# 7) Status do cluster (pcs status)
echo "==> 7) Status do cluster Pacemaker" | tee "$LOG_DIR/09_pcs_status.txt"
pcs status --full >> "$LOG_DIR/09_pcs_status.txt" 2>&1 || echo "pcs status falhou" >> "$LOG_DIR/09_pcs_status.txt"
echo

# 8) Versões dos pacotes relevantes
echo "==> 8) Versões dos pacotes" | tee "$LOG_DIR/10_versions.txt"
dpkg -l | grep -E 'dlm|lvm2|corosync|pacemaker' >> "$LOG_DIR/10_versions.txt" 2>&1 || echo "dpkg list falhou" >> "$LOG_DIR/10_versions.txt"
echo

echo "Coleta de logs concluída. Arquivos disponíveis em: $LOG_DIR"
