#!/usr/bin/env bash
# Script de preparação de host HVM para Datastore GFS2 no Morpheus Data
# Deve ser executado em todos os nós do cluster como root

set -e

echo "=== 1. Atualizar repositórios e instalar pacotes necessários ==="
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  open-iscsi multipath-tools \
  gfs2-utils dlm-controld pcs \
  pacemaker corosync

echo "=== 2. Configurar multipath para Fibre Channel ==="
cat > /etc/multipath.conf <<'EOF'
defaults {
    user_friendly_names yes
    find_multipaths yes
    enable_foreign "^$"
}
blacklist {
    devnode "^(ram|raw|loop|fd|md|dm-|sr|scd|st)[0-9]*"
    devnode "^hd[a-z]"
    devnode "^sda[0-9]*"
}
devices {
    device {
        vendor "HPE|DellEMC"
        product ".*"
        path_grouping_policy group_by_prio
        prio alua
        path_checker tur
        hardware_handler "1 alua"
        path_selector "queue-length 0"
        failback immediate
        rr_weight priorities
        no_path_retry 18
    }
}
EOF
systemctl restart multipath-tools
multipath -F
multipath -r

echo "=== 3. Habilitar e iniciar serviços de cluster ==="
echo "Definindo senha do usuário 'hacluster' (ajuste conforme política)..."
echo "hacluster:clusterPass1" | chpasswd

systemctl enable --now pcsd
systemctl enable --now corosync
systemctl enable --now pacemaker

echo "=== 4. Configurar override para dlm.service (remover opção -T) ==="
mkdir -p /etc/systemd/system/dlm.service.d
cat > /etc/systemd/system/dlm.service.d/override.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/sbin/dlm_controld --foreground
EOF

systemctl daemon-reload
systemctl enable dlm
systemctl restart dlm

echo "=== 5. Configurar DLM_DEFAULTS opcionalmente ==="
cat > /etc/default/dlm <<'EOF'
# Arquivo de configuração do DLM (sem -T)
# Sem opções adicionais necessárias para Ubuntu 22.04+
EOF

echo "=== 6. Verificações Finais ==="
echo "Status dos serviços:"
systemctl is-active corosync pacemaker dlm multipath-tools

echo
echo "Dispositivos multipath detectados:"
multipath -ll

echo
echo "Verifique o status do cluster (após formar quorum):"
echo "  crm status  # requer configuração de fencing e quorum via pcs"
