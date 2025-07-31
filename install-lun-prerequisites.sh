#!/bin/bash

################################################################################
# Script: install-lun-prerequisites.sh
# Descrição: Preparação completa de ambiente Ubuntu 22.04 para cluster GFS2
#
# FUNCIONALIDADES PRINCIPAIS:
# - Instala pacotes essenciais para cluster GFS2 (gfs2-utils, corosync, pacemaker, etc.)
# - Configura serviços de cluster (multipathd, dlm_controld, lvmlockd)
# - Cria unit files systemd personalizados para dlm_controld e lvmlockd (Ubuntu 22.04)
# - Ajusta configuração LVM para uso em cluster (/etc/lvm/lvm.conf)
# - Detecta automaticamente devices disponíveis (multipath ou diretos)
# - Cria Volume Group e Logical Volume compartilhado com tamanho otimizado
# - Configura usuário/grupo para permissões adequadas
# - Valida configuração de hostname único para cluster
#
# PRÉ-REQUISITOS:
# - Ubuntu 22.04 LTS
# - Acesso sudo
# - Device de storage compartilhado disponível (LUN iSCSI, multipath, etc.)
# - Conectividade de rede entre nós do cluster
#
# USO:
# 1. Execute em AMBOS os nós do cluster
# 2. Siga os prompts interativos
# 3. Após sucesso, execute configure-lun-multipath.sh
#
# SAÍDA ESPERADA:
# - Todos os serviços essenciais ativos
# - Volume LVM compartilhado criado (/dev/vg_cluster/lv_gfs2)
# - Sistema pronto para configuração GFS2
#
# COMPATIBILIDADE:
# - Ubuntu 22.04 (adaptado para ausência de unit files systemd padrão)
# - Multipath devices (/dev/mapper/*)
# - Devices diretos (/dev/sd*)
# - Ambientes físicos e virtualizados (Proxmox, VMware, etc.)
#
################################################################################

function error_exit {
    echo "Erro: $1"
    exit 1
}

function check_pkg {
    dpkg -s "$1" &>/dev/null
}

function check_service_active {
    systemctl is-active --quiet "$1"
}

function check_service_enabled {
    systemctl is-enabled --quiet "$1"
}

echo "==== Preparando ambiente Ubuntu 22.04 para LUN GFS2 em cluster ===="

PKGS=(gfs2-utils corosync dlm-controld lvm2-lockd pcs lvm2 multipath-tools)
MISSING=()

echo "Checando pacotes necessários..."
for pkg in "${PKGS[@]}"; do
    if check_pkg "$pkg"; then
        echo "✔ Pacote $pkg instalado."
    else
        MISSING+=("$pkg")
    fi
done

