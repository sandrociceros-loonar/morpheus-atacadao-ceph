#!/bin/bash

function error_exit {
    echo "Erro: $1"
    exit 1
}

function cleanup_previous_config {
    echo "=== Limpeza de Configurações Anteriores ==="
    echo "Removendo configurações conflitantes para garantir ambiente limpo..."
    
    # 1. Desmontar GFS2 existente
    echo "Verificando montagens GFS2 existentes..."
    GFS2_MOUNTS=$(mount | grep "type gfs2" | awk '{print $3}')
    for mount_point in $GFS2_MOUNTS; do
        echo "Desmontando $mount_point..."
        sudo umount "$mount_point" 2>/dev/null || true
    done
    
    # 2. Remover entradas do fstab
    echo "Limpando entradas GFS2 do /etc/fstab..."
    sudo sed -i '/gfs2/d' /etc/fstab
    
    # 3. Limpar recursos STONITH duplicados
    echo "Verificando recursos STONITH existentes..."
    if sudo pcs stonith show my-fake-fence &>/dev/null; then
        echo "Removendo STONITH dummy existente..."
        sudo pcs stonith delete my-fake-fence 2>/dev/null || true
    fi
    
    # 4. Resetar propriedades do cluster para padrão
    echo "Resetando propriedades do cluster..."
    sudo pcs property set stonith-enabled=true 2>/dev/null || true
    sudo pcs property unset no-quorum-policy 2>/dev/null || true
    
    # 5. Parar e limpar locks DLM se necessário
    echo "Limpando locks DLM existentes..."
    sudo dlm_tool plocks_stored 2>/dev/null | while read lock; do
        sudo dlm_tool plocks_stored -c "$lock" 2>/dev/null || true
    done
    
    # 6. Aguardar estabilização
    sleep 3
    echo "✔ Limpeza de configurações anteriores concluída"
    echo
}

# === EXECUTAR LIMPEZA INICIAL ===
cleanup_previous_config

# === SOLICITAR NOME DO CLUSTER ===
echo "=== Configuração do Nome do Cluster ==="
echo "O nome do cluster será usado para:"
echo "- Sistema de arquivos GFS2 (cluster_name:volume_name)"
echo "- Coordenação com DLM e Corosync"
echo "- Identificação única do cluster"
echo

# Detectar nome atual do cluster se existir
CURRENT_CLUSTER_NAME=""
if command -v pcs &>/dev/null; then
    CURRENT_CLUSTER_NAME=$(sudo pcs status cluster 2>/dev/null | grep -i "cluster name" | awk '{print $3}' || true)
    if [ -z "$CURRENT_CLUSTER_NAME" ]; then
        # Tentar obter do corosync.conf
        CURRENT_CLUSTER_NAME=$(sudo grep -E "^\s*cluster_name:" /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}' || true)
    fi
fi

if [ -n "$CURRENT_CLUSTER_NAME" ]; then
    echo "Nome do cluster atual detectado: $CURRENT_CLUSTER_NAME"
    echo "⚠️ IMPORTANTE: Para evitar conflitos, recomenda-se usar o nome atual do cluster."
    read -p "Deseja usar este nome ou definir um novo? [usar atual/novo]: " CLUSTER_CHOICE
    CLUSTER_CHOICE=$(echo "${CLUSTER_CHOICE:-usar atual}" | tr '[:upper:]' '[:lower:]')
    if [[ "$CLUSTER_CHOICE" =~ ^(usar|atual|u|a)$ ]]; then
        CLUSTER_NAME="$CURRENT_CLUSTER_NAME"
        echo "✔ Usando nome do cluster atual: $CLUSTER_NAME"
    else
        read -p "Digite o nome do cluster desejado: " CLUSTER_NAME
        echo "⚠️ AVISO: Usar nome diferente pode causar problemas de montagem GFS2!"
        echo "Será necessário reconfigurar o cluster Corosync para '$CLUSTER_NAME'."
        read -p "Deseja continuar mesmo assim? [s/N]: " CONTINUE_DIFF
        CONTINUE_DIFF=$(echo "${CONTINUE_DIFF:-n}" | tr '[:upper:]' '[:lower:]')
        if [[ "$CONTINUE_DIFF" != "s" && "$CONTINUE_DIFF" != "y" ]]; then
            echo "Usando nome do cluster atual para evitar conflitos: $CURRENT_CLUSTER_NAME"
            CLUSTER_NAME="$CURRENT_CLUSTER_NAME"
        fi
    fi
