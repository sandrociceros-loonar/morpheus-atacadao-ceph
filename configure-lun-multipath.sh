#!/bin/bash

function error_exit {
    echo "Erro: $1"
    exit 1
}

# === VERIFICA E CONFIGURA STONITH DUMMY SE NÃO EXISTE (apenas para laboratório!) ===
STONITH_OK=$(sudo pcs stonith show 2>/dev/null | grep fence_dummy)
if [ -z "$STONITH_OK" ]; then
    echo
    echo "ATENÇÃO: O cluster NÃO possui fencing (STONITH) configurado."
    echo "Sem fencing, GFS2/DLM podem recusar operações ou ficar instáveis."
    read -p "Deseja criar um STONITH dummy (apenas para LAB/teste)? [s/N]: " ADDSTONITH
    ADDSTONITH=$(echo "${ADDSTONITH:-n}" | tr '[:upper:]' '[:lower:]')
    if [[ "$ADDSTONITH" == "s" || "$ADDSTONITH" == "y" ]]; then
        # Tenta listar automaticamente os nós presentes
        NODELIST=$(sudo pcs status nodes 2>/dev/null | grep -oE "[a-zA-Z0-9._-]+" | grep -v "Online" | tr '\n' ',' | sed 's/,$//')
        if [ -z "$NODELIST" ]; then
            read -p "Informe a lista de nós separada por vírgula (ex: srvmvm001a,srvmvm001b): " NODELIST
            NODELIST=${NODELIST// /}
        fi
        sudo pcs stonith create my-fake-fence fence_dummy pcmk_host_list="${NODELIST}"
        echo "STONITH dummy criado: my-fake-fence (fence_dummy, nodes: $NODELIST)."
        sleep 2
    else
        error_exit "Operação cancelada por falta de fencing. Configure fencing real ou aceite o dummy para seguir."
    fi
fi

# === Fluxo normal do script ===

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

DEFAULT_MOUNT="/mnt/gfs2"
read -p "Informe o diretório de montagem desejado [$DEFAULT_MOUNT]: " MOUNT_POINT
MOUNT_POINT=${MOUNT_POINT:-$DEFAULT_MOUNT}

if [[ "$MOUNT_POINT" =~ ^/(boot|var|)$ || "$MOUNT_POINT" = "/" ]]; then
    error_exit "Não é permitido montar sobre um ponto de montagem crítico do SO!"
fi

# Checa se device já está montado ou possui entrada no fstab
MONTADO=$(mount | grep -w "$DEVICE" | awk '{print $3}')
FSTAB_EXISTS=$(grep -w "$DEVICE" /etc/fstab || grep -w "$MOUNT_POINT" /etc/fstab)

if [ -n "$MONTADO" ] || [ -n "$FSTAB_EXISTS" ]; then
    echo "Já existe configuração/montagem anterior para $DEVICE:"
    [ -n "$MONTADO" ] && echo "Montado em: $MONTADO"
    [ -n "$FSTAB_EXISTS" ] && {
        echo "Entrada no /etc/fstab:"
        grep -w "$DEVICE" /etc/fstab
        grep -w "$MOUNT_POINT" /etc/fstab
    }
    read -p "Deseja remover a configuração anterior e reconfigurar? [s/N]: " RECONF
    RECONF=$(echo "${RECONF:-n}" | tr '[:upper:]' '[:lower:]')
    if [[ "$RECONF" != "s" && "$RECONF" != "y" ]]; then
        echo "Operação cancelada."
        exit 0
    fi

    if [ -n "$MONTADO" ]; then
        sudo umount "$DEVICE" || error_exit "Falha ao desmontar $DEVICE"
    fi
    sudo sed -i "\|$DEVICE|d" /etc/fstab
    sudo sed -i "\|$MOUNT_POINT|d" /etc/fstab
    if [ -n "$MONTADO" ] && [ "$MONTADO" != "$MOUNT_POINT" ] && [ -d "$MONTADO" ]; then
        sudo rm -rf "$MONTADO"
    fi
fi

echo "O device $DEVICE será formatado como GFS2 e montado em $MOUNT_POINT."
read -p "Confirma? (S/N): " CONFIRM
CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "y" ]]; then
    echo "Operação cancelada."
    exit 0