if [ ${#MISSING[@]} -ne 0 ]; then
    echo "Pacotes faltantes: ${MISSING[*]}"
    echo "Instalará estes pacotes essenciais para cluster e multipath:"
    echo "- gfs2-utils: suporte a sistema de arquivos GFS2"
    echo "- corosync: comunicação do cluster"
    echo "- dlm-controld: Distributed Lock Manager"
    echo "- lvm2-lockd: lock do LVM para clusters"
    echo "- pcs: gerenciador Pacemaker/Corosync"
    echo "- lvm2: volumes lógicos"
    echo "- multipath-tools: multipath para SAN/iSCSI/FC"
    read -p "Deseja instalar agora? [s/N]: " ans
    ans=${ans,,}
    if [[ $ans == "s" || $ans == "y" ]]; then
        sudo apt update || error_exit "Falha no apt update"
        sudo apt install -y "${MISSING[@]}" || error_exit "Falha instalando pacotes"
    else
        error_exit "Instalação necessária negada. Abortando."
    fi
else
    echo "✔ Todos os pacotes necessários já estão instalados."
fi

# Verificar serviço multipathd (tem unit file systemd)
echo "Verificando serviço multipathd..."
if check_service_active "multipathd" && check_service_enabled "multipathd"; then
    echo "✔ Serviço multipathd ativo e habilitado."
else
    echo "Serviço multipathd não está ativo/habilitado."
    read -p "Ativar e habilitar multipathd agora? [s/N]: " r
    r=${r,,}
    if [[ $r == "s" || $r == "y" ]]; then
        sudo systemctl enable --now multipathd || error_exit "Falha ao ativar multipathd"
        echo "✔ Serviço multipathd ativado."
    else
        error_exit "Serviço multipathd obrigatório não habilitado. Abortando."
    fi
fi

# Tratamento especial para dlm_controld (não há unit systemd por padrão)
echo "Verificando daemon dlm_controld (Distributed Lock Manager do cluster)..."
if [ -x /usr/sbin/dlm_controld ]; then
    echo "✔ Binário dlm_controld disponível em /usr/sbin/dlm_controld."
    if pgrep -x dlm_controld >/dev/null; then
        echo "✔ dlm_controld já está rodando."
    else
        echo "⚠️ O daemon dlm_controld NÃO está rodando."
        echo "No Ubuntu 22.04, dlm_controld não possui unit file systemd padrão."
        echo "Criando unit file personalizado para dlm_controld..."
        
        # Criar unit file personalizado
        sudo tee /etc/systemd/system/dlm_controld.service > /dev/null << 'EOF'
[Unit]
Description=DLM Control Daemon (Cluster Locked Filesystems)
After=network.target corosync.service
Requires=corosync.service

[Service]
Type=simple
ExecStart=/usr/sbin/dlm_controld -D
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        
        # Recarregar systemd e ativar serviço
        sudo systemctl daemon-reload
        
        read -p "Deseja habilitar e iniciar o dlm_controld agora? (s/N): " RESP
        RESP=${RESP,,}
        if [[ $RESP == "s" || $RESP == "y" ]]; then
            sudo systemctl enable --now dlm_controld || error_exit "Falha ao ativar dlm_controld"
            echo "✔ dlm_controld habilitado e iniciado via systemd."
        else
            echo "⚠️ AVISO: dlm_controld não iniciado. GFS2/DLM não funcionará corretamente."
        fi
    fi
else
    echo "❌ Binário dlm_controld não encontrado! Instale o pacote dlm-controld."
    error_exit "dlm_controld ausente, não é possível prosseguir."
fi

# Tratamento especial para lvmlockd (não há unit systemd por padrão)
echo "Verificando daemon lvmlockd (lock manager do LVM para cluster)..."
if [ -x /usr/sbin/lvmlockd ]; then
    echo "✔ Binário lvmlockd disponível em /usr/sbin/lvmlockd."
    if pgrep -x lvmlockd >/dev/null; then
        echo "✔ lvmlockd já está rodando."
    else
        echo "⚠️ O daemon lvmlockd NÃO está rodando."
        echo "No Ubuntu 22.04, lvmlockd não possui unit file systemd padrão."
        echo "Criando unit file personalizado para lvmlockd..."
        
        # Criar unit file personalizado
        sudo tee /etc/systemd/system/lvmlockd.service > /dev/null << 'EOF'
[Unit]
Description=LVM Lock Daemon
After=network.target dlm_controld.service
Requires=dlm_controld.service

[Service]
Type=simple
ExecStart=/usr/sbin/lvmlockd -D
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
        
        # Recarregar systemd
        sudo systemctl daemon-reload
        
        read -p "Deseja habilitar e iniciar o lvmlockd agora? (s/N): " RESP
        RESP=${RESP,,}
        if [[ $RESP == "s" || $RESP == "y" ]]; then
            sudo systemctl enable --now lvmlockd || error_exit "Falha ao ativar lvmlockd"
            echo "✔ lvmlockd habilitado e iniciado via systemd."
        else
            echo "⚠️ AVISO: lvmlockd não iniciado. O uso de LVM compartilhado pode não funcionar corretamente."
        fi
    fi
else
    echo "❌ Binário lvmlockd não encontrado! Instale o pacote lvm2-lockd."
    error_exit "lvmlockd ausente, não é possível prosseguir."
fi

# Assegurar configuração mínima em /etc/lvm/lvm.conf
echo "Ajustando configuração do LVM para cluster locking..."
if ! grep -q "use_lvmlockd.*=.*1" /etc/lvm/lvm.conf; then
    sudo sed -i 's/^ *use_lvmlockd *=.*/use_lvmlockd = 1/' /etc/lvm/lvm.conf 2>/dev/null || {
        echo "use_lvmlockd = 1" | sudo tee -a /etc/lvm/lvm.conf > /dev/null
    }
fi
grep -q "use_lvmlockd.*=.*1" /etc/lvm/lvm.conf && echo "✔ use_lvmlockd = 1 presente em /etc/lvm/lvm.conf"

# Checagem dos serviços de cluster corosync/pacemaker
echo "Verificando serviços de cluster corosync e pacemaker..."
for clustsvc in corosync pacemaker; do
    if check_service_active "$clustsvc"; then
        echo "✔ Serviço $clustsvc ativo."
    else
        echo "ALERTA: Serviço $clustsvc NÃO está ativo."
        read -p "Deseja continuar mesmo assim? [s/N]: " r
        r=${r,,}
        if [[ $r != "s" && $r != "y" ]]; then
            error_exit "Serviço $clustsvc deve estar ativo para cluster funcionar. Abortando."
        fi
    fi
done

# === NOVA SEÇÃO: Configuração automática de Volume LVM Compartilhado ===
echo "Verificando e configurando Volumes Lógicos LVM para compartilhar a LUN..."

# Verificar se já existe volume compartilhado
lvs_sharing=$(sudo lvs -a -o vg_name,lv_name,lv_attr --noheadings 2>/dev/null | grep wz--s)

if [ -n "$lvs_sharing" ]; then
    echo "✔ Volumes LVM compartilhados já existem:"
    echo "$lvs_sharing"
else
    echo "⚠️ Nenhum volume lógico compartilhado encontrado."
    
    # Detectar devices disponíveis (multipath ou direto)
    CANDIDATE_DEVICES=()
    
    # Procurar devices multipath primeiro
    if ls /dev/mapper/fc-lun-* &>/dev/null; then
        CANDIDATE_DEVICES+=($(ls /dev/mapper/fc-lun-*))
    fi
    
    # Procurar other multipath devices
    if ls /dev/mapper/[0-9a-fA-F]* &>/dev/null; then
        CANDIDATE_DEVICES+=($(ls /dev/mapper/[0-9a-fA-F]* | grep -v control))
    fi
    
    # Fallback para devices diretos (sdb, sdc, etc - excluindo sda que geralmente é SO)
    if [ ${#CANDIDATE_DEVICES[@]} -eq 0 ]; then
        CANDIDATE_DEVICES+=($(ls /dev/sd[b-z] 2>/dev/null | head -5))
    fi
    
    if [ ${#CANDIDATE_DEVICES[@]} -eq 0 ]; then
        echo "❌ Nenhum device candidato encontrado para criar VG compartilhado."
        error_exit "Device para LUN compartilhada não encontrado."
    fi
    
    echo "Devices candidatos detectados:"
    for i in "${!CANDIDATE_DEVICES[@]}"; do
        DEVICE=${CANDIDATE_DEVICES[$i]}
        SIZE=$(lsblk -bdno SIZE "$DEVICE" 2>/dev/null)
        if [ -n "$SIZE" ]; then
            SIZE_H=$(numfmt --to=iec $SIZE)
            echo "$((i+1)). $DEVICE - Tamanho: $SIZE_H"
        else
            echo "$((i+1)). $DEVICE - (tamanho não detectado)"
        fi
    done
    
    read -p "Selecione o device para criar VG compartilhado (número): " DEVICE_NUM
    DEVICE_INDEX=$((DEVICE_NUM-1))
    
    if [ "$DEVICE_INDEX" -lt 0 ] || [ "$DEVICE_INDEX" -ge ${#CANDIDATE_DEVICES[@]} ]; then
        error_exit "Seleção inválida."
    fi
    
    SELECTED_DEVICE=${CANDIDATE_DEVICES[$DEVICE_INDEX]}
    echo "Device selecionado: $SELECTED_DEVICE"
    
    # Obter tamanho disponível do device
    TOTAL_SIZE_BYTES=$(lsblk -bdno SIZE "$SELECTED_DEVICE")
    if [ -z "$TOTAL_SIZE_BYTES" ]; then
        error_exit "Não foi possível determinar o tamanho do device $SELECTED_DEVICE"
    fi
    
    # Calcular tamanho em GB (deixando margem de segurança de ~5%)
    TOTAL_SIZE_GB=$((TOTAL_SIZE_BYTES / 1024 / 1024 / 1024))
    USABLE_SIZE_GB=$((TOTAL_SIZE_GB * 95 / 100))
    
    # Mínimo de 1GB
    if [ "$USABLE_SIZE_GB" -lt 1 ]; then
        USABLE_SIZE_GB=1
    fi
    
    echo "Tamanho total do device: ${TOTAL_SIZE_GB}GB"
    echo "Tamanho utilizável (95%): ${USABLE_SIZE_GB}GB"
    
    read -p "Criar VG 'vg_cluster' e LV 'lv_gfs2' de ${USABLE_SIZE_GB}GB no device $SELECTED_DEVICE? [s/N]: " CREATE_LVM
    CREATE_LVM=${CREATE_LVM,,}
    
    if [[ "$CREATE_LVM" == "s" || "$CREATE_LVM" == "y" ]]; then
        echo "Criando Volume Group compartilhado..."
        
        # Verificar se o device não está sendo usado
        if sudo pvdisplay "$SELECTED_DEVICE" &>/dev/null; then
            echo "⚠️ Device $SELECTED_DEVICE já está sendo usado pelo LVM."
            read -p "Deseja remover uso anterior e recriar? [s/N]: " RECREATE
            RECREATE=${RECREATE,,}
            if [[ "$RECREATE" == "s" || "$RECREATE" == "y" ]]; then
                # Remover configuração anterior de forma segura
                sudo vgremove -f $(sudo pvdisplay "$SELECTED_DEVICE" | grep "VG Name" | awk '{print $3}') 2>/dev/null || true
                sudo pvremove -f "$SELECTED_DEVICE" 2>/dev/null || true
            else
                error_exit "Não é possível prosseguir com device em uso."
            fi
        fi
        
        # Criar VG compartilhado
        sudo vgcreate --shared vg_cluster "$SELECTED_DEVICE" || error_exit "Falha ao criar VG compartilhado"
        echo "✔ Volume Group 'vg_cluster' criado com sucesso"
        
        # Criar LV compartilhado
        sudo lvcreate --shared -n lv_gfs2 -L "${USABLE_SIZE_GB}G" vg_cluster || error_exit "Falha ao criar LV compartilhado"
        echo "✔ Logical Volume 'lv_gfs2' criado com ${USABLE_SIZE_GB}GB"
        
        # Ativar LV em modo compartilhado
        sudo lvchange --activate sy /dev/vg_cluster/lv_gfs2 || error_exit "Falha ao ativar LV compartilhado"
        echo "✔ Logical Volume ativado em modo compartilhado"
        
        # Verificar criação
        echo "Verificando volumes compartilhados criados:"
        sudo lvs -a -o vg_name,lv_name,lv_attr,lv_size --noheadings | grep wz--s
        
    else
        echo "Criação de VG/LV compartilhado cancelada pelo usuário."
        read -p "Deseja continuar sem volume compartilhado? [s/N]: " CONTINUE
        CONTINUE=${CONTINUE,,}
        if [[ "$CONTINUE" != "s" && "$CONTINUE" != "y" ]]; then
            error_exit "Volume compartilhado é necessário para cluster GFS2."
        fi
    fi
fi

# Verificação de hostname único
hostname=$(hostname)
echo "Hostname atual: $hostname"
echo "Verifique se ele é único entre os nós do cluster para evitar conflitos."
read -p "Confirma que hostname é único? [s/N]: " r
r=${r,,}
if [[ $r != "s" && $r != "y" ]]; then
    error_exit "Hostname deve ser exclusivo nos nós. Abortando."
fi

# Usuário/grupo para permissões se necessário
if ! id "morpheus-node" &>/dev/null; then
    echo "Criando usuário 'morpheus-node' e grupo 'kvm' para permissões comuns ..."
    sudo groupadd -f kvm
    sudo useradd -M -g kvm morpheus-node 2>/dev/null || echo "Usuário 'morpheus-node' pode já existir."
else
    echo "Usuário 'morpheus-node' já existe."
fi

cat << EOF

---
[✔] Checagem e configuração concluídas! O sistema está preparado para prosseguir.

⚠️ UNIT FILES CRIADOS (se necessário):
- /etc/systemd/system/dlm_controld.service
- /etc/systemd/system/lvmlockd.service

✔ VOLUME LVM COMPARTILHADO:
- Volume Group: vg_cluster
- Logical Volume: lv_gfs2
- Device: /dev/vg_cluster/lv_gfs2 (use este no próximo script)

⚠️ RECOMENDAÇÕES FUTURAS:
- Execute este script no OUTRO NÓ do cluster também
- Configure e inicie corretamente o cluster Corosync e Pacemaker
- Implemente STONITH (fencing) para garantir segurança do cluster
- Após configurar ambos os nós, execute configure-lun-multipath.sh
- Use o device /dev/vg_cluster/lv_gfs2 para o sistema de arquivos GFS2

EOF

exit 0
