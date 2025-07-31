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
        NODELIST=$(sudo pcs status nodes 2>/dev/null | grep -oE "[a-zA-Z0-9._-]+" | grep -v "Online" | tr '\n' ',' | sed 's/,$//')
        if [ -z "$NODELIST" ]; then
            read -p "Informe a lista de nós separada por vírgula (ex: fc-test1,fc-test2): " NODELIST
            NODELIST=${NODELIST// /}
        fi
        sudo pcs stonith create my-fake-fence fence_dummy pcmk_host_list="${NODELIST}"
        echo "STONITH dummy criado: my-fake-fence (fence_dummy, nodes: $NODELIST)."
        sleep 2
    else
        error_exit "Operação cancelada por falta de fencing. Configure fencing real ou aceite o dummy para seguir."
    fi
fi

# === Detecção Melhorada de Devices (LVM + Multipath Direto) ===

AVAILABLE_DEVICES=()

echo "Detectando devices disponíveis para GFS2..."

# 1. Procurar devices LVM compartilhados primeiro
echo "Procurando volumes LVM compartilhados..."
LVM_DEVICES=$(sudo lvs -a -o lv_path,lv_attr --noheadings 2>/dev/null | grep "w.*a" | awk '{print $1}' | tr -d ' ')
for lvm_dev in $LVM_DEVICES; do
    if [ -e "$lvm_dev" ]; then
        AVAILABLE_DEVICES+=("$lvm_dev")
        echo "  Encontrado LVM: $lvm_dev"
    fi
done

# 2. Procurar devices multipath diretos
echo "Procurando devices multipath diretos..."
# Padrão expandido para capturar fc-lun-*, mpath*, e devices com IDs
MULTIPATH_PATTERNS=(
    "fc-lun-*"           # fc-lun-cluster, fc-lun-storage, etc.
    "mpath[0-9]*"        # mpath0, mpath1, etc.
    "mpath[a-zA-Z]*"     # mpatha, mpathb, etc.
    "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*" # IDs hexadecimais
)

for pattern in "${MULTIPATH_PATTERNS[@]}"; do
    for device in /dev/mapper/$pattern; do
        if [ -e "$device" ] && [ "$device" != "/dev/mapper/control" ]; then
            # Verificar se não é LVM (evitar duplicatas)
            if ! sudo lvdisplay "$device" &>/dev/null; then
                AVAILABLE_DEVICES+=("$device")
                echo "  Encontrado Multipath: $device"
            fi
        fi
    done
done

# 3. Fallback para devices diretos (sdb, sdc, etc.) se nenhum multipath foi encontrado
if [ ${#AVAILABLE_DEVICES[@]} -eq 0 ]; then
    echo "Procurando devices diretos como fallback..."
    for device in /dev/sd[b-z]; do
        if [ -e "$device" ]; then
            AVAILABLE_DEVICES+=("$device")
            echo "  Encontrado device direto: $device"
        fi
    done
fi

# Verificar se encontrou algum device
if [ ${#AVAILABLE_DEVICES[@]} -eq 0 ]; then
    error_exit "Nenhum device disponível encontrado para configurar GFS2"
fi

# === Exibir lista de devices disponíveis ===
echo
echo "Devices disponíveis para configuração GFS2:"
for i in "${!AVAILABLE_DEVICES[@]}"; do
    DEVICE=${AVAILABLE_DEVICES[$i]}
    SIZE=$(lsblk -bdno SIZE "$DEVICE" 2>/dev/null)
    if [ -n "$SIZE" ]; then
        SIZE_H=$(numfmt --to=iec $SIZE)
        
        # Identificar o tipo do device
        DEVICE_TYPE="Direto"
        if [[ "$DEVICE" =~ ^/dev/vg_ ]] || sudo lvdisplay "$DEVICE" &>/dev/null; then
            DEVICE_TYPE="LVM"
        elif [[ "$DEVICE" =~ ^/dev/mapper/ ]]; then
            DEVICE_TYPE="Multipath"
        fi
        
        echo "$((i+1)). $DEVICE - Tamanho: $SIZE_H - Tipo: $DEVICE_TYPE"
    else
        echo "$((i+1)). $DEVICE - (tamanho não detectado)"
    fi
done

read -p "Digite o número do device que deseja utilizar: " SELECAO
INDEX=$((SELECAO-1))
if ! [[ "$SELECAO" =~ ^[0-9]+$ ]] || [ "$INDEX" -lt 0 ] || [ "$INDEX" -ge ${#AVAILABLE_DEVICES[@]} ]; then
    error_exit "Seleção inválida."
fi
DEVICE=${AVAILABLE_DEVICES[$INDEX]}
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

✔ DEVICE CONFIGURADO:
- Device utilizado: $DEVICE
- Sistema de arquivos: GFS2
- Ponto de montagem: $MOUNT_POINT
- Lockproto: lock_dlm (cluster)

⚠️ RECOMENDAÇÕES FUTURAS:
- Certifique-se de que os serviços do cluster (corosync, pacemaker) estão ativos e funcionais em ambos os nós.
- Garanta que o nome do cluster (exemplo: meucluster:gfs2vol) usado no mkfs.gfs2 seja o mesmo em todos os nós.
- Configure STONITH (fencing) válido para produção! Esse dummy serve apenas para LAB.
- Realize testes de leitura/escrita em ambos os nós para validar a sincronização.
- Execute o script test-lun-gfs2.sh para validar o funcionamento completo.
---

EOF

exit 0
