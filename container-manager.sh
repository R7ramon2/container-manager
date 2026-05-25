#!/usr/bin/env bash
# =============================================================================
#  container-manager.sh — Gerenciador Multi-Container para Raspberry Pi
#  Suporte: qualquer imagem Docker · macvlan · USB Passthrough · Monitor
# =============================================================================
set -uo pipefail

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURAÇÕES GLOBAIS DE REDE
# ─────────────────────────────────────────────────────────────────────────────

HOST_INTERFACE="wlan0"
LAN_SUBNET="192.168.1.0/24"
LAN_GATEWAY="192.168.1.1"
MACVLAN_NET="pi-macvlan"
DATA_BASE="$HOME/containers"
LOG_FILE="/var/log/container-manager.log"
SERVICE_PREFIX="pi-container"

# ─────────────────────────────────────────────────────────────────────────────
#  ARQUIVOS DE ESTADO
# ─────────────────────────────────────────────────────────────────────────────

CONTAINERS_CONF="$DATA_BASE/.containers.conf"
CATALOG_FILE="$DATA_BASE/.catalog.conf"

# ─────────────────────────────────────────────────────────────────────────────
#  CATÁLOGO PADRÃO (gravado em $CATALOG_FILE na primeira execução)
#  Formato: nome_amigavel|imagem:tag|ip_sugerido|descricao
# ─────────────────────────────────────────────────────────────────────────────

DEFAULT_CATALOG='kali-rolling|kalilinux/kali-rolling|192.168.1.50|Kali Linux (rolling) — pentest e segurança
kali-bleeding|kalilinux/kali-bleeding-edge|192.168.1.51|Kali Bleeding Edge — ferramentas mais novas
ubuntu-22|ubuntu:22.04|192.168.1.52|Ubuntu Server 22.04 LTS (Jammy)
ubuntu-24|ubuntu:24.04|192.168.1.53|Ubuntu Server 24.04 LTS (Noble)
debian-stable|debian:stable-slim|192.168.1.54|Debian Stable (slim)
debian-bookworm|debian:bookworm|192.168.1.55|Debian Bookworm (completo)
parrot-os|parrotsec/core:latest|192.168.1.56|Parrot OS Security Edition
alpine|alpine:latest|192.168.1.57|Alpine Linux — ultraleve
arch-linux|archlinux:latest|192.168.1.58|Arch Linux (rolling)
fedora|fedora:latest|192.168.1.59|Fedora Linux (latest)
raspbian|balenalib/raspberry-pi-debian:bullseye|192.168.1.60|Raspbian/Debian ARM
centos-stream|quay.io/centos/centos:stream9|192.168.1.61|CentOS Stream 9
kali-minimal|kalilinux/kali-last-release|192.168.1.62|Kali última release estável'

# ─────────────────────────────────────────────────────────────────────────────
#  CORES E HELPERS
# ─────────────────────────────────────────────────────────────────────────────

R='\033[0;31m' G='\033[0;32m' Y='\033[1;33m' B='\033[0;34m'
P='\033[0;35m' C='\033[0;36m' W='\033[1;37m' DIM='\033[2m' RST='\033[0m'

log()    { echo -e "${C}[$(date '+%H:%M:%S')]${RST} $*" | tee -a "$LOG_FILE" 2>/dev/null || true; }
ok()     { echo -e " ${G}✔${RST} $*"; }
warn()   { echo -e " ${Y}⚠${RST}  $*"; }
err()    { echo -e " ${R}✘${RST}  $*" >&2; }
info()   { echo -e " ${B}ℹ${RST}  $*"; }
die()    { err "$*"; exit 1; }
hr()     { echo -e "${DIM}$(printf '─%.0s' {1..62})${RST}"; }
pause()  { echo; echo -n " Pressione Enter para continuar..."; read -r; }
confirm(){ echo -ne " ${Y}${1:-Tem certeza?} [s/N]:${RST} "; read -r r; [[ "$r" =~ ^[sS]$ ]]; }

require_root()   { [[ $EUID -eq 0 ]] || die "Execute como root: sudo $0"; }
require_docker() {
    command -v docker &>/dev/null   || die "Docker não encontrado. Use [I] para instalar."
    docker info &>/dev/null 2>&1    || die "Docker daemon não responde. Rode: sudo systemctl start docker"
}

# ─────────────────────────────────────────────────────────────────────────────
#  INICIALIZAÇÃO
# ─────────────────────────────────────────────────────────────────────────────

init_state() {
    mkdir -p "$DATA_BASE"
    touch "$CONTAINERS_CONF"
    # Grava catálogo padrão se ainda não existir
    if [[ ! -f "$CATALOG_FILE" ]]; then
        echo "$DEFAULT_CATALOG" > "$CATALOG_FILE"
        log "Catálogo padrão criado em $CATALOG_FILE"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  GERENCIAMENTO DO CATÁLOGO DE IMAGENS
# ─────────────────────────────────────────────────────────────────────────────

catalog_list() {
    echo -e "\n ${W}┌─ Catálogo de Imagens ─────────────────────────────────────┐${RST}"
    printf "  ${DIM}%-3s %-16s %-34s %-7s${RST}\n" "#" "NOME" "IMAGEM:TAG" "LOCAL?"
    hr
    local i=1
    while IFS='|' read -r name image _ desc; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        # Verifica se a imagem já foi baixada localmente
        local local_mark="${DIM}—${RST}"
        if docker image inspect "$image" &>/dev/null 2>&1; then
            local_mark="${G}sim${RST}"
        fi
        printf "  ${C}%-3s${RST} %-16s %-34s " "$i" "${name:0:15}" "${image:0:33}"
        echo -e "$local_mark  ${DIM}${desc:0:28}${RST}"
        (( i++ ))
    done < "$CATALOG_FILE"
    echo -e " ${W}└──────────────────────────────────────────────────────────────┘${RST}"
}

catalog_add() {
    echo -e "\n ${P}◈ Adicionar Imagem ao Catálogo${RST}"
    hr

    echo -n "  Nome amigável (ex: meu-ubuntu): "; read -r name
    [[ -z "$name" ]] && { warn "Nome não pode ser vazio."; return; }

    # Verifica duplicata
    if grep -q "^${name}|" "$CATALOG_FILE" 2>/dev/null; then
        warn "Já existe uma entrada com o nome '${name}'."
        confirm "Substituir?" || return
        sed -i "/^${name}|/d" "$CATALOG_FILE"
    fi

    echo -n "  Imagem Docker (ex: ubuntu:20.04 ou nginx:alpine): "; read -r image
    [[ -z "$image" ]] && { warn "Imagem não pode ser vazia."; return; }

    # Sugere próximo IP disponível
    local last_ip; last_ip=$(awk -F'|' 'NF>=3{print $3}' "$CATALOG_FILE" \
        | grep -oP '\d+$' | sort -n | tail -1)
    local next_ip="${LAN_GATEWAY%.*}.$((last_ip + 1))"
    echo -n "  IP sugerido na LAN [${next_ip}]: "; read -r ip_in
    local ip="${ip_in:-$next_ip}"

    echo -n "  Descrição curta: "; read -r desc

    echo "${name}|${image}|${ip}|${desc}" >> "$CATALOG_FILE"
    ok "Imagem '${name}' adicionada ao catálogo."
    info "Use a opção [pull] para baixar agora, ou ela será baixada ao criar um container."
}

catalog_edit() {
    echo -e "\n ${P}◈ Editar Entrada do Catálogo${RST}"
    catalog_list

    echo -n "  Número da entrada para editar: "; read -r num
    [[ ! "$num" =~ ^[0-9]+$ ]] && { warn "Número inválido."; return; }

    local i=1 target_line=""
    while IFS='|' read -r name image ip desc; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        if [[ $i -eq $num ]]; then
            target_line="${name}|${image}|${ip}|${desc}"
            break
        fi
        (( i++ ))
    done < "$CATALOG_FILE"

    [[ -z "$target_line" ]] && { warn "Entrada não encontrada."; return; }

    IFS='|' read -r o_name o_image o_ip o_desc <<< "$target_line"
    echo -e "\n  Editando: ${C}${o_name}${RST}"
    echo -e "  ${DIM}(Enter para manter o valor atual)${RST}\n"

    echo -n "  Nome amigável [${o_name}]: "; read -r n_name;   n_name="${n_name:-$o_name}"
    echo -n "  Imagem:tag    [${o_image}]: "; read -r n_image; n_image="${n_image:-$o_image}"
    echo -n "  IP sugerido   [${o_ip}]: ";   read -r n_ip;    n_ip="${n_ip:-$o_ip}"
    echo -n "  Descrição     [${o_desc}]: "; read -r n_desc;  n_desc="${n_desc:-$o_desc}"

    # Substitui linha no arquivo
    sed -i "/^${o_name}|/d" "$CATALOG_FILE"
    echo "${n_name}|${n_image}|${n_ip}|${n_desc}" >> "$CATALOG_FILE"

    ok "Entrada '${n_name}' atualizada."
    info "Se a tag da imagem mudou, use [pull] para baixar a nova versão."
}

catalog_remove() {
    echo -e "\n ${P}◈ Remover Entrada do Catálogo${RST}"
    catalog_list

    echo -n "  Número da entrada para remover: "; read -r num
    [[ ! "$num" =~ ^[0-9]+$ ]] && { warn "Número inválido."; return; }

    local i=1 target_name=""
    while IFS='|' read -r name _; do
        [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
        if [[ $i -eq $num ]]; then target_name="$name"; break; fi
        (( i++ ))
    done < "$CATALOG_FILE"

    [[ -z "$target_name" ]] && { warn "Entrada não encontrada."; return; }

    confirm "Remover '${target_name}' do catálogo?" || return
    sed -i "/^${target_name}|/d" "$CATALOG_FILE"
    ok "'${target_name}' removido do catálogo."
    info "Containers já criados com essa imagem não são afetados."
}

catalog_pull_one() {
    # Baixa/atualiza a imagem de uma entrada específica do catálogo
    local name=$1 image=$2
    echo -e "\n ${B}↓${RST} Baixando ${W}${image}${RST}..."

    local before_id=""
    before_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)

    if docker pull "$image" 2>&1 | tee -a "$LOG_FILE"; then
        local after_id
        after_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)

        if [[ -n "$before_id" && "$before_id" == "$after_id" ]]; then
            info "Imagem já estava na versão mais recente."
        elif [[ -n "$before_id" && "$before_id" != "$after_id" ]]; then
            ok "Imagem ${name} ATUALIZADA (nova camada disponível)."
            warn "Containers existentes com essa imagem precisam ser recriados para usar a nova versão."
            warn "Use a opção [17] no menu principal para recriar."
        else
            ok "Imagem ${name} baixada pela primeira vez."
        fi
    else
        err "Falha ao baixar '${image}'. Verifique o nome e sua conexão."
    fi
}

