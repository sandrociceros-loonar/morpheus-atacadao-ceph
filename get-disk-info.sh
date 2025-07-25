#!/bin/bash

# Script para listar discos, partições, interfaces e uso de espaço em disco

print_header() {
    echo -e "Disco Físico\tInterface\tPartição\tMontagem\tTamanho\tUsado\tLivre"
    echo -e "-----------------\t---------\t---------\t--------\t-------\t-----\t-----"
}

# Coleta discos físicos e interfaces
mapfile -t disks < <(lsblk -d -o NAME,SIZE,TRAN,MODEL | tail -n +2)

# Coleta informações de partições e espaço em disco
mapfile -t df_info < <(df -h | tail -n +2)

print_header

# Percorre cada disco detectado
for disk in "${disks[@]}"; do
    disk_name=$(echo "$disk" | awk '{print $1}')
    disk_size=$(echo "$disk" | awk '{print $2}')
    disk_iface=$(echo "$disk" | awk '{print $3}')
    disk_model=$(echo "$disk" | cut -d' ' -f4-)

    # Lista partições ligadas a este disco
    part_info=$(lsblk /dev/$disk_name -o NAME,SIZE,MOUNTPOINT -n | grep -v "^$disk_name$" || true)

    if [[ -z "$part_info" ]]; then
        # Sem partições
        echo -e "$disk_name ($disk_model)\t$disk_iface\t--\t--\t$disk_size\t--\t--"
    else
        while IFS= read -r part_line; do
            part_name=$(echo "$part_line" | awk '{print $1}')
            part_size=$(echo "$part_line" | awk '{print $2}')
            part_mount=$(echo "$part_line" | awk '{print $3}')

            df_line=$(printf "%s\n" "${df_info[@]}" | grep "/dev/$part_name")
            used="--"
            avail="--"
            if [[ ! -z "$df_line" ]]; then
                used=$(echo "$df_line" | awk '{print $3}')
                avail=$(echo "$df_line" | awk '{print $4}')
                mount_point=$(echo "$df_line" | awk '{print $6}')
            else
                mount_point="$part_mount"
            fi

            echo -e "$disk_name ($disk_model)\t$disk_iface\t$part_name\t$mount_point\t$part_size\t$used\t$avail"
        done <<< "$part_info"
    fi
    echo
done

# Comentários adaptados dinamicamente ao ambiente detectado
count_disks=$(echo "${disks[@]}" | wc -w)
interfaces=$(printf "%s\n" "${disks[@]}" | awk '{print $3}' | sort | uniq | grep -v '^$' | paste -sd, -)
count_partitions=$(df -h | tail -n +2 | wc -l)

cat << EOF
# Disco(s) físico(s) detectado(s): $((count_disks / 4))
# Interface(s) presente(s): $interfaces
# Total de partições montadas no sistema: $count_partitions

# Observações:
# - A coluna "Disco Físico" traz o nome do dispositivo e modelo, se disponível.
# - A coluna "Interface" mostra o tipo de conexão (ex: NVMe, SATA, USB, etc).
# - As colunas "Partição" e "Montagem" listam subdivisões do disco e pontos de acesso.
# - "Tamanho", "Usado" e "Livre" informam, respectivamente, capacidade total, ocupação e espaço disponível em cada partição detectada e montada.
# - Caso um disco não possua partições detectáveis ou montadas, aparecerá como "--" nas colunas correspondentes.
# - Todas as informações adaptam-se automaticamente ao hardware e à configuração de armazenamento do sistema analisado.
EOF
