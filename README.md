# archlab

Instalador de **Arch Linux ARM em chroot no Android**, no estilo do `archinstall`: wizard interativo, perfis, seleção de pacotes, mirrors, modo não-interativo por flags/config e comandos de manutenção.

O objetivo é funcionar em qualquer device Android **arm64/aarch64** (e armv7, quando o aparelho/kernel suportar), sem depender de um modelo específico. O `archlab.sh` é um único arquivo `sh` POSIX, pensado para rodar no `mksh`/toybox do Android.

> **Status:** alpha. O script foi reestruturado a partir de um instalador testado em Galaxy S21 (aarch64), mas a generalização para outros devices ainda precisa de testes da comunidade. Rode `doctor` antes de instalar e reporte o resultado.

---

## Recursos

- Wrapper para PC (`archlab.cmd` + `archlab.ps1`): acha o device, confere os requisitos, envia o script e roda os comandos via `adb`, sem abrir shell no celular. Sem argumentos abre o wizard (se não houver lab) ou um painel de operações (se já houver).
- Wizard interativo com valores padrão (pasta, arquitetura, mirror, hostname, timezone, locale, usuário, senha).
- Modo 100% não-interativo com flags ou arquivo de config.
- Instalação resumível: se falhar, rode `install` de novo.
- Reconfiguração sem reinstalar: mudar a config e rodar `install` de novo reaplica só as etapas afetadas (usuário, pacotes, SSH, mirror etc.). `--force` é para recriar o rootfs do zero.
- Detecção de device, Android, ABI, root manager (Magisk/KernelSU/APatch), busybox, SELinux e capacidades do kernel.
- Rootfs oficial do Arch Linux ARM (`aarch64` ou `armv7`), com verificação MD5.
- Download com retomada (`.part`) e fallback entre mirrors.
- Mirrorlist do pacman com mirror principal + fallbacks.
- Perfis: `minimal`, `dev`, `server`, `custom`.
- Menu de grupos de pacotes + campo para pacotes avulsos (`--packages`).
- Usuário com `sudo`, grupos de rede do Android (`aid_inet`/`aid_net_raw`) e grupos de armazenamento quando `/sdcard` é montado.
- SSH opcional (porta, senha/chave pública, `sshd_config.d`).
- Tailscale opcional em userspace networking (sem TUN).
- Autostart no boot via `/data/adb/service.d` (Magisk/KernelSU/APatch).
- Wakelock opcional.
- Bind de `/sdcard` em `/mnt/sdcard` e binds extras (`origem:destino`).
- `doctor` com diagnóstico de mounts, suid, devpts, chroot, namespace, rede e espaço.
- `shell`, `exec`, `pacman`, `update`, `backup`, `uninstall`, `status`, `info`, `mirror`, `config`.

---

## Requisitos

- Android com **root**:
  - Magisk, KernelSU (incl. Next) ou APatch.
  - Acesso a `su` e mount namespace global.
- Arquitetura **aarch64/arm64** (recomendado) ou **armv7**.
  - x86/x86_64 **não** é suportado nesta versão.
- **4 GB livres** em `/data` no mínimo; **6 GB** recomendado.
  - O tarball aarch64 atual tem ~830 MB e extrai ~2,5 GB; o pacman ainda precisa de espaço.
- Internet no device (Wi-Fi/dados) ou tarball baixado no PC.
- Kernel com `proc`, `sysfs`, `tmpfs` e, idealmente, `devpts`.
- `chroot` disponível no toybox ou busybox.

No PC, só para usar o wrapper (`archlab.cmd`): `adb` (platform-tools) no PATH, PowerShell 5.1+ e depuração USB autorizada no celular.

> O rootfs **precisa** ficar em `/data` (ext4/f2fs). Não instale em `/sdcard`, `/storage` ou cartão exFAT/FAT: esses mounts são FUSE e não preservam dono/permissões/suid.

---

## Início rápido (Windows)

Com o celular conectado por USB e a depuração USB autorizada:

```bat
git clone https://github.com/Leandro-74/archinstaller-chroot.git
cd archinstaller-chroot
.\archlab.cmd
```