fi

# Tenta formatar
sudo mkfs.gfs2 -j2 -p lock_dlm -t meucluster:gfs2vol "$DEVICE"
MKFS_RC=$?

if [ $MKFS_RC -ne 0 ]; then
    echo
    echo "Falha ao formatar $DEVICE para GFS2."
    echo "⚠️ O dispositivo pode estar ocupado ou com outro sistema de arquivos/partição (ex: XFS, LVM, partições, assinatura antiga etc)."
    echo "Esse processo APAGARÁ todo conteúdo anterior desse disco!"
    read -p "Deseja forçar a limpeza, remover partições e assinaturas anteriores (wipefs/sgdisk/dd) e executar a configuração do zero? [s/N]: " ZAPCONF
    ZAPCONF=$(echo "${ZAPCONF:-n}" | tr '[:upper:]' '[:lower:]')
    if [[ "$ZAPCONF" == "s" || "$ZAPCONF" == "y" ]]; then
        echo "Limpando assinaturas e tabelas de partição..."
        sudo umount "$DEVICE" 2>/dev/null
        sudo swapoff "$DEVICE" 2>/dev/null
        sudo wipefs -a "$DEVICE"
        if command -v sgdisk &>/dev/null; then
            sudo sgdisk --zap-all "$DEVICE"
        fi
        if command -v blkdiscard &>/dev/null; then
            sudo blkdiscard "$DEVICE"
        else
            sudo dd if=/dev/zero of="$DEVICE" bs=1M count=10 status=progress
        fi
        sudo partprobe "$DEVICE" 2>/dev/null

        echo "Tentando nova formatação como GFS2..."
        sudo mkfs.gfs2 -j2 -p lock_dlm -t meucluster:gfs2vol "$DEVICE" || error_exit "Ainda falhou ao formatar $DEVICE para GFS2"
    else
        error_exit "Não foi possível preparar/formatar o device. Revisão manual obrigatória."
    fi
fi

if [ ! -d "$MOUNT_POINT" ]; then
    sudo mkdir -p "$MOUNT_POINT" || error_exit "Falha ao criar diretório $MOUNT_POINT"
fi

sudo mount -t gfs2 -o lockproto=lock_dlm,sync "$DEVICE" "$MOUNT_POINT" || error_exit "Falha ao montar $DEVICE em $MOUNT_POINT"

if grep -qs "$MOUNT_POINT" /etc/fstab; then
    echo "Entrada para $MOUNT_POINT já existe em /etc/fstab, pulando inclusão."
else
    echo "$DEVICE $MOUNT_POINT gfs2 defaults,lockproto=lock_dlm,sync 0 0" | sudo tee -a /etc/fstab > /dev/null
fi

sudo chown -R morpheus-node:kvm "$MOUNT_POINT"
sudo chmod -R 775 "$MOUNT_POINT"

cat << EOF

---
[✔] Configuração concluída!

⚠️ RECOMENDAÇÕES FUTURAS:
- Certifique-se de que os serviços do cluster (corosync, pacemaker) estão ativos e funcionais em ambos os nós.
- Verifique se o volume lógico LVM está criado, marcado com --shared e ativado em ambos os nós.
- Garanta que o nome do cluster (exemplo: meucluster:gfs2vol) usado no mkfs.gfs2 seja o mesmo em todos os nós.
- Configure STONITH (fencing) válido para produção! Esse dummy serve apenas para LAB.
- Realize testes de leitura/escrita em ambos os nós para validar a sincronização.
---

EOF

exit 0
