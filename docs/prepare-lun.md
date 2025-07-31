Aqui estão as **instruções detalhadas** para executar os scripts de preparação e configuração da LUN multipath GFS2 em cluster Ubuntu 22.04, além de sugestões de procedimentos de teste prático e scripts auxiliares para troubleshooting e acompanhamento do cluster/GFS2.

# 🛠️ Instruções Passo a Passo para Execução dos Scripts

## 1. Copie os scripts para ambos os nós

Salve o conteúdo corrigido de cada script em ambos os servidores, com os nomes:

- `install-lun-prerequisites.sh`
- `configure-lun-multipath.sh`
- (Opcional após configuração: `test-lun-gfs2.sh`, fornecido abaixo)

Garanta permissões de execução:

```bash
chmod +x install-lun-prerequisites.sh
chmod +x configure-lun-multipath.sh
chmod +x test-lun-gfs2.sh  # quando for utilizar
```

## 2. Execute o script de pré-requisitos em ambos os nós

No **primeiro nó:**

```bash
sudo ./install-lun-prerequisites.sh
```

- Siga os prompts do script para instalar pacotes, habilitar serviços e realizar checagens.
- Repita o procedimento no **segundo nó**.

> **Importante:** Certifique-se de ajustar manualmente arquivos de configuração do cluster (`/etc/corosync/corosync.conf`), criar e ativar o VG/LV compartilhado com `--shared`, e garantir que os nomes dos hosts são únicos conforme orientado.

## 3. Configure o cluster e ative o LVM compartilhado (**etapas manuais**)

- Edite o `/etc/corosync/corosync.conf` em ambos os nós para incluir ambos os IPs e autentique os nós com `pcs` (segue guia no rodapé).
- **Crie e ative o Volume Lógico Compartilhado:**
  ```bash
  sudo vgcreate --shared vg_cluster /dev/mapper/mpathX
  sudo lvcreate --shared -n lv_gfs2 -L 10G vg_cluster
  sudo lvchange --activate sy /dev/vg_cluster/lv_gfs2
  ```
- Ative o cluster usando pacotes `pcs/corosync/pacemaker` e configure STONITH conforme sua infraestrutura.

## 4. Execute o script de configuração/montagem em ambos os nós

No **primeiro nó:**

```bash
sudo ./configure-lun-multipath.sh
```
- Siga os prompts para selecionar o device multipath, montar e configurar o filesystem.
- Repita no **segundo nó**, usando o mesmo device e ponto de montagem.

## 5. Teste Básico de Sincronização

Com a LUN montada em ambos os nós:
- No nó 1:
  ```bash
  echo "Teste de GFS2" > /mnt/gfs2/teste.txt
  ```
- No nó 2:
  ```bash
  cat /mnt/gfs2/teste.txt
  ls -l /mnt/gfs2/
  ```

O arquivo deve aparecer imediatamente nos dois servidores.

# 🧪 Script Auxiliar de Teste: test-lun-gfs2.sh

Salve e execute este script depois da configuração, em ambos os nós, para checar consistência:

```bash
#!/bin/bash

MOUNT_POINT="/mnt/gfs2"
FILE="$MOUNT_POINT/test_gfs2_$(hostname)_$$.txt"

if ! mountpoint -q "$MOUNT_POINT"; then
    echo "Erro: $MOUNT_POINT não está montado."
    exit 1
fi

echo "Testando escrita em $FILE"
echo "Teste GFS2 - Nó $(hostname) - $(date)" > "$FILE" || { echo "Falha ao escrever arquivo de teste."; exit 1; }
sync
ls -l "$MOUNT_POINT"

echo "Agora, execute este script no outro nó e confira se o arquivo aparece."

# Limpeza opcional:
# rm -f "$FILE"
```

# 🚨 Auxiliares para Troubleshooting e Acompanhamento

## 1. Checar status dos serviços essenciais

```bash
systemctl status multipathd dlm-controld lvm2-lockd corosync pacemaker
```

## 2. Verificar status do cluster

```bash
sudo pcs status
```

## 3. Listar volumes compartilhados

```bash
sudo vgs -o +shared
sudo lvs -a -o vg_name,lv_name,lv_attr,lv_active
```

## 4. Checar montagem do GFS2

```bash
mount | grep gfs2
findmnt -t gfs2
```

## 5. Visualizar logs de serviços

```bash
journalctl -u multipathd -u dlm-controld -u lvm2-lockd -u corosync -u pacemaker
# Ou individualmente:
journalctl -u lvm2-lockd
journalctl -u dlm-controld
```

## 6. Verificar travas DLM no GFS2 (avançado)

```bash
sudo gfs2_tool df /mnt/gfs2
sudo gfs2_tool lockdump /mnt/gfs2
```

## 7. Verificar entradas no /etc/fstab

```bash
cat /etc/fstab | grep gfs2
```

# 📋 Referências para etapas manuais

- **Criar e iniciar cluster:**  
  - Guia rápido Pacemaker/Corosync:  
    ```
    sudo pcs cluster auth node1 node2
    sudo pcs cluster setup --name meucluster node1 node2
    sudo pcs cluster start --all
    sudo pcs status
    ```
- **Configurar STONITH:**  
  - Consulte sua infraestrutura para o método (IPMI, PDU, fencing device etc).

## 💡 **Resumo**
- Execute ambos scripts em todos os nós.
- Realize as etapas manuais descritas.
- Use o script de teste para validar a solução.
- Utilize os comandos auxiliares acima para troubleshooting e monitoramento.
- Em dúvida ou para automação/diagnóstico avançado, ajuste e amplie os exemplos conforme seu ambiente.

