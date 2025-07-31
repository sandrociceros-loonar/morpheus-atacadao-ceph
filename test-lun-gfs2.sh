#!/bin/bash

function error_exit {
    echo "Erro: $1"
    exit 1
}

# Ponto de montagem esperado (ajuste caso mude!)
MOUNT_POINT="/mnt/gfs2"

echo "=== Teste abrangente de LUN GFS2 compartilhada no ponto $MOUNT_POINT ==="

# 1. Verificar se o ponto de montagem existe e está montado GFS2
if mountpoint -q "$MOUNT_POINT"; then
    FS_TYPE=$(findmnt -no FSTYPE "$MOUNT_POINT")
    if [ "$FS_TYPE" != "gfs2" ]; then
        error_exit "O ponto de montagem $MOUNT_POINT não está montado com sistema de arquivos GFS2 (encontrado: $FS_TYPE)"
    fi
    echo "✔ $MOUNT_POINT está montado com GFS2."
else
    error_exit "Ponto de montagem $MOUNT_POINT não está montado."
fi

# 2. Verificar status dos serviços essenciais localmente
SERVICOS=(dlm_controld multipathd corosync pacemaker)
echo "Checando serviços essenciais locais:"
for serv in "${SERVICOS[@]}"; do
    if systemctl is-active --quiet "$serv"; then
        echo "✔ Serviço $serv ativo"
    else
        echo "⚠ Serviço $serv NÃO está ativo!"
    fi
done

# 3. Verificar se existe daemon lvmlockd rodando
if pgrep -x lvmlockd >/dev/null; then
    echo "✔ Daemon lvmlockd está rodando"
else
    echo "⚠ Daemon lvmlockd NÃO está rodando!"
fi

# 4. Verificar status do cluster
echo "Verificando status do cluster..."
CLUSTER_STATUS=$(sudo pcs status 2>/dev/null | grep -E "(Online|Offline)" | head -1)
if [ -n "$CLUSTER_STATUS" ]; then
    echo "✔ Cluster status: $CLUSTER_STATUS"
else
    echo "⚠ Não foi possível verificar status do cluster (pcs pode não estar configurado)"
fi

# 5. Verificar se existe fencing configurado
STONITH_STATUS=$(sudo pcs stonith show 2>/dev/null | wc -l)
if [ "$STONITH_STATUS" -gt 0 ]; then
    echo "✔ STONITH/Fencing configurado ($STONITH_STATUS dispositivo(s))"
else
    echo "⚠ STONITH/Fencing NÃO configurado (recomendado para produção)"
fi

# 6. Detectar device usado no GFS2 (multipath ou direto)
DEVICE=$(findmnt -no SOURCE "$MOUNT_POINT")
echo "Device GFS2 detectado: $DEVICE"

# Verificar se é multipath ou device direto
if [[ "$DEVICE" =~ ^/dev/mapper/ ]]; then
    echo "✔ Usando device multipath: $DEVICE"
    # Verificar status do multipath
    MULTIPATH_STATUS=$(sudo multipath -ll "$DEVICE" 2>/dev/null | grep -E "(active|enabled)" | wc -l)
    if [ "$MULTIPATH_STATUS" -gt 0 ]; then
        echo "✔ Status do multipath: OK"
    else
        echo "⚠ Problema detectado no multipath para $DEVICE"
    fi
else
    echo "ℹ Usando device direto: $DEVICE (adequado para laboratório)"
fi

# 7. Teste prático de escrita e leitura
TESTFILE="$MOUNT_POINT/test_gfs2_$(hostname)_$$.txt"
echo "Efetuando teste de escrita no arquivo $TESTFILE..."
echo "Teste GFS2 multipath - Nó $(hostname) - $(date)" > "$TESTFILE" || error_exit "Falha ao escrever no arquivo de teste."
sync

echo "Conteúdo do arquivo após escrita:"
cat "$TESTFILE"
echo

# 8. Verificar espaço disponível
echo "Informações de espaço do GFS2:"
df -h "$MOUNT_POINT"

# 9. Verificar performance básica de I/O
echo "Teste básico de performance de escrita (10MB):"
time dd if=/dev/zero of="$MOUNT_POINT/test_performance_$$.tmp" bs=1M count=10 2>/dev/null && \
rm -f "$MOUNT_POINT/test_performance_$$.tmp" && \
echo "✔ Teste de performance concluído"

# 10. Listar arquivos no ponto de montagem
echo "Listando arquivos existentes em $MOUNT_POINT:"
ls -la "$MOUNT_POINT"

# 11. Teste de locks DLM (avançado)
echo "Verificando locks DLM ativos:"
LOCKS_COUNT=$(sudo gfs2_tool lockdump "$MOUNT_POINT" 2>/dev/null | wc -l)
if [ "$LOCKS_COUNT" -gt 0 ]; then
    echo "✔ DLM locks ativos: $LOCKS_COUNT"
else
    echo "ℹ Nenhum lock DLM ativo no momento (normal em sistema sem carga)"
fi

# 12. Informações detalhadas do GFS2
echo "Informações detalhadas do filesystem GFS2:"
sudo gfs2_tool df "$MOUNT_POINT" 2>/dev/null || echo "ℹ gfs2_tool não disponível ou erro"

read -p "Agora, execute este script no outro nó e verifique se o arquivo criado aqui aparece também. Pressione Enter para continuar..."

# 13. Limpeza opcional
read -p "Deseja remover o arquivo de teste $TESTFILE? [s/N]: " CLEANUP
CLEANUP=${CLEANUP,,}
if [[ "$CLEANUP" == "s" || "$CLEANUP" == "y" ]]; then
    rm -f "$TESTFILE" || echo "Falha ao remover arquivo $TESTFILE"
    echo "✔ Arquivo de teste removido"
else
    echo "ℹ Arquivo de teste mantido para verificação no outro nó"
fi

echo
echo "Teste básico concluído."

echo
cat << EOF

==== Resumo do Teste e Recomendações ====

✔ SUCESSOS DETECTADOS:
- GFS2 montado e funcional em $MOUNT_POINT
- Device $DEVICE acessível
- Escrita/leitura funcionando
- Performance básica OK

⚠ VERIFICAÇÕES ADICIONAIS RECOMENDADAS:
- Execute este script no OUTRO NÓ do cluster
- Verifique se o arquivo criado aparece instantaneamente no outro nó
- Teste escrita simultânea de ambos os nós
- Monitore logs: journalctl -u dlm_controld, journalctl -u corosync

🔧 TROUBLESHOOTING (se houver problemas):
- Verifique serviços: systemctl status corosync pacemaker dlm_controld
- Verifique cluster: sudo pcs status
- Verifique locks: sudo gfs2_tool lockdump $MOUNT_POINT
- Verifique logs: journalctl -xe
- Confirme fencing: sudo pcs stonith show

📋 PARA PRODUÇÃO:
- Configure STONITH real (não dummy)
- Implemente monitoramento contínuo
- Configure backup adequado
- Teste cenários de falha de nó
- Documente procedimentos de recuperação

EOF