catalog_pull_menu() {
    require_docker
    echo -e "\n ${P}◈ Baixar / Atualizar Imagens${RST}"
    echo -e " ${DIM}Verifica se há versão nova e baixa automaticamente.${RST}\n"

    echo -e "  ${C}1)${RST} Baixar/atualizar UMA imagem do catálogo"
    echo -e "  ${C}2)${RST} Baixar/atualizar TODAS as imagens do catálogo"
    echo -e "  ${C}3)${RST} Digitar imagem manualmente (fora do catálogo)"
    echo -e "  ${C}4)${RST} Ver imagens já baixadas localmente"
    echo -e "  ${C}5)${RST} Limpar imagens antigas (dangling)"
    echo -n "  Escolha: "; read -r opt

    case "$opt" in
        1)
            catalog_list
            echo -n "  Número da imagem: "; read -r num
            [[ ! "$num" =~ ^[0-9]+$ ]] && { warn "Inválido."; return; }
            local i=1
            while IFS='|' read -r name image _ _; do
                [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
                if [[ $i -eq $num ]]; then catalog_pull_one "$name" "$image"; break; fi
                (( i++ ))
            done < "$CATALOG_FILE"
            ;;
        2)
            local total=0 updated=0 failed=0
            echo ""
            while IFS='|' read -r name image _ _; do
                [[ "$name" =~ ^#.*$ || -z "$name" ]] && continue
                (( total++ ))
                catalog_pull_one "$name" "$image" && (( updated++ )) || (( failed++ ))
                echo ""
            done < "$CATALOG_FILE"
            echo -e "\n ${W}Resumo:${RST} ${total} imagens · ${G}${updated} ok${RST} · ${R}${failed} falhas${RST}"
            ;;
        3)
            echo -n "  Imagem (ex: nginx:1.25-alpine): "; read -r img
            [[ -z "$img" ]] && return
            catalog_pull_one "manual" "$img"
            confirm "Adicionar '${img}' ao catálogo?" && {
                echo -n "  Nome amigável: "; read -r nm
                echo -n "  Descrição: "; read -r dc
                local last_ip; last_ip=$(awk -F'|' 'NF>=3{print $3}' "$CATALOG_FILE" \
                    | grep -oP '\d+$' | sort -n | tail -1)
                local nip="${LAN_GATEWAY%.*}.$((last_ip + 1))"
                echo "${nm:-custom}|${img}|${nip}|${dc}" >> "$CATALOG_FILE"
                ok "Adicionado ao catálogo."
            }
            ;;
        4)
            echo -e "\n ${W}Imagens Docker locais:${RST}"
            docker images --format "table {{.Repository}}:{{.Tag}}\t{{.Size}}\t{{.CreatedSince}}" \
                | head -40
            ;;
        5)
            local dangling; dangling=$(docker images -f "dangling=true" -q 2>/dev/null | wc -l)
            if [[ "$dangling" -gt 0 ]]; then
                info "${dangling} imagem(ns) antigas encontradas."
                confirm "Remover imagens dangling (antigas/sem tag)?" && \
                    docker image prune -f && ok "Imagens limpas." || true
            else
                info "Nenhuma imagem antiga para limpar."
            fi
            ;;
        *) warn "Opção inválida." ;;
    esac
}

catalog_menu() {
    while true; do
        clear
        echo -e "\n ${P}◈ Gerenciador de Catálogo de Imagens${RST}"
        hr
        catalog_list
        echo ""
        echo -e "  ${G}a)${RST} Adicionar nova imagem ao catálogo"
        echo -e "  ${Y}e)${RST} Editar entrada existente (nome, tag, IP)"
        echo -e "  ${R}r)${RST} Remover entrada do catálogo"
        echo -e "  ${B}p)${RST} Baixar / atualizar imagens"
        echo -e "  ${DIM}v)${RST} Ver imagens locais (docker images)"
        echo -e "  ${DIM}q)${RST} Voltar ao menu principal"
        echo -n "  Opção: "; read -r opt

        case "$opt" in
            a) catalog_add ;;
            e) catalog_edit ;;
            r) catalog_remove ;;
            p) catalog_pull_menu ;;
            v) echo ""; docker images; echo "" ;;
            q|Q) return ;;
            *) warn "Opção inválida." ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  MONITOR DE RECURSOS DO HOST
# ─────────────────────────────────────────────────────────────────────────────

get_cpu_percent() {
    local s1 s2
    s1=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    sleep 0.5
    s2=$(awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8, $5}' /proc/stat)
    local t1 i1 t2 i2
    read -r t1 i1 <<< "$s1"; read -r t2 i2 <<< "$s2"
    local dt=$(( t2 - t1 )); local di=$(( i2 - i1 ))
    [[ $dt -eq 0 ]] && echo "0" || echo $(( (dt - di) * 100 / dt ))
}

get_ram_info() {
    awk '/MemTotal/{t=$2} /MemAvailable/{a=$2}
         END{u=t-a; printf "%d %d %d %d", t/1024, u/1024, a/1024, u*100/t}' /proc/meminfo
}

get_cpu_temp() {
    local tf="/sys/class/thermal/thermal_zone0/temp"
    [[ -f "$tf" ]] && echo "$(( $(cat "$tf") / 1000 ))°C" || echo "N/A"
}

get_disk_info() {
    df -BM / | awk 'NR==2{gsub("M","",$2); gsub("M","",$3); gsub("M","",$4);
        printf "%d %d %d %d", $2, $3, $4, $3*100/$2}'
}

color_bar() {
    local pct=${1:-0} width=${2:-20}
    local filled=$(( pct * width / 100 ))
    [[ $filled -gt $width ]] && filled=$width
    local color
    if   [[ $pct -lt 60 ]]; then color="$G"
    elif [[ $pct -lt 80 ]]; then color="$Y"
    else                         color="$R"; fi
    printf "${color}"; printf '█%.0s' $(seq 1 $filled 2>/dev/null)
    printf "${DIM}"; printf '░%.0s' $(seq 1 $(( width - filled )) 2>/dev/null)
    printf "${RST}"
}

show_host_resources() {
    local cpu; cpu=$(get_cpu_percent)
    local ram_t ram_u ram_a ram_pct
    read -r ram_t ram_u ram_a ram_pct <<< "$(get_ram_info)"
    local disk_t disk_u disk_a disk_pct
    read -r disk_t disk_u disk_a disk_pct <<< "$(get_disk_info)"
    local temp; temp=$(get_cpu_temp)

    echo -e " ${W}┌─ Host: Raspberry Pi ─────────────────────────────────────┐${RST}"
    printf "  ${W}CPU   ${RST} %s %3d%%  ${DIM}(%s cores · %s)${RST}\n" \
        "$(color_bar "$cpu" 20)" "$cpu" "$(nproc)" "$temp"
    printf "  ${W}RAM   ${RST} %s %3d%%  ${DIM}(%s MB / %s MB)${RST}\n" \
        "$(color_bar "$ram_pct" 20)" "$ram_pct" "$ram_u" "$ram_t"
    printf "  ${W}DISCO ${RST} %s %3d%%  ${DIM}(%s MB / %s MB)${RST}\n" \
        "$(color_bar "$disk_pct" 20)" "$disk_pct" "$disk_u" "$disk_t"
    echo -e " ${W}└──────────────────────────────────────────────────────────┘${RST}"
}

show_container_resources() {
    require_docker
    local running; running=$(docker ps -q 2>/dev/null | wc -l)
    [[ "$running" -eq 0 ]] && return

    echo -e "\n ${W}┌─ Recursos por Container ─────────────────────────────────┐${RST}"
    printf "  ${DIM}%-20s %-9s %-14s %-12s${RST}\n" "CONTAINER" "CPU%" "RAM" "NET I/O"
    hr

    docker stats --no-stream --format \
        "{{.Name}}|{{.CPUPerc}}|{{.MemUsage}}|{{.NetIO}}" 2>/dev/null \
    | while IFS='|' read -r name cpu mem net; do
        local cpuval; cpuval=$(echo "$cpu" | tr -d '%' | cut -d'.' -f1)
        cpuval=${cpuval:-0}
        local color
        if   [[ $cpuval -lt 50 ]]; then color="$G"
        elif [[ $cpuval -lt 80 ]]; then color="$Y"
        else                            color="$R"; fi
        printf "  %-20s ${color}%-9s${RST} %-14s %-12s\n" \
            "${name:0:19}" "$cpu" "${mem:0:13}" "${net:0:11}"
    done

    echo -e " ${W}└──────────────────────────────────────────────────────────┘${RST}"
}

