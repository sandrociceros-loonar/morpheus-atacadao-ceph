#!/bin/bash

#TODO: Prever se o device multipath já pode ter sido formatado e montado numa execução anterior. Perguntar se deseja formatar novamente ou montar o existente.


# Função erro e sair
function error_exit {
  echo "Erro: $1"
  exit 1
}

# Lista de multipaths disponíveis
MULTIPATHS=($(ls /dev/mapper/ | grep -E '^[0-9a-fA-F]{32,}$|mpath[0-9]+|mpath[a-z]+' | awk '{print "/dev/mapper/"$1}'))

if [ ${#MULTIPATHS[@]} -eq 0 ]; then
  error_exit "Nenhum device multipath encontrado em /dev/mapper/"
fi

echo "Dispositivos multipath detectados no sistema:"
for i in "${!MULTIPATHS[@]}"; do
  SIZE=$(lsblk -bdno SIZE "${MULTIPATHS[$i]}")
  SIZE_H=$(numfmt --to=iec $SIZE)
  echo "$((i+1)). ${MULTIPATHS[$i]} - Tamanho: $SIZE_H"
done

read -p "Digite o número do device multipath que deseja utilizar: " SELECAO

INDEX=$((SELECAO-1))
if ! [[ "$SELECAO" =~ ^[0-9]+$ ]] || [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge ${#MULTIPATHS[@]} ]; then
  error_exit "Seleção inválida."
fi

DEVICE=${MULTIPATHS[$INDEX]}
echo "Você selecionou: $DEVICE"

# Confirmação/alteração do local de montagem
DEFAULT_MOUNT="/mnt/vmstorage"
read -p "Informe o diretório de montagem desejado [$DEFAULT_MOUNT]: " MOUNT_POINT
MOUNT_POINT=${MOUNT_POINT:-$DEFAULT_MOUNT}

if [ "$MOUNT_POINT" = "/" ] || [ "$MOUNT_POINT" = "/boot" ] || [ "$MOUNT_POINT" = "/var" ]; then
  error_exit "Não é permitido montar sobre um ponto de montagem crítico do SO!"
fi

# Confirma com o usuário
echo "O device $DEVICE será formatado como ext4 e montado em $MOUNT_POINT."
read -p "Confirma? (S/N): " CONFIRM
CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
if [ "$CONFIRM" != "s" ] && [ "$CONFIRM" != "y" ]; then
  echo "Operação cancelada."
  exit 0
fi

# Formatar (ATENÇÃO: APAGA TODOS OS DADOS!)
sudo mkfs.ext4 -F "$DEVICE" || error_exit "Falha ao formatar $DEVICE"

# Criar ponto de montagem
if [ ! -d "$MOUNT_POINT" ]; then
  sudo mkdir -p "$MOUNT_POINT" || error_exit "Falha ao criar diretório $MOUNT_POINT"
fi

# Montar device
sudo mount "$DEVICE" "$MOUNT_POINT" || error_exit "Falha ao montar $DEVICE em $MOUNT_POINT"

# Adicionar a /etc/fstab usando UUID
UUID=$(sudo blkid -s UUID -o value "$DEVICE")
if [ -z "$UUID" ]; then
  error_exit "Não foi possível obter UUID do dispositivo $DEVICE"
fi

if grep -qs "$MOUNT_POINT" /etc/fstab; then
  echo "Entrada para $MOUNT_POINT já existe em /etc/fstab, pulando..."
else
  echo "UUID=$UUID $MOUNT_POINT ext4 defaults 0 2" | sudo tee -a /etc/fstab > /dev/null
fi

# Permissões (ajuste conforme ambiente)
sudo chown -R morpheus-node:kvm "$MOUNT_POINT"
sudo chmod -R 775 "$MOUNT_POINT"

echo "Configuração concluída:"
echo "Multipath utilizado: $DEVICE"
echo "Montado em: $MOUNT_POINT"
echo "Adicionado ao /etc/fstab para montagem automática."
echo "Agora, no Morpheus Data, crie um Directory Pool apontando para $MOUNT_POINT."