(No `cmd.exe`, `archlab.cmd` também funciona sem o `.\`.)

O `archlab.cmd` faz o trabalho chato:

1. encontra o device (ou pede `-s SERIAL` se houver mais de um);
2. confere root, arquitetura, `chroot`, `tar`, espaço em `/data`, download e SELinux;
3. envia o `archlab.sh` para `/data/local/tmp/archlab/`;
4. roda o comando como root, repassando os argumentos;
5. envia e reescreve os caminhos de arquivos locais (`--config`, `--ssh-key`, `--rootfs`).

Sem argumentos, ele decide o que fazer:

- **sem lab instalado** → abre o wizard;
- **com lab instalado** → abre o painel: status, shell, `exec`, pacman, doctor, logs, backup, pull, start/stop, reconfigurar, SSH via USB (abre um terminal já conectado), energia/boot (wakelock, autostart, Tailscale) e uninstall. O cabeçalho mostra o estado atual (wakelock e autostart).

O wizard roda no celular, mas você responde tudo na janela do PC. Nada de `adb shell` + `su -c`.

```bat
.\archlab.cmd menu                :: abre o painel (mesmo sem argumentos)
.\archlab.cmd doctor              :: diagnóstico completo
.\archlab.cmd status              :: estado e comandos de SSH
.\archlab.cmd shell               :: shell root dentro do chroot
.\archlab.cmd install --yes --config .\meu.env
.\archlab.cmd backup              :: cria o .tar.gz no celular
.\archlab.cmd pull                :: baixa o backup mais novo para o PC
.\archlab.cmd forward 2222        :: SSH via USB em localhost:2222
.\archlab.cmd logs 100            :: últimas linhas do log
.\archlab.cmd devices             :: device + requisitos
.\archlab.cmd -h                  :: ajuda do wrapper
```

Opções do wrapper (não vão para o device):

```text
-s, --serial SERIAL   escolhe o device
    --adb CAMINHO     caminho do adb
    --file CAMINHO    outro archlab.sh local a enviar
    --no-push         não reenvia o script
    --tty / --no-tty  força/desliga o terminal interativo
```

Qualquer outro argumento é repassado ao `archlab.sh` (a lista completa do `install` aparece em `archlab.cmd help`).

### Instalação manual (sem o wrapper)

```sh
adb push archlab.sh /data/local/tmp/archlab.sh
adb shell
su -c "sh /data/local/tmp/archlab.sh doctor"
su -c "sh /data/local/tmp/archlab.sh install"
```

Corrija o que o `doctor` mostrar como falha crítica antes de continuar; avisos sobre `devpts` e namespace podem ser contornados pelo próprio instalador.

Ou direto no device (Termux/outro shell com curl):

```sh
curl -fsSL -o /data/local/tmp/archlab.sh \
  https://raw.githubusercontent.com/Leandro-74/archinstaller-chroot/main/archlab.sh
```

O wizard (tanto pelo wrapper quanto no modo manual) pergunta:

1. pasta de instalação;
2. arquitetura (`aarch64`/`armv7`);
3. mirror do Arch Linux ARM;
4. hostname, timezone e locale;
5. usuário e senha (Enter gera uma senha aleatória);
6. perfil e pacotes adicionais;
7. SSH (porta, senha/chave);
8. Tailscale;
9. bind de `/sdcard`, autostart e wakelock;
10. modo do SELinux (auto/permissivo/enforcing).

No fim ele mostra um resumo e pede confirmação.

### Acessar

Se o SSH estiver habilitado, o instalador mostra os comandos. Exemplos:

```sh
# mesma rede Wi-Fi
ssh -p 2222 lab@192.168.0.123

# via USB (sem depender do Wi-Fi)
adb forward tcp:2222 tcp:2222     # ou, no PC: archlab.cmd forward 2222
ssh -p 2222 lab@127.0.0.1

# shell local, sem SSH
su -c "sh /data/local/archlab/archlab.sh shell"
```

Dentro do Arch, o `labctl` (instalado pelo `archlab.sh`) executa os comandos de controle do Android — útil pelo SSH:

```sh
sudo pacman -Syu

sudo labctl status      # estado do lab
sudo labctl wake        # segura o wakelock (celular acordado)
sudo labctl standby     # libera o wakelock (pode dormir)
sudo labctl poweroff    # para o lab; so volta rodando start no Android
```

---

## Instalação não-interativa

Use `--yes` para não perguntar nada. Se nenhuma senha for passada, uma senha aleatória é gerada e salva em `/data/local/archlab/credentials` (modo 600).

```sh
su -c "sh archlab.sh install --yes \
  --user lab \
  --hostname archlab \
  --timezone America/Sao_Paulo \
  --locale pt_BR.UTF-8 \
  --profile dev \
  --packages 'nano htop ripgrep' \
  --ssh-port 2222 \
  --autostart \
  --wake"
```

Sem SSH (acesso só local):

```sh
su -c "sh archlab.sh install --yes --profile minimal --no-ssh"
```

Com chave pública:

```sh
su -c "sh archlab.sh install --yes --ssh-key /sdcard/Download/id_ed25519.pub --ssh-password no"
```

Com Tailscale e autostart:

```sh
su -c "sh archlab.sh install --yes \
  --tailscale --ts-authkey tskey-auth-xxxx \
  --autostart"
```

Simular sem alterar nada:

```sh
su -c "sh archlab.sh install --dry-run --profile server"
```

### Arquivo de config

O config gerado fica em `/data/local/archlab/config.env`. Use `config.example.env` como base:

```sh
adb push config.example.env /sdcard/Download/archlab.env
su -c "sh archlab.sh install --config /sdcard/Download/archlab.env --yes"
```

No Windows o wrapper já envia o arquivo e troca o caminho sozinho:

```bat
copy config.example.env meu.env
archlab.cmd install --yes --config .\meu.env
```

O mesmo vale para `--ssh-key` e `--rootfs` (tarball local): passe o caminho do PC e o `archlab.cmd` envia antes de rodar.

O arquivo é um shell script (`VAR=valor`). Senhas e `TS_AUTHKEY` não são gravados no `config.env` por padrão; use `--save-secrets` apenas se souber o risco.

Rodar `install` de novo com a mesma config continua a instalação. Se você mudar hostname, mirror, usuário, pacotes ou SSH e rodar de novo, as etapas correspondentes são reaplicadas; o rootfs e os dados não são apagados. `--force` apaga o rootfs e começa do zero.

**Precedência:** defaults < config (`config.env`/`--config`) < flags de linha de comando. O `ARCHLAB_BASE` do ambiente escolhe a pasta antes de carregar o config.

---

## Comandos

| Comando | Função |
|---|---|
| `install` | wizard de instalação |
| `install --yes ...` | instalação não-interativa |
| `doctor` | diagnóstico do device |
| `start` | monta o chroot e sobe SSH/Tailscale |
| `stop` | mata processos do chroot e desmonta |
| `restart` | `stop` + `start` |
| `status` | estado, IPs e comandos de acesso |
| `info` | device, kernel, rootfs e espaço |
| `shell [usuário]` | shell no chroot (padrão root) |
| `exec -- CMD` | executa um comando no chroot |
| `pacman -- ARGS` | roda `pacman` no chroot |
| `update` | `pacman -Syu` + limpeza opcional do cache |
| `tailscale on\|off\|login\|status` | controla o Tailscale |
| `autostart on\|off` | script em `/data/adb/service.d` |
| `wake` / `standby` | wakelock do Android |
| `mirror list\|test\|set` | gerencia o mirror |
| `config show\|path` | mostra a configuração |
| `backup [arquivo]` | para o lab e cria `.tar.gz` do rootfs; rode `start` depois |
| `uninstall` | remove o Arch (pede confirmação) |
| `ip` | mostra os comandos de SSH |
| `help` | ajuda |

Do PC, troque `sh archlab.sh` por `archlab.cmd` nos exemplos acima. O wrapper ainda adiciona `devices`, `logs [n]`, `forward [porta]` e `pull [arquivo] [local]` (baixa o backup para o PC).

Flags do `install` (resumo):

```text
--base DIR
--arch aarch64|armv7
--mirror URL
--rootfs ARQUIVO | --rootfs-url URL
--user NOME --password SENHA
--hostname NOME --timezone TZ --locale LOCALE
--profile minimal|dev|server|custom
--packages "pkg1 pkg2"
--ssh | --no-ssh
--ssh-port N --ssh-password yes|no --ssh-key ARQUIVO
--tailscale | --no-tailscale
--ts-hostname NOME --ts-ssh --ts-authkey KEY --ts-args "..."
--autostart | --no-autostart
--boot-delay SEGUNDOS
--wake | --no-wake
--bind-sdcard | --no-bind-sdcard
--extra-binds "origem:destino origem2:destino2"
--dns "1.1.1.1 8.8.8.8"
--selinux auto|1|0
--min-free MB
--sudo-nopasswd
--lock-root | --no-lock-root
--clean | --no-clean
--keep-tarball | --no-keep-tarball
--force
--save-secrets
--yes
--interactive | --no-interactive
--dry-run
--no-color
```

---

## Perfis e pacotes

| Perfil | Pacotes base |
|---|---|
| `minimal` | `sudo ca-certificates` + `openssh` se SSH estiver ligado |
| `dev` | `sudo ca-certificates base-devel git neovim tmux python nodejs` |
| `server` | `sudo ca-certificates rsync tmux htop` |
| `custom` | só o básico; você escolhe os grupos |

No wizard, o menu de pacotes permite marcar/desmarcar:

1. Ferramentas: `nano vim htop curl wget rsync`
2. Desenvolvimento: `base-devel git neovim tmux python nodejs`
3. Rede: `iproute2 inetutils bind`
4. Mídia: `ffmpeg imagemagick`
5. Desktop experimental: `xfce4 tigervnc dbus`
6. Pacotes avulsos por nome

> O grupo **Desktop** apenas instala os pacotes. Não há servidor VNC/X11 configurado nesta versão. Para usar GUI, configure TigerVNC/XFCE manualmente dentro do chroot.

`--packages` adiciona pacotes sem remover o que o perfil já inclui.

---

## Mirrors

O padrão é `http://mirror.archlinuxarm.org` (GeoIP), com fallbacks `fl.us` e `ca.us`. O instalador:

- baixa o tarball do primeiro mirror que responder (o GeoIP às vezes aponta para um espelho desatualizado e o `/os/...` volta 404 — o fallback resolve);
- verifica o `.md5` quando disponível;
- grava `/etc/pacman.d/mirrorlist` com o mirror principal + fallbacks.

Trocar depois:

```sh
su -c "sh archlab.sh mirror set http://fl.us.mirror.archlinuxarm.org"
su -c "sh archlab.sh mirror test"
```

Use a **raiz** do mirror, sem `/os` e sem `$arch/$repo`.

> O site `os.archlinuxarm.org` pode apresentar redirecionamento/certificado estranho em algumas redes. Por isso o padrão usa os mirrors HTTP diretos e verifica MD5. Se quiser HTTPS, use um mirror com certificado válido e teste com `mirror test`.

---

## SSH

- Porta padrão: `2222`.
- `PermitRootLogin no`; login só com o usuário criado.
- `sshd_config.d/10-archlab.conf` é gerado no rootfs.
- Chave pública:
  - `--ssh-key /caminho/id_ed25519.pub`, ou
  - coloque `id_ed25519.pub`/`id_rsa.pub`/`authorized_keys` em `/sdcard/Download`, que o instalador detecta.
- `--ssh-password no` exige uma chave válida.
- O root tem senha bloqueada por padrão (`LOCK_ROOT=1`); use `sudo`.
- Se o SSH não subir: `su -c "sh archlab.sh shell"` e veja `/var/log/sshd.log`.

---

## Tailscale

Modo **userspace networking**, sem precisar de `/dev/net/tun`:

```sh
su -c "sh archlab.sh install --yes --tailscale --ts-authkey tskey-auth-..."
# ou depois:
su -c "sh archlab.sh tailscale on"
su -c "sh archlab.sh tailscale login"
su -c "sh archlab.sh tailscale status"
```

Sem auth key, o `tailscale up` mostra uma URL para abrir no navegador. Em instalação não-interativa sem auth key, o login é adiado; rode `tailscale login` depois.

`--ts-ssh` habilita o Tailscale SSH (porta 22 do tailnet, independente da porta do sshd).

---

## Autostart e wakelock

```sh
su -c "sh archlab.sh autostart on"
su -c "sh archlab.sh autostart off"
su -c "sh archlab.sh wake"
su -c "sh archlab.sh standby"
```

Os mesmos controles estão no painel do PC (opção `13) energia/boot`) e dentro do Arch via `sudo labctl wake|standby|status`.

O autostart grava `/data/adb/service.d/99-archlab.sh`, espera `sys.boot_completed`, espera `BOOT_DELAY` segundos (padrão 30) e roda `start`. Log em `/data/local/archlab/boot.log`.

- Funciona em Magisk/KernelSU/APatch que executam `service.d`.
- Depois de reiniciar, o `/data` precisa estar descriptografado/desbloqueado; em alguns devices o `service.d` roda antes disso.
- Wakelock usa `/sys/power/wake_lock`; alguns kernels restringem. Se falhar, o SSH pode cair com a tela apagada.

---

## Como funciona

1. Baixa/extrai o rootfs ALARM em `$BASE/rootfs`.
2. Configura hostname, hosts, timezone, locale, DNS, mirrorlist e `pacman.conf`
   (`CheckSpace` desligado e `DisableSandbox` porque o kernel Android não tem Landlock).
3. Monta `proc`, `sys`, `dev`, `devpts`, `tmpfs` e binds.
4. Faz bind do rootfs nele mesmo e tenta `remount,bind,suid,dev` para `sudo`/`su`.
5. Roda `pacman-key`, `pacman -Syu`, instala os pacotes e gera locales.
6. Cria usuário, grupos Android, sudoers e senha.
7. Configura SSH, `labctl`, Tailscale e autostart.
8. Sobe o sshd e mostra os IPs.

O chroot **não usa systemd**. Não rode `systemctl` esperando que funcione. Os serviços são controlados pelo `archlab` (`sshd`, `tailscaled`) e por scripts próprios.

---

## Doctor e troubleshooting

```sh
su -c "sh archlab.sh doctor"
```

Ele testa root, arquitetura, ferramentas, `proc/sysfs/tmpfs/devpts`, `tmpfs`, bind+remount suid, chroot, namespace, SELinux, rede, mirror, página de 16 KB e espaço.

Problemas comuns:

| Sintoma | O que tentar |
|---|---|
| `mount: Permission denied` | `SELINUX_PERMISSIVE=1` ou `--selinux 1`; veja `doctor` |
| `chroot: not found` | instale busybox (Magisk/KernelSU) ou use um toybox com chroot |
| `sudo: effective uid is not 0` | remount suid falhou; `doctor` mostra; reinicie e tente de novo |
| `pacman: keyring` | rode de novo; o script tenta `pacman-key --refresh-keys` |
| `devpts` falhou | o script faz bind de `/dev/pts` do Android |
| sshd não sobe | `archlab shell`, veja `/var/log/sshd.log`, confira porta/chave |
| Tailscale não conecta | `archlab tailscale status`, veja `/var/log/tailscaled.log` |
| mounts somem após reboot | ative `autostart`; o Android não mantém mounts entre boots |
| página de 16 KB | alguns binários ARM podem falhar; reporte o device no issue |
| `systemd-sysusers: Protocol driver not attached` no `pacman` | kernels antigos (ex.: 5.4) não têm `openat2`, usado pelo systemd novo; o hook falha mas a instalação continua. Se um serviço reclamar de usuário inexistente, crie na mão (`useradd -r`) |

Logs:

```text
/data/local/archlab/archlab.log
/data/local/archlab/boot.log
/data/local/archlab/rootfs/var/log/sshd.log
/data/local/archlab/rootfs/var/log/tailscaled.log
```

---

## Limitações conhecidas

- Sem x86/x86_64.
- Sem systemd; serviços precisam ser gerenciados manualmente.
- Sem GUI/VNC/áudio configurados automaticamente.
- Sem GPU/aceleração gráfica.
- Sem suporte oficial a cartão SD/exFAT para o rootfs.
- `armv7` depende do kernel/device ainda suportar 32 bits e dos pacotes ALARM.
- Tailscale em userspace não cria interface `tailscale0` normal; é o modo suportado sem TUN.
- Android 15+ com páginas de 16 KB pode exigir testes.
- Em kernels sem `openat2` (anteriores ao 5.6, como o 5.4 do Galaxy S21), os hooks `systemd-sysusers`/`systemd-tmpfiles` do pacote `systemd` falham dentro do chroot. A instalação segue normal, mas usuários de sistema de pacotes novos podem precisar ser criados manualmente.
- Autostart depende do root manager executar `service.d` e do `/data` estar disponível no boot.
- O projeto não afiliação com Arch Linux, Arch Linux ARM, Android, Magisk, KernelSU ou APatch.

---

## Segurança

- O rootfs fica em `/data/local/archlab` com permissão restrita.
- Não exponha a porta SSH na internet sem firewall/chave.
- Prefira chave pública e `--ssh-password no`.
- `SELINUX_PERMISSIVE=1` reduz a segurança até o próximo reboot; use só quando necessário.
- `--password`/`TS_AUTHKEY` podem aparecer no histórico do shell ou em `ps`; prefira o wizard.
- O arquivo `credentials` (quando a senha é gerada) fica em modo 600.
- `--save-secrets` grava o `TS_AUTHKEY` no `config.env`; use com cuidado.
- O wrapper envia o script/config para `/data/local/tmp/archlab` (gravável pelo shell do `adb`); ao rodar como root, o `archlab.sh` se copia para `/data/local/archlab` com modo 700.

---

## Desenvolvimento

O projeto é um único `archlab.sh` em `sh` POSIX para manter a instalação simples (copiar um arquivo para o celular). A estrutura interna é separada por seções:

```text
config/detecção -> logs/lock/run -> mounts -> download/extração
-> config do rootfs -> pacotes -> usuários -> SSH/serviços
-> wizard/flags -> comandos -> doctor/main
```

O `archlab.ps1` é só o bootstrap do PC (não instala nada): acha o `adb`, escolhe o device, envia o `archlab.sh` e o `preflight.sh` para `/data/local/tmp/archlab/`, roda o preflight como root e executa o comando via `su -c 'sh /data/local/tmp/archlab/run.sh'`. Os argumentos são escapados em um `run.sh` no device (`'...'` com `'\''`), então não dependem do quoting do `adb shell`.

Detalhe de implementação: os comandos de apoio do adb recebem um stdin próprio (`'' | adb ...`), senão o `adb shell` do preflight consome a entrada destinada ao comando final — é isso que permite `Get-Content respostas.txt | .\archlab.cmd install --interactive`.

Para testar sintaxe:

```sh
bash -n archlab.sh
bash --posix -n archlab.sh
```

Para carregar funções sem executar o `main`:

```sh
ARCHLAB_LIB=1 . ./archlab.sh
```

Contribuições úteis:

- relatório do `doctor` em devices diferentes (modelo, Android, kernel, root manager);
- logs de falha de mount/devpts/suid;
- suporte a mais root managers;
- perfis e serviços opcionais;
- modularização em `lib/` com um `build.sh` gerando o arquivo único.

---

## Arquivos

- `archlab.sh` - instalador e CLI (arquivo único, roda no Android).
- `archlab.cmd` / `archlab.ps1` - wrapper de PC: encontra o device via `adb`, valida requisitos, envia o script e executa os comandos.
- `config.example.env` - modelo comentado para o modo não-interativo.
- `README.md` - esta documentação.
- `LICENSE` - MIT.

---

## Licença

MIT. Veja `LICENSE`.
