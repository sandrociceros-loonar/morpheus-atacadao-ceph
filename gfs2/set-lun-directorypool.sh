#!/usr/bin/env bash
#
# Script interativo para configurar Directory Pool em Ubuntu 22.04
# Detecta dispositivos multipath (WWID/dm-*), solicita seleção, e configura LUN FC.
# Uso: sudo ./setup_directory_pool.sh
#

set -euo pipefail

DEFAULT_MOUNT_POINT="/mnt/morpheus/directorypool"

# Função para listar dispositivos multipath via WWID e mapper
listar_multipaths() {
  echo "Dispositivos multipath disponíveis:"
  multipath -ll | awk '/^[0-9a-f]/ { w=$1; getline; sub(/^ +`-+/, "", $0); split($0, a, " "); m=a[1]; print NR ": WWID=" w " -> mapper=" m }'
}

# Passo 1: Instalar pacotes necessários
echo "==> Instalando multipath-tools e lsscsi..."
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y multipath-tools lsscsi

# Passo 2: Habilitar e iniciar multipathd
echo "==> Habilitando multipathd..."
mpathconf --enable
systemctl enable --now multipathd

# Passo 3: Detectar e selecionar WWID
echo
listar_multipaths
echo
read -p "Informe o número do WWID a usar: " idx
read WWID MAPPER < <(multipath -ll | awk '/^[0-9a-f]/ { w=$1; getline; sub(/^ +`-+/, "", $0); split($0, a, " "); m=a[1]; print NR, w, m }' | awk -v i="$idx" '$1==i { print $2, $3 }')
if [[ -z "$WWID" || -z "$MAPPER" ]]; then
  echo "Seleção inválida."
  exit 1
fi
MAPPATH="/dev/mapper/${WWID}"
echo "Selecionado: WWID=$WWID (mapper $MAPPER)"

# Passo 4: Definir ponto de montagem (com padrão)
read -p "Informe o diretório de montagem [${DEFAULT_MOUNT_POINT}]: " MOUNT_POINT
MOUNT_POINT="${MOUNT_POINT:-$DEFAULT_MOUNT_POINT}"
mkdir -p "$MOUNT_POINT"

# Passo 5: Criar filesystem XFS na LUN
echo "==> Criando XFS em $MAPPATH..."
mkfs.xfs -f "$MAPPATH"

# Passo 6: Configurar /etc/fstab
FSTAB_LINE="$MAPPATH  $MOUNT_POINT  xfs  defaults,_netdev  0 0"
if ! grep -qF "$WWID" /etc/fstab; then
  echo "==> Adicionando entrada no /etc/fstab..."
  echo "$FSTAB_LINE" >> /etc/fstab
else
  echo "Entrada já existe em /etc/fstab."
fi

# Passo 7: Montar imediatamente
echo "==> Montando $MOUNT_POINT..."
mount "$MOUNT_POINT"

# Passo 8: Ajustar permissões
echo "==> Ajustando permissões para morpheus-agent..."
chown -R morpheus-agent:morpheus-agent "$MOUNT_POINT"
chmod -R 770 "$MOUNT_POINT"

# Passo 9: Reiniciar Morpheus Agent
echo "==> Reiniciando morpheus-agent..."
systemctl restart morpheus-agent

echo "==> Concluído! Directory Pool configurado em $MOUNT_POINT para $MAPPATH."
