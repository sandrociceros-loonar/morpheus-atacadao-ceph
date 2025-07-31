# test-lun-gfs2.sh

## 📋 Descrição

O script `test-lun-gfs2.sh` é uma ferramenta completa de **validação e diagnóstico** para clusters GFS2 (Global File System 2). Este script executa uma série abrangente de testes para verificar se todos os componentes do ambiente de cluster estão funcionando corretamente, incluindo conectividade entre nós, serviços essenciais, sincronização de dados e performance básica.

### **Funcionalidades Principais:**

- ✅ **Verificação de conectividade** entre nós do cluster
- ✅ **Validação de serviços** (Corosync, Pacemaker, DLM, LVM Lock Daemon)
- ✅ **Teste de multipath** e acessibilidade de devices
- ✅ **Verificação do DLM** (Distributed Lock Manager)
- ✅ **Validação do filesystem GFS2** e pontos de montagem
- ✅ **Teste de sincronização** entre nós em tempo real
- ✅ **Testes básicos de performance** (I/O sequencial)
- ✅ **Verificação de fencing/STONITH**
- ✅ **Análise de logs** de erro do sistema
- ✅ **Relatório detalhado** com status geral

## 🚀 Como Executar

### **Pré-requisitos:**

- Cluster GFS2 configurado (scripts `install-lun-prerequisites.sh` e `configure-lun-multipath.sh` executados)
- Ambos os nós do cluster funcionais
- GFS2 montado em `/mnt/gfs2`
- Conectividade de rede entre os nós

### **Execução:**

```bash
# Tornar o script executável
chmod +x test-lun-gfs2.sh

# Executar com privilégios de administrador
sudo ./test-lun-gfs2.sh
```

### **Interação Durante a Execução:**

O script solicitará as seguintes informações:

1. **Nome do primeiro nó** (padrão: hostname atual)
2. **Nome do segundo nó** do cluster
3. **Confirmação para iniciar** os testes após verificação de conectividade

**Exemplo de interação:**
```
Nome do primeiro nó do cluster [fc-test1]: fc-test1
Nome do segundo nó do cluster: fc-test2
Iniciar testes do cluster GFS2? [S/n]: s
```

## 📊 Resultados Esperados

### **Execução Bem-sucedida:**

```
====================================================================
📊 RELATÓRIO FINAL DOS TESTES
====================================================================

📋 RESUMO DOS RESULTADOS:
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Total de testes:    15
Testes aprovados:   15
Testes falharam:    0
Status geral:       ✅ TODOS OS TESTES APROVADOS
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### **Interpretação dos Status:**

| Status | Significado | Ação Necessária |
|--------|-------------|-----------------|
| **✅ TODOS OS TESTES APROVADOS** | Cluster 100% funcional | Nenhuma ação necessária |
| **⚠️ MAJORITARIAMENTE FUNCIONAL** | 80%+ dos testes passaram | Verificar alertas menores |
| **❌ PROBLEMAS CRÍTICOS** | :3260
sudo iscsiadm -m node --login

# 3. Reiniciar multipath
sudo systemctl restart multipathd
sudo multipath -r

# 4. Verificar configuração multipath
sudo multipath -ll
```

#### **❌ GFS2 não está montado**

**Sintomas:**
```
❌ Filesystem GFS2 não está montado
```

**Soluções:**
```bash
# 1. Verificar se device existe
ls -la /dev/mapper/fc-lun-cluster

# 2. Verificar se filesystem existe
sudo file -s /dev/mapper/fc-lun-cluster

# 3. Montar manualmente
sudo mkdir -p /mnt/gfs2
sudo mount -t gfs2 -o lockproto=lock_dlm,sync /dev/mapper/fc-lun-cluster /mnt/gfs2

# 4. Verificar se DLM está funcionando
sudo dlm_tool status
```

#### **❌ DLM não possui lockspaces ativos**

**Sintomas:**
```
❌ DLM não possui lockspaces ativos
```

**Soluções:**
```bash
# 1. Verificar status do DLM
sudo dlm_tool status

# 2. Reiniciar DLM
sudo systemctl restart dlm_controld

# 3. Verificar cluster
sudo pcs status

# 4. Remontar GFS2
sudo umount /mnt/gfs2
sudo mount -t gfs2 -o lockproto=lock_dlm,sync /dev/mapper/fc-lun-cluster /mnt/gfs2
```

### **Comandos Úteis para Diagnóstico**

```bash
# Status geral do cluster
sudo pcs status

# Verificar montagens GFS2
mount | grep gfs2

# Status do multipath
sudo multipath -ll

# Status do DLM
sudo dlm_tool status
sudo dlm_tool ls

# Logs importantes
journalctl -u corosync -n 20
journalctl -u pacemaker -n 20
dmesg | grep -i gfs2

# Teste manual de sincronização
echo "teste-$(date)" | sudo tee /mnt/gfs2/teste-sync.txt
```

### **Problemas de Performance**

**Se os testes de I/O falharem:**

```bash
# 1. Verificar espaço em disco
df -h /mnt/gfs2

# 2. Testar I/O manualmente
sudo dd if=/dev/zero of=/mnt/gfs2/teste-io.dat bs=1M count=10
sudo dd if=/mnt/gfs2/teste-io.dat of=/dev/null bs=1M

# 3. Verificar locks GFS2
sudo gfs2_tool gettune /dev/mapper/fc-lun-cluster

# 4. Monitorar performance em tempo real
iostat -x 1
```

## 💡 Dicas Importantes

### **Execução Regular:**
- Execute o script **após qualquer alteração** na configuração do cluster
- **Teste em ambos os nós** para validação completa
- Use como **ferramenta de monitoramento** preventivo

### **Interpretação de Resultados:**
- **100% de sucesso** = ambiente totalmente funcional
- **80-99% de sucesso** = funcional com questões menores
- **<80% de sucesso** = problemas críticos que precisam correção

### **Manutenção:**
- Execute **semanalmente** em ambientes de produção
- Documente **falhas recorrentes** para análise de tendências
- Use em conjunto com **monitoramento contínuo** do cluster

O script `test-lun-gfs2.sh` é uma ferramenta essencial para garantir a **confiabilidade e performance** do seu ambiente de cluster GFS2, fornecendo validação completa e diagnósticos detalhados para manutenção proativa.