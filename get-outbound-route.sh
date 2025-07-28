#!/bin/bash

TARGET_NET="172.18.0.0/20"

echo "🧭 Rede-alvo: $TARGET_NET"

ROUTE=$(ip route get "$TARGET_NET" 2>/dev/null)
SRC_IP=$(echo "$ROUTE" | grep -oP 'src \K[\d.]+')
IFACE=$(echo "$ROUTE" | grep -oP 'dev \K\S+')

if [[ -z "$SRC_IP" || -z "$IFACE" ]]; then
  echo "❌ Não foi possível determinar rota para $TARGET_NET"
  exit 1
fi

echo "🌐 IP de origem: $SRC_IP"
echo "🔌 Interface: $IFACE"

# Verifica se interface está em OVS
if [[ -d "/sys/class/net/$IFACE/brport" ]]; then
  echo "🔄 Interface $IFACE está em Open vSwitch"
else
  echo "🔄 Interface $IFACE NÃO está em Open vSwitch"
fi

# Informações da interface
echo "🧩 Informações da interface:"
ethtool -i "$IFACE" 2>/dev/null | grep -E 'driver|bus-info' || echo "   (Sem informações do ethtool)"
echo "📛 Modelo/NIC física:"
lshw -class network -short 2>/dev/null | grep -i "$IFACE" || echo "   (Não foi possível obter modelo da NIC)"

# Gateway
GW=$(ip route | grep "^default.*$IFACE" | awk '{print $3}')
if [[ -n "$GW" ]]; then
  echo "🚪 Gateway para $IFACE: $GW"
else
  echo "🚪 Nenhum gateway padrão encontrado para a interface $IFACE"
fi

# DNS configurado
DNS_LIST=$(grep -E "^nameserver" /etc/resolv.conf | awk '{print $2}' | paste -sd ', ')
echo "🔍 Servidores DNS configurados: $DNS_LIST"

# systemd-resolved
if grep -q "127.0.0.53" /etc/resolv.conf; then
  echo "⚠️  DNS está sendo resolvido via systemd-resolved (127.0.0.53)"
  echo "    ➤ Verifique o status com: systemctl status systemd-resolved"
  echo "    ➤ Para consultar DNS real: resolvectl status"
  echo
  echo "📡 Consultando DNS real via resolvectl:"
  resolvectl status | awk '
    /Link [0-9]+/ { iface=$0; next }
    /Current DNS Server/ { dns1=$NF }
    /DNS Servers/ { getline; dns2=$1 }
    /DNS Domain/ || /DNSSEC/ || /LLMNR/ || /MulticastDNS/ { extras=extras "\n    " $0 }
    END {
      print "🔸 Interface:", iface
      if (dns1) print "🔸 DNS principal:", dns1
      if (dns2 && dns2 != dns1) print "🔸 DNS secundário:", dns2
      if (length(extras)) print "🔸 Configurações adicionais:" extras
    }
  '
fi
