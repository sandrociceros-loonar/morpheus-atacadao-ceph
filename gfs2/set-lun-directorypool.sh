#!/usr/bin/env bash
#
# Script interativo para configurar Directory Pool em Ubuntu 22.04
# Detecta dispositivos multipath (WWID/dm-*), solicita seleção, configura LUN FC
# e permite escolher usuário para permissões e reinício de serviço.
# Uso: sudo ./setup_directory_pool.sh
#

set -euo pipefail

DEFAULT_MOUNT_POINT="/mnt/morpheus/directorypool"

listar_multipaths() {
  echo "Dispositivos multipath disponíveis:"
  multipath -ll | awk '/^[0-9a-f]/ { w=$1; getline; sub(/^ +`-+/, "", $0); split($0, a, " "); m=a[1]; print NR ": WWID=" w " -> mapper=" m }'
}

listar_usuarios() {
  echo "Usuários do sistema disponíveis:"
  # Filtra usuários com UID>=1000 (usuários normais)
  awk -F: '$3>=1000 && $3<65534 { print NR ": " $1 }' /etc/passwd
}

echo "==> Instalando multipath-tools e lsscsi..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y multipath-tools lsscsi

echo "==> Criando /etc/multipath.conf mínimo..."
cat > /etc/multipath.conf <<EOF
defaults {
    user_friendly_names yes
    find_multipaths yes
}
blacklist {
    devnode "^sd[a-z]"
}
EOF

echo "==> Habilitando multipathd..."
systemctl enable --now multipathd

echo
listar_multipaths
echo
read -p "Informe o número do WWID a usar: " idx
read WWID MAPPER < <(multipath -ll | awk '/^[0-9a-f]/ { w=$1; getline; sub(/^ +`-+/, "", $0); split($0, a, " "); m=a[1]; print NR, w, m }' | awk -v i="$idx" '$1==i { print $2, $3 }')
[[ -z "$WWID" || -z "$MAPPER" ]] && { echo "Seleção inválida."; exit 1; }
MAPPATH="/dev/mapper/${WWID}"
echo "Selecionado: WWID=$WWID (mapper $MAPPER)"

echo
listar_usuarios
echo
read -p "Informe o número do usuário a usar para 'agent user': " uidx
USER_AG=$(awk -F: '$3>=1000 && $3<65534 { print NR, $1 }' /etc/passwd | awk -v i="$uidx" '$1==i { print $2 }')
[[ -z "$USER_AG" ]] && { echo "Seleção inválida."; exit 1; }
echo "Usuário selecionado: $USER_AG"

read -p "Informe o diretório de montagem [${DEFAULT_MOUNT_POINT}]: " MOUNT_POINT
MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT_POINT}"
mkdir -p "$MOUNT_POINT"

echo "==> Criando XFS em $MAPPATH..."
mkfs.xfs -f "$MAPPATH"

FSTAB_LINE="$MAPPATH  $MOUNT_POINT  xfs  defaults,_netdev  0 0"
if ! grep -qF "$WWID" /etc/fstab; then
  echo "==> Adicionando em /etc/fstab..."
  echo "$FSTAB_LINE" >> /etc/fstab
else
  echo "Entrada já existe em /etc/fstab."
fi

echo "==> Montando $MOUNT_POINT..."
mount "$MOUNT_POINT"

echo "==> Ajustando permissões para $USER_AG..."
chown -R "${USER_AG}:${USER_AG}" "$MOUNT_POINT"
chmod -R 770 "$MOUNT_POINT"

echo "==> Reiniciando serviço do agente (usuário $USER_AG)..."
SERVICE_NAME="morpheus-agent"
if systemctl list-units --full -all | grep -q "${SERVICE_NAME}"; then
  systemctl restart "${SERVICE_NAME}"
  echo "Serviço '${SERVICE_NAME}' reiniciado."
else
  echo "Serviço '${SERVICE_NAME}' não encontrado; verifique manualmente."
fi

echo "==> Concluído! Directory Pool configurado em $MOUNT_POINT para $MAPPATH com usuário $USER_AG."
