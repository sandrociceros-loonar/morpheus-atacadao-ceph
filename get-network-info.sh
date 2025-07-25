#!/bin/bash

echo "====== Inventário de Placas de Rede ======"

LHW_OUTPUT=$(lshw -class network 2>/dev/null)

get_state() {
  iface=$1
  [[ -e "/sys/class/net/$iface/operstate" ]] && cat "/sys/class/net/$iface/operstate" | tr '[:lower:]' '[:upper:]' || echo "UNKNOWN"
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
  printf "%-16s %-8s\n" "Nome Porta" "Estado"
  echo "---------------- --------"
  for iface in ${iface_map[$pci_base]}; do
    state=$(get_state "$iface")
    printf "%-16s %-8s\n" "$iface" "$state"
  done
done

echo
echo "Portas virtuais:"
printf "%-16s %-8s\n" "Nome Porta" "Estado"
echo "---------------- --------"
for virt in $(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^lo$|^ens|^enp'); do
  state=$(get_state "$virt")
  printf "%-16s %-8s\n" "$virt" "$state"
done
