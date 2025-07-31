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

echo "==== Preparando ambiente Ubuntu para LUN GFS2 compartilhada em cluster ===="

PKGS=(gfs2-utils corosync dlm lvmlockd pcs lvm2 multipath-tools)
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
    echo "- dlm: Distributed Lock Manager"
    echo "- lvmlockd: bloqueio para LVM compartilhado"
    echo "- pcs: ferramenta para gerenciar pacemaker/corosync"
    echo "- lvm2: gerenciador de volumes lógicos"
    echo "- multipath-tools: gerenciador de multipath para storage"
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

# Serviços essenciais
SERVICOS=(multipathd dlm lvmlockd)
for serv in "${SERVICOS[@]}"; do
    echo "Verificando serviço $serv..."
    active=0
    enabled=0
    if check_service_active "$serv"; then active=1; fi
    if check_service_enabled "$serv"; then enabled=1; fi

    if (( active && enabled )); then
        echo "✔ Serviço $serv ativo e habilitado."
    else
        echo "Serviço $serv não está ativo/habilitado."
        read -p "Ativar e habilitar $serv agora? [s/N]: " r
        r=${r,,}
        if [[ $r == "s" || $r == "y" ]]; then
            sudo systemctl enable --now "$serv" || error_exit "Falha ao ativar $serv"
            echo "✔ Serviço $serv ativado."
        else
            error_exit "Serviço $serv obrigatório não habilitado. Abortando."
        fi
    fi
done

# Verificação de cluster corosync/pacemaker
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
lvs_sharing=$(sudo lvs -a -o vg_name,lv_name,lv_attr --noheadings | grep wz--s)

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

# Verificação de hostname único (simples, exige ajuste manual)
hostname=$(hostname)
echo "Hostname atual: $hostname"
echo "Verifique se ele é único entre os nós do cluster para evitar conflitos."
read -p "Confirma que hostname é único? [s/N]: " r
r=${r,,}
if [[ $r != "s" && $r != "y" ]]; then
    error_exit "Hostname deve ser exclusivo nos nós. Abortando."
fi

# Usuário e grupo para permissões conforme ambiente
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

⚠️ RECOMENDAÇÕES FUTURAS:
- Configure e inicie corretamente o cluster Corosync e Pacemaker, editando /etc/corosync/corosync.conf para incluir os nós adequados.
- Implemente STONITH (fencing) para garantir segurança do cluster e evitar corrupção.
- Crie e ative o volume lógico LVM compartilhado com a opção --shared em ambos os nós.
- Certifique-se de manter o hostname único e consistente em ambos os servidores.
- Após finalizar estas configurações manuais, prossiga com o script de configuração/montagem da LUN (ex: configure-lun-multipath.sh).

EOF

exit 0
