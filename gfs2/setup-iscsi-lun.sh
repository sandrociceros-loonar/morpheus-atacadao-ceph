#!/bin/bash

################################################################################
# Script: setup-iscsi-lun.sh
# Descrição: Configuração completa de initiator iSCSI e multipath em nós do cluster
#
# FUNCIONALIDADES:
# - Instala e configura open-iscsi e multipath-tools
# - Conecta ao target iSCSI e configura sessões
# - Configura multipath para device compartilhado
# - Prepara device para uso em cluster GFS2
# - Configura montagem automática
#
# PRÉ-REQUISITOS:
# - VM com TGT (iSCSI Target) funcionando
# - Target iSCSI disponível e acessível
# - Conectividade de rede entre VMs
#
# USO:
# Execute em AMBAS as VMs (fc-test1 e fc-test2)
# sudo ./setup-iscsi-lun.sh
#
# VERSÃO: 1.0 - Script baseado na configuração desenvolvida
################################################################################

function error_exit {
    echo "❌ Erro: $1"
    exit 1
}

function log_info {
    echo "ℹ️  $1"
}

function log_success {
    echo "✅ $1"
}

function log_warning {
    echo "⚠️  $1"
}

# Verificar se está rodando como root/sudo
if [[ $EUID -ne 0 ]]; then
   error_exit "Este script deve ser executado como root ou com sudo"
fi

echo "======================================================================"
echo "🎯 Configuração de iSCSI Initiator e Multipath"
echo "======================================================================"

# Detectar hostname atual
CURRENT_NODE=$(hostname)
echo "Nó atual: $CURRENT_NODE"

# === CONFIGURAÇÃO INTERATIVA ===
echo ""
log_info "Configuração do Target iSCSI..."

# Solicitar informações do target
read -p "IP do servidor iSCSI Target: " TARGET_IP
if [ -z "$TARGET_IP" ]; then
    error_exit "IP do target é obrigatório"
fi

read -p "IQN do target iSCSI (ex: iqn.2024-01.com.lab:target01): " TARGET_IQN
if [ -z "$TARGET_IQN" ]; then
    error_exit "IQN do target é obrigatório"
fi

# Verificar conectividade com o target
log_info "Testando conectividade com $TARGET_IP..."
if ! ping -c 2 "$TARGET_IP" &>/dev/null; then
    log_warning "Target $TARGET_IP não responde ao ping. Continuando mesmo assim..."
fi

# === INSTALAÇÃO DE PACOTES ===
log_info "Instalando pacotes necessários..."

apt update || error_exit "Falha no apt update"
apt install -y open-iscsi multipath-tools lvm2 || error_exit "Falha na instalação de pacotes"

log_success "Pacotes instalados com sucesso"

# === CONFIGURAÇÃO DO iSCSI INITIATOR ===
log_info "Configurando iSCSI initiator..."

# Iniciar e habilitar serviço iscsid
systemctl enable --now iscsid
systemctl enable --now open-iscsi

# Verificar se serviços estão rodando
if ! systemctl is-active --quiet iscsid; then
    error_exit "Serviço iscsid não está ativo"
fi

log_success "Serviços iSCSI iniciados"

# === DESCOBERTA E CONEXÃO DO TARGET ===
log_info "Descobrindo targets iSCSI..."

# Descobrir targets
iscsiadm -m discovery -t sendtargets -p "$TARGET_IP" || error_exit "Falha na descoberta do target"

# Conectar ao target específico
log_info "Conectando ao target $TARGET_IQN..."
iscsiadm -m node -T "$TARGET_IQN" -p "$TARGET_IP" --login || error_exit "Falha ao conectar ao target"

# Configurar login automático
iscsiadm -m node -T "$TARGET_IQN" -p "$TARGET_IP" --op update --name node.startup --value automatic

log_success "Conectado ao target iSCSI com sucesso"

# Verificar sessões ativas
log_info "Verificando sessões iSCSI..."
iscsiadm -m session

# === CONFIGURAÇÃO DO MULTIPATH ===
log_info "Configurando multipath..."

# Iniciar e habilitar multipath
systemctl enable --now multipathd

# Aguardar estabilização
sleep 3

# Recarregar configuração multipath
multipath -r

# Verificar devices multipath
log_info "Verificando devices multipath..."
multipath -ll

# === IDENTIFICAÇÃO DO DEVICE MULTIPATH ===
log_info "Identificando device multipath criado..."

# Aguardar criação do device
sleep 5

# Listar devices em /dev/mapper/
echo "Devices multipath disponíveis:"
ls -la /dev/mapper/ | grep -v control