monitor_live() {
    echo -e "${Y} Monitor ao vivo — Ctrl+C para sair${RST}\n"
    while true; do
        clear
        echo -e " ${P}◈ Monitor de Recursos  ${DIM}$(date '+%d/%m/%Y %H:%M:%S')${RST}"
        hr
        show_host_resources
        show_container_resources
        echo -e "\n ${DIM}Atualiza a cada 3s · Ctrl+C para sair${RST}"
        sleep 3
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  DISPOSITIVOS USB
# ─────────────────────────────────────────────────────────────────────────────

list_usb_devices() {
    echo -e "\n ${W}┌─ Dispositivos USB Detectados ───────────────────────────┐${RST}"

    local found=false
    for d in /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm*; do
        [[ -e "$d" ]] && { echo -e "  ${B}[modem/serial]${RST} $d"; found=true; }
    done

    while IFS= read -r line; do
        [[ -n "$line" ]] && { echo -e "  ${C}[storage]${RST} $line"; found=true; }
    done < <(lsblk -ndo NAME,TYPE,SIZE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1"  ("$3")"}')

    [[ "$found" == false ]] && echo -e "  ${DIM}Nenhum dispositivo USB de bloco/serial detectado.${RST}"

    if command -v lsusb &>/dev/null; then
        echo -e "\n  ${DIM}Todos os dispositivos USB (lsusb):${RST}"
        lsusb 2>/dev/null | while read -r line; do
            echo -e "  ${DIM}$line${RST}"
        done
    fi

    echo -e " ${W}└──────────────────────────────────────────────────────────┘${RST}"
}

select_usb_for_container() {
    # Todo output interativo vai para stderr para não contaminar a captura via $()
    local usb_list=()
    for d in /dev/ttyUSB* /dev/ttyACM* /dev/cdc-wdm* /dev/net/tun; do
        [[ -e "$d" ]] && usb_list+=("$d")
    done
    while IFS= read -r d; do
        [[ -n "$d" ]] && usb_list+=("$d")
    done < <(lsblk -ndo NAME,TYPE 2>/dev/null | awk '$2=="disk"{print "/dev/"$1}')

    if [[ ${#usb_list[@]} -eq 0 ]]; then
        echo -e "\n ${Y}⚠${RST}  Nenhum dispositivo USB encontrado no momento." >&2
        echo ""   # stdout vazio = sem flags
        return
    fi

    echo -e "\n ${W}Dispositivos disponíveis:${RST}" >&2
    local i=1
    for d in "${usb_list[@]}"; do echo -e "  ${C}$i)${RST} $d" >&2; (( i++ )); done
    echo -e "  ${DIM}0) Nenhum${RST}" >&2
    echo -n "  Escolha (ex: 1 3): " >&2; read -r choices

    local flags=""
    for c in $choices; do
        [[ "$c" == "0" ]] && continue
        local idx=$(( c - 1 ))
        if [[ $idx -ge 0 && $idx -lt ${#usb_list[@]} ]]; then
            flags+=" --device=${usb_list[$idx]}"
        fi
    done
    # Só o resultado vai para stdout — capturado limpo pelo $()
    echo "$flags"
}

# ─────────────────────────────────────────────────────────────────────────────
#  REDE MACVLAN
# ─────────────────────────────────────────────────────────────────────────────

ensure_macvlan() {
    docker network ls --format '{{.Name}}' 2>/dev/null | grep -q "^${MACVLAN_NET}$" && return 0
    log "Criando rede macvlan '${MACVLAN_NET}'..."
    local host_ip; host_ip=$(ip -4 addr show "$HOST_INTERFACE" 2>/dev/null \
        | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1)
    local aux="${host_ip%.*}.254/32"
    docker network create -d macvlan \
        --subnet="$LAN_SUBNET" --gateway="$LAN_GATEWAY" \
        --ip-range="$aux" -o parent="$HOST_INTERFACE" "$MACVLAN_NET" \
        || die "Falha ao criar rede macvlan."
    ok "Rede macvlan criada."
}

ensure_host_bridge() {
    ip link show macvlan0 &>/dev/null 2>&1 && return 0
    local host_ip; host_ip=$(ip -4 addr show "$HOST_INTERFACE" 2>/dev/null \
        | grep -oP '(?<=inet\s)\d+\.\d+\.\d+\.\d+' | head -1)
    ip link add macvlan0 link "$HOST_INTERFACE" type macvlan mode bridge 2>/dev/null || true
    ip addr add "${host_ip%.*}.254/32" dev macvlan0 2>/dev/null || true
    ip link set macvlan0 up 2>/dev/null || true
    [[ -f "$CONTAINERS_CONF" ]] && while IFS='|' read -r _ _ cip _ _; do
        [[ -n "$cip" ]] && ip route add "$cip/32" dev macvlan0 2>/dev/null || true
    done < "$CONTAINERS_CONF"
    ok "Bridge host-side (macvlan0) configurada."
}

remove_macvlan() {
    ip link set macvlan0 down 2>/dev/null || true
    ip link delete macvlan0 2>/dev/null || true
    docker network rm "$MACVLAN_NET" 2>/dev/null || true
    ok "Rede macvlan removida."
}

# ─────────────────────────────────────────────────────────────────────────────
#  GERENCIAMENTO DE CONTAINERS
# ─────────────────────────────────────────────────────────────────────────────

save_container() {
    # nome|imagem|ip|autostart|usb_flags|internet|dns
    local name=$1 image=$2 ip=$3 auto=$4 usb=${5:-""} internet=${6:-"yes"} dns=${7:-"8.8.8.8,1.1.1.1"}
    grep -v "^${name}|" "$CONTAINERS_CONF" > "${CONTAINERS_CONF}.tmp" 2>/dev/null || true
    echo "${name}|${image}|${ip}|${auto}|${usb}|${internet}|${dns}" >> "${CONTAINERS_CONF}.tmp"
    mv "${CONTAINERS_CONF}.tmp" "$CONTAINERS_CONF"
}

conf_get() {
    # conf_get <nome_container> <campo: 1=nome 2=image 3=ip 4=auto 5=usb 6=internet 7=dns>
    local name=$1 field=$2
    grep "^${name}|" "$CONTAINERS_CONF" 2>/dev/null | cut -d'|' -f"${field}"
}

remove_container_conf() {
    grep -v "^${1}|" "$CONTAINERS_CONF" > "${CONTAINERS_CONF}.tmp" 2>/dev/null || true
    mv "${CONTAINERS_CONF}.tmp" "$CONTAINERS_CONF"
}

get_container_ip() {
    docker inspect "$1" 2>/dev/null \
    | python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    nets=d[0]['NetworkSettings']['Networks']
    print(list(nets.values())[0].get('IPAddress',''))
except: print('')
" 2>/dev/null || echo ""
}

create_container_run() {
    # Cria e sobe o container com base nos parâmetros
    # Args: name image ip usb_flags internet dns
    local name=$1 image=$2 ip=$3 usb_flags="${4:-}" internet="${5:-yes}" dns="${6:-8.8.8.8,1.1.1.1}"
    local data_dir="$DATA_BASE/$name"
    mkdir -p "$data_dir/data" "$data_dir/tools"

    # Converte usb_flags string para array — evita word-splitting com valores vazios
    local -a usb_args=()
    if [[ -n "${usb_flags// /}" ]]; then
        read -ra usb_args <<< "$usb_flags"
    fi

    # Monta flags de rede extras
    local -a net_args=()
    # DNS sempre explícito para evitar herdar resolv.conf quebrado do host
    IFS=',' read -ra dns_servers <<< "$dns"
    for srv in "${dns_servers[@]}"; do
        [[ -n "${srv// /}" ]] && net_args+=("--dns=${srv// /}")
    done
    # Sem internet: adiciona --network=none depois de criar, via pós-configuração
    # (macvlan não suporta --network=none direto; bloqueio é feito via iptables dentro do container)

    # Passa gateway e política para dentro do container via env
    docker run -d \
        --name "$name" \
        --network "$MACVLAN_NET" \
        --ip "$ip" \
        --hostname "$name" \
        --privileged \
        --cap-add=NET_ADMIN \
        --cap-add=NET_RAW \
        -v "${data_dir}/data:/root/persistent" \
        -v "${data_dir}/tools:/opt/tools" \
        -e LANG=pt_BR.UTF-8 \
        -e CONTAINER_INTERNET="$internet" \
        -e CONTAINER_GW="$LAN_GATEWAY" \
        --restart=unless-stopped \
        "${usb_args[@]+"${usb_args[@]}"}" \
        "${net_args[@]+"${net_args[@]}"}" \
        "$image" \
        bash -c '
            export DEBIAN_FRONTEND=noninteractive

            # ── 1. Instala pacotes essenciais ──────────────────────────────
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -qq 2>/dev/null
                apt-get install -y -qq \
                    openssh-server iproute2 iputils-ping \
                    curl wget net-tools iptables 2>/dev/null || true
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache openssh iproute2 iputils curl wget iptables 2>/dev/null || true
                ssh-keygen -A 2>/dev/null || true
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y openssh-server iproute iputils curl wget iptables 2>/dev/null || true
            elif command -v pacman >/dev/null 2>&1; then
                pacman -Sy --noconfirm openssh iproute2 iputils curl wget iptables 2>/dev/null || true
            elif command -v zypper >/dev/null 2>&1; then
                zypper -n install openssh iproute2 iputils curl wget iptables 2>/dev/null || true
            fi

            # ── 2. Configura SSH ───────────────────────────────────────────
            mkdir -p /run/sshd /var/run/sshd
            echo "root:raspberry" | chpasswd 2>/dev/null || true
            sed -i "s/#PermitRootLogin.*/PermitRootLogin yes/" /etc/ssh/sshd_config 2>/dev/null || true
            sed -i "s/PermitRootLogin.*/PermitRootLogin yes/"  /etc/ssh/sshd_config 2>/dev/null || true
            (which /usr/sbin/sshd && /usr/sbin/sshd) 2>/dev/null \
                || (which sshd && sshd) 2>/dev/null || true

            # ── 3. Configura rota default (macvlan não injeta rota) ────────
            # O Docker com macvlan não adiciona rota default automaticamente.
            # Precisamos configurar explicitamente via gateway da LAN.
            GW="${CONTAINER_GW:-192.168.1.1}"
            ip route del default 2>/dev/null || true
            ip route add default via "$GW" 2>/dev/null || true

            # ── 4. Aplica política de internet ─────────────────────────────
            case "$CONTAINER_INTERNET" in
                lan-only)
                    iptables -F OUTPUT 2>/dev/null || true
                    iptables -A OUTPUT -o lo            -j ACCEPT 2>/dev/null || true
                    iptables -A OUTPUT -d 10.0.0.0/8    -j ACCEPT 2>/dev/null || true
                    iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT 2>/dev/null || true
                    iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT 2>/dev/null || true
                    iptables -A OUTPUT -j DROP 2>/dev/null || true
                    ;;
                none)
                    iptables -F OUTPUT 2>/dev/null || true
                    iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
                    iptables -A OUTPUT -j DROP 2>/dev/null || true
                    ;;
                # yes ou qualquer outro: internet livre, nada a bloquear
            esac

            tail -f /dev/null
        ' 2>&1
}

add_new_container() {
    require_root; require_docker
    echo -e "\n ${P}◈ Adicionar Novo Container${RST}"
    hr

    # Fonte da imagem
    echo -e "\n  ${W}De onde vem a imagem?${RST}"
    echo -e "  ${C}1)${RST} Escolher do catálogo"
    echo -e "  ${C}2)${RST} Digitar imagem manualmente"
    echo -n "  Escolha: "; read -r src

    local name image suggested_ip desc

    if [[ "$src" == "1" ]]; then
        catalog_list
        echo -n "  Número no catálogo: "; read -r num
        [[ ! "$num" =~ ^[0-9]+$ ]] && { warn "Inválido."; return; }
        local i=1
        while IFS='|' read -r cn ci cip cd; do
            [[ "$cn" =~ ^#.*$ || -z "$cn" ]] && continue
            if [[ $i -eq $num ]]; then
                name="$cn"; image="$ci"; suggested_ip="$cip"; desc="$cd"; break
            fi
            (( i++ ))
        done < "$CATALOG_FILE"
        [[ -z "${name:-}" ]] && { warn "Entrada não encontrada."; return; }
        echo -e "  Selecionado: ${G}${name}${RST} (${image})"
        echo -n "  Nome do container [${name}]: "; read -r name_in
        [[ -n "$name_in" ]] && name="$name_in"
        echo -n "  IP na LAN [${suggested_ip}]: "; read -r ip_in
        [[ -n "$ip_in" ]] && suggested_ip="$ip_in"
    else
        echo -n "  Imagem (ex: ubuntu:20.04): "; read -r image
        [[ -z "$image" ]] && { warn "Imagem não pode ser vazia."; return; }
        echo -n "  Nome do container: "; read -r name
        [[ -z "$name" ]] && name="${image%%:*}"
        local last_ip; last_ip=$(awk -F'|' 'NF>=3{print $3}' "$CATALOG_FILE" \
            | grep -oP '\d+$' | sort -n | tail -1)
        suggested_ip="${LAN_GATEWAY%.*}.$((last_ip + 1))"
        echo -n "  IP na LAN [${suggested_ip}]: "; read -r ip_in
        [[ -n "$ip_in" ]] && suggested_ip="$ip_in"
        confirm "Adicionar '${image}' ao catálogo também?" && {
            echo -n "  Descrição: "; read -r cdesc
            echo "${name}|${image}|${suggested_ip}|${cdesc:-Adicionado manualmente}" >> "$CATALOG_FILE"
            ok "Adicionado ao catálogo."
        }
    fi

    # Verifica duplicata
    if docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        warn "Container '${name}' já existe."; return
    fi

    # Autostart
    echo -n "  Iniciar automaticamente com o Raspberry? [s/N]: "; read -r au
    local autostart="no"; [[ "$au" =~ ^[sS]$ ]] && autostart="yes"

    # USB
    echo -n "  Configurar passthrough de USB? [s/N]: "; read -r usb_ask
    local usb_flags=""
    [[ "$usb_ask" =~ ^[sS]$ ]] && usb_flags=$(select_usb_for_container)

    # Internet
    echo ""
    echo -e "  ${W}Acesso à internet:${RST}"
    echo -e "  ${C}1)${RST} Habilitada (container acessa a internet normalmente)"
    echo -e "  ${C}2)${RST} Apenas LAN (bloqueia internet, mantém acesso à rede local)"
    echo -e "  ${C}3)${RST} Sem rede (isolado completamente — sem LAN nem internet)"
    echo -n "  Escolha [1]: "; read -r inet_opt
    local internet="yes" net_mode="completa"
    case "${inet_opt:-1}" in
        2) internet="lan-only"; net_mode="apenas LAN" ;;
        3) internet="none";     net_mode="sem rede" ;;
        *) internet="yes";      net_mode="completa" ;;
    esac

    # DNS
    local dns="8.8.8.8,1.1.1.1"
    if [[ "$internet" == "yes" || "$internet" == "lan-only" ]]; then
        echo -e "
  ${W}Servidores DNS:${RST}"
        echo -e "  ${C}1)${RST} Google        (8.8.8.8, 8.8.4.4)"
        echo -e "  ${C}2)${RST} Cloudflare    (1.1.1.1, 1.0.0.1)"
        echo -e "  ${C}3)${RST} Gateway/roteador (${LAN_GATEWAY})"
        echo -e "  ${C}4)${RST} OpenDNS       (208.67.222.222, 208.67.220.220)"
        echo -e "  ${C}5)${RST} Digitar manualmente"
        echo -n "  Escolha [1]: "; read -r dns_opt
        case "${dns_opt:-1}" in
            2) dns="1.1.1.1,1.0.0.1" ;;
            3) dns="$LAN_GATEWAY" ;;
            4) dns="208.67.222.222,208.67.220.220" ;;
            5) echo -n "  DNS (separados por vírgula): "; read -r dns_in
               [[ -n "$dns_in" ]] && dns="$dns_in" ;;
            *) dns="8.8.8.8,8.8.4.4" ;;
        esac
    fi

    # Baixa imagem se necessário
    if ! docker image inspect "$image" &>/dev/null 2>&1; then
        log "Imagem '${image}' não encontrada localmente. Baixando..."
        docker pull "$image" || { err "Falha ao baixar imagem."; return; }
    else
        info "Imagem '${image}' já está local."
        confirm "Verificar se há atualização disponível?" && docker pull "$image"
    fi

    ensure_macvlan
    ensure_host_bridge

    log "Criando container '${name}' com IP ${suggested_ip} · internet: ${net_mode}..."
    if create_container_run "$name" "$image" "$suggested_ip" "$usb_flags" "$internet" "$dns"; then
        save_container "$name" "$image" "$suggested_ip" "$autostart" "$usb_flags" "$internet" "$dns"
        ip route add "${suggested_ip}/32" dev macvlan0 2>/dev/null || true
        [[ "$autostart" == "yes" ]] && install_container_service "$name"

        # Aplica isolamento de rede imediato se necessário
        [[ "$internet" != "yes" ]] && apply_net_policy "$name" "$internet"

        ok "Container '${name}' criado com sucesso!"
        echo -e "  ${DIM}IP      :${RST} ${C}${suggested_ip}${RST}"
        echo -e "  ${DIM}Internet:${RST} ${net_mode}"
        echo -e "  ${DIM}DNS     :${RST} ${dns}"
        echo -e "  ${DIM}SSH     :${RST} ssh root@${suggested_ip}  ${DIM}(senha: raspberry)${RST}"
        echo -e "  ${DIM}Shell   :${RST} sudo docker exec -it ${name} bash"
    else
        err "Falha ao criar container '${name}'."
    fi
}

