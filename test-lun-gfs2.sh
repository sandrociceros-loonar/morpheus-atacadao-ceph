#!/bin/bash

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

# Verificar volume LVM compartilhado
echo "Verificando Volumes Lógicos do LVM para compartilhar a LUN..."
echo "Listando VG e LVs com atributo compartilhado (wz--s):"
lvs_sharing=$(sudo lvs -a -o vg_name,lv_name,lv_attr --noheadings 2>/dev/null | grep wz--s)

if [ -z "$lvs_sharing" ]; then
    echo "Nenhum volume lógico ativado com opção --shared encontrado."
    echo "É necessário criar e ativar o VG/LV com --shared para uso em cluster."
    echo "Exemplo: sudo vgcreate --shared vg_cluster /dev/sdX"
    echo "sudo lvcreate --shared -n lv_gfs2 -L tamanho vg_cluster"
    read -p "Deseja continuar mesmo assim? [s/N]: " r
    r=${r,,}
    if [[ $r != "s" && $r != "y" ]]; then
        error_exit "Volume compartilhado necessário ausente. Abortando."
    fi
else
    echo "Volumes com --shared ativados encontrados:"
    echo "$lvs_sharing"
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
[✔] Checagem concluída! O sistema está preparado para prosseguir.

⚠️ UNIT FILES CRIADOS:
- /etc/systemd/system/dlm_controld.service
- /etc/systemd/system/lvmlockd.service

⚠️ RECOMENDAÇÕES FUTURAS:
- Configure e inicie corretamente o cluster Corosync e Pacemaker, editando /etc/corosync/corosync.conf para incluir os nós adequados.
- Implemente STONITH (fencing) para garantir segurança do cluster e evitar corrupção.
- Crie e ative o volume lógico LVM compartilhado com a opção --shared em ambos os nós.
- Certifique-se de manter o hostname único e consistente nos servidores.
- Após finalizar estas configurações manuais, prossiga com o script de configuração/montagem da LUN (ex: configure-lun-multipath.sh).

EOF

exit 0
