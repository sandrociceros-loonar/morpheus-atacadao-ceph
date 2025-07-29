# Instruções

## Comandos úteis

Lista as interfaces ativas e seus IPs

```bash
ip -o -4 addr show | awk '{print $2, $4}' | cut -d/ -f1
```

Após alterações no netplan

````bash
sudo netplan generate
sudo netplan apply
```

