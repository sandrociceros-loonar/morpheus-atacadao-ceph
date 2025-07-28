#!/bin/bash

echo "====== Inventário de Placas de Rede ======"

LHW_OUTPUT=$(lshw -class network 2>/dev/null)

get_state() {
  iface=$1
  [[ -e "/sys/class/net/$iface/operstate" ]] && cat "/sys/class/net/$iface/operstate" | tr '[:lower:]' '[:upper:]' || echo "UNKNOWN"
}

get_ipv4() {
  iface=$1
  ip -4 addr show "$iface" | grep -oP '(?<=inet\s)\d+(\.\d+){3}' || echo "N/A"
}

get_mac() {
  iface=$1
  cat "/sys/class/net/$iface/address" 2>/dev/null || echo "N/A"
}

get_ip_source() {
  iface=$1
  # Verifica se a interface está configurada como DHCP no Netplan
  if grep -q "${iface}:" /etc/netplan/*.yaml; then
    if grep -A 2 "${iface}:" /etc/netplan/*.yaml | grep -q "dhcp4: true"; then
      echo "DHCP"
    else
      echo "Static"
    fi
  else
    echo "Unknown"
  fi
}

get_gateway() {
  iface=$1
  ip -4 route show dev "$iface" | grep -oP '(?<=via\s)\d+(\.\d+){3}' | head -n 1 || echo "N/A"
}

# Arrays associativos para agrupar por PCI base
declare -A vendor_map
declare -A product_map
declare -A iface_map

# Parseando cada bloco do lshw individualmente
while read -r line; do
  [[ $line =~ ^\*-network ]] && { bus=''; iface=''; vendor=''; product=''; }
  [[ $line =~ bus\ info:\ (pci@[0-9a-f:.]+) ]] && bus="${BASH_REMATCH[1]}"
  [[ $line =~ logical\ name:\ ([^ ]+) ]] && iface="${BASH_REMATCH[1]}"
  [[ $line =~ vendor:\ (.*) ]] && vendor="${BASH_REMATCH[1]}"
  [[ $line =~ product:\ (.*) ]] && product="${BASH_REMATCH[1]}"
  # Se temos todos, registra
  if [[ -n $bus && -n $iface ]]; then
    pci_base=$(echo "$bus" | sed -E 's/\.[0-9]+$//')
    vendor_map["$pci_base"]="$vendor"
    product_map["$pci_base"]="$product"
    iface_map["$pci_base"]="${iface_map["$pci_base"]} $iface"
    bus=''; iface=''; vendor=''; product=''
  fi
done < <(echo "$LHW_OUTPUT" | grep -E '^\*-network|bus info:|logical name:|vendor:|product:')

for pci_base in "${!iface_map[@]}"; do
  echo
  echo "Placa física: $pci_base"
  echo "Fabricante : ${vendor_map[$pci_base]:-'-'}"
  echo "Modelo     : ${product_map[$pci_base]:-'-'}"
  echo "Portas físicas:"
  printf "%-16s %-8s %-16s %-18s %-8s %-16s %-16s\n" "Nome Porta" "Estado" "IPv4" "MAC Address" "Origem IP" "Gateway" "Placa Física"
  echo "---------------- -------- ---------------- ------------------ -------- ---------------- ----------------"
  for iface in ${iface_map[$pci_base]}; do
    state=$(get_state "$iface")
    ipv4=$(get_ipv4 "$iface")
    mac=$(get_mac "$iface")
    ip_source=$(get_ip_source "$iface")
    gateway="N/A"
    if [[ "$state" == "UP" && "$ipv4" != "N/A" ]]; then
      gateway=$(get_gateway "$iface")
    fi
    printf "%-16s %-8s %-16s %-18s %-8s %-16s %-16s\n" "$iface" "$state" "$ipv4" "$mac" "$ip_source" "$gateway" "$pci_base"
  done
done

echo
echo "Portas virtuais:"
printf "%-16s %-8s %-16s %-18s %-8s %-16s %-16s\n" "Nome Porta" "Estado" "IPv4" "MAC Address" "Origem IP" "Gateway" "Placa Física"
echo "---------------- -------- ---------------- ------------------ -------- ---------------- ----------------"
for virt in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^lo$|^ens|^enp'); do
  state=$(get_state "$virt")
  ipv4=$(get_ipv4 "$virt")
  mac=$(get_mac "$virt")
  ip_source=$(get_ip_source "$virt")
  gateway="N/A"
  if [[ "$state" == "UP" && "$ipv4" != "N/A" ]]; then
    gateway=$(get_gateway "$virt")
  fi
  printf "%-16s %-8s %-16s %-18s %-8s %-16s %-16s\n" "$virt" "$state" "$ipv4" "$mac" "$ip_source" "$gateway" "N/A"
done