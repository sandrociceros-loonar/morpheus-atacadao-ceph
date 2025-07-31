#!/bin/bash

echo "=== Configuração do Segundo Nó do Cluster GFS2 ==="

# Verificar se cluster está ativo
if ! sudo pcs status &>/dev/null; then
    echo "❌ Cluster não está ativo neste nó"
    exit 1
fi

# Detectar nome do cluster
CLUSTER_NAME=$(sudo pcs status cluster 2>/dev/null | grep -i "cluster name" | awk '{print $3}')
if [ -z "$CLUSTER_NAME" ]; then
    CLUSTER_NAME=$(sudo grep -E "^\s*cluster_name:" /etc/corosync/corosync.conf 2>/dev/null | awk '{print $2}')
fi

echo "Nome do cluster detectado: $CLUSTER_NAME"

# Verificar se GFS2 já está formatado
DEVICE="/dev/mapper/fc-lun-cluster"
if ! sudo file -s "$DEVICE" | grep -q gfs2; then
    echo "❌ Device não contém filesystem GFS2. Execute o script completo no primeiro nó primeiro."
    exit 1
fi

echo "✅ Filesystem GFS2 já existe no device"

# Criar ponto de montagem
sudo mkdir -p /mnt/gfs2

# Montar GFS2 (sem formatação)
echo "Montando GFS2 compartilhado..."
sudo mount -t gfs2 -o lockproto=lock_dlm,sync "$DEVICE" /mnt/gfs2

if [ $? -eq 0 ]; then
    echo "✅ GFS2 montado com sucesso!"
    
    # Configurar fstab
    if ! grep -q "/mnt/gfs2" /etc/fstab; then
        echo "$DEVICE /mnt/gfs2 gfs2 defaults,lockproto=lock_dlm,sync 0 0" | sudo tee -a /etc/fstab
        echo "✅ Entrada adicionada ao /etc/fstab"
    fi
    
    # Configurar permissões
    sudo chown -R morpheus-node:kvm /mnt/gfs2 2>/dev/null || true
    sudo chmod -R 775 /mnt/gfs2
    
    echo "✅ Segundo nó configurado com sucesso!"
    echo ""
    echo "=== Teste de Sincronização ==="
    echo "Crie um arquivo no fc-test1:"
    echo "echo 'teste-do-fc-test1' | sudo tee /mnt/gfs2/teste-sync.txt"
    echo ""
    echo "Depois verifique neste nó:"
    echo "cat /mnt/gfs2/teste-sync.txt"
    
else
    echo "❌ Falha na montagem do GFS2"
    echo "Verifica se o primeiro nó está funcionando e se o cluster está saudável"
fi