start_container() {
    local name=$1; require_docker
    ensure_macvlan; ensure_host_bridge
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$" \
        && { warn "'${name}' já está rodando."; return; }
    docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$" \
        || { err "Container '${name}' não encontrado."; return; }
    log "Iniciando '${name}'..."
    docker start "$name"
    local ip; ip=$(get_container_ip "$name")
    [[ -n "$ip" ]] && ip route add "${ip}/32" dev macvlan0 2>/dev/null || true
    ok "'${name}' iniciado — IP: ${C}${ip}${RST}"
}

stop_container() {
    local name=$1; require_docker
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$" \
        || { warn "'${name}' não está rodando."; return; }
    log "Parando '${name}'..."; docker stop "$name"; ok "'${name}' parado."
}

remove_container() {
    local name=$1; require_root; require_docker
    confirm "Remover container '${name}' permanentemente?" || return
    docker stop "$name" 2>/dev/null || true
    docker rm "$name" 2>/dev/null || true
    remove_container_conf "$name"
    local svc="${SERVICE_PREFIX}-${name}"
    systemctl disable "$svc" 2>/dev/null || true
    rm -f "/etc/systemd/system/${svc}.service"
    systemctl daemon-reload 2>/dev/null || true
    ok "'${name}' removido."
    confirm "Remover dados persistentes em $DATA_BASE/$name?" && rm -rf "$DATA_BASE/$name" && ok "Dados removidos."
}

shell_into() {
    local name=$1; require_docker
    docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$" || {
        warn "'${name}' não está rodando. Iniciando..."; start_container "$name"; sleep 2
    }
    log "Shell em '${name}'..."
    docker exec -it "$name" bash 2>/dev/null || docker exec -it "$name" sh
}

