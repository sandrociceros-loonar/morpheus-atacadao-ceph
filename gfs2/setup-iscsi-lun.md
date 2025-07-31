# setup-iscsi-lun.md

## 📋 Descrição do Script

O script `setup-iscsi-lun.sh` é uma ferramenta automatizada para configurar o initiator iSCSI e multipath nas VMs que atuarão como nós em um cluster de armazenamento. Este script prepara completamente os hosts para conectar-se ao target iSCSI e utilizar uma LUN compartilhada com suporte a multipath.

### **Funcionalidades principais:**

- ✅ **Instalação automática** dos pacotes essenciais (open-iscsi, multipath-tools, lvm2)
- ✅ **Configuração e inicialização** dos serviços iSCSI e multipath
- ✅ **Descoberta e conexão** automática ao target iSCSI especificado
- ✅ **Configuração de multipath** para redundância e alta disponibilidade
- ✅ **Detecção automática** do device multipath e criação de alias personalizado
- ✅ **Validação de conectividade** e acessibilidade ao dispositivo
- ✅ **Preparação para uso** em sistemas de arquivos clusterizados como GFS2

## 🚀 Como Executar

### **Pré-requisitos:**

- VM com Ubuntu 20.04/22.04 ou similar
- Target iSCSI configurado e funcionando (usando `install-tgt-iscsi-target.sh`)
- Conectividade de rede entre as VMs e o servidor iSCSI
- Conhecimento do IP do target e IQN configurado

### **Passos para execução:**

1. **Transferir o script** para as VMs onde será configurado o initiator:

```bash
# Exemplo de transferência via scp
scp setup-iscsi-lun.sh usuario@vm-cliente:/home/usuario/
```

2. **Dar permissão de execução:**

```bash
chmod +x setup-iscsi-lun.sh
```

3. **Executar o script** com privilégios administrativos:

```bash
sudo ./setup-iscsi-lun.sh
```

4. **Fornecer as informações solicitadas** durante a execução:
   - **IP do servidor iSCSI** (target)
   - **IQN do target iSCSI** (configurado no servidor)

### **Exemplo de interação:**

```
IP do servidor iSCSI Target: 192.168.1.100
IQN do target iSCSI (ex: iqn.2024-01.com.lab:target01): iqn.2024-01.com.lab:target01
```

**⚠️ Importante:** Execute este script em **ambas as VMs** que farão parte do cluster.

## 📊 Resultados Esperados

### **Configuração bem-sucedida:**

- ✅ **Pacotes instalados:** open-iscsi, multipath-tools, lvm2 configurados e ativos
- ✅ **Sessão iSCSI estabelecida:** Conexão ativa com o target especificado
- ✅ **Multipath configurado:** Paths redundantes detectados e gerenciados
- ✅ **Device disponível:** `/dev/mapper/fc-lun-cluster` criado com alias personalizado
- ✅ **Login automático:** Configuração persistente para reconexão após reboot
- ✅ **Sistema preparado:** Pronto para configuração do cluster GFS2

### **Saída final esperada:**

```
====================================================================
✅ CONFIGURAÇÃO CONCLUÍDA COM SUCESSO!
====================================================================

📋 RESUMO DA CONFIGURAÇÃO:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Nó atual:            fc-test1
Target IP:           192.168.1.100
Target IQN:          iqn.2024-01.com.lab:target01
Device multipath:    /dev/mapper/fc-lun-cluster
Tamanho da LUN:      2GB
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## 🔧 Troubleshooting

### **Problemas comuns e soluções:**

#### **❌ Falha na conexão ao target iSCSI**

**Sintomas:**
```
❌ Falha na descoberta do target
❌ Falha ao conectar ao target
```

**Soluções:**
```bash
# 1. Verificar conectividade
ping 
telnet  3260

# 2. Verificar se target está ativo
# (no servidor target)
sudo systemctl status tgt
sudo tgtadm --mode target --op show

# 3. Descoberta manual
sudo iscsiadm -m discovery -t st -p :3260

# 4. Verificar firewall
sudo ufw status
sudo iptables -L | grep 3260
```

#### **❌ Device multipath não detectado**

**Sintomas:**
```
❌ Device multipath não encontrado automaticamente
```

**Soluções:**
```bash
# 1. Verificar sessões iSCSI
sudo iscsiadm -m session

# 2. Reiniciar multipath
sudo systemctl restart multipathd
sudo multipath -r

# 3. Listar devices disponíveis
ls -la /dev/mapper/
sudo multipath -ll

# 4. Aguardar estabilização
sleep 10 && sudo multipath -ll
```

#### **❌ Problemas de autenticação CHAP**

**Sintomas:**
```
Authentication failed
Login failed
```

**Soluções:**
```bash
# 1. Configurar CHAP no initiator
sudo iscsiadm -m node -T  -p  --op update --name node.session.auth.authmethod --value CHAP
sudo iscsiadm -m node -T  -p  --op update --name node.session.auth.username --value 
sudo iscsiadm -m node -T  -p  --op update --name node.session.auth.password --value 

# 2. Tentar login novamente
sudo iscsiadm -m node -T  -p  --login
```

#### **❌ Device não acessível**

**Sintomas:**
```
❌ Device não está acessível para leitura
```

**Soluções:**
```bash
# 1. Verificar permissões
sudo ls -la /dev/mapper/fc-lun-cluster

# 2. Testar acesso direto
sudo dd if=/dev/mapper/fc-lun-cluster of=/dev/null bs=4096 count=1

# 3. Verificar logs
sudo journalctl -xe | grep -i iscsi
sudo dmesg | tail -20

# 4. Reiniciar serviços
sudo systemctl restart iscsid multipathd
```

### **Comandos úteis para diagnóstico:**

```bash
# Verificar sessões iSCSI ativas
sudo iscsiadm -m session

# Status do multipath
sudo multipath -ll

# Listar devices multipath
ls -l /dev/mapper/

# Verificar serviços
systemctl status iscsid multipathd

# Logs importantes
journalctl -u iscsid -n 20
journalctl -u multipathd -n 20

# Teste de leitura do device
sudo dd if=/dev/mapper/fc-lun-cluster of=/dev/null bs=4k count=100
```

## 💡 Próximos Passos

### **Após execução bem-sucedida:**

1. **Execute em ambas as VMs** do cluster (fc-test1 e fc-test2)
2. **Proceda com a configuração do cluster:**
   - Execute `install-lun-prerequisites.sh` em ambos os nós
   - Configure o cluster com `configure-lun-multipath.sh` no primeiro nó
   - Configure o segundo nó com `configure-second-node.sh`
3. **Teste a sincronização** com `test-lun-gfs2.sh`

### **Validação manual:**

```bash
# Verificar se device está disponível em ambos os nós
ls -la /dev/mapper/fc-lun-cluster

# Testar conectividade entre nós
ping 

# Verificar configuração multipath
sudo multipath -ll | grep fc-lun-cluster
```

## ⚠️ Notas Importantes

- **Execute o script em AMBAS as VMs** que farão parte do cluster
- **Use as mesmas informações** (IP e IQN) em ambos os nós
- **Aguarde a conclusão completa** antes de prosseguir com outros scripts
- **Documente as configurações** utilizadas para referência futura

O script `setup-iscsi-lun.sh` é fundamental para estabelecer a base do seu laboratório de cluster, criando a conectividade necessária entre as VMs e o storage compartilhado via iSCSI com suporte a multipath.