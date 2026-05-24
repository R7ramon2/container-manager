# Container Manager — Raspberry Pi

Gerenciador interativo de múltiplos containers Docker para Raspberry Pi. Cada container recebe um **IP próprio na sua rede local** via macvlan — aparece na rede como se fosse um computador separado. Suporta qualquer imagem Docker, passthrough de dispositivos USB (modems, pendrives, seriais), monitor de recursos do host em tempo real e autostart individual por container via systemd.

---

## Sumário

- [Container Manager — Raspberry Pi](#container-manager--raspberry-pi)
  - [Sumário](#sumário)
  - [Como funciona](#como-funciona)
  - [Requisitos](#requisitos)
  - [Instalação](#instalação)
  - [Configuração inicial](#configuração-inicial)
  - [Uso](#uso)
    - [Menu principal](#menu-principal)
    - [Gerenciador de catálogo (opção `C`)](#gerenciador-de-catálogo-opção-c)
    - [Monitor de recursos](#monitor-de-recursos)
    - [USB passthrough](#usb-passthrough)
    - [Autostart](#autostart)
  - [Arquivos e estrutura](#arquivos-e-estrutura)
  - [Catálogo de imagens padrão](#catálogo-de-imagens-padrão)
  - [Acesso aos containers](#acesso-aos-containers)
  - [Rede macvlan — como funciona](#rede-macvlan--como-funciona)
  - [Perguntas frequentes](#perguntas-frequentes)

---

## Como funciona

O script usa o driver de rede **macvlan** do Docker para criar uma interface virtual diretamente sobre a interface física do Raspberry Pi (`wlan0` por padrão). Isso faz com que cada container apareça na sua rede Wi-Fi ou Ethernet como um dispositivo independente, com endereço MAC e IP próprios atribuídos pelo roteador ou configurados de forma estática.

```
Sua rede local (192.168.1.0/24)
│
├── Roteador          192.168.1.1
├── Raspberry Pi      192.168.1.10   (host)
│   ├── kali-linux    192.168.1.50   (container — IP próprio na LAN)
│   ├── ubuntu-server 192.168.1.51   (container — IP próprio na LAN)
│   └── parrot-os     192.168.1.52   (container — IP próprio na LAN)
└── Outros dispositivos...
```

Outros dispositivos na rede podem acessar os containers diretamente pelo IP, sem NAT ou redirecionamento de porta.

---

## Requisitos

| Componente | Versão mínima |
|---|---|
| Raspberry Pi | 3B+ ou superior (testado no Pi 4) |
| Sistema operacional | Raspberry Pi OS / Ubuntu Server (ARM) |
| Docker | 20.10+ |
| Python 3 | 3.7+ (já incluso no Raspberry Pi OS) |
| Bash | 4.0+ |

O script instala automaticamente as dependências que faltarem ao rodar a opção `I` do menu.

---

## Instalação

```bash

# Dê permissão de execução
chmod +x container-manager.sh

# Execute como root
sudo ./container-manager.sh
```

Na primeira execução, use a opção `I` para instalar Docker e dependências, depois configure a rede no topo do script.

---

## Configuração inicial

Antes de criar qualquer container, edite o bloco de configurações no início do arquivo `container-manager.sh`:

```bash
HOST_INTERFACE="wlan0"          # sua interface de rede (wlan0, eth0, etc)
LAN_SUBNET="192.168.1.0/24"    # subnet da sua rede local
LAN_GATEWAY="192.168.1.1"      # IP do seu roteador
```

Para descobrir a interface correta:

```bash
ip link show
# ou
ip addr
```

> **Dica:** Se o Raspberry Pi está conectado via cabo, use `eth0`. Via Wi-Fi, use `wlan0`.

> **Importante:** Os IPs dos containers devem estar fora do range DHCP do seu roteador para evitar conflitos. Reserve uma faixa estática no roteador (ex: `.50` a `.80`) e use esses endereços nos containers.

---

## Uso

### Menu principal

```
sudo ./container-manager.sh
```

O banner exibe em tempo real o uso de CPU, RAM, temperatura e disco do Raspberry Pi, seguido da lista de todos os containers configurados com status e IP.

```
Containers
  1) Adicionar novo container
  2) Iniciar   3) Parar   4) Reiniciar   5) Remover
  6) Shell     7) Logs    8) Status detalhado

Catálogo de Imagens
  C) Gerenciar catálogo (adicionar · editar · pull · atualizar)
  U) Atualizar imagem de um container (pull + recriar)

USB & Rede
  9) Listar dispositivos USB
  10) Adicionar USB a container
  11) Reconfigurar rede macvlan
  12) Testar conectividade (ping)

Monitor
  13) Monitor ao vivo (tempo real)
  14) Snapshot de recursos

Sistema
  15) Toggle autostart de container
  I)  Instalar dependências
  18) Reset total
  q)  Sair
```

---

### Gerenciador de catálogo (opção `C`)

O catálogo é um arquivo de texto em `~/containers/.catalog.conf` onde ficam registradas todas as imagens disponíveis para criar containers. Ele é criado automaticamente na primeira execução com 13 imagens pré-configuradas.

Dentro do submenu de catálogo:

**`a` — Adicionar nova imagem**

Cadastra qualquer imagem Docker no catálogo. Aceita imagens do Docker Hub, GitHub Container Registry (`ghcr.io`), Quay ou qualquer registry público:

```
Nome amigável : meu-nginx
Imagem        : nginx:1.25-alpine
IP sugerido   : 192.168.1.63   (sugerido automaticamente)
Descrição     : Nginx 1.25 Alpine para testes
```

**`e` — Editar entrada existente**

Permite trocar a tag de uma imagem (ex: `ubuntu:22.04` → `ubuntu:24.04`), renomear, mudar o IP padrão ou a descrição. Após editar a tag, use pull para baixar a nova versão.

**`r` — Remover entrada do catálogo**

Remove a entrada do catálogo. Containers já criados com essa imagem não são afetados.

**`p` — Baixar / atualizar imagens**

Submenu com cinco opções:

| Opção | Ação |
|---|---|
| 1 | Baixar ou atualizar uma imagem específica do catálogo |
| 2 | Baixar ou atualizar **todas** as imagens do catálogo de uma vez |
| 3 | Digitar imagem fora do catálogo e opcionalmente adicioná-la |
| 4 | Ver todas as imagens já baixadas localmente (com tamanho) |
| 5 | Limpar imagens antigas sem tag (dangling) que sobram após updates |

Ao fazer pull, o script compara o hash da imagem antes e depois. Se mudou, avisa que há versão nova e oferece recriar o container para aplicar a atualização. Se não mudou, informa que já estava na versão mais recente.

---

### Monitor de recursos

**Opção `13` — Monitor ao vivo**

Atualiza a cada 3 segundos com barras visuais coloridas:

```
◈ Monitor de Recursos  24/05/2026 14:32:11
──────────────────────────────────────────────────────────────
┌─ Host: Raspberry Pi ─────────────────────────────────────┐
  CPU   ████████░░░░░░░░░░░░  38%  (4 cores · 54°C)
  RAM   ████████████░░░░░░░░  57%  (2134 MB / 3700 MB)
  DISCO ███████████░░░░░░░░░  56%  (18000 MB / 32000 MB)
└──────────────────────────────────────────────────────────┘

┌─ Recursos por Container ─────────────────────────────────┐
  CONTAINER            CPU%      RAM            NET I/O
  ──────────────────────────────────────────────────────────
  kali-linux           12.4%     512MiB/3.7GiB  1.2MB/800kB
  ubuntu-server        2.1%      128MiB/3.7GiB  450kB/120kB
└──────────────────────────────────────────────────────────┘
```

As barras mudam de cor automaticamente: verde abaixo de 60%, amarelo entre 60–80%, vermelho acima de 80%.

**Opção `14` — Snapshot**

Mesma visualização, mas estática (sem loop).

---

### USB passthrough

Ao criar um container (opção `1`), o script pergunta se deseja mapear dispositivos USB. Ele lista automaticamente:

- Modems USB: `/dev/ttyUSB0`, `/dev/ttyACM0`, `/dev/cdc-wdm0`, etc.
- Dispositivos de bloco: `/dev/sda`, `/dev/sdb`, etc.
- Interface TUN: `/dev/net/tun`

Você escolhe quais mapear digitando os números separados por espaço (ex: `1 3`). Os dispositivos ficam acessíveis dentro do container exatamente nos mesmos paths.

**Modem USB 4G/LTE**

Quando você conecta um modem USB ao Raspberry Pi, ele aparece na lista como `ttyUSB0` e possivelmente `cdc-wdm0`. Ao mapear para um container, o modem fica acessível dentro do container como se fosse hardware nativo — você pode usar `ModemManager`, `nmcli` ou `wvdial` dentro do container para estabelecer conexão.

**Adicionar USB a container já criado (opção `10`)**

Como o Docker não suporta adicionar dispositivos a containers em execução, o script oferece recriar o container automaticamente com o novo dispositivo. Os dados em `~/containers/<nome>/data` são preservados.

---

### Autostart

Cada container tem seu próprio serviço systemd independente. Para habilitar ou desabilitar o autostart de um container específico, use a opção `15`.

O serviço gerado fica em `/etc/systemd/system/pi-container-<nome>.service` e faz o seguinte na ordem correta ao ligar o Raspberry Pi:

1. Aguarda 8 segundos para a rede estabilizar
2. Recria a interface `macvlan0` (que é volátil e some após reboot)
3. Garante que a rede Docker macvlan existe
4. Inicia o container

Para gerenciar manualmente os serviços:

```bash
# Ver status
systemctl status pi-container-kali-linux

# Iniciar manualmente
systemctl start pi-container-kali-linux

# Ver logs do serviço
journalctl -u pi-container-kali-linux -f
```

---

## Arquivos e estrutura

```
~/containers/
├── .catalog.conf          # catálogo de imagens (editável)
├── .containers.conf       # estado dos containers criados
├── kali-linux/
│   ├── data/              # /root/persistent dentro do container
│   └── tools/             # /opt/tools dentro do container
├── ubuntu-server/
│   ├── data/
│   └── tools/
└── ...

/var/log/container-manager.log     # log de operações

/etc/systemd/system/
├── pi-container-kali-linux.service
├── pi-container-ubuntu-server.service
└── ...
```

**Formato do `.catalog.conf`**

```
nome_amigavel|imagem:tag|ip_sugerido|descricao
kali-rolling|kalilinux/kali-rolling|192.168.1.50|Kali Linux (rolling)
ubuntu-22|ubuntu:22.04|192.168.1.52|Ubuntu Server 22.04 LTS
meu-nginx|nginx:1.25-alpine|192.168.1.63|Nginx para testes
```

O arquivo pode ser editado manualmente com qualquer editor de texto.

**Formato do `.containers.conf`**

```
nome|imagem|ip|autostart|usb_flags
kali-linux|kalilinux/kali-rolling|192.168.1.50|yes|--device=/dev/ttyUSB0
ubuntu-server|ubuntu:22.04|192.168.1.51|no|
```

---

## Catálogo de imagens padrão

| Nome | Imagem | IP padrão |
|---|---|---|
| kali-rolling | `kalilinux/kali-rolling` | 192.168.1.50 |
| kali-bleeding | `kalilinux/kali-bleeding-edge` | 192.168.1.51 |
| ubuntu-22 | `ubuntu:22.04` | 192.168.1.52 |
| ubuntu-24 | `ubuntu:24.04` | 192.168.1.53 |
| debian-stable | `debian:stable-slim` | 192.168.1.54 |
| debian-bookworm | `debian:bookworm` | 192.168.1.55 |
| parrot-os | `parrotsec/core:latest` | 192.168.1.56 |
| alpine | `alpine:latest` | 192.168.1.57 |
| arch-linux | `archlinux:latest` | 192.168.1.58 |
| fedora | `fedora:latest` | 192.168.1.59 |
| raspbian | `balenalib/raspberry-pi-debian:bullseye` | 192.168.1.60 |
| centos-stream | `quay.io/centos/centos:stream9` | 192.168.1.61 |
| kali-minimal | `kalilinux/kali-last-release` | 192.168.1.62 |

Os IPs são sugestões — você pode mudar ao criar o container.

---

## Acesso aos containers

Todos os containers são criados com SSH habilitado e um usuário root configurado:

```bash
# SSH direto pelo IP do container
ssh root@192.168.1.50
# Senha padrão: raspberry

# Shell via Docker (sem SSH)
sudo docker exec -it kali-linux bash

# Ou pela opção 6 do menu
```

> **Recomendado:** Troque a senha root dentro do container após o primeiro acesso com `passwd`.

Os containers também ficam acessíveis a qualquer outro dispositivo da sua rede pelo IP atribuído, incluindo outros computadores, celulares, etc.

---

## Rede macvlan — como funciona

O macvlan cria interfaces virtuais diretamente sobre a interface física, dando ao container um MAC address único. O roteador enxerga cada container como um dispositivo físico separado.

**Limitação conhecida:** por padrão, o próprio Raspberry Pi não consegue se comunicar com os containers via macvlan (limitação do kernel). O script resolve isso criando uma interface `macvlan0` no host com uma rota estática para cada container:

```bash
ip link add macvlan0 link wlan0 type macvlan mode bridge
ip addr add 192.168.1.254/32 dev macvlan0
ip link set macvlan0 up
ip route add 192.168.1.50/32 dev macvlan0  # rota para o container
```

Essa interface é recriada automaticamente pelo serviço systemd após cada reboot.

---

## Perguntas frequentes

**O container aparece na rede mas o Raspberry Pi não consegue pingar ele.**

Use a opção `11` para reconfigurar a rede macvlan. Isso recria a interface `macvlan0` e as rotas estáticas. Isso pode ocorrer após reboot se o serviço systemd do container não estava habilitado.

**Adicionei um modem USB mas o container não o vê.**

Use a opção `10` para recriar o container mapeando o dispositivo. Confirme que o modem está listado em `/dev/ttyUSB*` ou `/dev/cdc-wdm*` com `ls /dev/tty*` antes de tentar.

**Quero usar interface eth0 e wlan0 ao mesmo tempo.**

O macvlan funciona sobre uma única interface por rede Docker. Crie duas redes macvlan com nomes diferentes, uma sobre `wlan0` e outra sobre `eth0`, e conecte containers diferentes a cada uma.

**O container some após eu reiniciar o Raspberry Pi sem parar pelo script.**

Os dados em `~/containers/<nome>/data` são preservados. O container em si pode ter sido parado abruptamente, mas basta rodá-lo novamente com a opção `2`. Para evitar isso, habilite o autostart com a opção `15`.

**Posso usar o script em outra distro ARM além do Raspberry Pi OS?**

Sim. Qualquer distro baseada em Debian/Ubuntu com `systemd` e `apt` funciona. Em distros com outro gerenciador de pacotes, a instalação de dependências (opção `I`) pode precisar de ajuste manual, mas o restante funciona normalmente desde que Docker esteja instalado.

**Quanto de RAM cada container consome?**

Depende da imagem e do que está rodando dentro. Um container Kali vazio consome em torno de 80–150 MB de RAM. O monitor ao vivo (opção `13`) mostra o consumo exato de cada container em tempo real.