update_container_image() {
    local name=$1; require_docker
    local image; image=$(grep "^${name}|" "$CONTAINERS_CONF" | cut -d'|' -f2)
    [[ -z "$image" ]] && { err "Container '${name}' não encontrado na configuração."; return; }

    echo -e "\n ${B}↓${RST} Verificando atualização para ${W}${image}${RST}..."
    local before_id; before_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)
    docker pull "$image"
    local after_id; after_id=$(docker image inspect "$image" --format '{{.Id}}' 2>/dev/null || true)

    if [[ "$before_id" == "$after_id" ]]; then
        info "Já estava na versão mais recente. Nenhuma ação necessária."
        return
    fi

    ok "Nova versão disponível!"
    confirm "Recriar o container para usar a nova imagem? (dados persistentes mantidos)" || return

    local ip; ip=$(grep "^${name}|" "$CONTAINERS_CONF" | cut -d'|' -f3)
    local auto; auto=$(grep "^${name}|" "$CONTAINERS_CONF" | cut -d'|' -f4)
    local usb; usb=$(grep "^${name}|" "$CONTAINERS_CONF" | cut -d'|' -f5)

    stop_container "$name"
    docker rm "$name"

    if create_container_run "$name" "$image" "$ip" "$usb"; then
        ok "Container '${name}' recriado com imagem atualizada."
    else
        err "Falha ao recriar. Dados em $DATA_BASE/$name estão intactos."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  CONFIGURAÇÃO DE REDE DOS CONTAINERS
# ─────────────────────────────────────────────────────────────────────────────

apply_net_policy() {
    # Aplica política de internet a um container em execução
    # apply_net_policy <nome> <internet: yes|lan-only|none>
    local name=$1 policy="${2:-yes}"

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        warn "Container '${name}' não está rodando. A política será aplicada na próxima inicialização."
        return
    fi

    log "Aplicando política de rede '${policy}' em '${name}'..."

    case "$policy" in
        yes)
            # Remove quaisquer regras de bloqueio anteriores
            docker exec "$name" bash -c '
                iptables -F OUTPUT 2>/dev/null || true
                iptables -P OUTPUT ACCEPT 2>/dev/null || true
            ' 2>/dev/null && ok "Internet habilitada em '${name}'."                           || warn "Não foi possível aplicar (iptables ausente na imagem?)."
            ;;
        lan-only)
            # Permite LAN, bloqueia internet
            docker exec "$name" bash -c '
                iptables -F OUTPUT 2>/dev/null || true
                iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
                iptables -A OUTPUT -d 10.0.0.0/8 -j ACCEPT 2>/dev/null
                iptables -A OUTPUT -d 172.16.0.0/12 -j ACCEPT 2>/dev/null
                iptables -A OUTPUT -d 192.168.0.0/16 -j ACCEPT 2>/dev/null
                iptables -A OUTPUT -j DROP 2>/dev/null
            ' 2>/dev/null && ok "Modo lan-only aplicado em '${name}' (LAN OK, internet bloqueada)."                           || warn "Não foi possível aplicar iptables. Verifique se a imagem tem iptables."
            ;;
        none)
            # Bloqueia tudo
            docker exec "$name" bash -c '
                iptables -F OUTPUT 2>/dev/null || true
                iptables -A OUTPUT -o lo -j ACCEPT 2>/dev/null
                iptables -A OUTPUT -j DROP 2>/dev/null
            ' 2>/dev/null && ok "Modo isolado aplicado em '${name}' (sem rede externa)."                           || warn "Não foi possível aplicar iptables."
            ;;
    esac
}

check_net_policy() {
    # Mostra política atual detectada no container
    local name=$1
    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        echo "stopped"; return
    fi
    local rules
    rules=$(docker exec "$name" iptables -L OUTPUT --line-numbers -n 2>/dev/null || echo "")
    if echo "$rules" | grep -q "DROP"; then
        if echo "$rules" | grep -q "192.168"; then
            echo "lan-only"
        else
            echo "none"
        fi
    else
        echo "yes"
    fi
}

net_diag() {
    # Diagnóstico completo de rede de um container
    local name=$1
    echo -e "\n ${W}━━ Diagnóstico de Rede: ${C}${name}${RST} ${W}━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RST}"

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        err "Container não está rodando."; return
    fi

    local ip; ip=$(conf_get "$name" 3)
    local internet; internet=$(conf_get "$name" 6)
    local dns; dns=$(conf_get "$name" 7)
    local detected; detected=$(check_net_policy "$name")

    printf "  %-14s %s\n" "IP:" "${C}${ip}${RST}"
    printf "  %-14s %s\n" "Config salva:" "${internet:-não definido}"
    printf "  %-14s %s\n" "Política ativa:" "${detected}"
    printf "  %-14s %s\n" "DNS configurado:" "${dns:-padrão}"

    echo -e "\n  ${DIM}Testando conectividade...${RST}"

    # Ping gateway
    docker exec "$name" ping -c1 -W2 "$LAN_GATEWAY" &>/dev/null 2>&1         && printf "  Gateway %-6s ${G}✔ acessível${RST}\n" "(${LAN_GATEWAY})"         || printf "  Gateway %-6s ${R}✘ sem resposta${RST}\n" "(${LAN_GATEWAY})"

    # Ping DNS
    local first_dns="${dns%%,*}"
    docker exec "$name" ping -c1 -W2 "${first_dns:-8.8.8.8}" &>/dev/null 2>&1         && printf "  DNS     %-6s ${G}✔ acessível${RST}\n" "(${first_dns})"         || printf "  DNS     %-6s ${R}✘ sem resposta${RST}\n" "(${first_dns})"

    # Resolução DNS
    docker exec "$name" bash -c 'getent hosts google.com 2>/dev/null | head -1' 2>/dev/null         | grep -q '[0-9]'         && echo -e "  DNS resolve  ${G}✔ ok (google.com resolvido)${RST}"         || echo -e "  DNS resolve  ${R}✘ falhou (sem resolução de nome)${RST}"

    # Internet (HTTP)
    docker exec "$name" bash -c 'curl -s --max-time 4 -o /dev/null -w "%{http_code}" http://detectportal.firefox.com/success.txt 2>/dev/null' 2>/dev/null         | grep -q "200"         && echo -e "  Internet     ${G}✔ saída HTTP ok${RST}"         || echo -e "  Internet     ${R}✘ sem saída HTTP${RST}"

    # Mostra /etc/resolv.conf do container
    echo -e "\n  ${DIM}/etc/resolv.conf dentro do container:${RST}"
    docker exec "$name" cat /etc/resolv.conf 2>/dev/null         | grep -v '^#' | grep -v '^$'         | while read -r line; do echo -e "    ${DIM}$line${RST}"; done

    echo -e "\n  ${DIM}Rotas no container:${RST}"
    local routes
    routes=$(docker exec "$name" bash -c \
        'command -v ip >/dev/null 2>&1 && ip route || command -v route >/dev/null 2>&1 && route -n || echo "(iproute2 não instalado — use opção 7 para instalar e corrigir)"' \
        2>/dev/null)
    echo "$routes" | while read -r line; do echo -e "    ${DIM}$line${RST}"; done

    # ── Status do SSH ──────────────────────────────────────────────────────
    echo -e "\n  ${DIM}Status do SSH:${RST}"
    local ip_val; ip_val=$(conf_get "$name" 3)
    if docker exec "$name" bash -c 'pgrep -x sshd >/dev/null 2>&1' 2>/dev/null; then
        echo -e "    ${G}✔  sshd está rodando${RST}"
        if nc -z -w2 "$ip_val" 22 2>/dev/null; then
            echo -e "    ${G}✔  Porta 22 acessível em ${ip_val}${RST}"
            echo -e "    ${DIM}   ssh root@${ip_val}  (senha: raspberry)${RST}"
        else
            echo -e "    ${Y}⚠  sshd rodando mas porta 22 não responde externamente${RST}"
            echo -e "    ${DIM}   Verifique firewall ou use: docker exec -it ${name} bash${RST}"
        fi
    else
        echo -e "    ${R}✘  sshd não está rodando${RST}"
        if docker exec "$name" bash -c 'command -v sshd >/dev/null 2>&1' 2>/dev/null; then
            echo -e "    ${Y}   openssh instalado mas não iniciado — use opção 9 para corrigir${RST}"
        else
            echo -e "    ${Y}   openssh não instalado — use opção 9 para instalar${RST}"
        fi
    fi

    # ── Causa provável ─────────────────────────────────────────────────────
    echo -e "\n  ${DIM}Causa provável:${RST}"
    if ! docker exec "$name" bash -c 'command -v ip >/dev/null 2>&1' 2>/dev/null; then
        echo -e "    ${Y}⚠  iproute2 não encontrado — use opção 7 para instalar e corrigir rota${RST}"
    elif ! docker exec "$name" ping -c1 -W1 "$LAN_GATEWAY" &>/dev/null 2>&1; then
        echo -e "    ${Y}⚠  Gateway inacessível — rota default provavelmente ausente${RST}"
        echo -e "    ${DIM}   Use a opção 7 (corrigir rota default) para resolver${RST}"
    else
        echo -e "    ${G}✔  Rede ok${RST}"
    fi
}

net_fix_dns() {
    # Reescreve /etc/resolv.conf dentro do container com os DNS configurados
    local name=$1
    local dns; dns=$(conf_get "$name" 7)
    [[ -z "$dns" ]] && dns="8.8.8.8,1.1.1.1"

    log "Corrigindo DNS em '${name}'..."
    local resolv="# Gerenciado pelo container-manager"
    IFS=',' read -ra servers <<< "$dns"
    for s in "${servers[@]}"; do
        [[ -n "${s// /}" ]] && resolv+="\nnameserver ${s// /}"
    done

    docker exec "$name" bash -c "printf '${resolv}\n' > /etc/resolv.conf" 2>/dev/null         && ok "DNS reescrito em '${name}': ${dns}"         || err "Falha ao reescrever DNS."
}