# Tentar identificar o device automaticamente
MULTIPATH_DEVICE=""
for device in /dev/mapper/*; do
    if [ "$device" != "/dev/mapper/control" ] && [ -e "$device" ]; then
        # Verificar se é um device de bloco válido
        if [ -b "$device" ]; then
            MULTIPATH_DEVICE="$device"
            break
        fi
    fi
done

if [ -n "$MULTIPATH_DEVICE" ]; then
    log_success "Device multipath detectado: $MULTIPATH_DEVICE"
else
    log_warning "Device multipath não detectado automaticamente"
    echo "Devices disponíveis em /dev/mapper/:"
    ls -la /dev/mapper/
    read -p "Digite o caminho completo do device multipath: " MULTIPATH_DEVICE
    
    if [ ! -e "$MULTIPATH_DEVICE" ]; then
        error_exit "Device $MULTIPATH_DEVICE não existe"
    fi
fi

# === CONFIGURAÇÃO DE ALIAS MULTIPATH ===
log_info "Configurando alias multipath..."

# Criar configuração multipath com alias
MULTIPATH_CONF="/etc/multipath.conf"
DEVICE_WWID=$(multipath -ll | grep -A 1 "$MULTIPATH_DEVICE" | grep -o '[0-9a-f]\{32\}' | head -1)

if [ -n "$DEVICE_WWID" ]; then
    cat >> "$MULTIPATH_CONF" << EOF

# Configuração para LUN do cluster
multipaths {
    multipath {
        wwid $DEVICE_WWID
        alias fc-lun-cluster
    }
}
EOF
    
    # Recarregar configuração
    systemctl reload multipathd
    multipath -r
    
    # Aguardar criação do alias
    sleep 3
    
    if [ -e "/dev/mapper/fc-lun-cluster" ]; then
        MULTIPATH_DEVICE="/dev/mapper/fc-lun-cluster"
        log_success "Alias fc-lun-cluster configurado com sucesso"
    fi
fi

# === VERIFICAÇÃO DO DEVICE ===
log_info "Verificando acessibilidade do device..."

# Testar leitura do device
if dd if="$MULTIPATH_DEVICE" of=/dev/null bs=4096 count=1 &>/dev/null; then
    log_success "Device $MULTIPATH_DEVICE está acessível"
else
    error_exit "Device $MULTIPATH_DEVICE não está acessível"
fi

# Obter tamanho do device
DEVICE_SIZE=$(lsblk -b -d -o SIZE "$MULTIPATH_DEVICE" 2>/dev/null)
if [ -n "$DEVICE_SIZE" ]; then
    DEVICE_SIZE_GB=$((DEVICE_SIZE / 1024 / 1024 / 1024))
    log_info "Tamanho do device: ${DEVICE_SIZE_GB}GB"
fi

# === CONFIGURAÇÃO FINAL ===
echo ""
echo "======================================================================"
echo "✅ CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!"
echo "======================================================================"

echo ""
echo "📋 RESUMO DA CONFIGURAÇÃO:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Nó atual:            $CURRENT_NODE"
echo "Target IP:           $TARGET_IP"
echo "Target IQN:          $TARGET_IQN"
echo "Device multipath:    $MULTIPATH_DEVICE"
if [ -n "$DEVICE_SIZE_GB" ]; then
echo "Tamanho da LUN:      ${DEVICE_SIZE_GB}GB"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "🔍 COMANDOS DE VERIFICAÇÃO:"
echo "iscsiadm -m session                   # Verificar sessões iSCSI"
echo "multipath -ll                         # Status do multipath"
echo "lsblk | grep -E '(fc-lun|dm-)'        # Listar devices relacionados"

echo ""
echo "⚠️  PRÓXIMOS PASSOS:"
echo "1. Execute este script no OUTRO nó do cluster também"
echo "2. Depois execute o script install-lun-prerequisites.sh em ambos os nós"
echo "3. Configure o cluster GFS2 com configure-lun-multipath.sh"
echo "4. Teste a sincronização com test-lun-gfs2.sh"

echo ""
echo "💡 INFORMAÇÕES IMPORTANTES:"
echo "- O device $MULTIPATH_DEVICE agora está disponível para uso em cluster"
echo "- O login iSCSI foi configurado como automático"
echo "- O multipath está ativo e monitorando o device"
echo "- Execute o mesmo script no outro nó para configuração completa"

echo ""
log_success "Setup do iSCSI initiator concluído no nó $CURRENT_NODE!"
