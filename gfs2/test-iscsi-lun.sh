#!/bin/bash
# test-iscsi-setup.sh - Validação da configuração iSCSI

echo "🧪 Testando Configuração iSCSI/Multipath"
echo "========================================"

# Teste 1: Sessões iSCSI
echo -n "1. Sessões iSCSI ativas: "
SESSIONS=$(sudo iscsiadm -m session 2>/dev/null | wc -l)
if [[ $SESSIONS -gt 0 ]]; then
    echo "✅ $SESSIONS sessões encontradas"
else
    echo "❌ Nenhuma sessão ativa"
fi

# Teste 2: Dispositivo multipath
echo -n "2. Dispositivo fc-lun-cluster: "
if [[ -b "/dev/mapper/fc-lun-cluster" ]]; then
    SIZE=$(lsblk -dn -o SIZE /dev/mapper/fc-lun-cluster)
    echo "✅ Existe ($SIZE)"
else
    echo "❌ Não existe"
fi

# Teste 3: Acesso ao dispositivo
echo -n "3. Teste de leitura: "
if sudo dd if=/dev/mapper/fc-lun-cluster of=/dev/null bs=4k count=1 &>/dev/null; then
    echo "✅ Sucesso"
else
    echo "❌ Falha"
fi

# Teste 4: Status multipath
echo -n "4. Status multipath: "
if sudo multipath -ll fc-lun-cluster &>/dev/null; then
    echo "✅ OK"
else
    echo "❌ Problema"
fi

# Teste 5: Serviços habilitados
echo -n "5. Serviços auto-start: "
if systemctl is-enabled --quiet open-iscsi && systemctl is-enabled --quiet multipathd; then
    echo "✅ Configurados"
else
    echo "⚠️  Verificar configuração"
fi

echo ""
echo "📋 Relatório Detalhado:"
echo "Sessões iSCSI:"
sudo iscsiadm -m session 2>/dev/null || echo "Nenhuma sessão"

echo ""
echo "Dispositivos multipath:"
sudo multipath -ll 2>/dev/null || echo "Nenhum mapa multipath"

echo ""
echo "Dispositivo final:"
lsblk /dev/mapper/fc-lun-cluster 2>/dev/null || echo "Dispositivo não encontrado"

echo ""
echo "🎯 Teste concluído!"
