#!/usr/bin/env bash
# Script de preparação e verificação de host HVM para Datastore GFS2 no Morpheus Data com SBD fencing
# Execute em todos os nós do cluster como root

set -e

# Ajuste estes valores conforme seu ambiente
CLUSTER_NODES=("srvmvm001a" "srvmvm002a" "srvmvm003a")
HACLUSTER_PASS="clusterPass1"
WWID_DEV="/dev/mapper/3600c0ff000632041c7a4876801000000"
SBD_PARTITION="${WWID_DEV}p1"  # Partição reservada para SBD
CLUSTER_NAME="hvmcluster"

echo "=== 1. Atualizar repositórios e instalar pacotes necessários ==="
apt update
DEBIAN_FRONTEND=noninteractive apt install -y \
  open-iscsi multipath-tools \
  gfs2-utils dlm-controld pcs \
  pacemaker corosync sbd

echo "=== 2. Configurar multipath para Fibre Channel (preservar WWID) ==="
cat > /etc/multipath.conf <<'EOF'
defaults {
    user_friendly_names no
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
echo "Definindo senha do usuário 'hacluster'..."
echo "hacluster:${HACLUSTER_PASS}" | chpasswd

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

echo "=== 5. Configurar SBD fencing ==="
if [ ! -b "${SBD_PARTITION}" ]; then
  echo "ERRO: partição SBD ${SBD_PARTITION} não encontrada."
  exit 1
else
  sbd -d "${SBD_PARTITION}" create
fi

cat > /etc/default/sbd <<'EOF'
SBD_DEVICE="${SBD_PARTITION}"
SBD_OPTS="--noproc"
EOF
systemctl enable --now sbd

echo "=== 6. Configurar cluster via pcs (somente no primeiro nó) ==="
if [ "$(hostname)" = "${CLUSTER_NODES[0]}" ]; then
  pcs cluster auth "${CLUSTER_NODES[@]}" -u hacluster -p "${HACLUSTER_PASS}" --force
  pcs cluster setup --name "${CLUSTER_NAME}" "${CLUSTER_NODES[@]}" --force
  pcs stonith create sbd-fence stonith:external/sbd op monitor interval=60s
  pcs property set stonith-enabled=true
  pcs property set no-quorum-policy=freeze
  pcs property set symmetric-cluster=false
  pcs cluster start --all
fi

echo
echo "=== 7. Verificações Finais ==="

# Verificar pacotes
echo "- Pacotes instalados:"
for pkg in open-iscsi multipath-tools gfs2-utils dlm-controld pcs pacemaker corosync sbd; do
  dpkg -l | grep -qw "$pkg" && echo "  OK: $pkg" || echo "  ERRO: $pkg ausente"
done

# Serviços
echo "- Serviços systemd ativos:"
for svc in multipath-tools corosync pacemaker dlm sbd; do
  systemctl is-active --quiet "$svc" && echo "  OK: $svc ativo" || echo "  ERRO: $svc inativo"
done

# multipath.conf
echo "- multipath.conf:"
grep -q "user_friendly_names no" /etc/multipath.conf \
  && echo "  OK: preserva WWID" \
  || echo "  ERRO: user_friendly_names deve ser 'no'"

# WWID
echo "- Dispositivo multipath:"
if multipath -ll | grep -q "$(basename ${WWID_DEV})"; then
  echo "  OK: WWID detectado"
else
  echo "  ERRO: WWID não detectado"
fi

# DLM override
echo "- Configuração dlm.service:"
grep -q "dlm_controld --foreground" /etc/systemd/system/dlm.service.d/override.conf \
  && echo "  OK: override aplicado" \
  || echo "  ERRO: override ausente ou incorreto"

# SBD
echo "- SBD fencing:"
systemctl is-active --quiet sbd && echo "  OK: sbd ativo" || echo "  ERRO: sbd inativo"
grep -q "^SBD_DEVICE=\"${SBD_PARTITION}\"" /etc/default/sbd \
  && echo "  OK: SBD_DEVICE correto" \
  || echo "  ERRO: SBD_DEVICE incorreto em /etc/default/sbd"

# Cluster
echo "- Status do cluster:"
if command -v crm &> /dev/null; then
  crm status | sed -n '1,5p'
else
  echo "  AVISO: comando crm não disponível"
fi

echo
echo "Preparação e verificação concluídas."