else
    echo "Nenhum cluster detectado ou nome não encontrado."
    read -p "Digite o nome do cluster desejado: " CLUSTER_NAME
fi

# Validar nome do cluster
if [ -z "$CLUSTER_NAME" ]; then
    error_exit "Nome do cluster não pode estar vazio"
fi

# Validar formato do nome (sem espaços, caracteres especiais)
if [[ ! "$CLUSTER_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error_exit "Nome do cluster deve conter apenas letras, números, hífens e underscores"
fi

echo "✔ Nome do cluster configurado: $CLUSTER_NAME"
echo

# === SOLICITAR NOME DO VOLUME GFS2 ===
DEFAULT_VOLUME_NAME="gfs2vol"
read -p "Nome do volume GFS2 [$DEFAULT_VOLUME_NAME]: " VOLUME_NAME
VOLUME_NAME=${VOLUME_NAME:-$DEFAULT_VOLUME_NAME}

# Validar nome do volume
if [[ ! "$VOLUME_NAME" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error_exit "Nome do volume deve conter apenas letras, números, hífens e underscores"
fi

echo "✔ Nome do volume GFS2: $VOLUME_NAME"
echo "✔ Identificador completo do filesystem: $CLUSTER_NAME:$VOLUME_NAME"
echo

# === CONFIGURAÇÃO STONITH MELHORADA ===

# Verificar se já existe algum recurso STONITH configurado
EXISTING_STONITH=$(sudo pcs stonith show 2>/dev/null)

if [ -n "$EXISTING_STONITH" ]; then
    echo "✔ Recursos STONITH já configurados no cluster:"
    echo "$EXISTING_STONITH"
    echo "Prosseguindo com configuração existente de fencing."
else
    echo "ATENÇÃO: O cluster NÃO possui fencing (STONITH) configurado."
    echo "Sem fencing, GFS2/DLM podem recusar operações ou ficar instáveis."
    echo
    echo "Opções disponíveis para laboratório:"
    echo "1. Criar STONITH dummy (simula fencing para testes)"
    echo "2. Desabilitar STONITH completamente (não recomendado para produção)"
    echo "3. Pular configuração de fencing"
    read -p "Escolha uma opção [1/2/3]: " STONITH_OPTION
    
    case $STONITH_OPTION in
        1)
            echo "=== Configurando STONITH Dummy ==="
            
            # Verificar e instalar pacotes fence-agents
            FENCE_PACKAGES=(fence-agents-base fence-agents-common fence-agents-extra)
            MISSING_FENCE=()
            
            for pkg in "${FENCE_PACKAGES[@]}"; do
                if ! dpkg -s "$pkg" &>/dev/null; then
                    MISSING_FENCE+=("$pkg")
                fi
            done
            
            if [ ${#MISSING_FENCE[@]} -ne 0 ]; then
                echo "Instalando pacotes fence-agents necessários: ${MISSING_FENCE[*]}"
                sudo apt update || error_exit "Falha no apt update"
                sudo apt install -y "${MISSING_FENCE[@]}" || error_exit "Falha ao instalar fence-agents"
            fi
            
            # Detectar nós do cluster
            NODELIST=$(sudo pcs status nodes 2>/dev/null | grep -oE "[a-zA-Z0-9._-]+" | grep -v -E "(Online|Offline|Standby|Maintenance|resource|running|Remote|Nodes|Pacemaker|with)" | tr '\n' ',' | sed 's/,$//')
            
            if [ -z "$NODELIST" ] || [[ "$NODELIST" =~ ^,*$ ]]; then
                read -p "Informe a lista de nós separada por vírgula (ex: fc-test1,fc-test2): " NODELIST
                NODELIST=${NODELIST// /}
            fi
            
            if [ -n "$NODELIST" ]; then
                echo "Criando STONITH dummy para nós: $NODELIST"
                if sudo pcs stonith create my-fake-fence fence_dummy pcmk_host_list="${NODELIST}"; then
                    echo "✔ STONITH dummy criado com sucesso"
                else
                    echo "⚠️ Falha ao criar STONITH dummy. Desabilitando STONITH para laboratório."
                    sudo pcs property set stonith-enabled=false
                fi
            fi
            ;;
        2)
            echo "Desabilitando STONITH para laboratório..."
            sudo pcs property set stonith-enabled=false
            echo "✔ STONITH desabilitado"
            ;;
        3)
            echo "Pulando configuração de fencing."
            echo "⚠️ AVISO: GFS2 pode falhar na montagem sem fencing adequado."
            ;;
        *)
            echo "Opção inválida. Desabilitando STONITH para permitir prosseguimento."
            sudo pcs property set stonith-enabled=false
            ;;
    esac
fi

# === Detecção de Devices ===

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
MULTIPATH_PATTERNS=(
    "fc-lun-*"
    "mpath[0-9]*"
    "mpath[a-zA-Z]*"
    "[0-9a-fA-F][0-9a-fA-F][0-9a-fA-F][0-9a-fA-F]*"
)

for pattern in "${MULTIPATH_PATTERNS[@]}"; do
    for device in /dev/mapper/$pattern; do
        if [ -e "$device" ] && [ "$device" != "/dev/mapper/control" ]; then
            if ! sudo lvdisplay "$device" &>/dev/null; then
                AVAILABLE_DEVICES+=("$device")
                echo "  Encontrado Multipath: $device"
            fi
        fi
    done
done

# 3. Fallback para devices diretos
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

# === Seleção do Device ===
echo
echo "Devices disponíveis para configuração GFS2:"
for i in "${!AVAILABLE_DEVICES[@]}"; do
    DEVICE=${AVAILABLE_DEVICES[$i]}
    SIZE=$(lsblk -bdno SIZE "$DEVICE" 2>/dev/null)
    if [ -n "$SIZE" ]; then
        SIZE_H=$(numfmt --to=iec $SIZE)
        
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

# === Limpeza do Device Selecionado ===
echo "=== Preparando Device para GFS2 ==="

# Verificar se device está montado
MONTADO=$(mount | grep -w "$DEVICE" | awk '{print $3}')
if [ -n "$MONTADO" ]; then
    echo "Device $DEVICE está montado em $MONTADO. Desmontando..."
    sudo umount "$DEVICE" || error_exit "Falha ao desmontar $DEVICE"
fi

# Limpar assinaturas existentes
echo "Limpando assinaturas existentes do device..."
sudo wipefs -a "$DEVICE" 2>/dev/null || true

# Verificar se device tem conflitos de GFS2 anterior
if sudo file -s "$DEVICE" | grep -q gfs2; then
    echo "⚠️ Device contém filesystem GFS2 anterior."
    echo "Para garantir compatibilidade, será realizada limpeza completa."
fi

echo "O device $DEVICE será formatado como GFS2 e montado em $MOUNT_POINT."
echo "Nome do cluster: $CLUSTER_NAME"
echo "Nome do volume: $VOLUME_NAME"
echo "Identificador GFS2: $CLUSTER_NAME:$VOLUME_NAME"
read -p "Confirma? (S/N): " CONFIRM
CONFIRM=$(echo "$CONFIRM" | tr '[:upper:]' '[:lower:]')
if [[ "$CONFIRM" != "s" && "$CONFIRM" != "y" ]]; then
    echo "Operação cancelada."
    exit 0
fi

# === Formatação e Montagem ===
echo "Formatando $DEVICE como GFS2 com identificador $CLUSTER_NAME:$VOLUME_NAME..."
sudo mkfs.gfs2 -j2 -p lock_dlm -t "$CLUSTER_NAME:$VOLUME_NAME" "$DEVICE" -f
MKFS_RC=$?

if [ $MKFS_RC -ne 0 ]; then
    echo "Falha na formatação. Tentando limpeza forçada..."
    sudo dd if=/dev/zero of="$DEVICE" bs=1M count=10 status=progress
    sudo mkfs.gfs2 -j2 -p lock_dlm -t "$CLUSTER_NAME:$VOLUME_NAME" "$DEVICE" -f || error_exit "Falha definitiva na formatação"
fi

if [ ! -d "$MOUNT_POINT" ]; then
    sudo mkdir -p "$MOUNT_POINT" || error_exit "Falha ao criar diretório $MOUNT_POINT"
fi

echo "Montando $DEVICE em $MOUNT_POINT..."
sudo mount -t gfs2 -o lockproto=lock_dlm,sync "$DEVICE" "$MOUNT_POINT" || {
    echo "⚠️ Falha na montagem. Verificando compatibilidade de nomes..."
    
    # Verificar se o problema é incompatibilidade de nomes
    if [ "$CLUSTER_NAME" != "$CURRENT_CLUSTER_NAME" ] && [ -n "$CURRENT_CLUSTER_NAME" ]; then
        echo "Detectado conflito de nomes do cluster!"
        echo "Filesystem: $CLUSTER_NAME | Cluster ativo: $CURRENT_CLUSTER_NAME"
        echo "Corrigindo nome no filesystem..."
        sudo tunegfs2 -T "$CURRENT_CLUSTER_NAME:$VOLUME_NAME" "$DEVICE"
        sudo mount -t gfs2 -o lockproto=lock_dlm,sync "$DEVICE" "$MOUNT_POINT" || error_exit "Falha persistente na montagem"
    else
        error_exit "Falha ao montar $DEVICE em $MOUNT_POINT"
    fi
}

# Configurar entrada no fstab
if grep -qs "$MOUNT_POINT" /etc/fstab; then
    echo "Atualizando entrada existente no /etc/fstab..."
    sudo sed -i "\|$MOUNT_POINT|d" /etc/fstab
fi
echo "$DEVICE $MOUNT_POINT gfs2 defaults,lockproto=lock_dlm,sync 0 0" | sudo tee -a /etc/fstab > /dev/null

# Configurar permissões
sudo chown -R morpheus-node:kvm "$MOUNT_POINT" 2>/dev/null || true
sudo chmod -R 775 "$MOUNT_POINT"

cat << EOF

---
[✔] Configuração concluída com sucesso!

✔ CLUSTER GFS2 CONFIGURADO:
- Nome do cluster: $CLUSTER_NAME
- Nome do volume: $VOLUME_NAME
- Identificador GFS2: $CLUSTER_NAME:$VOLUME_NAME
- Device utilizado: $DEVICE
- Sistema de arquivos: GFS2
- Ponto de montagem: $MOUNT_POINT
- Lockproto: lock_dlm (cluster)

✔ CONFIGURAÇÕES APLICADAS:
- Limpeza de configurações anteriores realizada
- Device formatado e montado com sucesso
- Entrada no /etc/fstab configurada
- Permissões adequadas aplicadas

⚠️ PRÓXIMOS PASSOS:
- Execute este script no SEGUNDO NÓ usando o MESMO nome de cluster ($CLUSTER_NAME)
- Realize testes de sincronização entre os nós
- Execute test-lun-gfs2.sh para validação completa
- Para produção: substitua STONITH dummy por fencing real

EOF

exit 0
