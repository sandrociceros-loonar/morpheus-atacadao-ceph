#!/bin/bash

################################################################################
# Script: install-tgt-iscsi-target.sh
# Descrição: Instalação e configuração completa do TGT iSCSI Target
#
# FUNCIONALIDADES:
# - Instala e configura TGT (Target iSCSI) no Ubuntu/Proxmox
# - Cria e configura targets iSCSI automaticamente
# - Configura autenticação CHAP
# - Cria LUNs baseadas em arquivos ou devices de bloco
# - Configura permissões de acesso por IP/IQN
# - Habilita serviços para inicialização automática
#
# PRÉ-REQUISITOS:
# - Ubuntu 20.04/22.04 ou Proxmox VE
# - Acesso sudo/root
# - Espaço em disco para criar LUNs
#
# USO:
# sudo ./install-tgt-iscsi-target.sh
#
# VERSÃO: 1.0 - Script completo baseado na configuração desenvolvida
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
echo "🎯 Instalação e Configuração do TGT iSCSI Target"
echo "======================================================================"

# === FASE 1: Instalação de Pacotes ===
log_info "Instalando pacotes TGT..."

apt update || error_exit "Falha no apt update"
apt install -y tgt tgt-utils || error_exit "Falha na instalação do TGT"

log_success "Pacotes TGT instalados com sucesso"

# === FASE 2: Configuração Básica ===
log_info "Configurando serviços TGT..."

# Habilitar e iniciar serviços
systemctl enable tgt
systemctl start tgt

# Verificar se serviço está rodando
if systemctl is-active --quiet tgt; then
    log_success "Serviço TGT iniciado com sucesso"
else
    error_exit "Falha ao iniciar serviço TGT"
fi

# === FASE 3: Configuração Interativa ===
echo ""
log_info "Configuração do Target iSCSI"

# Solicitar configurações básicas
read -p "Nome do Target (ex: iqn.2024-01.com.empresa:target01): " TARGET_NAME
if [ -z "$TARGET_NAME" ]; then
    TARGET_NAME="iqn.2024-01.com.lab:target01"
    log_warning "Usando nome padrão: $TARGET_NAME"
fi

read -p "Tamanho da LUN em GB (ex: 10): " LUN_SIZE_GB
if [ -z "$LUN_SIZE_GB" ]; then
    LUN_SIZE_GB="10"
    log_warning "Usando tamanho padrão: ${LUN_SIZE_GB}GB"
fi

read -p "Diretório para armazenar LUNs [/var/lib/tgt/luns]: " LUN_DIR
LUN_DIR=${LUN_DIR:-/var/lib/tgt/luns}

read -p "IP dos initiators permitidos (separados por vírgula, ou * para todos): " ALLOWED_IPS
ALLOWED_IPS=${ALLOWED_IPS:-*}

# Configuração de autenticação CHAP
read -p "Configurar autenticação CHAP? [s/N]: " SETUP_CHAP
SETUP_CHAP=$(echo "${SETUP_CHAP:-n}" | tr '[:upper:]' '[:lower:]')