net_fix_route() {
    # Configura rota default no container SEM depender de pacotes instalados nele.
    #
    # Estratégia em camadas (da mais simples para a mais robusta):
    #   1. nsenter: entra no namespace de rede do container pelo host e roda o
    #      'ip' do PRÓPRIO HOST — não precisa de nada instalado no container.
    #   2. /proc/net/route (escrita direta): fallback puro bash, sem binários.
    #   3. docker cp do binário 'ip' do host para dentro do container.
    #   4. apt-get/apk (só funciona se já tiver rota — caso raro de reparo parcial).
    local name=$1
    local gw="$LAN_GATEWAY"
    log "Corrigindo rota default em '${name}' via ${gw}..."

    # Pega o PID do processo principal do container
    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null)
    if [[ -z "$pid" || "$pid" == "0" ]]; then
        err "Container '${name}' não está rodando ou sem PID."; return 1
    fi

    # ── Método 1: nsenter ─────────────────────────────────────────────────────
    # Entra no network namespace do container e usa o 'ip' do host.
    # Não toca no filesystem do container, não precisa de nada instalado nele.
    if command -v nsenter &>/dev/null && command -v ip &>/dev/null; then
        local result
        result=$(nsenter -t "$pid" -n -- bash -c "
            ip route del default 2>/dev/null || true
            ip route add default via $gw 2>/dev/null && echo OK || echo FAIL
        " 2>/dev/null)
        if [[ "$result" == "OK" ]]; then
            ok "Rota default -> ${gw} (via nsenter)."
            # Agora com rede funcionando, aproveita para instalar iproute2 no container
            log "Instalando iproute2 no container agora que há conectividade..."
            docker exec "$name" bash -c "
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get install -y -qq iproute2 iputils-ping iptables 2>/dev/null || true
                elif command -v apk >/dev/null 2>&1; then
                    apk add --no-cache iproute2 iputils iptables 2>/dev/null || true
                fi
            " 2>/dev/null && info "iproute2 instalado no container." || true
            return 0
        fi
        warn "nsenter falhou, tentando método alternativo..."
    else
        warn "nsenter não encontrado no host. Instale com: apt-get install util-linux"
    fi

    # ── Método 2: ip netns via PID (equivalente ao nsenter mas usando ip) ─────
    if command -v ip &>/dev/null; then
        # Cria link temporário do netns para o ip netns possa encontrá-lo
        mkdir -p /var/run/netns
        ln -sfn "/proc/${pid}/ns/net" "/var/run/netns/__cm_${name}" 2>/dev/null
        local result
        result=$(ip netns exec "__cm_${name}" bash -c "
            ip route del default 2>/dev/null || true
            ip route add default via $gw 2>/dev/null && echo OK || echo FAIL
        " 2>/dev/null)
        rm -f "/var/run/netns/__cm_${name}" 2>/dev/null
        if [[ "$result" == "OK" ]]; then
            ok "Rota default -> ${gw} (via ip netns)."
            log "Instalando iproute2 agora que há conectividade..."
            docker exec "$name" bash -c "
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get install -y -qq iproute2 iputils-ping iptables 2>/dev/null || true
                elif command -v apk >/dev/null 2>&1; then
                    apk add --no-cache iproute2 iputils iptables 2>/dev/null || true
                fi
            " 2>/dev/null && info "iproute2 instalado." || true
            return 0
        fi
        warn "ip netns falhou, tentando cópia de binário..."
    fi

    # ── Método 3: copia o binário 'ip' do host para dentro do container ───────
    # Copia temporariamente o executável 'ip' do host para /tmp do container,
    # roda a configuração, e remove. Não deixa rastro permanente.
    local ip_bin; ip_bin=$(command -v ip 2>/dev/null)
    if [[ -n "$ip_bin" ]]; then
        log "Copiando binário 'ip' do host para o container temporariamente..."
        docker cp "$ip_bin" "${name}:/tmp/_ip_host" 2>/dev/null
        local result
        result=$(docker exec "$name" bash -c "
            chmod +x /tmp/_ip_host 2>/dev/null
            /tmp/_ip_host route del default 2>/dev/null || true
            /tmp/_ip_host route add default via $gw 2>/dev/null && echo OK || echo FAIL
            rm -f /tmp/_ip_host
        " 2>/dev/null)
        if [[ "$result" == "OK" ]]; then
            ok "Rota default -> ${gw} (via binário do host)."
            log "Instalando iproute2 agora que há conectividade..."
            docker exec "$name" bash -c "
                if command -v apt-get >/dev/null 2>&1; then
                    apt-get install -y -qq iproute2 iputils-ping iptables 2>/dev/null || true
                elif command -v apk >/dev/null 2>&1; then
                    apk add --no-cache iproute2 iputils iptables 2>/dev/null || true
                fi
            " 2>/dev/null && info "iproute2 instalado." || true
            return 0
        fi
        warn "Cópia de binário falhou. Tentando método final..."
    fi

    # ── Método 4: apt-get/apk (só funciona se já tiver alguma rota parcial) ───
    docker exec "$name" bash -c "
        if command -v apt-get >/dev/null 2>&1; then
            apt-get install -y -qq iproute2 2>/dev/null
        elif command -v apk >/dev/null 2>&1; then
            apk add --no-cache iproute2 2>/dev/null
        fi
        ip route del default 2>/dev/null || true
        ip route add default via $gw 2>/dev/null && echo OK || echo FAIL
    " 2>/dev/null | grep -q 'OK' \
        && ok "Rota default -> ${gw} (após instalar iproute2)." \
        || {
            err "Todos os métodos falharam."
            info "Instale nsenter no host: apt-get install util-linux"
            info "Ou recriar o container (opção 5 + 1) corrige permanentemente."
        }
}

net_fix_ssh() {
    # Instala e inicia SSH no container SEM depender de conectividade prévia.
    # Usa nsenter para entrar no namespace do container pelo host e acionar
    # o apt-get/apk de lá — que já tem rota configurada pelo host.
    local name=$1
    log "Verificando e corrigindo SSH em '${name}'..."

    if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
        err "Container '${name}' não está rodando."; return 1
    fi

    local pid
    pid=$(docker inspect -f '{{.State.Pid}}' "$name" 2>/dev/null)
    if [[ -z "$pid" || "$pid" == "0" ]]; then
        err "Sem PID — container não está rodando."; return 1
    fi

    # ── Passo 1: checar se sshd já está rodando ────────────────────────────
    if docker exec "$name" bash -c 'pgrep -x sshd >/dev/null 2>&1' 2>/dev/null; then
        ok "sshd já está rodando em '${name}'."
        return 0
    fi
    info "sshd não está rodando. Instalando e configurando..."

    # ── Passo 2: garantir rota antes de qualquer apt-get ──────────────────
    # Chama net_fix_route que já tem os 4 métodos sem dependência de rede
    net_fix_route "$name"

    # ── Passo 3: instalar openssh-server dentro do container ──────────────
    # Usa nsenter para entrar no namespace de mount+pid do container e rodar
    # o gerenciador de pacotes DE DENTRO do container mas COM rota do host.
    local install_ok=false

    if command -v nsenter &>/dev/null; then
        log "Instalando openssh via nsenter..."
        nsenter -t "$pid" -m -u -i -p -- bash -c '
            export DEBIAN_FRONTEND=noninteractive
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -qq 2>/dev/null
                apt-get install -y -qq openssh-server 2>/dev/null && echo INSTALL_OK
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache openssh 2>/dev/null
                ssh-keygen -A 2>/dev/null
                echo INSTALL_OK
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y -q openssh-server 2>/dev/null && echo INSTALL_OK
            elif command -v pacman >/dev/null 2>&1; then
                pacman -Sy --noconfirm openssh 2>/dev/null && echo INSTALL_OK
            fi
        ' 2>/dev/null | grep -q INSTALL_OK && install_ok=true
    fi

    # Fallback: docker exec normal (funciona se a rota já foi corrigida)
    if [[ "$install_ok" == false ]]; then
        log "Tentando instalação via docker exec..."
        docker exec "$name" bash -c '
            export DEBIAN_FRONTEND=noninteractive
            if command -v apt-get >/dev/null 2>&1; then
                apt-get update -qq 2>/dev/null
                apt-get install -y -qq openssh-server 2>/dev/null && echo INSTALL_OK
            elif command -v apk >/dev/null 2>&1; then
                apk add --no-cache openssh 2>/dev/null; ssh-keygen -A 2>/dev/null; echo INSTALL_OK
            elif command -v dnf >/dev/null 2>&1; then
                dnf install -y -q openssh-server 2>/dev/null && echo INSTALL_OK
            elif command -v pacman >/dev/null 2>&1; then
                pacman -Sy --noconfirm openssh 2>/dev/null && echo INSTALL_OK
            fi
        ' 2>/dev/null | grep -q INSTALL_OK && install_ok=true
    fi

    if [[ "$install_ok" == false ]]; then
        err "Não foi possível instalar openssh-server."
        info "Tente corrigir a rota primeiro (opção 7) e rode esta opção novamente."
        return 1
    fi

    # ── Passo 4: configurar e iniciar sshd ────────────────────────────────
    docker exec "$name" bash -c '
        mkdir -p /run/sshd /var/run/sshd

        # Permite login root via SSH
        cfg=/etc/ssh/sshd_config
        sed -i "s/^#*PermitRootLogin.*/PermitRootLogin yes/" "$cfg" 2>/dev/null || \
            echo "PermitRootLogin yes" >> "$cfg"
        sed -i "s/^#*PasswordAuthentication.*/PasswordAuthentication yes/" "$cfg" 2>/dev/null || \
            echo "PasswordAuthentication yes" >> "$cfg"

        # Garante que há uma senha para root
        echo "root:raspberry" | chpasswd 2>/dev/null || true

        # Gera chaves do host se não existirem
        ssh-keygen -A 2>/dev/null || true

        # Inicia sshd
        sshd_bin=$(command -v /usr/sbin/sshd || command -v sshd)
        "$sshd_bin" 2>/dev/null && echo SSHD_OK || echo SSHD_FAIL
    ' 2>/dev/null | grep -q SSHD_OK \
        && ok "sshd iniciado em '${name}'." \
        || err "Instalado mas falhou ao iniciar. Verifique: docker exec -it ${name} bash -c 'sshd -t'"

    # ── Passo 5: confirmar que está aceitando conexões ─────────────────────
    local ip; ip=$(conf_get "$name" 3)
    sleep 1
    if nc -z -w3 "$ip" 22 2>/dev/null; then
        ok "Porta 22 aberta em ${ip} — SSH pronto!"
        echo -e "  ${DIM}Acesso:${RST} ssh root@${ip}  ${DIM}(senha: raspberry)${RST}"
    else
        warn "Porta 22 não responde ainda. O sshd pode estar inicializando — tente em alguns segundos."
    fi
}

net_config_menu() {
    while true; do
        select_container "Configurar rede de qual container?" || return
        local name="$SELECTED_CONTAINER"

        local saved_internet; saved_internet=$(conf_get "$name" 6)
        local saved_dns; saved_dns=$(conf_get "$name" 7)
        local detected; detected=$(check_net_policy "$name")
        [[ -z "$saved_internet" ]] && saved_internet="yes"
        [[ -z "$saved_dns" ]]     && saved_dns="8.8.8.8,1.1.1.1"

        clear
        echo -e "\n ${P}◈ Configuração de Rede: ${C}${name}${RST}"
        hr
        echo -e "  Config salva  : ${W}${saved_internet}${RST}"
        echo -e "  Política ativa: ${W}${detected}${RST}"
        echo -e "  DNS           : ${W}${saved_dns}${RST}"
        echo ""
        echo -e "  ${W}Política de internet:${RST}"
        echo -e "  ${G}1)${RST} Habilitar internet completa"
        echo -e "  ${Y}2)${RST} Apenas LAN (sem saída para internet)"
        echo -e "  ${R}3)${RST} Isolado (sem nenhum acesso externo)"
        echo ""
        echo -e "  ${W}DNS:${RST}"
        echo -e "  ${C}4)${RST} Alterar servidores DNS"
        echo -e "  ${C}5)${RST} Corrigir DNS agora (reescreve resolv.conf)"
        echo ""
        echo -e "  ${W}Diagnóstico e reparo:${RST}"
        echo -e "  ${B}6)${RST} Diagnóstico completo de rede"
        echo -e "  ${B}7)${RST} Corrigir rota default (gateway)"
        echo -e "  ${B}8)${RST} Aplicar política salva agora"
        echo -e "  ${G}9)${RST} Instalar / corrigir SSH no container"
        echo ""
        echo -e "  ${DIM}q) Voltar${RST}"
        echo -n "  Opção: "; read -r nopt

        local image; image=$(conf_get "$name" 2)
        local ip; ip=$(conf_get "$name" 3)
        local auto; auto=$(conf_get "$name" 4)
        local usb; usb=$(conf_get "$name" 5)

        case "$nopt" in
            1)
                save_container "$name" "$image" "$ip" "$auto" "$usb" "yes" "$saved_dns"
                apply_net_policy "$name" "yes"
                net_fix_dns "$name"
                net_fix_route "$name"
                ;;
            2)
                save_container "$name" "$image" "$ip" "$auto" "$usb" "lan-only" "$saved_dns"
                apply_net_policy "$name" "lan-only"
                net_fix_dns "$name"
                net_fix_route "$name"
                ;;
            3)
                save_container "$name" "$image" "$ip" "$auto" "$usb" "none" "$saved_dns"
                apply_net_policy "$name" "none"
                ;;
            4)
                echo -e "\n  ${W}Novo DNS:${RST}"
                echo -e "  ${C}1)${RST} Google     (8.8.8.8, 8.8.4.4)"
                echo -e "  ${C}2)${RST} Cloudflare (1.1.1.1, 1.0.0.1)"
                echo -e "  ${C}3)${RST} Roteador   (${LAN_GATEWAY})"
                echo -e "  ${C}4)${RST} OpenDNS    (208.67.222.222, 208.67.220.220)"
                echo -e "  ${C}5)${RST} Manual"
                echo -n "  Escolha: "; read -r dc
                local new_dns
                case "$dc" in
                    1) new_dns="8.8.8.8,8.8.4.4" ;;
                    2) new_dns="1.1.1.1,1.0.0.1" ;;
                    3) new_dns="$LAN_GATEWAY" ;;
                    4) new_dns="208.67.222.222,208.67.220.220" ;;
                    5) echo -n "  DNS (ex: 8.8.8.8,1.1.1.1): "; read -r new_dns ;;
                    *) warn "Opção inválida."; new_dns="$saved_dns" ;;
                esac
                save_container "$name" "$image" "$ip" "$auto" "$usb" "$saved_internet" "$new_dns"
                confirm "Aplicar novo DNS agora no container em execução?"                     && { saved_dns="$new_dns"; net_fix_dns "$name"; }
                ;;
            5) net_fix_dns "$name" ;;
            6) net_diag "$name" ;;
            7) net_fix_route "$name" ;;
            8) apply_net_policy "$name" "$saved_internet"
               net_fix_dns "$name"
               [[ "$saved_internet" != "none" ]] && net_fix_route "$name"
               ;;
            9) net_fix_ssh "$name" ;;
            q|Q) return ;;
            *) warn "Opção inválida." ;;
        esac
        pause
    done
}

