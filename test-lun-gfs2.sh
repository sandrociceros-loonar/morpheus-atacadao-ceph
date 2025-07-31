#!/bin/bash

function error_exit {
    echo "Erro: $1"
    exit 1
}

# Ponto de montagem esperado (ajuste caso mude!)
MOUNT_POINT="/mnt/gfs2"

echo "=== Teste básico de LUN GFS2 compartilhada no ponto $MOUNT_POINT ==="

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
SERVICOS=(dlm lvmlockd multipathd corosync pacemaker)
echo "Checando serviços essenciais locais:"
for serv in "${SERVICOS[@]}"; do
    if systemctl is-active --quiet "$serv"; then
        echo "✔ Serviço $serv ativo"
    else
        echo "⚠ Serviço $serv NÃO está ativo!"
    fi
done

# 3. Teste prático de escrita e leitura

TESTFILE="$MOUNT_POINT/test_gfs2_$(hostname)_$$.txt"
echo "Efetuando teste de escrita no arquivo $TESTFILE..."
echo "Teste GFS2 multipath - Nó $(hostname) - $(date)" > "$TESTFILE" || error_exit "Falha ao escrever no arquivo de teste."
sync

echo "Conteúdo do arquivo após escrita:"
cat "$TESTFILE"
echo

read -p "Agora, execute este script no outro nó e verifique se o arquivo criado aqui aparece também. Se quiser, pressione Enter para verificar visualmente abaixo."

echo "Listando arquivos existentes em $MOUNT_POINT:"
ls -l "$MOUNT_POINT"

echo
echo "Removendo arquivo de teste $TESTFILE..."
rm -f "$TESTFILE" || echo "Falha ao remover arquivo $TESTFILE (isso pode exigir permissões)."

echo
echo "Teste básico concluído."

echo
cat << EOF

==== Recomendações pós-teste ====

- Se o arquivo criado aparecer no outro nó imediatamente após a escrita, a sincronização do GFS2 e bloqueio distribuído está funcionando.
- Caso contrário, revise os serviços dlm, lvmlockd, multipathd, corosync, pacemaker nos dois nós.
- Verifique logs: 
   - journalctl -u dlm
   - journalctl -u lvmlockd
   - journalctl -u corosync
   - dmesg para mensagens do sistema de arquivos.
- Certifique-se do uso das opções corretas de montagem no /etc/fstab (lockproto=lock_dlm,sync).
- Revise o status do volume LVM compartilhado e sua ativação.
- Confirme que STONITH está configurado para proteção do cluster.
  
EOF
