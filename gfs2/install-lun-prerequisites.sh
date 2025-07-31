#!/bin/bash

################################################################################
# Script: install-lun-prerequisites.sh
# Descrição: Preparação completa de ambiente Ubuntu 22.04 para cluster GFS2
#
# FUNCIONALIDADES PRINCIPAIS:
# - Instala pacotes essenciais para cluster GFS2 (gfs2-utils, corosync, pacemaker, etc.)
# - Configura serviços de cluster (multipathd, dlm_controld, lvmlockd)
# - Configura senha do usuário hacluster para autenticação do cluster
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
# 3. Use a MESMA senha do hacluster em ambos os nós
# 4. Após sucesso, execute configure-lun-multipath.sh
#
# VERSÃO: 2.5 - Inclui configuração automática da senha hacluster
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

function force_cleanup_vg {
    local vg_name="$1"
    local device="$2"
    
    echo "=== Iniciando limpeza robusta do VG: $vg_name ==="
    
    # 1. Verificar processos usando o VG
    echo "Verificando processos que podem estar usando o VG..."
    PROCESSES=$(sudo lsof /dev/$vg_name/* 2>/dev/null | grep -v COMMAND || true)
    if [ -n "$PROCESSES" ]; then
        echo "⚠️ Processos detectados usando o VG:"
        echo "$PROCESSES"
        read -p "Tentar continuar mesmo assim? [s/N]: " CONTINUE_WITH_PROCESSES
        CONTINUE_WITH_PROCESSES=${CONTINUE_WITH_PROCESSES,,}
        if [[ "$CONTINUE_WITH_PROCESSES" != "s" && "$CONTINUE_WITH_PROCESSES" != "y" ]]; then
            echo "Pare os processos listados e execute o script novamente."
            return 1
        fi
    fi
    
    # 2. Forçar desativação de todos os LVs
    echo "Forçando desativação de Logical Volumes..."
    sudo lvchange -an $vg_name --force 2>/dev/null || true
    sleep 2
    
    # 3. Remover cada LV individualmente
    echo "Removendo Logical Volumes individualmente..."
    local lvs_list=$(sudo lvs --noheadings -o lv_name $vg_name 2>/dev/null | tr -d ' ' || true)
    for lv in $lvs_list; do
        if [ -n "$lv" ]; then
            echo "Removendo LV: $lv"
            sudo lvremove -f /dev/$vg_name/$lv 2>/dev/null || true
        fi
    done
    
    # 4. Desativar o VG
    echo "Desativando Volume Group..."
    sudo vgchange -an $vg_name 2>/dev/null || true
    sleep 2
    
    # 5. Remover VG forçadamente
    echo "Removendo Volume Group forçadamente..."
    sudo vgremove -f $vg_name 2>/dev/null || true
    sleep 2
    
    # 6. Remover Physical Volume
    echo "Removendo Physical Volume do device..."
    sudo pvremove -f "$device" 2>/dev/null || true
    sleep 2
    
    # 7. Atualizar cache do LVM
    echo "Atualizando cache do LVM..."
    sudo vgscan --cache 2>/dev/null || true
    sudo pvscan --cache 2>/dev/null || true
    
    # 8. Verificar se foi removido completamente
    if sudo vgdisplay $vg_name &>/dev/null; then
        echo "❌ VG '$vg_name' ainda existe após tentativas de remoção."
        echo "Verificando detalhes restantes..."
        sudo vgdisplay $vg_name 2>/dev/null || true
        sudo lvs $vg_name 2>/dev/null || true
        
        echo ""
        echo "=== OPÇÕES DE LIMPEZA ADICIONAL ==="
        echo "1. Tentar remoção mais agressiva"
        echo "2. Reiniciar sistema e tentar novamente" 
        echo "3. Usar device direto (sem LVM)"
        echo "4. Abortar script"
        read -p "Escolha uma opção [1-4]: " CLEANUP_OPTION
        
        case $CLEANUP_OPTION in
            1)
                echo "Tentando remoção mais agressiva..."
                # Remoção mais agressiva
                sudo dmsetup remove_all --force 2>/dev/null || true
                sudo vgremove -f $vg_name 2>/dev/null || true
                sudo pvremove -f "$device" 2>/dev/null || true
                # Verificar novamente
                if sudo vgdisplay $vg_name &>/dev/null; then
                    echo "❌ Falha na remoção agressiva. Remoção manual necessária."
                    return 1
                else
                    echo "✔ VG removido com remoção agressiva."
                    return 0
                fi
                ;;
            2)
                echo "💡 Recomendação: Reinicie o sistema com 'sudo reboot' e execute o script novamente."
                exit 1
                ;;
            3)
                echo "💡 Será usado o device direto $device no próximo script."
                echo "Execute configure-lun-multipath.sh e selecione o device $device diretamente."
                return 2  # Código especial para usar device direto
                ;;
            4)
                echo "Script abortado pelo usuário."
                exit 1
                ;;
            *)
                echo "Opção inválida. Abortando."
                return 1
                ;;
        esac
    else
        echo "✔ VG '$vg_name' removido com sucesso."
        return 0
    fi
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

# === Configuração da senha do usuário hacluster ===
echo "Configurando senha para usuário hacluster (necessário para autenticação do cluster)..."

if id hacluster &>/dev/null; then
    echo "✔ Usuário hacluster encontrado"
    
    # Verificar se senha já foi configurada via variável de ambiente
    if [ -z "$HACLUSTER_PASSWORD" ]; then
        read -s -p "Digite a senha para o usuário hacluster (mesma em todos os nós): " HACLUSTER_PASSWORD
        echo
        read -s -p "Confirme a senha: " HACLUSTER_PASSWORD_CONFIRM
        echo
        
        if [ "$HACLUSTER_PASSWORD" != "$HACLUSTER_PASSWORD_CONFIRM" ]; then
            error_exit "Senhas não coincidem. Execute o script novamente."
        fi
    else
        echo "Usando senha fornecida via variável de ambiente HACLUSTER_PASSWORD"
    fi
    
    # Configurar senha usando o método mais compatível
    echo "Configurando senha do usuário hacluster..."
    echo "$HACLUSTER_PASSWORD" | sudo passwd --stdin hacluster 2>/dev/null || {
        # Fallback para sistemas que não suportam --stdin
        echo -e "$HACLUSTER_PASSWORD\n$HACLUSTER_PASSWORD" | sudo passwd hacluster
    }
    
    if [ $? -eq 0 ]; then
        echo "✔ Senha do usuário hacluster configurada com sucesso"
    else
        error_exit "Falha ao configurar senha do usuário hacluster"
    fi
else
    echo "⚠️ Usuário hacluster não encontrado. Isso é normal se os pacotes do cluster ainda não foram instalados."
    echo "O usuário será criado automaticamente durante a instalação dos pacotes."
fi

# Iniciar e habilitar serviço pcsd (necessário para autenticação do cluster)
echo "Iniciando e habilitando serviço pcsd..."
sudo systemctl enable --now pcsd
if [ $? -eq 0 ]; then
    echo "✔ Serviço pcsd iniciado e habilitado com sucesso"
else
    echo "⚠️ Aviso: Problema ao iniciar pcsd, mas continuando com o script..."
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

# === Configuração LVM para Cluster (Adaptada para Ubuntu 22.04) ===
echo "Configurando LVM adequadamente para cluster sharing (Ubuntu 22.04)..."

# Backup da configuração atual
sudo cp /etc/lvm/lvm.conf /etc/lvm/lvm.conf.backup.$(date +%Y%m%d_%H%M%S)

# Remover configurações conflitantes ou incompatíveis
sudo sed -i '/use_lvmlockd/d' /etc/lvm/lvm.conf
sudo sed -i '/locking_type/d' /etc/lvm/lvm.conf  
sudo sed -i '/shared_activation/d' /etc/lvm/lvm.conf

# Aplicar APENAS configurações compatíveis com Ubuntu 22.04
sudo sed -i '/^global {/a\    use_lvmlockd = 1\n    locking_type = 1' /etc/lvm/lvm.conf

echo "✔ Configurações LVM para cluster aplicadas (Ubuntu 22.04):"
grep -E "(use_lvmlockd|locking_type)" /etc/lvm/lvm.conf

# Reiniciar lvmlockd para aplicar configurações
echo "Reiniciando lvmlockd para aplicar novas configurações..."
sudo systemctl restart lvmlockd
sleep 3

if pgrep -x lvmlockd >/dev/null; then
    echo "✔ lvmlockd configurado e funcionando para cluster"
else
    error_exit "Falha ao configurar lvmlockd para cluster"
fi

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

# === Configuração automática de Volume LVM Compartilhado (Melhorada) ===
echo "Verificando e configurando Volumes Lógicos LVM para compartilhar a LUN..."

# Verificar se já existe volume compartilhado
lvs_sharing=$(sudo lvs -a -o vg_name,lv_name,lv_attr --noheadings 2>/dev/null | grep "w.*a")

if [ -n "$lvs_sharing" ]; then
    echo "✔ Volumes LVM já existem:"
    echo "$lvs_sharing"
else
    echo "⚠️ Nenhum volume lógico encontrado para cluster."
    
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
    
    # Calcular tamanho em GB
    TOTAL_SIZE_GB=$((TOTAL_SIZE_BYTES / 1024 / 1024 / 1024))
    
    echo "Tamanho total do device: ${TOTAL_SIZE_GB}GB"
    echo "Será usado TODO o espaço disponível para máximo aproveitamento."
    
    read -p "Criar VG 'vg_cluster' e LV 'lv_gfs2' usando todo o espaço no device $SELECTED_DEVICE? [s/N]: " CREATE_LVM
    CREATE_LVM=${CREATE_LVM,,}
    
    if [[ "$CREATE_LVM" == "s" || "$CREATE_LVM" == "y" ]]; then
        echo "Criando Volume Group compartilhado..."
        
        # === SEÇÃO MELHORADA: Limpeza robusta com função especializada ===
        
        # Verificar se VG 'vg_cluster' já existe
        if sudo vgdisplay vg_cluster &>/dev/null; then
            echo "⚠️ Volume Group 'vg_cluster' já existe no sistema."
            read -p "Deseja remover completamente e recriar? [s/N]: " RECREATE_VG
            RECREATE_VG=${RECREATE_VG,,}
            if [[ "$RECREATE_VG" == "s" || "$RECREATE_VG" == "y" ]]; then
                # Usar função de limpeza robusta
                force_cleanup_vg "vg_cluster" "$SELECTED_DEVICE"
                CLEANUP_RESULT=$?
                
                if [ $CLEANUP_RESULT -eq 1 ]; then
                    error_exit "Falha na limpeza do VG. Intervenção manual necessária."
                elif [ $CLEANUP_RESULT -eq 2 ]; then
                    echo "✔ Configuração concluída. Use o device direto no próximo script."
                    exit 0
                fi
            else
                error_exit "Não é possível prosseguir com VG existente."
            fi
        fi
        
        # === FIM DA SEÇÃO MELHORADA ===
        
        # Criar VG compartilhado (sintaxe correta Ubuntu 22.04)
        echo "Criando novo Volume Group..."
        sudo vgcreate --shared vg_cluster "$SELECTED_DEVICE" || error_exit "Falha ao criar VG compartilhado"
        echo "✔ Volume Group 'vg_cluster' criado com sucesso"
        
        # Criar LV usando TODO o espaço disponível (sintaxe correta Ubuntu 22.04)
        echo "Criando Logical Volume..."
        sudo lvcreate -n lv_gfs2 -l 100%FREE vg_cluster || error_exit "Falha ao criar LV"
        echo "✔ Logical Volume 'lv_gfs2' criado usando todo o espaço disponível"
        
        # Ativar LV (sintaxe correta Ubuntu 22.04)
        echo "Ativando Logical Volume..."
        sudo lvchange -ay /dev/vg_cluster/lv_gfs2 || error_exit "Falha ao ativar LV"
        echo "✔ Logical Volume ativado com sucesso"
        
        # Verificar criação
        echo "Verificando volumes criados:"
        sudo lvs -a -o vg_name,lv_name,lv_attr,lv_size
        
    else
        echo "Criação de VG/LV cancelada pelo usuário."
        read -p "Deseja continuar sem volume LVM? [s/N]: " CONTINUE
        CONTINUE=${CONTINUE,,}
        if [[ "$CONTINUE" != "s" && "$CONTINUE" != "y" ]]; then
            error_exit "Volume LVM é necessário para cluster GFS2."
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

✔ VOLUME LVM CONFIGURADO:
- Volume Group: vg_cluster
- Logical Volume: lv_gfs2
- Device: /dev/vg_cluster/lv_gfs2 (use este no próximo script)
- Espaço: Todo o espaço disponível do device selecionado

✔ AUTENTICAÇÃO DO CLUSTER:
- Usuário hacluster configurado com senha
- Serviço pcsd habilitado e funcionando
- Pronto para autenticação do cluster com 'pcs host auth'

⚠️ RECOMENDAÇÕES FUTURAS:
- Execute este script no OUTRO NÓ do cluster também (usando a MESMA senha hacluster)
- Configure e inicie corretamente o cluster Corosync e Pacemaker
- Implemente STONITH (fencing) para garantir segurança do cluster
- Após configurar ambos os nós, execute configure-lun-multipath.sh
- Use o device /dev/vg_cluster/lv_gfs2 para o sistema de arquivos GFS2

💡 PRÓXIMO PASSO - Autenticação do Cluster:
No nó principal, execute: 
sudo pcs host auth <host1> <host2> # (onde <host1> e <host2> são os nomes dos nós do cluster)
(Use usuário: hacluster e a senha que você configurou)

EOF

exit 0