# ─────────────────────────────────────────────────────────────────────────────
#  SYSTEMD
# ─────────────────────────────────────────────────────────────────────────────

install_container_service() {
    local name=$1
    local svc="${SERVICE_PREFIX}-${name}"
    local ip; ip=$(grep "^${name}|" "$CONTAINERS_CONF" 2>/dev/null | cut -d'|' -f3)

    cat > "/etc/systemd/system/${svc}.service" << EOF
[Unit]
Description=Container Manager — ${name}
After=network-online.target docker.service
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStartPre=/bin/sleep 8
ExecStartPre=-/sbin/ip link add macvlan0 link ${HOST_INTERFACE} type macvlan mode bridge
ExecStartPre=-/sbin/ip addr add ${LAN_GATEWAY%.*}.254/32 dev macvlan0
ExecStartPre=-/sbin/ip link set macvlan0 up
ExecStartPre=-/sbin/ip route add ${ip}/32 dev macvlan0
ExecStartPre=/bin/bash -c "docker network ls | grep -q ${MACVLAN_NET} || docker network create -d macvlan --subnet=${LAN_SUBNET} --gateway=${LAN_GATEWAY} -o parent=${HOST_INTERFACE} ${MACVLAN_NET}"
ExecStart=/usr/bin/docker start ${name}
ExecStop=/usr/bin/docker stop -t 10 ${name}
Restart=on-failure
RestartSec=30

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable "$svc"
    ok "Serviço '${svc}' instalado e habilitado."
}