if [[ "$SETUP_CHAP" == "s" || "$SETUP_CHAP" == "y" ]]; then
    read -p "Usuário CHAP: " CHAP_USER
    read -s -p "Senha CHAP (mínimo 12 caracteres): " CHAP_PASS
    echo
    
    if [ ${#CHAP_PASS} -lt 12 ]; then
        error_exit "Senha CHAP deve ter pelo menos 12 caracteres"
    fi
fi

# === FASE 4: Criação do Diretório e LUN ===
log_info "Criando estrutura de diretórios e LUN..."

# Criar diretório para LUNs
mkdir -p "$LUN_DIR" || error_exit "Falha ao criar diretório $LUN_DIR"

# Nome do arquivo da LUN
LUN_FILE="$LUN_DIR/lun01.img"

# Criar arquivo da LUN usando fallocate (mais rápido)
log_info "Criando LUN de ${LUN_SIZE_GB}GB em $LUN_FILE..."
fallocate -l "${LUN_SIZE_GB}G" "$LUN_FILE" || {
    log_warning "fallocate falhou, usando dd..."
    dd if=/dev/zero of="$LUN_FILE" bs=1G count="$LUN_SIZE_GB" status=progress || error_exit "Falha ao criar arquivo da LUN"
}

# Definir permissões adequadas
chmod 600 "$LUN_FILE"
chown root:root "$LUN_FILE"

log_success "LUN criada: $LUN_FILE (${LUN_SIZE_GB}GB)"

# === FASE 5: Configuração do Target ===
log_info "Configurando target iSCSI..."

# Gerar ID único para o target
TARGET_ID=1

# Criar configuração do target
CONFIG_FILE="/etc/tgt/conf.d/target01.conf"

cat > "$CONFIG_FILE" << EOF
# Configuração do Target iSCSI - Gerada automaticamente
# Target: $TARGET_NAME
# Data: $(date)

<target $TARGET_NAME>
    # Configuração da LUN
    backing-store $LUN_FILE
    
    # Configurações de acesso
    initiator-address $ALLOWED_IPS
    
    # Configurações de performance
    write-cache on
    
    # Configurações de timeout
    scsi_sn $(openssl rand -hex 8)
    
EOF

# Adicionar configuração CHAP se solicitada
if [[ "$SETUP_CHAP" == "s" || "$SETUP_CHAP" == "y" ]]; then
    cat >> "$CONFIG_FILE" << EOF
    # Autenticação CHAP
    incominguser $CHAP_USER $CHAP_PASS
    
EOF
    log_success "Autenticação CHAP configurada"
fi

# Fechar tag do target
echo "</target>" >> "$CONFIG_FILE"

log_success "Arquivo de configuração criado: $CONFIG_FILE"

# === FASE 6: Aplicar Configuração ===
log_info "Aplicando configuração do target..."

# Recarregar configuração do TGT
tgt-admin --update ALL || error_exit "Falha ao aplicar configuração do target"

log_success "Configuração aplicada com sucesso"

# === FASE 7: Verificação ===
log_info "Verificando configuração..."

# Verificar targets configurados
TARGETS_COUNT=$(tgtadm --mode target --op show | grep "Target" | wc -l)

if [ "$TARGETS_COUNT" -gt 0 ]; then
    log_success "Target iSCSI configurado com sucesso"
else
    error_exit "Nenhum target encontrado após configuração"
fi

# === FASE 8: Configuração de Firewall (se ufw estiver ativo) ===
if command -v ufw &> /dev/null && ufw status | grep -q "Status: active"; then
    log_info "Configurando firewall (UFW)..."
    ufw allow 3260/tcp comment "iSCSI Target"
    log_success "Regra de firewall adicionada para porta 3260"
fi

# === FASE 9: Relatório Final ===
echo ""
echo "======================================================================"
echo "🎉 INSTALAÇÃO CONCLUÍDA COM SUCESSO!"
echo "======================================================================"

echo ""
echo "📋 RESUMO DA CONFIGURAÇÃO:"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "Target Name:       $TARGET_NAME"
echo "LUN File:          $LUN_FILE"
echo "LUN Size:          ${LUN_SIZE_GB}GB"
echo "Allowed IPs:       $ALLOWED_IPS"
echo "Config File:       $CONFIG_FILE"
if [[ "$SETUP_CHAP" == "s" || "$SETUP_CHAP" == "y" ]]; then
echo "CHAP User:         $CHAP_USER"
echo "CHAP Password:     ********** (configurada)"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

echo ""
echo "🔍 COMANDOS DE VERIFICAÇÃO:"
echo "tgtadm --mode target --op show        # Ver targets configurados"
echo "tgtadm --mode conn --op show          # Ver conexões ativas"
echo "systemctl status tgt                  # Status do serviço"

echo ""
echo "🌐 CONFIGURAÇÃO DO INITIATOR (nos clientes):"
echo "# Descobrir targets:"
echo "iscsiadm -m discovery -t st -p $(hostname -I | awk '{print $1}'):3260"
echo ""
echo "# Conectar ao target:"
echo "iscsiadm -m node --targetname $TARGET_NAME --portal $(hostname -I | awk '{print $1}'):3260 --login"

if [[ "$SETUP_CHAP" == "s" || "$SETUP_CHAP" == "y" ]]; then
echo ""
echo "# Para CHAP, antes do login configure:"
echo "iscsiadm -m node --targetname $TARGET_NAME --portal $(hostname -I | awk '{print $1}'):3260 --op=update --name node.session.auth.authmethod --value=CHAP"
echo "iscsiadm -m node --targetname $TARGET_NAME --portal $(hostname -I | awk '{print $1}'):3260 --op=update --name node.session.auth.username --value=$CHAP_USER"
echo "iscsiadm -m node --targetname $TARGET_NAME --portal $(hostname -I | awk '{print $1}'):3260 --op=update --name node.session.auth.password --value=$CHAP_PASS"
fi

echo ""
echo "⚠️  PRÓXIMOS PASSOS:"
echo "1. Configure os initiators (clientes iSCSI) nos nós do cluster"
echo "2. Teste a conectividade com os comandos acima"
echo "3. Configure multipath se necessário"
echo "4. Execute os scripts de configuração do cluster GFS2"

echo ""
echo "📁 ARQUIVOS IMPORTANTES:"
echo "/etc/tgt/conf.d/target01.conf         # Configuração do target"
echo "/var/lib/tgt/luns/lun01.img          # Arquivo da LUN"
echo "/etc/tgt/targets.conf                # Configuração principal"

echo ""
log_success "TGT iSCSI Target instalado e configurado com sucesso!"
