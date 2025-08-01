#!/usr/bin/env bash
# Script de preparação de host HVM para Datastore GFS2 no Morpheus Data
# Deve ser executado em todos os nós do cluster como root

set -e

# 1. Atualizar repositórios e instalar pacotes necessários
echo "Instalando pacotes de cluster e GFS2..."
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  open-iscsi multipath-tools \
  gfs2-utils dlm-controld pcs \
  pacemaker corosync

# 2. Configurar multipath para Fibre Channel
echo "Configurando multipath..."
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

# 3. Habilitar e iniciar serviços de clustering
echo "Habilitando serviços de cluster..."
# Definir senha padrão do usuário hacluster (ajuste conforme política de senha)
echo "hacluster:clusterPass1" | chpasswd
systemctl enable --now pcsd
systemctl enable --now corosync
systemctl enable --now pacemaker
systemctl enable --now dlm
systemctl enable --now corosync
systemctl enable --now pacemaker

# 4. Configurar DLM
echo "Configurando DLM..."
cat > /etc/default/dlm <<'EOF'
DLM_CONTROLD_OPTS="-T 60"
EOF
systemctl restart dlm

# 5. Montagem automática de GFS2 (opcional, Morpheus faz após criar datastore)
# Aqui apenas garantimos que gfs2-utils esteja presente
echo "Preparação concluída. Verifique configuração de hosts no /etc/hosts e fencing antes de criar datastore."

# 6. Exibir status geral
echo
echo "=== Status dos serviços ==="
systemctl is-active corosync pacemaker dlm multipath-tools
echo
echo "=== Dispositivos multipath detectados ==="
multipath -ll