toggle_autostart() {
    local name=$1; require_root
    local svc="${SERVICE_PREFIX}-${name}"
    if systemctl is-enabled "$svc" &>/dev/null 2>&1; then
        systemctl disable "$svc"
        rm -f "/etc/systemd/system/${svc}.service"
        systemctl daemon-reload
        sed -i "s/^${name}|\([^|]*\)|\([^|]*\)|yes|/${name}|\1|\2|no|/" "$CONTAINERS_CONF" 2>/dev/null || true
        warn "Autostart desabilitado para '${name}'."
    else
        install_container_service "$name"
        sed -i "s/^${name}|\([^|]*\)|\([^|]*\)|no|/${name}|\1|\2|yes|/" "$CONTAINERS_CONF" 2>/dev/null || true
        ok "Autostart habilitado para '${name}'."
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  INSTALAÇÃO DE DEPENDÊNCIAS
# ─────────────────────────────────────────────────────────────────────────────

install_deps() {
    require_root
    log "Atualizando repositórios..."
    apt-get update -qq
    local pkgs=()
    command -v docker  &>/dev/null || pkgs+=(docker.io)
    command -v python3 &>/dev/null || pkgs+=(python3)
    command -v lsusb   &>/dev/null || pkgs+=(usbutils)
    command -v nsenter &>/dev/null || pkgs+=(util-linux)
    [[ ${#pkgs[@]} -gt 0 ]] && apt-get install -y "${pkgs[@]}"
    systemctl enable --now docker
    usermod -aG docker "${SUDO_USER:-pi}" 2>/dev/null || true
    ok "Dependências instaladas."
    info "Faça logout/login se o usuário foi adicionado ao grupo docker."
}

# ─────────────────────────────────────────────────────────────────────────────
#  SELEÇÃO DE CONTAINER
# ─────────────────────────────────────────────────────────────────────────────

SELECTED_CONTAINER=""

select_container() {
    local prompt="${1:-Selecione o container}"
    local containers=()
    [[ ! -f "$CONTAINERS_CONF" ]] && { err "Nenhum container configurado."; return 1; }
    while IFS='|' read -r name _; do [[ -n "$name" ]] && containers+=("$name"); done < "$CONTAINERS_CONF"
    [[ ${#containers[@]} -eq 0 ]] && { err "Nenhum container configurado."; return 1; }

    echo -e "\n ${W}${prompt}:${RST}"
    local i=1
    for c in "${containers[@]}"; do echo -e "  ${C}$i)${RST} $c"; (( i++ )); done
    echo -n "  Escolha: "; read -r choice

    if [[ "$choice" =~ ^[0-9]+$ && "$choice" -ge 1 && "$choice" -le ${#containers[@]} ]]; then
        SELECTED_CONTAINER="${containers[$((choice-1))]}"; return 0
    else
        warn "Opção inválida."; return 1
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
#  BANNER
# ─────────────────────────────────────────────────────────────────────────────

banner() {
    clear
    echo -e "${P}${W}"
    echo "  ╔═══════════════════════════════════════════════════════╗"
    echo "  ║       Container Manager — Raspberry Pi               ║"
    echo "  ║       Multi-OS · macvlan · USB · Catálogo            ║"
    echo "  ╚═══════════════════════════════════════════════════════╝${RST}"
    echo ""
    show_host_resources
    echo ""

    if [[ -f "$CONTAINERS_CONF" ]] && [[ -s "$CONTAINERS_CONF" ]]; then
        echo -e " ${W}┌─ Containers ────────────────────────────────────────────┐${RST}"
        printf "  ${DIM}%-3s %-18s %-16s %-16s %-8s %-4s${RST}\n" "#" "NOME" "IMAGEM" "IP" "STATUS" "AUTO"

        local idx=1
        while IFS='|' read -r name image ip autostart usb; do
            [[ -z "$name" ]] && continue
            local status_str ip_str
            if docker ps --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
                status_str="${G}● running${RST}"
                ip_str="${C}${ip}${RST}"
            elif docker ps -a --format '{{.Names}}' 2>/dev/null | grep -q "^${name}$"; then
                status_str="${Y}● stopped${RST}"; ip_str="${DIM}${ip}${RST}"
            else
                status_str="${R}● ausente${RST}"; ip_str="${DIM}—${RST}"
            fi
            local auto_str usb_mark=""
            [[ "$autostart" == "yes" ]] && auto_str="${G}sim${RST}" || auto_str="${DIM}não${RST}"
            [[ -n "${usb// /}" ]] && usb_mark=" ${B}[usb]${RST}"

            # Indicador de internet (campo 6 do .containers.conf)
            local full_line inet_field inet_mark=""
            full_line=$(grep "^${name}|" "$CONTAINERS_CONF" 2>/dev/null || echo "")
            inet_field=$(echo "$full_line" | cut -d'|' -f6)
            case "${inet_field:-yes}" in
                yes)      inet_mark=" ${G}[net]${RST}" ;;
                lan-only) inet_mark=" ${Y}[lan]${RST}" ;;
                none)     inet_mark=" ${R}[off]${RST}" ;;
            esac

            printf "  ${C}%-3s${RST} %-18s %-16s " "$idx" "${name:0:17}" "${image##*/}"
            echo -e "$ip_str   $status_str   $auto_str$usb_mark$inet_mark"
            (( idx++ ))
        done < "$CONTAINERS_CONF"
        echo -e " ${W}└──────────────────────────────────────────────────────────┘${RST}"
        echo ""
    fi
}

menu() {
    echo -e " ${W}Containers${RST}"
    echo -e "  ${G}1${RST}) Adicionar novo container"
    echo -e "  ${C}2${RST}) Iniciar   ${R}3${RST}) Parar   ${Y}4${RST}) Reiniciar   ${B}5${RST}) Remover"
    echo -e "  ${C}6${RST}) Shell     ${C}7${RST}) Logs    ${B}8${RST}) Status detalhado"
    echo ""
    echo -e " ${W}Catálogo de Imagens${RST}"
    echo -e "  ${P}C${RST}) Gerenciar catálogo (adicionar · editar · pull · atualizar)"
    echo -e "  ${P}U${RST}) Atualizar imagem de um container (pull + recriar)"
    echo ""
    echo -e " ${W}USB & Rede${RST}"
    echo -e "  ${B}9${RST}) Listar dispositivos USB"
    echo -e "  ${B}10${RST}) Adicionar USB a container"
    echo -e "  ${C}11${RST}) Reconfigurar rede macvlan"
    echo -e "  ${C}12${RST}) Testar conectividade (ping)"
    echo -e "  ${C}N${RST})  Configurar rede do container (internet · DNS · diagnóstico)"
    echo ""
    echo -e " ${W}Monitor${RST}"
    echo -e "  ${P}13${RST}) Monitor ao vivo (tempo real)"
    echo -e "  ${P}14${RST}) Snapshot de recursos"
    echo ""
    echo -e " ${W}Sistema${RST}"
    echo -e "  ${P}15${RST}) Toggle autostart de container"
    echo -e "  ${Y}I${RST})  Instalar dependências"
    echo -e "  ${R}18${RST}) Reset total"
    echo -e "  ${R}q${RST})  Sair"
    echo ""
    echo -n " Opção: "
}

# ─────────────────────────────────────────────────────────────────────────────
#  AÇÕES RÁPIDAS
# ─────────────────────────────────────────────────────────────────────────────

do_action() {
    local action=$1
    select_container "Selecione o container" || return
    case "$action" in
        start)   start_container "$SELECTED_CONTAINER" ;;
        stop)    stop_container  "$SELECTED_CONTAINER" ;;
        restart) stop_container  "$SELECTED_CONTAINER"; sleep 2; start_container "$SELECTED_CONTAINER" ;;
        remove)  remove_container "$SELECTED_CONTAINER" ;;
        shell)   shell_into      "$SELECTED_CONTAINER" ;;
        logs)    docker logs -f --tail=80 "$SELECTED_CONTAINER" ;;
        status)
            echo ""
            docker inspect "$SELECTED_CONTAINER" --format \
"  Nome    : {{.Name}}
  Estado  : {{.State.Status}}
  Iniciou : {{.State.StartedAt}}
  Imagem  : {{.Config.Image}}
  Restart : {{.HostConfig.RestartPolicy.Name}}
  Pid     : {{.State.Pid}}" 2>/dev/null
            echo ""
            docker stats "$SELECTED_CONTAINER" --no-stream --format \
"  CPU     : {{.CPUPerc}}
  RAM     : {{.MemUsage}} ({{.MemPerc}})
  Net I/O : {{.NetIO}}
  Block   : {{.BlockIO}}" 2>/dev/null || warn "Container não está rodando."
            ;;
        ping)
            local ip; ip=$(get_container_ip "$SELECTED_CONTAINER")
            [[ -z "$ip" ]] && ip=$(grep "^${SELECTED_CONTAINER}|" "$CONTAINERS_CONF" | cut -d'|' -f3)
            info "Pingando ${ip}..."
            ping -c4 -W2 "$ip" && ok "Acessível." || err "Sem resposta."
            ;;
        update)  update_container_image "$SELECTED_CONTAINER" ;;
        autostart) toggle_autostart "$SELECTED_CONTAINER" ;;
        usb)
            echo -e "\n ${Y}Docker não suporta adicionar dispositivos a containers em execução.${RST}"
            echo -e "  ${C}1)${RST} Recriar container com novo USB (recomendado)"
            echo -e "  ${C}2)${RST} Cancelar"
            echo -n "  Escolha: "; read -r uopt
            if [[ "$uopt" == "1" ]]; then
                local name="$SELECTED_CONTAINER"
                local image ip auto usb
                IFS='|' read -r _ image ip auto usb <<< "$(grep "^${name}|" "$CONTAINERS_CONF")"
                local new_usb; new_usb=$(select_usb_for_container)
                # Limpa espaços duplicados ao combinar flags existentes com novas
                local combined; combined=$(echo "${usb} ${new_usb}" | tr -s ' ' | sed 's/^ //;s/ $//')
                stop_container "$name"; docker rm "$name"
                create_container_run "$name" "$image" "$ip" "$combined"
                save_container "$name" "$image" "$ip" "$auto" "$combined"
                ok "Container recriado com novos dispositivos USB."
            fi
            ;;
    esac
}

do_reset() {
    require_root
    confirm "RESET TOTAL: remover TODOS os containers e a rede Docker?" || return
    [[ -f "$CONTAINERS_CONF" ]] && while IFS='|' read -r name _; do
        [[ -z "$name" ]] && continue
        docker stop "$name" 2>/dev/null || true
        docker rm   "$name" 2>/dev/null || true
        local svc="${SERVICE_PREFIX}-${name}"
        systemctl disable "$svc" 2>/dev/null || true
        rm -f "/etc/systemd/system/${svc}.service"
    done < "$CONTAINERS_CONF"
    remove_macvlan
    rm -f "$CONTAINERS_CONF"
    systemctl daemon-reload 2>/dev/null || true
    ok "Reset completo."
}

# ─────────────────────────────────────────────────────────────────────────────
#  MODO NÃO-INTERATIVO
# ─────────────────────────────────────────────────────────────────────────────

case "${1:-}" in
    --start)  [[ -n "${2:-}" ]] && start_container "$2"; exit 0 ;;
    --stop)   [[ -n "${2:-}" ]] && stop_container  "$2"; exit 0 ;;
    --bridge) ensure_host_bridge; exit 0 ;;
esac

# ─────────────────────────────────────────────────────────────────────────────
#  LOOP PRINCIPAL
# ─────────────────────────────────────────────────────────────────────────────

init_state

while true; do
    banner
    menu
    read -r opt

    case "$opt" in
        1)  add_new_container ;;
        2)  do_action start ;;
        3)  do_action stop ;;
        4)  do_action restart ;;
        5)  do_action remove ;;
        6)  do_action shell ;;
        7)  do_action logs ;;
        8)  do_action status ;;
        9)  list_usb_devices ;;
        10) do_action usb ;;
        11) require_root && remove_macvlan && ensure_macvlan && ensure_host_bridge ;;
        12) do_action ping ;;
        N|n) net_config_menu ;;
        13) monitor_live ;;
        14) show_host_resources; show_container_resources ;;
        15) do_action autostart ;;
        C|c) catalog_menu ;;
        U|u) do_action update ;;
        I|i) install_deps ;;
        18)  do_reset ;;
        q|Q) echo -e "${G} Até mais!${RST}"; exit 0 ;;
        *)   warn "Opção inválida." ;;
    esac

    [[ "$opt" != "6" && "$opt" != "7" && "$opt" != "13" ]] && pause
done