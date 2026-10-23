#!/system/bin/sh
# =============================================================================
#  archlab.sh - Arch Linux ARM em chroot no Android
#
#  Instalador no estilo do archinstall: wizard, perfis, selecao de pacotes,
#  mirrors, modo nao-interativo por flags/config e comandos de manutencao.
#
#  Requisitos: root (Magisk / KernelSU / APatch), aarch64 ou armv7,
#              ~4-6 GB livres em /data e internet (ou tarball local).
#
#  Uso rapido:
#    su -c "sh /data/local/tmp/archlab.sh install"
#    su -c "sh /data/local/tmp/archlab.sh install --yes --profile minimal"
#    su -c "sh /data/local/tmp/archlab.sh doctor"
#    sh archlab.sh help
#
#  Escrito em sh POSIX (mksh/toybox do Android). Sem bashismos.
# =============================================================================

VERSION="2.0.0-dev"
PROG="archlab"

# ------------------------------- CONFIGURACAO -------------------------------
BASE="${ARCHLAB_BASE:-${BASE:-/data/local/archlab}}"
CONFIG_FILE="${ARCHLAB_CONFIG:-}"

# Valores carregados de config.env / ambiente. Ambiente tem prioridade quando
# o config gerado usa a forma  : "${VAR:=valor}"
: "${ARCH:=auto}"
: "${MIRROR:=http://mirror.archlinuxarm.org}"
: "${MIRROR_FALLBACKS:=http://fl.us.mirror.archlinuxarm.org http://ca.us.mirror.archlinuxarm.org}"
: "${ROOTFS_URL:=}"
: "${ROOTFS_TARBALL:=}"

: "${LAB_USER:=lab}"
: "${LAB_HOST:=archlab}"
: "${LAB_TZ:=America/Sao_Paulo}"
: "${LAB_LANG:=en_US.UTF-8}"
: "${LAB_PASSWORD:=}"

: "${ENABLE_SSH:=1}"
: "${SSH_PORT:=2222}"
: "${SSH_PASSWORD_AUTH:=yes}"
: "${SSH_PUBKEY_FILE:=}"
: "${SSH_ALLOW_USERS:=}"

: "${PROFILE:=minimal}"
: "${PACKAGES:=}"

: "${ENABLE_TAILSCALE:=0}"
: "${TS_HOSTNAME:=}"
: "${TS_SSH:=0}"
: "${TS_AUTHKEY:=}"
: "${TS_ARGS:=}"

: "${AUTOSTART:=0}"
: "${BOOT_DELAY:=30}"
: "${WAKELOCK:=0}"
: "${BIND_SDCARD:=0}"
: "${EXTRA_BINDS:=}"
: "${DNS_SERVERS:=}"
: "${SELINUX_PERMISSIVE:=auto}"

: "${MIN_FREE_MB:=4096}"
: "${RECOMMENDED_FREE_MB:=6144}"
: "${FORCE:=0}"
: "${SUDO_NOPASSWD:=0}"
: "${LOCK_ROOT:=1}"
: "${CLEAN_CACHE:=1}"
: "${KEEP_TARBALL:=1}"
: "${SAVE_TS_AUTHKEY:=0}"
: "${ASSUME_YES:=0}"
: "${DRY_RUN:=0}"
: "${INTERACTIVE:=auto}"
: "${NO_COLOR:=0}"
: "${LOG_MAX_KB:=5120}"

# Derivados (recalculados por set_paths / finalize_config)
ROOT=""
DL=""
STATE=""
LOG=""
LOCKDIR=""
SELF=""
CRED=""
ROOTFS_FILE=""
KERNEL_PKGS=""
ALL_PKGS=""
PROFILE_PKGS=""
RESOLVED_KEY=""
DEV_MODEL=""
DEV_NAME=""
DEV_ANDROID=""
DEV_SDK=""
DEV_ABI=""
ROOT_MANAGER=""

CMD=""
LOCKED=0
PRE_MOUNTED=1
ST_ECHO=0
BB=""
CHROOT="chroot"
NSENTER=""
TAR="tar"
GZIP=""
MD5=""
CURL=""
WGET=""
TEE="tee"
GETPROP=""
IPCMD=""
NEW_MOUNTS=0

# ------------------------------- CORES / LOG --------------------------------
set_colors() {
  if [ -t 1 ] && [ "$NO_COLOR" != 1 ]; then
    C_R='\033[1;31m'; C_G='\033[1;32m'; C_Y='\033[1;33m'
    C_B='\033[1;34m'; C_C='\033[1;36m'; C_N='\033[0m'
  else
    C_R=''; C_G=''; C_Y=''; C_B=''; C_C=''; C_N=''
  fi
}
set_colors

log() {
  [ -n "$BASE" ] && [ -d "$BASE" ] || return 0
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S' 2>/dev/null)" "$*" >>"$LOG" 2>/dev/null
}
info() { printf '%b[*]%b %s\n' "$C_B" "$C_N" "$*"; log "INFO  $*"; }
ok()   { printf '%b[+]%b %s\n' "$C_G" "$C_N" "$*"; log "OK    $*"; }
warn() { printf '%b[!]%b %s\n' "$C_Y" "$C_N" "$*" >&2; log "WARN  $*"; }
err()  { printf '%b[x]%b %s\n' "$C_R" "$C_N" "$*" >&2; log "ERRO  $*"; }
die()  { err "$*"; exit 1; }

hr() { printf '%s\n' "------------------------------------------------------------"; }

log_init() {
  mkdir -p "$BASE" 2>/dev/null || return 0
  if [ -f "$LOG" ] && [ "$LOG_MAX_KB" -gt 0 ] 2>/dev/null; then
    _sz=$(wc -c <"$LOG" 2>/dev/null | tr -d ' ')
    case "$_sz" in ''|*[!0-9]*) _sz=0;; esac
    if [ "$_sz" -gt $((LOG_MAX_KB * 1024)) ]; then
      mv -f "$LOG" "$LOG.1" 2>/dev/null
    fi
  fi
  : >>"$LOG" 2>/dev/null
}

# ------------------------------- LOCK / CLEANUP -----------------------------
cleanup() {
  _rc=$?
  trap - EXIT INT TERM
  [ "$ST_ECHO" = 1 ] && stty echo 2>/dev/null
  if [ "$_rc" -ne 0 ]; then
    case "$CMD" in
      install|start|shell|exec|pacman|update|backup)
        if [ "$LOCKED" = 1 ] && [ "$PRE_MOUNTED" = 0 ]; then
          warn "Falhou (codigo $_rc). Desmontando para deixar o sistema limpo..."
          kill_procs TERM >/dev/null 2>&1; sleep 1
          kill_procs KILL >/dev/null 2>&1
          umount_all quiet
          wl_off
        fi ;;
    esac
    [ -f "$LOG" ] && warn "Log completo: $LOG"
  fi
  release_lock
  exit "$_rc"
}

acquire_lock() {
  if mkdir "$LOCKDIR" 2>/dev/null; then
    echo $$ >"$LOCKDIR/pid"; LOCKED=1; return 0
  fi
  _old=$(cat "$LOCKDIR/pid" 2>/dev/null)
  if [ -n "$_old" ] && kill -0 "$_old" 2>/dev/null; then
    die "Outra instancia do $PROG esta rodando (PID $_old)."
  fi
  warn "Lock orfao encontrado; removendo."
  rm -rf "$LOCKDIR"
  mkdir "$LOCKDIR" 2>/dev/null || die "Nao consegui criar o lock em $LOCKDIR"
  echo $$ >"$LOCKDIR/pid"; LOCKED=1
}

release_lock() {
  [ "$LOCKED" = 1 ] && rm -rf "$LOCKDIR" 2>/dev/null
  LOCKED=0
}

# ------------------------------- EXECUCAO -----------------------------------
run_rc() {
  _d="$1"; shift
  log "RUN: $_d :: $*"
  "$@" >>"$LOG" 2>&1
  _rc=$?
  [ "$_rc" -eq 0 ] && return 0
  err "Falhou: $_d (codigo $_rc)"
  err "Ultimas linhas do log:"
  tail -n 15 "$LOG" 2>/dev/null | sed 's/^/    /' >&2
  return "$_rc"
}
run() { run_rc "$@" || exit $?; }

run_live_rc() {
  _d="$1"; shift
  log "RUN(live): $_d :: $*"
  _rcf="$BASE/.rc.$$"
  if [ -n "$TEE" ]; then
    { "$@" 2>&1; echo $? >"$_rcf"; } </dev/null | tee -a "$LOG"
  else
    "$@" >>"$LOG" 2>&1; echo $? >"$_rcf"
  fi
  _rc=$(cat "$_rcf" 2>/dev/null); rm -f "$_rcf"
  case "$_rc" in ''|*[!0-9]*) _rc=1;; esac
  if [ "$_rc" -ne 0 ]; then
    err "Falhou: $_d (codigo $_rc)"
    err "Ultimas linhas do log:"
    tail -n 20 "$LOG" 2>/dev/null | sed 's/^/    /' >&2
    return "$_rc"
  fi
  return 0
}
run_live() { run_live_rc "$@" || exit $?; }

try() {
  _d="$1"; shift
  log "TRY: $_d :: $*"
  "$@" >>"$LOG" 2>&1 && return 0
  warn "Nao critico falhou: $_d"
  return 1
}

# ------------------------------- DETECCAO -----------------------------------
need_root() {
  [ "$(id -u 2>/dev/null)" = 0 ] && return 0
  err "Precisa de root."
  printf '  Magisk/KernelSU/APatch:  su -c "sh %s %s"\n' "$0" "${CMD:-help}" >&2
  printf '  Termux:                  su -c "sh %s install"\n' "$0" >&2
  exit 1
}

detect_tools() {
  BB=""
  for _b in \
    /data/adb/ksu/bin/busybox \
    /data/adb/ap/bin/busybox \
    /data/adb/magisk/busybox \
    /data/adb/modules/busybox-ndk/system/bin/busybox \
    /system/xbin/busybox /system/bin/busybox
  do
    if [ -x "$_b" ]; then BB="$_b"; break; fi
  done

  if command -v chroot >/dev/null 2>&1; then
    CHROOT="chroot"
  elif [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx chroot; then
    CHROOT="$BB chroot"
  else
    CHROOT=""
  fi

  command -v tar >/dev/null 2>&1 && TAR="tar" || TAR=""
  command -v gzip >/dev/null 2>&1 && GZIP="gzip" || GZIP=""
  command -v tee >/dev/null 2>&1 && TEE="tee" || TEE=""
  command -v curl >/dev/null 2>&1 && CURL="curl" || CURL=""
  [ -z "$CURL" ] && { command -v wget >/dev/null 2>&1 && WGET="wget" || WGET=""; }
  command -v getprop >/dev/null 2>&1 && GETPROP="getprop" || GETPROP=""
  command -v ip >/dev/null 2>&1 && IPCMD="ip" || IPCMD=""

  MD5=""
  if command -v md5sum >/dev/null 2>&1; then
    MD5="md5sum"
  elif [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx md5sum; then
    MD5="$BB md5sum"
  fi

  NSENTER=""
  if command -v nsenter >/dev/null 2>&1; then
    NSENTER="nsenter"
  elif [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx nsenter; then
    NSENTER="$BB nsenter"
  fi
}

have_download() {
  [ -n "$CURL" ] && return 0
  [ -n "$WGET" ] && return 0
  [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx wget
}

detect_device() {
  DEV_MODEL=""; DEV_NAME=""; DEV_ANDROID=""; DEV_SDK=""; DEV_ABI=""
  if [ -n "$GETPROP" ]; then
    DEV_MODEL=$($GETPROP ro.product.model 2>/dev/null)
    DEV_NAME=$($GETPROP ro.product.device 2>/dev/null)
    DEV_ANDROID=$($GETPROP ro.build.version.release 2>/dev/null)
    DEV_SDK=$($GETPROP ro.build.version.sdk 2>/dev/null)
    DEV_ABI=$($GETPROP ro.product.cpu.abilist 2>/dev/null)
  fi
  [ -n "$DEV_MODEL" ] || DEV_MODEL="desconhecido"
  [ -n "$DEV_NAME" ] || DEV_NAME="desconhecido"
  [ -n "$DEV_ANDROID" ] || DEV_ANDROID="desconhecido"

  ROOT_MANAGER="desconhecido"
  if [ -d /data/adb/ksu ] || [ -d /data/adb/ksunext ]; then
    ROOT_MANAGER="KernelSU"
  elif [ -d /data/adb/ap ] || [ -d /data/adb/apatch ]; then
    ROOT_MANAGER="APatch"
  elif [ -d /data/adb/magisk ]; then
    ROOT_MANAGER="Magisk"
  elif command -v su >/dev/null 2>&1; then
    case "$(su -v 2>/dev/null)" in
      *KernelSU*) ROOT_MANAGER="KernelSU";;
      *APatch*)   ROOT_MANAGER="APatch";;
      *MAGISK*|*Magisk*) ROOT_MANAGER="Magisk";;
    esac
  fi
}

detect_arch() {
  case "$ARCH" in
    auto|'')
      ARCH=$(uname -m 2>/dev/null)
      ;;
  esac
  case "$ARCH" in
    aarch64|arm64|arm64-v8a) ARCH="aarch64" ;;
    armv8l|armv7l|armv7|armv7a|arm)
      case "$DEV_ABI" in
        *arm64-v8a*) ARCH="aarch64" ;;
        *) ARCH="armv7" ;;
      esac ;;
    x86_64|i686|i386|x86)
      die "Arquitetura '$ARCH' nao suportada. Este projeto usa Arch Linux ARM (aarch64/armv7)." ;;
    *)
      die "Arquitetura desconhecida: '$ARCH'. Suportadas: aarch64, armv7." ;;
  esac

  case "$ARCH" in
    aarch64)
      ROOTFS_FILE="ArchLinuxARM-aarch64-latest.tar.gz"
      KERNEL_PKGS="linux-aarch64 linux-firmware" ;;
    armv7)
      ROOTFS_FILE="ArchLinuxARM-armv7-latest.tar.gz"
      KERNEL_PKGS="linux-armv7 linux-firmware" ;;
  esac
}

detect_root_manager() {
  [ -n "$ROOT_MANAGER" ] || detect_device
}

check_kernel_fs() {
  [ -r /proc/filesystems ] || return 0
  for _fs in proc sysfs; do
    grep -qw "$_fs" /proc/filesystems 2>/dev/null \
      || warn "Kernel sem suporte a '$_fs' em /proc/filesystems."
  done
  grep -qw devpts /proc/filesystems 2>/dev/null \
    || warn "Kernel sem devpts; sera usado fallback (bind /dev/pts)."
  grep -qw tmpfs /proc/filesystems 2>/dev/null \
    || warn "Kernel sem tmpfs; /run e /tmp serao diretorios normais."
}

handle_selinux() {
  command -v getenforce >/dev/null 2>&1 || return 0
  _mode=$(getenforce 2>/dev/null)
  [ "$_mode" = "Enforcing" ] || return 0

  case "$SELINUX_PERMISSIVE" in
    1|yes|on)
      if setenforce 0 2>>"$LOG"; then
        warn "SELinux -> Permissive (volta ao normal no reboot)."
      else
        warn "setenforce 0 falhou; siga e veja o log se houver erro de permissao."
      fi ;;
    auto)
      info "SELinux Enforcing. Se um mount falhar, tente: SELINUX_PERMISSIVE=1" ;;
    *)
      info "SELinux Enforcing. Se algo falhar por permissao: SELINUX_PERMISSIVE=1" ;;
  esac
}

validate_base_path() {
  case "$BASE" in
    /data/*) ;;
    *) die "BASE precisa ficar em /data (ex.: /data/local/archlab). Recebido: $BASE" ;;
  esac
  case "$BASE" in
    /data|/data/|/data/local|/data/local/|/data/media|/data/media/*|/data/adb|/data/adb/|/sdcard*|/storage*)
      die "Caminho inseguro para BASE: $BASE" ;;
  esac
  case "$BASE" in
    */../*|*/..|*/./*|*/.|*//*) die "BASE nao pode conter componentes . ou ..: $BASE" ;;
  esac
  case "$BASE" in
    *' '*) die "BASE nao pode conter espacos: '$BASE'" ;;
  esac
  case "$BASE" in
    *[!A-Za-z0-9._/-]*) die "BASE so pode usar letras, numeros, . _ / -: '$BASE'" ;;
  esac
}

check_space() {
  mkdir -p "$BASE" 2>/dev/null
  _free=$(df -k "$BASE" 2>/dev/null | tail -n 1 | sed 's/  */ /g' | cut -d' ' -f4)
  case "$_free" in ''|*[!0-9]*)
    warn "Nao consegui medir o espaco livre em $BASE; seguindo."
    return 0 ;;
  esac
  _mb=$((_free / 1024))
  if [ "$_mb" -lt "$MIN_FREE_MB" ]; then
    if [ "$FORCE" = 1 ]; then
      warn "Espaco abaixo do minimo ($_mb MB < $MIN_FREE_MB MB), mas FORCE=1."
    else
      die "Espaco insuficiente em $BASE: $_mb MB livres; minimo $MIN_FREE_MB MB (recomendado $RECOMMENDED_FREE_MB MB). Use FORCE=1 para ignorar."
    fi
  elif [ "$_mb" -lt "$RECOMMENDED_FREE_MB" ]; then
    warn "Espaco livre: $_mb MB. Recomendado: $RECOMMENDED_FREE_MB MB (tarball + rootfs + pacman)."
  else
    info "Espaco livre: $_mb MB."
  fi
}

check_net() {
  command -v ping >/dev/null 2>&1 || return 0
  ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 \
    || warn "Sem resposta de ping (1.1.1.1). Download/pacman podem falhar."
}

preflight() {
  need_root
  detect_tools
  detect_device
  detect_arch
  validate_base_path
  check_kernel_fs

  for _t in mount umount grep sed cut sort head tail tr df readlink kill; do
    command -v "$_t" >/dev/null 2>&1 || die "Ferramenta ausente no Android: $_t"
  done
  [ -n "$CHROOT" ] || die "Nao encontrei chroot (nem busybox com applet chroot)."

  mkdir -p "$BASE" "$DL" "$STATE" 2>/dev/null || die "Nao consegui criar $BASE"
  chmod 700 "$BASE" 2>/dev/null
  is_mounted /data || warn "/data nao parece montado; o rootfs nao vai persistir."

  case "$BASE" in
    /data/media/*|/sdcard*|/storage*)
      die "Nao instale em armazenamento FUSE (/sdcard). Use /data/local/..." ;;
  esac
}

# ------------------------------- MOUNTS -------------------------------------
is_mounted() {
  while read -r _dev _mp _rest; do
    [ "$_mp" = "$1" ] && return 0
  done </proc/mounts
  return 1
}

mounts_under_root() {
  while read -r _dev _mp _rest; do
    case "$_mp" in
      "$ROOT"|"$ROOT"/*) printf '%s\n' "$_mp" ;;
    esac
  done </proc/mounts | sort -r
}

# mnt <destino> <args do mount...>
mnt() {
  _tgt="$1"; shift
  is_mounted "$_tgt" && return 0
  mkdir -p "$_tgt" 2>>"$LOG"
  if mount "$@" "$_tgt" >>"$LOG" 2>&1; then
    NEW_MOUNTS=1
    return 0
  fi
  # fallback unico para SELinux Enforcing
  if [ "$SELINUX_PERMISSIVE" = auto ] && command -v setenforce >/dev/null 2>&1 \
     && [ "$(getenforce 2>/dev/null)" = Enforcing ]; then
    if setenforce 0 2>>"$LOG"; then
      warn "Mount falhou; SELinux -> Permissive e tentando de novo."
      if mount "$@" "$_tgt" >>"$LOG" 2>&1; then NEW_MOUNTS=1; return 0; fi
    fi
  fi
  die "Falha ao montar $_tgt (mount $*). Veja $LOG"
}

do_mounts() {
  [ -x "$ROOT/usr/bin/pacman" ] || die "Rootfs nao encontrado em $ROOT. Rode: sh $0 install"

  if is_mounted "$ROOT/proc"; then
    PRE_MOUNTED=1
  else
    PRE_MOUNTED=0
  fi

  # bind do rootfs nele mesmo: suid/dev para sudo, su e CheckSpace
  if ! is_mounted "$ROOT"; then
    mount -o bind "$ROOT" "$ROOT" >>"$LOG" 2>&1 || die "Falha no bind do rootfs ($ROOT)."
    NEW_MOUNTS=1
  fi
  mount -o remount,bind,suid,dev "$ROOT" >>"$LOG" 2>&1 \
    || warn "Nao consegui habilitar suid/dev no rootfs (sudo/su podem falhar)."

  mnt "$ROOT/proc" -t proc proc
  mnt "$ROOT/sys" -t sysfs sysfs
  mnt "$ROOT/dev" -o bind /dev

  if ! is_mounted "$ROOT/dev/pts"; then
    mkdir -p "$ROOT/dev/pts" 2>>"$LOG"
    if ! mount -t devpts -o rw,nosuid,noexec,gid=5,mode=620,ptmxmode=666 devpts "$ROOT/dev/pts" >>"$LOG" 2>&1; then
      if ! mount -t devpts devpts "$ROOT/dev/pts" >>"$LOG" 2>&1; then
        if mount -o bind /dev/pts "$ROOT/dev/pts" >>"$LOG" 2>&1; then
          warn "devpts novo falhou; usando bind de /dev/pts do Android."
        else
          die "Falha ao montar devpts em $ROOT/dev/pts"
        fi
      fi
    fi
    NEW_MOUNTS=1
  fi

  # Nao remontar por cima: um tmpfs novo esconderia o estado atual
  # (ex.: /run/sshd.pid), deixando o sshd antigo orfao e vivo.
  if ! is_mounted "$ROOT/dev/shm"; then
    if ! mount -t tmpfs -o mode=1777,nosuid,nodev tmpfs "$ROOT/dev/shm" >>"$LOG" 2>&1; then
      mkdir -p "$ROOT/dev/shm" 2>>"$LOG"; chmod 1777 "$ROOT/dev/shm" 2>/dev/null
    else
      NEW_MOUNTS=1
    fi
  fi
  if ! is_mounted "$ROOT/tmp"; then
    if ! mount -t tmpfs -o mode=1777 tmpfs "$ROOT/tmp" >>"$LOG" 2>&1; then
      mkdir -p "$ROOT/tmp"; chmod 1777 "$ROOT/tmp" 2>/dev/null
    else
      NEW_MOUNTS=1
    fi
  fi
  if ! is_mounted "$ROOT/run"; then
    if ! mount -t tmpfs -o mode=755 tmpfs "$ROOT/run" >>"$LOG" 2>&1; then
      mkdir -p "$ROOT/run"
    else
      NEW_MOUNTS=1
    fi
  fi

  if [ "$BIND_SDCARD" = 1 ]; then
    if [ -d /data/media/0 ]; then
      mnt "$ROOT/mnt/sdcard" -o bind /data/media/0
    else
      warn "BIND_SDCARD=1 mas /data/media/0 nao existe."
    fi
  fi

  if [ -n "$EXTRA_BINDS" ]; then
    for _b in $EXTRA_BINDS; do
      _src=${_b%%:*}
      _dst=${_b#*:}
      if [ -z "$_src" ] || [ -z "$_dst" ] || [ "$_src" = "$_b" ]; then
        warn "Bind invalido (use origem:destino): $_b"; continue
      fi
      if [ ! -e "$_src" ]; then warn "Bind ignorado (origem nao existe): $_src"; continue; fi
      case "$_dst" in
        /*) mnt "$ROOT$_dst" -o bind "$_src" ;;
        *) warn "Bind ignorado (destino precisa ser absoluto): $_dst" ;;
      esac
    done
  fi

  mkdir -p "$ROOT/run/faillock" "$ROOT/run/lock" "$ROOT/run/sshd" 2>>"$LOG"
  chmod 755 "$ROOT/run/faillock" "$ROOT/run/lock" "$ROOT/run/sshd" 2>>"$LOG"

  if grep " $ROOT " /proc/mounts 2>/dev/null | grep -q nosuid; then
    warn "O rootfs continua 'nosuid': sudo/su dentro do chroot podem falhar."
  fi
}

umount_all() {
  _quiet="$1"; _pass=0
  while [ "$_pass" -lt 4 ]; do
    _list=$(mounts_under_root)
    [ -z "$_list" ] && return 0
    for _m in $_list; do
      umount "$_m" >>"$LOG" 2>&1 || umount -l "$_m" >>"$LOG" 2>&1
    done
    _pass=$((_pass + 1)); sleep 1
  done
  _list=$(mounts_under_root)
  [ -z "$_list" ] && return 0
  [ "$_quiet" = quiet ] || err "Ainda ha mounts ativos: $_list"
  return 1
}

kill_procs() {
  _sig="$1"; _found=1
  for _d in /proc/[0-9]*; do
    _p="${_d#/proc/}"
    [ "$_p" = "$$" ] && continue
    _r=$(readlink "$_d/root" 2>/dev/null)
    if [ "$_r" = "$ROOT" ]; then
      kill "-$_sig" "$_p" 2>/dev/null; _found=0
    fi
  done
  return $_found
}

safe_wipe_root() {
  [ -n "$ROOT" ] && [ "$ROOT" != "/" ] || die "ROOT invalido."
  case "$ROOT" in
    /data/*) ;;
    *) die "Caminho inseguro para apagar: $ROOT" ;;
  esac
  if [ -n "$(mounts_under_root)" ]; then
    die "Ha mounts ativos em $ROOT; rode 'stop' antes (recusando apagar por seguranca)."
  fi
  [ -e "$ROOT" ] && rm -rf "$ROOT"
  return 0
}

# ------------------------------- DOWNLOAD / EXTRACAO ------------------------
download() {
  _url="$1"
  _out="$2"
  log "DOWNLOAD: $_url -> $_out"

  if [ -n "$CURL" ]; then
    if [ -t 2 ]; then
      $CURL -fL --progress-bar --retry 3 --retry-delay 5 --connect-timeout 20 \
        -C - -o "$_out" "$_url"
    else
      $CURL -fsSL --retry 3 --retry-delay 5 --connect-timeout 20 \
        -C - -o "$_out" "$_url"
    fi
    _rc=$?
    # 416 = arquivo parcial ja completo; tenta do zero uma vez
    if [ "$_rc" -ne 0 ] && [ -s "$_out" ]; then
      rm -f "$_out"
      if [ -t 2 ]; then
        $CURL -fL --progress-bar --retry 2 --connect-timeout 20 -o "$_out" "$_url"
      else
        $CURL -fsSL --retry 2 --connect-timeout 20 -o "$_out" "$_url"
      fi
      _rc=$?
    fi
    return $_rc
  fi

  if [ -n "$WGET" ]; then
    $WGET -T 30 -t 3 -c -O "$_out" "$_url"
    return $?
  fi

  if [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx wget; then
    "$BB" wget -T 30 -c -O "$_out" "$_url"
    return $?
  fi
  return 127
}

download_md5() {
  _file="$1"
  _dest="$2"
  rm -f "$_dest"
  for _m in $MIRROR $MIRROR_FALLBACKS; do
    if download "$(mirror_dir_url "$_m")/$_file.md5" "$_dest" >>"$LOG" 2>&1; then
      [ -s "$_dest" ] && return 0
    fi
  done
  return 1
}

mirror_dir_url() {
  case "$1" in
    */os|*/os/) printf '%s' "${1%/}" ;;
    *) printf '%s/os' "${1%/}" ;;
  esac
}

mirror_os_url() {
  printf '%s/%s\n' "$(mirror_dir_url "$1")" "$ROOTFS_FILE"
}

find_in_dl() {
  for _d in /sdcard/Download /storage/emulated/0/Download /data/media/0/Download /data/local/tmp "$BASE"; do
    if [ -f "$_d/$1" ]; then printf '%s\n' "$_d/$1"; return 0; fi
  done
  return 1
}

# url_exists URL: testa o arquivo em si (HEAD/spider, sem baixar).
# Nao basta checar o .md5: um mirror pode ter o .md5 e nao ter o tarball.
url_exists() {
  _ux="$1"
  if [ -n "$CURL" ]; then
    $CURL -fsIL --max-time 15 "$_ux" >/dev/null 2>&1 && return 0
    return 1
  fi
  if [ -n "$WGET" ]; then
    $WGET -q --spider -T 15 "$_ux" >/dev/null 2>&1 && return 0
    return 1
  fi
  if [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx wget; then
    "$BB" wget -q --spider -T 15 "$_ux" >/dev/null 2>&1 && return 0
    return 1
  fi
  return 2
}

get_tarball() {
  TARBALL=""

  if [ -n "$ROOTFS_TARBALL" ]; then
    [ -f "$ROOTFS_TARBALL" ] || die "ROOTFS_TARBALL nao existe: $ROOTFS_TARBALL"
    TARBALL="$ROOTFS_TARBALL"
    info "Usando tarball local: $TARBALL"
    return 0
  fi

  if [ -n "$ROOTFS_URL" ]; then
    _part="$DL/$ROOTFS_FILE.part"
    info "Baixando rootfs personalizado: $ROOTFS_URL"
    if download "$ROOTFS_URL" "$_part"; then
      mv -f "$_part" "$DL/$ROOTFS_FILE" && { TARBALL="$DL/$ROOTFS_FILE"; return 0; }
    fi
    rm -f "$_part"
    die "Falha ao baixar ROOTFS_URL: $ROOTFS_URL"
  fi

  if [ -f "$DL/$ROOTFS_FILE" ]; then
    TARBALL="$DL/$ROOTFS_FILE"
    info "Usando tarball em cache: $TARBALL"
    return 0
  fi
  _f=$(find_in_dl "$ROOTFS_FILE") && { TARBALL="$_f"; info "Usando tarball encontrado: $TARBALL"; return 0; }

  _part="$DL/$ROOTFS_FILE.part"
  for _m in $MIRROR $MIRROR_FALLBACKS; do
    _u=$(mirror_os_url "$_m")
    info "Baixando $_u"
    if download "$_u" "$_part"; then
      mv -f "$_part" "$DL/$ROOTFS_FILE" && { TARBALL="$DL/$ROOTFS_FILE"; return 0; }
    fi
    warn "Download falhou: $_m"
  done
  rm -f "$_part"
  err "Nao consegui baixar o rootfs (sem curl/wget ou sem internet)."
  err "Alternativa: baixe no PC e envie para /sdcard/Download/$ROOTFS_FILE"
  err "  adb push $ROOTFS_FILE /sdcard/Download/"
  exit 1
}

verify_md5() {
  _f="$1"
  [ -n "$MD5" ] || { warn "md5sum indisponivel; pulando verificacao."; return 0; }

  _mf=""
  if [ -n "$ROOTFS_URL" ]; then
    # Tarball personalizado: o .md5 do mirror nao vale para ele.
    if download "$ROOTFS_URL.md5" "$DL/$ROOTFS_FILE.md5" >>"$LOG" 2>&1 \
       && [ -s "$DL/$ROOTFS_FILE.md5" ]; then
      _mf="$DL/$ROOTFS_FILE.md5"
    else
      rm -f "$DL/$ROOTFS_FILE.md5"
      warn "Sem MD5 para ROOTFS_URL; pulando verificacao."
      return 0
    fi
  else
    case "$_f" in
      "$DL"/*)
        if download_md5 "$ROOTFS_FILE" "$DL/$ROOTFS_FILE.md5"; then
          _mf="$DL/$ROOTFS_FILE.md5"
        fi ;;
      *)
        if [ -f "$_f.md5" ]; then
          _mf="$_f.md5"
        fi ;;
    esac
  fi
  [ -n "$_mf" ] && [ -s "$_mf" ] || { warn "MD5 nao disponivel; pulando verificacao."; return 0; }

  _exp=$(cut -d' ' -f1 "$_mf" | head -n 1)
  _act=$($MD5 "$_f" | cut -d' ' -f1)
  log "md5 esperado=$_exp obtido=$_act"
  [ -n "$_exp" ] && [ "$_exp" = "$_act" ] && return 0

  warn "MD5 nao confere."
  case "$_f" in
    "$DL"/*) rm -f "$_f" ;;
  esac
  die "Tarball corrompido. Rode o install de novo."
}

extract_try() {
  _tb="$1"; _mode="$2"
  safe_wipe_root
  mkdir -p "$ROOT" || die "Nao consegui criar $ROOT"

  case "$_mode" in
    toybox)
      [ -n "$TAR" ] && $TAR -xzpf "$_tb" -C "$ROOT" --numeric-owner ;;
    toybox_n)
      [ -n "$TAR" ] && $TAR -xzpf "$_tb" -C "$ROOT" ;;
    busybox)
      [ -n "$BB" ] && "$BB" tar -xzpf "$_tb" -C "$ROOT" --numeric-owner ;;
    busybox_n)
      [ -n "$BB" ] && "$BB" tar -xzpf "$_tb" -C "$ROOT" ;;
    gzip_tar)
      [ -n "$GZIP" ] && $GZIP -dc "$_tb" | $TAR -xpf - -C "$ROOT" --numeric-owner ;;
    gzip_tar_n)
      [ -n "$GZIP" ] && $GZIP -dc "$_tb" | $TAR -xpf - -C "$ROOT" ;;
    gzip_bb)
      [ -n "$GZIP" ] && [ -n "$BB" ] && $GZIP -dc "$_tb" | "$BB" tar -xpf - -C "$ROOT" --numeric-owner ;;
    gzip_bb_n)
      [ -n "$GZIP" ] && [ -n "$BB" ] && $GZIP -dc "$_tb" | "$BB" tar -xpf - -C "$ROOT" ;;
    bbgzip_bb)
      [ -n "$BB" ] && "$BB" gzip -dc "$_tb" | "$BB" tar -xpf - -C "$ROOT" --numeric-owner ;;
    bbgzip_bb_n)
      [ -n "$BB" ] && "$BB" gzip -dc "$_tb" | "$BB" tar -xpf - -C "$ROOT" ;;
    plain)
      [ -n "$TAR" ] && $TAR -xpf "$_tb" -C "$ROOT" ;;
    *)
      return 1 ;;
  esac >>"$LOG" 2>&1

  [ -x "$ROOT/usr/bin/pacman" ] && [ -f "$ROOT/etc/os-release" ] || return 1

  _u=$(stat -c '%u' "$ROOT/usr/bin/pacman" 2>/dev/null)
  case "$_u" in
    ''|0) ;;
    *)
      warn "Rootfs extraido com owner $_u; corrigindo para root:root."
      chown -R 0:0 "$ROOT" >>"$LOG" 2>&1 || warn "chown -R falhou."
      ;;
  esac
  return 0
}

extract_rootfs() {
  _tb="$1"
  for _m in toybox toybox_n busybox busybox_n gzip_tar gzip_tar_n gzip_bb gzip_bb_n bbgzip_bb bbgzip_bb_n plain; do
    info "Extraindo rootfs (metodo: $_m)..."
    if extract_try "$_tb" "$_m"; then
      ok "Rootfs extraido."
      return 0
    fi
    warn "Metodo $_m falhou; tentando o proximo."
  done
  safe_wipe_root
  die "Todos os metodos de extracao falharam. Veja $LOG (tar do Android sem gzip?)."
}

# ------------------------------- PATHS / CONFIG -----------------------------
set_paths() {
  ROOT="$BASE/rootfs"
  DL="$BASE/dl"
  STATE="$BASE/state"
  LOG="$BASE/archlab.log"
  LOCKDIR="$BASE/.lock"
  SELF="$BASE/archlab.sh"
  CRED="$BASE/credentials"
}

shquote() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

setvar() { eval "$1=$(shquote "$2")"; }

# Le uma linha do stdin removendo CR: arquivos de resposta/config criados no
# Windows vem com CRLF e o CR acaba virando parte do valor.
rd() {
  IFS= read -r "$1" || eval "$1="
  eval "_rd_v=\$$1"
  setvar "$1" "$(printf '%s' "$_rd_v" | tr -d '\r')"
}

normalize_bool() {
  case "$1" in
    1|yes|YES|true|TRUE|on|ON|s|S|sim|SIM|y|Y) printf '1\n' ;;
    0|no|NO|false|FALSE|off|OFF|n|N|nao|NAO|'') printf '0\n' ;;
    *) printf '%s\n' "$1" ;;
  esac
}

source_config() {
  _sc_f="$1"
  [ -f "$_sc_f" ] || return 0
  if mkdir -p "$BASE" 2>/dev/null && tr -d '\r' <"$_sc_f" >"$BASE/.config.load.$$" 2>/dev/null; then
    . "$BASE/.config.load.$$"
    rm -f "$BASE/.config.load.$$"
  else
    . "$_sc_f"
  fi
}

load_config() {
  source_config "$BASE/config.env"
  if [ -n "$CONFIG_FILE" ] && [ "$CONFIG_FILE" != "$BASE/config.env" ]; then
    source_config "$CONFIG_FILE"
  fi
}

save_config() {
  [ -d "$BASE" ] || return 0
  _tmp="$BASE/.config.env.$$"
  {
    printf '# archlab config - gerado em %s\n' "$(date '+%Y-%m-%d %H:%M:%S')"
    printf '# Formato: VAR=valor. Segredos nao sao salvos por padrao.\n\n'
    for _v in \
      ARCH MIRROR MIRROR_FALLBACKS ROOTFS_URL ROOTFS_TARBALL \
      LAB_USER LAB_HOST LAB_TZ LAB_LANG \
      ENABLE_SSH SSH_PORT SSH_PASSWORD_AUTH SSH_PUBKEY_FILE SSH_ALLOW_USERS \
      PROFILE PACKAGES \
      ENABLE_TAILSCALE TS_HOSTNAME TS_SSH TS_ARGS \
      AUTOSTART BOOT_DELAY WAKELOCK BIND_SDCARD EXTRA_BINDS DNS_SERVERS \
      SELINUX_PERMISSIVE MIN_FREE_MB RECOMMENDED_FREE_MB \
      SUDO_NOPASSWD LOCK_ROOT CLEAN_CACHE KEEP_TARBALL
    do
      eval "_val=\$$_v"
      printf '%s=%s\n' "$_v" "$(shquote "$_val")"
    done
    if [ "$SAVE_TS_AUTHKEY" = 1 ] && [ -n "$TS_AUTHKEY" ]; then
      printf 'TS_AUTHKEY=%s\n' "$(shquote "$TS_AUTHKEY")"
    fi
  } >"$_tmp" || { warn "Nao consegui salvar $BASE/config.env"; rm -f "$_tmp"; return 1; }
  mv -f "$_tmp" "$BASE/config.env" || return 1
  chmod 600 "$BASE/config.env" 2>/dev/null
  return 0
}

resolve_pubkey() {
  RESOLVED_KEY="${SSH_PUBKEY_FILE:-}"
  if [ -z "$RESOLVED_KEY" ]; then
    for _n in id_ed25519.pub id_ecdsa.pub id_rsa.pub authorized_keys; do
      _f=$(find_in_dl "$_n") && { RESOLVED_KEY="$_f"; break; }
    done
  fi
  if [ -n "$RESOLVED_KEY" ]; then
    [ -f "$RESOLVED_KEY" ] || die "SSH_PUBKEY_FILE nao existe: $RESOLVED_KEY"
    grep -qE '^(ssh-|ecdsa-|sk-)' "$RESOLVED_KEY" \
      || die "Nao parece uma chave publica SSH: $RESOLVED_KEY"
  fi
}

resolve_packages() {
  case "$PROFILE" in
    minimal) PROFILE_PKGS="sudo ca-certificates" ;;
    dev)     PROFILE_PKGS="sudo ca-certificates base-devel git neovim tmux python nodejs" ;;
    server)  PROFILE_PKGS="sudo ca-certificates rsync tmux htop" ;;
    custom)  PROFILE_PKGS="sudo ca-certificates" ;;
    *)       die "PROFILE invalido: $PROFILE (minimal|dev|server|custom)" ;;
  esac
  [ "$ENABLE_SSH" = 1 ] && PROFILE_PKGS="$PROFILE_PKGS openssh"
  [ "$ENABLE_TAILSCALE" = 1 ] && PROFILE_PKGS="$PROFILE_PKGS tailscale"

  ALL_PKGS=""
  for _p in $PROFILE_PKGS $PACKAGES; do
    case " $ALL_PKGS " in *" $_p "*) ;; *) ALL_PKGS="$ALL_PKGS $_p" ;; esac
  done
  ALL_PKGS=${ALL_PKGS# }
}

normalize_options() {
  ENABLE_SSH=$(normalize_bool "$ENABLE_SSH")
  ENABLE_TAILSCALE=$(normalize_bool "$ENABLE_TAILSCALE")
  TS_SSH=$(normalize_bool "$TS_SSH")
  AUTOSTART=$(normalize_bool "$AUTOSTART")
  WAKELOCK=$(normalize_bool "$WAKELOCK")
  BIND_SDCARD=$(normalize_bool "$BIND_SDCARD")
  SUDO_NOPASSWD=$(normalize_bool "$SUDO_NOPASSWD")
  LOCK_ROOT=$(normalize_bool "$LOCK_ROOT")
  CLEAN_CACHE=$(normalize_bool "$CLEAN_CACHE")
  KEEP_TARBALL=$(normalize_bool "$KEEP_TARBALL")
  FORCE=$(normalize_bool "$FORCE")
  NO_COLOR=$(normalize_bool "$NO_COLOR")
}

validate_options() {
  normalize_options

  detect_arch
  validate_base_path

  case "$LAB_USER" in
    ''|root) die "LAB_USER nao pode ser vazio nem root." ;;
  esac
  case "$LAB_USER" in
    [!a-z_]*|*[!a-z0-9_-]*) die "LAB_USER invalido (minusculas, numeros, _ ou -)." ;;
  esac
  [ "${#LAB_USER}" -le 32 ] || die "LAB_USER muito longo."

  case "$LAB_HOST" in
    ''|*[!A-Za-z0-9-]*) die "LAB_HOST invalido (letras, numeros e -)." ;;
  esac
  case "$LAB_HOST" in
    -*|*-) die "LAB_HOST nao pode comecar/terminar com -." ;;
  esac
  [ "${#LAB_HOST}" -le 63 ] || die "LAB_HOST muito longo."

  case "$SSH_PORT" in
    ''|*[!0-9]*) die "SSH_PORT invalida: '$SSH_PORT'" ;;
  esac
  { [ "$SSH_PORT" -ge 1 ] && [ "$SSH_PORT" -le 65535 ]; } \
    || die "SSH_PORT fora de 1-65535."

  case "$SSH_PASSWORD_AUTH" in
    yes|no) ;;
    *) die "SSH_PASSWORD_AUTH deve ser yes ou no." ;;
  esac

  case "$LAB_LANG" in
    ''|*[!A-Za-z0-9._@-]*) die "LAB_LANG invalido: '$LAB_LANG'" ;;
  esac
  case "$LAB_TZ" in
    ''|*[!A-Za-z0-9_+/-]*) die "LAB_TZ invalido: '$LAB_TZ'" ;;
  esac

  case "$SELINUX_PERMISSIVE" in
    auto|0|1|yes|no) ;;
    *) die "SELINUX_PERMISSIVE deve ser auto, 0 ou 1." ;;
  esac

  case "$MIN_FREE_MB" in ''|*[!0-9]*) die "MIN_FREE_MB invalido." ;; esac
  case "$BOOT_DELAY" in ''|*[!0-9]*) die "BOOT_DELAY invalido." ;; esac

  case "$MIRROR" in
    http://*|https://*) ;;
    *) die "MIRROR deve comecar com http:// ou https://" ;;
  esac
  MIRROR="${MIRROR%/}"
  case "$MIRROR" in
    */os|*/os/) MIRROR="${MIRROR%/os}"; MIRROR="${MIRROR%/}" ;;
  esac
  case "$MIRROR" in
    *'$arch'*|*'$repo'*) die "Use a raiz do mirror, sem \$arch/\$repo (ex.: http://fl.us.mirror.archlinuxarm.org)." ;;
  esac

  [ -n "$TS_HOSTNAME" ] || TS_HOSTNAME="$LAB_HOST"

  for _p in $ALL_PKGS; do
    case "$_p" in
      -*) die "Pacote invalido (nao pode comecar com -): $_p" ;;
    esac
    case "$_p" in
      *[!A-Za-z0-9@._+-]*) die "Nome de pacote invalido: $_p" ;;
    esac
  done

  if [ -n "$DNS_SERVERS" ]; then
    for _d in $DNS_SERVERS; do
      case "$_d" in
        *[!A-Fa-f0-9.:]*) die "DNS invalido: $_d" ;;
      esac
    done
  fi

  if [ -n "$EXTRA_BINDS" ]; then
    for _b in $EXTRA_BINDS; do
      case "$_b" in
        *:/*) ;;
        *) die "EXTRA_BINDS invalido (use origem:destino_absoluto): $_b" ;;
      esac
      case "${_b#*:}" in
        *..*) die "EXTRA_BINDS com '..' recusado: $_b" ;;
      esac
    done
  fi

  if [ -n "$TS_HOSTNAME" ]; then
    case "$TS_HOSTNAME" in
      *[!A-Za-z0-9.-]*) die "TS_HOSTNAME invalido." ;;
    esac
  fi

  resolve_pubkey
  if [ "$ENABLE_SSH" = 1 ] && [ "$SSH_PASSWORD_AUTH" = no ] && [ -z "$RESOLVED_KEY" ]; then
    die "SSH_PASSWORD_AUTH=no exige uma chave publica (SSH_PUBKEY_FILE)."
  fi
}

finalize_config() {
  normalize_options
  set_colors
  set_paths
  detect_device
  detect_arch
  [ -n "$TS_HOSTNAME" ] || TS_HOSTNAME="$LAB_HOST"
  resolve_packages

  if [ "$INTERACTIVE" = 1 ]; then
    : # --interactive explicito tem prioridade
  elif [ "$ASSUME_YES" = 1 ]; then
    INTERACTIVE=0
  elif [ "$INTERACTIVE" = auto ]; then
    if [ -t 0 ] && [ -t 1 ]; then INTERACTIVE=1; else INTERACTIVE=0; fi
  fi
}

# ------------------------------- STAGES -------------------------------------
# Cada etapa concluida deixa um marcador em $STATE/<etapa> e um "fingerprint"
# das variaveis que a definem em $STATE/<etapa>.fp. Se a config mudar, a etapa
# e reaplicada (sem precisar de --force, que apaga o rootfs inteiro).
stage_done() { [ -f "$STATE/$1" ]; }
stage_mark() { : >"$STATE/$1"; }
stage_clear() { rm -f "$STATE"/* 2>/dev/null; }

cfg_fingerprint() {
  for _cf_v in "$@"; do
    eval "_cf_val=\$$_cf_v"
    printf '%s=%s\n' "$_cf_v" "$_cf_val"
  done
}

stage_save() {
  _ss_name="$1"; shift
  cfg_fingerprint "$@" >"$STATE/$_ss_name.fp" 2>/dev/null
}

stage_same() {
  _sm_name="$1"; shift
  [ -f "$STATE/$_sm_name" ] || return 1
  # Instalacao antiga (sem fingerprint): considera valida para nao mexer
  # em senha/usuario sem necessidade.
  [ -f "$STATE/$_sm_name.fp" ] || return 0
  [ "$(cfg_fingerprint "$@")" = "$(cat "$STATE/$_sm_name.fp" 2>/dev/null)" ]
}

stage_run() {
  _sr_name="$1"; _sr_fn="$2"; shift 2
  if stage_done "$_sr_name"; then
    if stage_same "$_sr_name" "$@"; then
      info "Etapa '$_sr_name' ja concluida (config inalterada); pulando."
      return 0
    fi
    info "Config de '$_sr_name' mudou; reaplicando..."
    rm -f "$STATE/$_sr_name" "$STATE/$_sr_name.fp"
  fi
  "$_sr_fn" || die "Falha na etapa '$_sr_name' (veja $LOG)."
  stage_save "$_sr_name" "$@"
}

# ------------------------------- BASE CONFIG --------------------------------
default_dns() {
  if [ -n "$DNS_SERVERS" ]; then
    printf '%s\n' "$DNS_SERVERS"
    return 0
  fi
  _dns=""
  if [ -n "$GETPROP" ]; then
    for _p in net.dns1 net.dns2 net.dns3; do
      _v=$($GETPROP "$_p" 2>/dev/null)
      case "$_v" in
        ''|0.0.0.0|::|::1) ;;
        *) _dns="$_dns $_v" ;;
      esac
    done
  fi
  [ -n "$_dns" ] || _dns="1.1.1.1 8.8.8.8"
  printf '%s\n' "${_dns# }"
}

write_resolv() {
  [ -d "$ROOT/etc" ] || return 0
  rm -f "$ROOT/etc/resolv.conf"
  {
    printf '# archlab\n'
    for _ns in $(default_dns); do
      printf 'nameserver %s\n' "$_ns"
    done
  } >"$ROOT/etc/resolv.conf" || die "Nao consegui escrever resolv.conf"
  log "resolv.conf: $(default_dns)"
}

pacman_server() {
  case "$1" in
    *'$arch'*) printf '%s\n' "$1" ;;
    *) printf '%s/$arch/$repo\n' "${1%/}" ;;
  esac
}

setup_mirrors() {
  _mf="$ROOT/etc/pacman.d/mirrorlist"
  [ -d "$ROOT/etc/pacman.d" ] || die "Diretorio pacman.d nao encontrado no rootfs."
  {
    printf '## archlab - mirror principal: %s\n' "$MIRROR"
    printf 'Server = %s\n' "$(pacman_server "$MIRROR")"
    for _m in $MIRROR_FALLBACKS; do
      [ "$_m" = "$MIRROR" ] && continue
      printf 'Server = %s\n' "$(pacman_server "$_m")"
    done
  } >"$_mf" || die "Nao consegui escrever $_mf"
  ok "Mirrorlist configurado."
}

cfg_base() {
  info "Configurando base (hostname, DNS, fuso, mirrorlist, pacman.conf)..."

  write_resolv
  printf '%s\n' "$LAB_HOST" >"$ROOT/etc/hostname"
  printf '127.0.0.1\tlocalhost\n::1\tlocalhost\n127.0.1.1\t%s\n' "$LAB_HOST" >"$ROOT/etc/hosts"

  if [ -f "$ROOT/usr/share/zoneinfo/$LAB_TZ" ]; then
    ln -sf "/usr/share/zoneinfo/$LAB_TZ" "$ROOT/etc/localtime"
  else
    warn "Timezone '$LAB_TZ' nao encontrado; usando UTC."
    LAB_TZ="UTC"
    ln -sf /usr/share/zoneinfo/UTC "$ROOT/etc/localtime"
  fi

  setup_mirrors

  _pc="$ROOT/etc/pacman.conf"
  [ -f "$_pc" ] || die "pacman.conf nao encontrado no rootfs."
  sed -i 's/^CheckSpace/#CheckSpace/' "$_pc" || die "Falha editando pacman.conf"
  sed -i 's/^#ParallelDownloads/ParallelDownloads/' "$_pc" 2>/dev/null

  if ! grep -q '^DisableSandbox' "$_pc"; then
    : >"$_pc.new"
    while IFS= read -r _line; do
      printf '%s\n' "$_line" >>"$_pc.new"
      if [ "$_line" = "[options]" ]; then printf 'DisableSandbox\n' >>"$_pc.new"; fi
    done <"$_pc"
    mv -f "$_pc.new" "$_pc" || die "Falha atualizando pacman.conf"
  fi

  if [ -f "$ROOT/etc/locale.gen" ]; then
    if grep -qE "^#?${LAB_LANG} UTF-8" "$ROOT/etc/locale.gen" 2>/dev/null; then
      sed -i "s/^#\\(${LAB_LANG} UTF-8\\)/\\1/" "$ROOT/etc/locale.gen"
    else
      warn "Locale '$LAB_LANG' nao encontrado em locale.gen; usando en_US.UTF-8."
      LAB_LANG="en_US.UTF-8"
    fi
    sed -i 's/^#\(en_US\.UTF-8 UTF-8\)/\1/' "$ROOT/etc/locale.gen" 2>/dev/null
  fi

  stage_mark base
}

check_pacman_conf() {
  if ! chroot_exec pacman-conf >/dev/null 2>>"$LOG"; then
    warn "pacman.conf rejeitado; removendo DisableSandbox."
    sed -i '/^DisableSandbox$/d' "$ROOT/etc/pacman.conf"
    chroot_exec pacman-conf >/dev/null 2>>"$LOG" || die "pacman.conf invalido (veja $LOG)."
  fi
}

# ------------------------------- PACOTES ------------------------------------
setup_packages() {
  check_pacman_conf

  if [ ! -d "$ROOT/etc/pacman.d/gnupg" ]; then
    info "Inicializando keyring do pacman (pode demorar)..."
    run "pacman-key --init" chroot_exec pacman-key --init
    run "pacman-key --populate archlinuxarm" chroot_exec pacman-key --populate archlinuxarm
  else
    try "pacman-key --populate archlinuxarm" chroot_exec pacman-key --populate archlinuxarm
  fi

  for _p in $KERNEL_PKGS; do
    if chroot_exec pacman -Qq "$_p" >/dev/null 2>&1; then
      info "Removendo $_p (inutil em chroot)..."
      try "remover $_p" chroot_exec pacman -Rns --noconfirm "$_p"
    fi
  done

  info "Atualizando o sistema e instalando pacotes (varios minutos)..."
  if [ -n "$ALL_PKGS" ]; then
    if ! run_live_rc "pacman -Syu + pacotes" \
        chroot_exec pacman -Syu --noconfirm --needed $ALL_PKGS; then
      warn "Pacman falhou; tentando atualizar o keyring e repetir..."
      try "keyring init" chroot_exec pacman-key --init
      try "keyring populate" chroot_exec pacman-key --populate archlinuxarm
      try "keyring refresh" chroot_exec pacman-key --refresh-keys
      run_live "pacman -Syu (retry)" chroot_exec pacman -Syu --noconfirm --needed $ALL_PKGS
    fi
  else
    if ! run_live_rc "pacman -Syu" chroot_exec pacman -Syu --noconfirm; then
      warn "Pacman falhou; tentando atualizar o keyring e repetir..."
      try "keyring init" chroot_exec pacman-key --init
      try "keyring populate" chroot_exec pacman-key --populate archlinuxarm
      try "keyring refresh" chroot_exec pacman-key --refresh-keys
      run_live "pacman -Syu (retry)" chroot_exec pacman -Syu --noconfirm
    fi
  fi

  if [ -f "$ROOT/etc/locale.gen" ]; then
    info "Gerando locales..."
    run "locale-gen" chroot_exec locale-gen
  fi
  printf 'LANG=%s\n' "$LAB_LANG" >"$ROOT/etc/locale.conf"

  if [ "$CLEAN_CACHE" = 1 ]; then
    try "limpar cache do pacman" chroot_exec pacman -Sc --noconfirm
  fi

  stage_mark packages
}

# ------------------------------- USUARIOS -----------------------------------
ensure_group() {
  if chroot_exec getent group "$1" >/dev/null 2>&1; then
    return 0
  fi
  if chroot_exec getent group "$2" >/dev/null 2>&1; then
    _g=$(chroot_exec getent group "$2" 2>/dev/null | cut -d: -f1)
    warn "GID $2 ja usado por '$_g'; criando '$1' com GID duplicado."
    try "Criando grupo $1 (gid $2 duplicado)" chroot_exec groupadd -o -g "$2" "$1" \
      || die "Nao consegui criar o grupo $1."
    return 0
  fi
  run "Criando grupo $1 (gid $2)" chroot_exec groupadd -g "$2" "$1"
}

ask_password() {
  _tries=0
  while [ "$_tries" -lt 3 ]; do
    ST_ECHO=1; stty -echo 2>/dev/null
    printf 'Senha para %s: ' "$LAB_USER" >&2; rd _p1
    printf '\nConfirme a senha: ' >&2; rd _p2
    stty echo 2>/dev/null; ST_ECHO=0; printf '\n' >&2
    if [ -n "$_p1" ] && [ "$_p1" = "$_p2" ]; then
      LAB_PASSWORD="$_p1"; return 0
    fi
    warn "Senhas vazias ou diferentes. Tente de novo."
    _tries=$((_tries + 1))
  done
  return 1
}

generate_password() {
  LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c 16
}

setup_users() {
  info "Criando usuario e ajustando grupos de rede do Android..."
  # Android (paranoid network): usuarios nao-root precisam dos GIDs de rede.
  ensure_group aid_inet 3003
  ensure_group aid_net_raw 3004
  _extra_groups=""
  if [ "$BIND_SDCARD" = 1 ]; then
    ensure_group aid_sdcard_rw 1015
    ensure_group aid_media_rw 1023
    _extra_groups=",aid_sdcard_rw,aid_media_rw"
  fi

  run "root nos grupos de rede" chroot_exec usermod -aG aid_inet,aid_net_raw root

  if chroot_exec id "$LAB_USER" >/dev/null 2>&1; then
    run "Ajustando grupos de $LAB_USER" \
      chroot_exec usermod -aG "wheel,aid_inet,aid_net_raw$_extra_groups" "$LAB_USER"
  else
    run "Criando usuario $LAB_USER" \
      chroot_exec useradd -m -s /bin/bash -G "wheel,aid_inet,aid_net_raw$_extra_groups" "$LAB_USER"
  fi

  if chroot_exec id alpm >/dev/null 2>&1; then
    try "alpm no grupo aid_inet" chroot_exec usermod -aG aid_inet alpm
  fi

  mkdir -p "$ROOT/etc/sudoers.d" 2>/dev/null
  if [ "$SUDO_NOPASSWD" = 1 ]; then
    printf '%%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n' >"$ROOT/etc/sudoers.d/10-wheel"
  else
    printf '%%wheel ALL=(ALL:ALL) ALL\n' >"$ROOT/etc/sudoers.d/10-wheel"
  fi
  chmod 440 "$ROOT/etc/sudoers.d/10-wheel"

  PASS="$LAB_PASSWORD"; GENERATED=0
  if [ -z "$PASS" ]; then
    if [ "$INTERACTIVE" = 1 ] && [ -t 0 ]; then
      ask_password || die "Senha nao definida."
      PASS="$LAB_PASSWORD"
    else
      PASS=$(generate_password)
      [ -n "$PASS" ] || die "Nao consegui gerar senha."
      GENERATED=1
    fi
  fi
  case "$PASS" in
    *:*|*'
'*) die "A senha nao pode conter ':' nem quebra de linha." ;;
  esac

  printf '%s:%s\n' "$LAB_USER" "$PASS" | chroot_exec chpasswd >>"$LOG" 2>&1 \
    || die "chpasswd falhou (veja $LOG)"
  LAB_PASSWORD="$PASS"

  if [ "$GENERATED" = 1 ]; then
    ( umask 077; printf 'usuario=%s\nsenha=%s\n' "$LAB_USER" "$PASS" >"$CRED" )
    chmod 600 "$CRED" 2>/dev/null
    GEN_PASS="$PASS"
  fi
  PASS=""

  if chroot_exec id alarm >/dev/null 2>&1; then
    try "remover usuario padrao alarm" chroot_exec userdel -r alarm
  fi
  if [ "$LOCK_ROOT" = 1 ]; then
    try "bloquear senha do root (use sudo)" chroot_exec passwd -l root
  fi

  stage_mark users
}

# ------------------------------- CHROOT -------------------------------------
CH_PATH="/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/sbin:/sbin:/bin"

chroot_exec() {
  # CHROOT pode ser "chroot" ou "busybox chroot": expansao sem quotes e proposital.
  # shellcheck disable=SC2086
  $CHROOT "$ROOT" /usr/bin/env -i HOME=/root USER=root LOGNAME=root \
    SHELL=/bin/bash TERM="${TERM:-xterm-256color}" LANG=C PATH="$CH_PATH" "$@"
}

chroot_user() {
  # shellcheck disable=SC2086
  $CHROOT "$ROOT" /usr/bin/env -i TERM="${TERM:-xterm-256color}" LANG="$LAB_LANG" \
    PATH="$CH_PATH" /usr/bin/su -l "$1"
}

# ------------------------------- SSH ----------------------------------------
sshd_pid() {
  _p=$(cat "$ROOT/run/sshd.pid" 2>/dev/null)
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && printf '%s\n' "$_p"
}

# Lista os sshd "mestre" (o listener) rodando dentro do chroot.
# Nao depende so do pidfile: /run e tmpfs e pode ter sido remontado.
sshd_pids() {
  _seen=""
  _p=$(sshd_pid)
  if [ -n "$_p" ]; then printf '%s\n' "$_p"; _seen=" $_p "; fi
  for _d in /proc/[0-9]*; do
    _pid="${_d#/proc/}"
    case "$_seen" in *" $_pid "*) continue ;; esac
    [ "$(readlink "$_d/root" 2>/dev/null)" = "$ROOT" ] || continue
    _c=$(tr '\0' ' ' <"$_d/cmdline" 2>/dev/null)
    case "$_c" in
      *sshd*) ;;
      *) continue ;;
    esac
    # sessoes filhas aparecem como "sshd: user@pts/N": nao matar.
    case "$_c" in
      sshd:*|*" sshd:"*) continue ;;
    esac
    printf '%s\n' "$_pid"
  done
}

stop_sshd() {
  _pids=$(sshd_pids)
  [ -n "$_pids" ] || { rm -f "$ROOT/run/sshd.pid"; return 0; }
  for _p in $_pids; do kill "$_p" 2>/dev/null; done
  sleep 1
  for _p in $_pids; do
    kill -0 "$_p" 2>/dev/null && kill -9 "$_p" 2>/dev/null
  done
  rm -f "$ROOT/run/sshd.pid"
  return 0
}

setup_ssh() {
  if [ "$ENABLE_SSH" != 1 ]; then
    if [ -n "$(sshd_pids)" ]; then
      info "Parando sshd (SSH foi desabilitado)..."
      stop_sshd
    fi
    info "SSH desabilitado (acesso local via: archlab shell)."
    stage_mark ssh
    return 0
  fi

  info "Configurando o SSH..."
  [ -x "$ROOT/usr/bin/sshd" ] || die "openssh nao esta instalado no rootfs."
  _d="$ROOT/etc/ssh"
  [ -f "$_d/sshd_config" ] || die "sshd_config nao encontrado."

  # Se a config mudou (porta/chave), reinicia para aplicar.
  _old=$(sshd_pids | head -n 1)
  if [ -n "$_old" ]; then
    info "Parando sshd antigo (PID $_old) para aplicar a nova configuracao..."
    stop_sshd
  fi

  if ! grep -qE '^[[:space:]]*Include' "$_d/sshd_config"; then
    { printf 'Include /etc/ssh/sshd_config.d/*.conf\n'; cat "$_d/sshd_config"; } >"$_d/sshd_config.new" \
      && mv -f "$_d/sshd_config.new" "$_d/sshd_config" || die "Falha ajustando sshd_config"
  fi
  mkdir -p "$_d/sshd_config.d"

  _allow="$LAB_USER"
  [ -n "$SSH_ALLOW_USERS" ] && _allow="$SSH_ALLOW_USERS"
  {
    printf 'Port %s\n' "$SSH_PORT"
    printf 'PermitRootLogin no\n'
    printf 'AllowUsers %s\n' "$_allow"
    printf 'PasswordAuthentication %s\n' "$SSH_PASSWORD_AUTH"
    printf 'PubkeyAuthentication yes\n'
    printf 'UsePAM yes\n'
    printf 'ClientAliveInterval 30\nClientAliveCountMax 4\n'
  } >"$_d/sshd_config.d/10-archlab.conf" || die "Falha escrevendo 10-archlab.conf"

  if [ -n "$RESOLVED_KEY" ]; then
    _h="$ROOT/home/$LAB_USER"
    mkdir -p "$_h/.ssh" || die "Falha criando ~/.ssh"
    cat "$RESOLVED_KEY" >"$_h/.ssh/authorized_keys" || die "Falha copiando a chave"
    chmod 700 "$_h/.ssh"; chmod 600 "$_h/.ssh/authorized_keys"
    run "chown ~/.ssh" chroot_exec chown -R "$LAB_USER:" "/home/$LAB_USER/.ssh"
    ok "Chave publica instalada para $LAB_USER."
  fi

  run "Gerando host keys (ssh-keygen -A)" chroot_exec ssh-keygen -A
  run "Validando sshd_config (sshd -t)" chroot_exec /usr/bin/sshd -t

  stage_mark ssh
}

start_sshd() {
  [ "$ENABLE_SSH" = 1 ] || return 0
  [ -x "$ROOT/usr/bin/sshd" ] || { warn "sshd nao instalado; pulando SSH."; return 0; }

  _pid=$(sshd_pids | head -n 1)
  [ -n "$_pid" ] && { ok "sshd ja esta rodando (PID $_pid)."; return 0; }
  rm -f "$ROOT/run/sshd.pid"
  mkdir -p "$ROOT/run/sshd" 2>/dev/null; chmod 755 "$ROOT/run/sshd" 2>/dev/null

  run "Iniciando sshd na porta $SSH_PORT" \
    chroot_exec /usr/bin/sshd -E /var/log/sshd.log

  _i=0
  while [ "$_i" -lt 10 ]; do
    _pid=$(sshd_pids | head -n 1)
    [ -n "$_pid" ] && { ok "sshd ativo (PID $_pid, porta $SSH_PORT)."; return 0; }
    sleep 1; _i=$((_i + 1))
  done
  err "sshd nao subiu. Ultimas linhas de /var/log/sshd.log:"
  tail -n 15 "$ROOT/var/log/sshd.log" 2>/dev/null | sed 's/^/    /' >&2
  exit 1
}

get_ips() {
  if [ -n "$IPCMD" ]; then
    # Toybox/KernelSU pode nao suportar "-4"; nesse caso filtra na mao.
    _out=$($IPCMD -4 addr show 2>/dev/null)
    [ -n "$_out" ] || _out=$($IPCMD addr show 2>/dev/null)
    printf '%s\n' "$_out" | while read -r _line; do
      case "$_line" in
        [0-9]*:*)
          _if=${_line#*: }; _if=${_if%%:*}; _if=${_if%%@*}; _if=$(printf '%s' "$_if" | tr -d ' ') ;;
        *'inet '*)
          _ip=${_line#*inet }; _ip=${_ip%%/*}
          case "$_ip" in ''|*[!0-9.]*) continue ;; esac
          case "$_if" in ''|lo) ;; *) printf '%s %s\n' "$_if" "$_ip" ;; esac ;;
      esac
    done
    return 0
  fi
  if command -v ifconfig >/dev/null 2>&1; then
    ifconfig 2>/dev/null | while read -r _line; do
      case "$_line" in
        *'inet addr:'*) _ip=${_line#*inet addr:}; _ip=${_ip%% *}
          case "$_ip" in 127.*) ;; *) printf '? %s\n' "$_ip" ;; esac ;;
      esac
    done
  fi
}

show_access() {
  printf '\n'
  if [ "$ENABLE_SSH" != 1 ]; then
    info "SSH desabilitado. Acesso local:"
    printf '    su -c "sh %s shell"\n\n' "$SELF"
    return 0
  fi

  info "Acesso SSH a partir do PC:"
  _tsip=$(ts_ip 2>/dev/null)
  if [ -n "$_tsip" ]; then
    printf '    ssh -p %s %s@%s      (tailscale)\n' "$SSH_PORT" "$LAB_USER" "$_tsip"
  fi
  _ips=$(get_ips)
  if [ -n "$_ips" ]; then
    printf '%s\n' "$_ips" | while read -r _if _ip; do
      printf '    ssh -p %s %s@%s      (%s)\n' "$SSH_PORT" "$LAB_USER" "$_ip" "$_if"
    done
  else
    warn "Nenhum IP detectado (Wi-Fi desligado?)."
  fi
  printf '    Via USB:  adb forward tcp:%s tcp:%s  &&  ssh -p %s %s@127.0.0.1\n\n' \
    "$SSH_PORT" "$SSH_PORT" "$SSH_PORT" "$LAB_USER"
}

# ------------------------------- LABCTL -------------------------------------
install_labctl() {
  mkdir -p "$ROOT/usr/local/bin" "$ROOT/etc/sudoers.d" 2>/dev/null
  _tmp="$ROOT/usr/local/bin/labctl"
  cat >"$_tmp" <<'LABCTL_EOF'
#!/bin/sh
# labctl - controla o Android de dentro do chroot (gerado pelo archlab)
SELF=@SELF@
BASE=@BASE@
HOSTPATH=/system/bin:/system/xbin:/data/adb/ksu/bin:/data/adb/ap/bin

[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"

host() {
  chroot /proc/1/root /system/bin/env -i PATH="$HOSTPATH" HOME=/data/local/tmp \
    /system/bin/sh "$SELF" "$@"
}

case "${1:-}" in
  wake)
    host wake 2>/dev/null || {
      echo archlab >/sys/power/wake_lock 2>/dev/null && echo "Modo ativo (wakelock ligado)."
    } ;;
  standby)
    host standby 2>/dev/null || {
      echo archlab >/sys/power/wake_unlock 2>/dev/null && echo "Standby (wakelock liberado)."
    } ;;
  status)
    host status 2>/dev/null || {
      if grep -qw archlab /sys/power/wake_lock 2>/dev/null; then
        echo "Modo: ATIVO (wakelock ligado)"
      else
        echo "Modo: STANDBY (sem wakelock)"
      fi
    } ;;
  poweroff)
    echo "Parando o lab em 3s - esta conexao vai cair."
    setsid nohup chroot /proc/1/root /system/bin/env -i PATH="$HOSTPATH" HOME=/data/local/tmp \
      /system/bin/sh -c "sleep 3; sh $SELF stop" >/dev/null 2>&1 </dev/null &
    ;;
  *)
    echo "Uso: labctl wake | standby | status | poweroff"
    echo "  wake      segura wakelock (celular acordado; mais bateria)"
    echo "  standby   libera o wakelock (celular pode dormir)"
    echo "  status    mostra o estado do lab"
    echo "  poweroff  para o lab (sshd, mounts); so volta localmente"
    exit 2 ;;
esac
LABCTL_EOF

  sed -i "s|@SELF@|$SELF|g; s|@BASE@|$BASE|g" "$_tmp" 2>/dev/null \
    || die "Falha gerando labctl"
  chmod 755 "$_tmp"
  printf '%%wheel ALL=(root) NOPASSWD: /usr/local/bin/labctl\n' \
    >"$ROOT/etc/sudoers.d/20-labctl"
  chmod 440 "$ROOT/etc/sudoers.d/20-labctl"
}

# ------------------------------- TAILSCALE ----------------------------------
TS_SOCK=/run/tailscale/tailscaled.sock

ts_pid() {
  _p=$(cat "$ROOT/run/tailscaled.pid" 2>/dev/null)
  [ -n "$_p" ] && kill -0 "$_p" 2>/dev/null && printf '%s\n' "$_p"
}

ts_cli() { chroot_exec /usr/bin/tailscale --socket="$TS_SOCK" "$@"; }
ts_ip() { ts_pid >/dev/null && ts_cli ip -4 2>/dev/null | head -n 1; }

ts_start() {
  [ -x "$ROOT/usr/bin/tailscaled" ] || { warn "tailscale nao instalado."; return 1; }
  ts_pid >/dev/null && return 0
  mkdir -p "$ROOT/var/lib/tailscale" "$ROOT/run/tailscale" 2>>"$LOG"
  rm -f "$ROOT$TS_SOCK" "$ROOT/run/tailscaled.pid"
  chroot_exec /usr/bin/sh -c \
    "nohup /usr/bin/tailscaled --tun=userspace-networking --state=/var/lib/tailscale/tailscaled.state --socket=$TS_SOCK >>/var/log/tailscaled.log 2>&1 </dev/null & echo \$! >/run/tailscaled.pid" \
    >>"$LOG" 2>&1 || return 1
  _i=0
  while [ "$_i" -lt 15 ]; do
    [ -S "$ROOT$TS_SOCK" ] && ts_pid >/dev/null && return 0
    sleep 1; _i=$((_i + 1))
  done
  return 1
}

ts_login() {
  _args="--hostname=$TS_HOSTNAME --accept-dns=false --timeout=180s"
  [ "$TS_SSH" = 1 ] && _args="$_args --ssh"
  [ -n "$TS_ARGS" ] && _args="$_args $TS_ARGS"
  if [ -n "$TS_AUTHKEY" ]; then
    _args="$_args --authkey=$TS_AUTHKEY"
  else
    info "Abra a URL abaixo num navegador e faca login no Tailscale."
  fi
  ts_cli up $_args || return 1
  mkdir -p "$STATE" 2>/dev/null
  : >"$STATE/ts_enabled"
}

ts_stop() {
  if _p=$(ts_pid); then
    ts_cli down >>"$LOG" 2>&1
    kill "$_p" 2>/dev/null
  fi
  rm -f "$STATE/ts_enabled"
}

cmd_tailscale() {
  case "${1:-status}" in
    on)
      need_root; detect_tools; detect_device; detect_arch; validate_options
      [ -x "$ROOT/usr/bin/sshd" ] || [ -x "$ROOT/usr/bin/pacman" ] \
        || die "Instale o lab antes (install)."
      is_mounted "$ROOT/proc" || { handle_selinux; do_mounts; write_resolv; }
      if [ ! -x "$ROOT/usr/bin/tailscaled" ]; then
        info "Instalando o pacote tailscale..."
        run_live "pacman -S tailscale" chroot_exec pacman -S --noconfirm --needed tailscale
      fi
      info "Iniciando tailscaled (userspace, sem TUN)..."
      ts_start || die "tailscaled nao subiu. Veja $ROOT/var/log/tailscaled.log"
      ts_login || die "'tailscale up' falhou. Rode: archlab tailscale on"
      ok "Tailscale ativo. IP: $(ts_ip)"
      show_access ;;
    login)
      need_root; is_mounted "$ROOT/proc" || { handle_selinux; do_mounts; write_resolv; }
      ts_start || die "tailscaled nao subiu."
      ts_login || die "Login do Tailscale falhou."
      ok "Tailscale logado. IP: $(ts_ip)" ;;
    off)
      need_root; ts_stop; ok "Tailscale desligado (login continua salvo)." ;;
    status)
      if _p=$(ts_pid); then
        ok "tailscaled rodando (PID $_p). IP: $(ts_ip)"
        ts_cli status 2>&1 | head -n 8
      else
        warn "tailscaled parado."
      fi
      if [ -f "$STATE/ts_enabled" ]; then info "Sobe junto com o lab: sim"; else info "Sobe junto com o lab: nao"; fi ;;
    *) die "Uso: archlab tailscale on|off|login|status" ;;
  esac
}

# ------------------------------- AUTOSTART / WAKE ---------------------------
autostart_file() { printf '/data/adb/service.d/99-archlab.sh\n'; }

cmd_autostart() {
  _f=$(autostart_file)
  case "${1:-}" in
    on)
      [ -x "$ROOT/usr/bin/pacman" ] || die "Instale o lab antes (install)."
      [ -f "$SELF" ] || die "Nao encontrei $SELF; rode o script a partir de um arquivo."
      mkdir -p /data/adb/service.d || die "Nao consegui criar /data/adb/service.d"
      cat >"$_f" <<EOF
#!/system/bin/sh
# gerado por archlab
until [ "\$(getprop sys.boot_completed)" = "1" ]; do sleep 5; done
sleep $BOOT_DELAY
ARCHLAB_BASE="$BASE" sh "$SELF" start >>"$BASE/boot.log" 2>&1
EOF
      chmod 755 "$_f" || die "chmod falhou em $_f"
      ok "Autostart ativado ($_f). Log: $BASE/boot.log" ;;
    off)
      rm -f "$_f"; ok "Autostart desativado." ;;
    *) die "Uso: archlab autostart on|off" ;;
  esac
}

wl_active() { grep -qw archlab /sys/power/wake_lock 2>/dev/null; }
wl_off() { [ -w /sys/power/wake_unlock ] && echo archlab >/sys/power/wake_unlock 2>/dev/null; return 0; }

wl_on() {
  if [ "$WAKELOCK" != 1 ] && [ ! -f "$STATE/awake" ]; then
    info "Standby: sem wakelock (use 'archlab wake' para sessoes longas)."
    return 0
  fi
  if [ -w /sys/power/wake_lock ] && echo archlab >/sys/power/wake_lock 2>/dev/null; then
    info "Wakelock ativo (o aparelho nao suspende; consome bateria)."
  else
    warn "Nao consegui segurar wakelock; o SSH pode cair com a tela apagada."
  fi
}

cmd_wake() {
  [ -w /sys/power/wake_lock ] || die "Sem acesso a /sys/power/wake_lock."
  mkdir -p "$STATE" 2>/dev/null
  : >"$STATE/awake"
  echo archlab >/sys/power/wake_lock 2>/dev/null || die "Nao consegui segurar o wakelock."
  ok "Modo ATIVO: celular acordado. Para voltar: archlab standby"
}

cmd_standby() {
  rm -f "$STATE/awake"
  wl_off
  ok "Modo STANDBY: wakelock liberado; o celular pode dormir."
}

# ------------------------------- SUMMARY -----------------------------------
show_summary() {
  resolve_packages
  printf '\n'
  hr
  printf '%bResumo da instalacao%b\n' "$C_C" "$C_N"
  hr
  printf '  Device      : %s (%s) - Android %s\n' "$DEV_MODEL" "$DEV_NAME" "$DEV_ANDROID"
  printf '  Root manager: %s\n' "$ROOT_MANAGER"
  printf '  Arquitetura : %s\n' "$ARCH"
  printf '  Base        : %s\n' "$BASE"
  _sfree=$(df -k "$BASE" 2>/dev/null | tail -n 1 | sed 's/  */ /g' | cut -d' ' -f4)
  case "$_sfree" in
    ''|*[!0-9]*) _sfree="?" ;;
    *) _sfree="$((_sfree / 1024)) MB" ;;
  esac
  printf '  Espaco livre: %s\n' "$_sfree"
  printf '  Mirror      : %s\n' "$MIRROR"
  printf '  Rootfs      : %s\n' "$ROOTFS_FILE"
  printf '  Hostname    : %s\n' "$LAB_HOST"
  printf '  Timezone    : %s\n' "$LAB_TZ"
  printf '  Locale      : %s\n' "$LAB_LANG"
  printf '  Usuario     : %s (senha %s)\n' "$LAB_USER" \
    "$([ -n "$LAB_PASSWORD" ] && printf 'definida' || printf 'sera gerada')"
  printf '  Perfil      : %s\n' "$PROFILE"
  printf '  Pacotes     : %s\n' "${ALL_PKGS:-(nenhum extra)}"
  if [ "$ENABLE_SSH" = 1 ]; then
    printf '  SSH         : porta %s, senha %s, chave %s\n' "$SSH_PORT" \
      "$SSH_PASSWORD_AUTH" "${RESOLVED_KEY:-nao}"
  else
    printf '  SSH         : desabilitado\n'
  fi
  if [ "$ENABLE_TAILSCALE" = 1 ]; then
    printf '  Tailscale   : sim (host %s, ssh %s)\n' "$TS_HOSTNAME" "$TS_SSH"
  else
    printf '  Tailscale   : nao\n'
  fi
  printf '  Autostart   : %s\n' "$AUTOSTART"
  printf '  Wakelock    : %s\n' "$WAKELOCK"
  printf '  Bind sdcard : %s\n' "$BIND_SDCARD"
  [ -n "$EXTRA_BINDS" ] && printf '  Binds extra : %s\n' "$EXTRA_BINDS"
  printf '  SELinux     : %s\n' "$SELINUX_PERMISSIVE"
  hr
  printf '\n'
}

# ------------------------------- WIZARD ------------------------------------
choose_mirror() {
  printf '\nEspelhos Arch Linux ARM:\n'
  printf '  1) %s (GeoIP, recomendado)\n' "http://mirror.archlinuxarm.org"
  printf '  2) %s (EUA)\n' "http://fl.us.mirror.archlinuxarm.org"
  printf '  3) %s (Canada)\n' "http://ca.us.mirror.archlinuxarm.org"
  printf '  4) personalizado (URL)\n'
  printf '  5) manter atual (%s)\n' "$MIRROR"
  printf 'Escolha [1-5]: '
  rd _n
  case "${_n:-1}" in
    1) MIRROR="http://mirror.archlinuxarm.org" ;;
    2) MIRROR="http://fl.us.mirror.archlinuxarm.org" ;;
    3) MIRROR="http://ca.us.mirror.archlinuxarm.org" ;;
    4)
      ask MIRROR "URL do mirror (sem /os; ex.: http://meu.mirror)" "$MIRROR" ;;
    5) ;;
    *) warn "Opcao invalida; mantendo $MIRROR." ;;
  esac
  MIRROR="${MIRROR%/}"
  info "Mirror selecionado: $MIRROR"
}

choose_profile() {
  printf '\nPerfis:\n'
  printf '  1) minimal - base funcional + SSH opcional\n'
  printf '  2) dev     - base-devel, git, neovim, tmux, python, nodejs\n'
  printf '  3) server  - rsync, tmux, htop (SSH opcional)\n'
  printf '  4) custom  - voce escolhe os grupos de pacotes\n'
  printf 'Perfil [1-4] (%s): ' "$PROFILE"
  rd _n
  case "${_n:-1}" in
    1) PROFILE=minimal ;;
    2) PROFILE=dev ;;
    3) PROFILE=server ;;
    4) PROFILE=custom ;;
    *) warn "Opcao invalida; usando $PROFILE." ;;
  esac
}

group_pkgs() {
  case "$1" in
    1) printf 'nano vim htop curl wget rsync\n' ;;
    2) printf 'base-devel git neovim tmux python nodejs\n' ;;
    3) printf 'iproute2 inetutils bind\n' ;;
    4) printf 'ffmpeg imagemagick\n' ;;
    5) printf 'xfce4 tigervnc dbus\n' ;;
    *) printf '\n' ;;
  esac
}

group_name() {
  case "$1" in
    1) printf 'Ferramentas (nano, vim, htop, curl, wget, rsync)' ;;
    2) printf 'Desenvolvimento (base-devel, git, neovim, tmux, python, nodejs)' ;;
    3) printf 'Rede (iproute2, inetutils, bind/dig)' ;;
    4) printf 'Midia (ffmpeg, imagemagick)' ;;
    5) printf 'Desktop experimental (xfce4, tigervnc, dbus)' ;;
  esac
}

menu_packages() {
  _sel=""
  while :; do
    printf '\nPacotes adicionais (o perfil ja inclui o basico):\n'
    for _i in 1 2 3 4 5; do
      _mark="[ ]"
      case " $_sel " in *" $_i "*) _mark="[x]" ;; esac
      printf '  %s %s) %s\n' "$_mark" "$_i" "$(group_name "$_i")"
    done
    printf '  Pacotes ja escolhidos: %s\n' "${PACKAGES:-(nenhum)}"
    printf 'Digite numeros para marcar/desmarcar, 0 limpa, Enter/done conclui: '
    rd _ans
    case "$_ans" in
      ''|done|fim|ok) break ;;
      0) _sel="" ;;
      *)
        for _n in $_ans; do
          case "$_n" in
            [1-5])
              case " $_sel " in
                *" $_n "*) _sel=$(printf ' %s ' "$_sel" | sed "s/ $_n / /g") ;;
                *) _sel="$_sel $_n" ;;
              esac ;;
            *) warn "Ignorando opcao: $_n" ;;
          esac
        done ;;
    esac
  done

  for _n in $_sel; do
    _g=$(group_pkgs "$_n")
    PACKAGES="$PACKAGES $_g"
  done

  printf 'Pacotes adicionais por nome (ex.: firefox nodejs; Enter pula): '
  rd _extra
  [ -n "$_extra" ] && PACKAGES="$PACKAGES $_extra"
  PACKAGES=$(printf '%s\n' "$PACKAGES" | tr -s ' ')
  PACKAGES=${PACKAGES# }
  PACKAGES=${PACKAGES% }
}

wizard() {
  printf '\n'
  hr
  printf '%bArchlab %s - assistente de instalacao%b\n' "$C_C" "$VERSION" "$C_N"
  hr
  printf 'Device: %s (%s), Android %s, %s\n' "$DEV_MODEL" "$DEV_NAME" "$DEV_ANDROID" "$ROOT_MANAGER"
  printf 'Enter aceita o valor entre [ ].\n\n'

  ask BASE "Pasta de instalacao" "$BASE"
  validate_base_path
  set_paths
  mkdir -p "$BASE" "$DL" "$STATE" 2>/dev/null || die "Nao consegui criar $BASE"
  chmod 700 "$BASE" 2>/dev/null

  ask ARCH "Arquitetura (aarch64/armv7)" "$ARCH"
  detect_arch

  choose_mirror

  ask LAB_HOST "Hostname" "$LAB_HOST"
  printf '\nFusos comuns: America/Sao_Paulo, America/New_York, Europe/Lisbon, Europe/Madrid, UTC\n'
  ask LAB_TZ "Timezone" "$LAB_TZ"
  printf '\nLocales: en_US.UTF-8, pt_BR.UTF-8, es_ES.UTF-8, fr_FR.UTF-8, de_DE.UTF-8\n'
  ask LAB_LANG "Locale" "$LAB_LANG"

  ask LAB_USER "Usuario do Arch" "$LAB_USER"
  if [ -n "$LAB_PASSWORD" ]; then
    ask_yesno KEEP_PASS "Manter a senha ja definida" 1
    if [ "$KEEP_PASS" != 1 ]; then LAB_PASSWORD=""; fi
  fi
  if [ -z "$LAB_PASSWORD" ]; then
    printf 'Senha (Enter = gerar senha aleatoria): '
    ST_ECHO=1; stty -echo 2>/dev/null
    rd _p1
    stty echo 2>/dev/null; ST_ECHO=0; printf '\n'
    if [ -n "$_p1" ]; then
      printf 'Confirme a senha: '
      ST_ECHO=1; stty -echo 2>/dev/null
      rd _p2
      stty echo 2>/dev/null; ST_ECHO=0; printf '\n'
      [ "$_p1" = "$_p2" ] || die "Senhas diferentes."
      LAB_PASSWORD="$_p1"
    fi
  fi

  choose_profile
  menu_packages

  ask_yesno ENABLE_SSH "Habilitar SSH" "$ENABLE_SSH"
  if [ "$ENABLE_SSH" = 1 ]; then
    ask SSH_PORT "Porta SSH" "$SSH_PORT"
    ask_yesno _pw "Permitir login por senha" "$([ "$SSH_PASSWORD_AUTH" = yes ] && echo 1 || echo 0)"
    [ "$_pw" = 1 ] && SSH_PASSWORD_AUTH=yes || SSH_PASSWORD_AUTH=no
    ask SSH_PUBKEY_FILE "Arquivo de chave publica (Enter auto-detecta)" "$SSH_PUBKEY_FILE"
  fi

  ask_yesno ENABLE_TAILSCALE "Instalar/ativar Tailscale" "$ENABLE_TAILSCALE"
  if [ "$ENABLE_TAILSCALE" = 1 ]; then
    ask TS_HOSTNAME "Hostname no Tailscale" "$TS_HOSTNAME"
    ask_yesno TS_SSH "Habilitar Tailscale SSH" "$TS_SSH"
    if [ -n "$TS_AUTHKEY" ]; then
      ask_yesno _keep_ts "Manter a auth key do Tailscale" 1
      [ "$_keep_ts" = 1 ] || TS_AUTHKEY=""
    else
      printf 'Auth key do Tailscale (Enter = login por URL depois): '
      rd TS_AUTHKEY
    fi
  fi

  ask_yesno BIND_SDCARD "Montar /sdcard em /mnt/sdcard" "$BIND_SDCARD"
  if [ "$BIND_SDCARD" = 1 ]; then
    ask EXTRA_BINDS "Binds extras origem:destino (espaco separado, Enter pula)" "$EXTRA_BINDS"
  fi

  ask_yesno AUTOSTART "Iniciar no boot (service.d)" "$AUTOSTART"
  ask_yesno WAKELOCK "Segurar wakelock por padrao" "$WAKELOCK"

  printf '\nSELinux: auto = tenta normal, muda para permissivo se um mount falhar\n'
  printf '  1) auto   2) permissivo   3) enforcing (nao mexer)\n'
  printf 'Escolha [1-3] (auto): '
  rd _n
  case "${_n:-1}" in
    2) SELINUX_PERMISSIVE=1 ;;
    3) SELINUX_PERMISSIVE=0 ;;
    *) SELINUX_PERMISSIVE=auto ;;
  esac

  validate_options
  show_summary
  ask_yesno _go "Iniciar a instalacao agora" 1
  [ "$_go" = 1 ] || { info "Cancelado."; exit 0; }
  WIZARD_CONFIRMED=1
}

# ------------------------------- FLAGS --------------------------------------
ask() {
  _var="$1"; _label="$2"; _def="$3"
  printf '%s [%s]: ' "$_label" "$_def"
  rd _ans
  [ -z "$_ans" ] && _ans="$_def"
  setvar "$_var" "$_ans"
}

ask_yesno() {
  _var="$1"; _label="$2"; _def="$3"
  case "$_def" in 1) _hint="S/n" ;; *) _hint="s/N" ;; esac
  printf '%s [%s]: ' "$_label" "$_hint"
  rd _ans
  case "$_ans" in
    '' ) _v="$_def" ;;
    s|S|y|Y|sim|SIM|yes|YES) _v=1 ;;
    n|N|nao|NAO|no|NO) _v=0 ;;
    *) _v="$_def" ;;
  esac
  setvar "$_var" "$_v"
}

prescan_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --base) [ $# -ge 2 ] && BASE=$2; shift 2; continue ;;
      --base=*) BASE=${1#*=}; shift; continue ;;
      --config) [ $# -ge 2 ] && CONFIG_FILE=$2; shift 2; continue ;;
      --config=*) CONFIG_FILE=${1#*=}; shift; continue ;;
      --) break ;;
    esac
    shift
  done
}

parse_args() {
  while [ $# -gt 0 ]; do
    _a="$1"; shift
    case "$_a" in
      --base) [ $# -ge 1 ] || die "--base exige valor"; BASE=$1; shift ;;
      --base=*) BASE=${_a#*=} ;;
      --config) [ $# -ge 1 ] || die "--config exige valor"; CONFIG_FILE=$1; shift ;;
      --config=*) CONFIG_FILE=${_a#*=} ;;
      --arch) [ $# -ge 1 ] || die "--arch exige valor"; ARCH=$1; shift ;;
      --arch=*) ARCH=${_a#*=} ;;
      --mirror) [ $# -ge 1 ] || die "--mirror exige valor"; MIRROR=$1; shift ;;
      --mirror=*) MIRROR=${_a#*=} ;;
      --rootfs) [ $# -ge 1 ] || die "--rootfs exige valor"; ROOTFS_TARBALL=$1; shift ;;
      --rootfs=*) ROOTFS_TARBALL=${_a#*=} ;;
      --rootfs-url) [ $# -ge 1 ] || die "--rootfs-url exige valor"; ROOTFS_URL=$1; shift ;;
      --rootfs-url=*) ROOTFS_URL=${_a#*=} ;;
      --user) [ $# -ge 1 ] || die "--user exige valor"; LAB_USER=$1; shift ;;
      --user=*) LAB_USER=${_a#*=} ;;
      --hostname) [ $# -ge 1 ] || die "--hostname exige valor"; LAB_HOST=$1; shift ;;
      --hostname=*) LAB_HOST=${_a#*=} ;;
      --timezone|--tz) [ $# -ge 1 ] || die "$_a exige valor"; LAB_TZ=$1; shift ;;
      --timezone=*|--tz=*) LAB_TZ=${_a#*=} ;;
      --locale) [ $# -ge 1 ] || die "--locale exige valor"; LAB_LANG=$1; shift ;;
      --locale=*) LAB_LANG=${_a#*=} ;;
      --password) [ $# -ge 1 ] || die "--password exige valor"; LAB_PASSWORD=$1; shift ;;
      --password=*) LAB_PASSWORD=${_a#*=} ;;
      --profile) [ $# -ge 1 ] || die "--profile exige valor"; PROFILE=$1; shift ;;
      --profile=*) PROFILE=${_a#*=} ;;
      --packages) [ $# -ge 1 ] || die "--packages exige valor"; PACKAGES="$PACKAGES $1"; shift ;;
      --packages=*) PACKAGES="$PACKAGES ${_a#*=}" ;;
      --ssh) ENABLE_SSH=1 ;;
      --no-ssh) ENABLE_SSH=0 ;;
      --ssh-port) [ $# -ge 1 ] || die "--ssh-port exige valor"; SSH_PORT=$1; shift ;;
      --ssh-port=*) SSH_PORT=${_a#*=} ;;
      --ssh-password) [ $# -ge 1 ] || die "--ssh-password exige valor"; SSH_PASSWORD_AUTH=$1; shift ;;
      --ssh-password=*) SSH_PASSWORD_AUTH=${_a#*=} ;;
      --no-ssh-password) SSH_PASSWORD_AUTH=no ;;
      --ssh-key|--pubkey) [ $# -ge 1 ] || die "$_a exige valor"; SSH_PUBKEY_FILE=$1; shift ;;
      --ssh-key=*|--pubkey=*) SSH_PUBKEY_FILE=${_a#*=} ;;
      --tailscale) ENABLE_TAILSCALE=1 ;;
      --no-tailscale) ENABLE_TAILSCALE=0 ;;
      --ts-hostname) [ $# -ge 1 ] || die "--ts-hostname exige valor"; TS_HOSTNAME=$1; shift ;;
      --ts-hostname=*) TS_HOSTNAME=${_a#*=} ;;
      --ts-ssh) TS_SSH=1 ;;
      --no-ts-ssh) TS_SSH=0 ;;
      --ts-authkey) [ $# -ge 1 ] || die "--ts-authkey exige valor"; TS_AUTHKEY=$1; shift ;;
      --ts-authkey=*) TS_AUTHKEY=${_a#*=} ;;
      --ts-args) [ $# -ge 1 ] || die "--ts-args exige valor"; TS_ARGS=$1; shift ;;
      --ts-args=*) TS_ARGS=${_a#*=} ;;
      --autostart) AUTOSTART=1 ;;
      --no-autostart) AUTOSTART=0 ;;
      --boot-delay) [ $# -ge 1 ] || die "--boot-delay exige valor"; BOOT_DELAY=$1; shift ;;
      --boot-delay=*) BOOT_DELAY=${_a#*=} ;;
      --wake) WAKELOCK=1 ;;
      --no-wake) WAKELOCK=0 ;;
      --bind-sdcard) BIND_SDCARD=1 ;;
      --no-bind-sdcard) BIND_SDCARD=0 ;;
      --extra-binds) [ $# -ge 1 ] || die "--extra-binds exige valor"; EXTRA_BINDS=$1; shift ;;
      --extra-binds=*) EXTRA_BINDS=${_a#*=} ;;
      --dns) [ $# -ge 1 ] || die "--dns exige valor"; DNS_SERVERS=$1; shift ;;
      --dns=*) DNS_SERVERS=${_a#*=} ;;
      --selinux) [ $# -ge 1 ] || die "--selinux exige valor"; SELINUX_PERMISSIVE=$1; shift ;;
      --selinux=*) SELINUX_PERMISSIVE=${_a#*=} ;;
      --min-free) [ $# -ge 1 ] || die "--min-free exige valor"; MIN_FREE_MB=$1; shift ;;
      --min-free=*) MIN_FREE_MB=${_a#*=} ;;
      --force) FORCE=1 ;;
      --no-force) FORCE=0 ;;
      --sudo-nopasswd) SUDO_NOPASSWD=1 ;;
      --lock-root) LOCK_ROOT=1 ;;
      --no-lock-root) LOCK_ROOT=0 ;;
      --clean) CLEAN_CACHE=1 ;;
      --no-clean) CLEAN_CACHE=0 ;;
      --keep-tarball) KEEP_TARBALL=1 ;;
      --no-keep-tarball) KEEP_TARBALL=0 ;;
      --save-secrets) SAVE_TS_AUTHKEY=1 ;;
      --yes|-y) ASSUME_YES=1 ;;
      --dry-run) DRY_RUN=1 ;;
      --interactive|-i) INTERACTIVE=1 ;;
      --no-interactive) INTERACTIVE=0; ASSUME_YES=1 ;;
      --no-color) NO_COLOR=1 ;;
      -h|--help) usage; exit 0 ;;
      --) break ;;
      *) die "Opcao desconhecida: $_a (veja: archlab help)" ;;
    esac
  done
}

# ------------------------------- INSTALL ------------------------------------
prepare_rootfs() {
  if [ "$FORCE" = 1 ]; then
    if [ -n "$(mounts_under_root)" ]; then
      info "Parando o lab para reinstalar..."
      kill_procs TERM >/dev/null 2>&1; sleep 2
      kill_procs KILL >/dev/null 2>&1
      umount_all || die "Nao consegui desmontar para reinstalar."
    fi
    safe_wipe_root
    stage_clear
    rm -f "$CRED"
    ok "Rootfs anterior removido (FORCE=1)."
  fi

  if [ -x "$ROOT/usr/bin/pacman" ]; then
    _oldarch=$(cat "$STATE/arch" 2>/dev/null)
    if [ -n "$_oldarch" ] && [ "$_oldarch" != "$ARCH" ]; then
      die "Rootfs existente e $_oldarch, mas ARCH=$ARCH. Use --force para reinstalar."
    fi
    info "Rootfs existente encontrado; retomando instalacao."
    printf '%s\n' "$ARCH" >"$STATE/arch"
    stage_mark extracted
    return 0
  fi

  stage_clear
  check_space
  check_net
  get_tarball
  info "Verificando integridade do tarball..."
  verify_md5 "$TARBALL"
  extract_rootfs "$TARBALL"
  printf '%s\n' "$ARCH" >"$STATE/arch"
  stage_mark extracted

  if [ "$KEEP_TARBALL" != 1 ]; then
    case "$TARBALL" in
      "$DL"/*) rm -f "$TARBALL"; ok "Tarball removido do cache." ;;
    esac
  fi
}

cmd_install() {
  preflight

  if [ "$INTERACTIVE" = 1 ]; then
    wizard
    preflight
  fi
  validate_options
  resolve_packages

  if [ "${WIZARD_CONFIRMED:-0}" != 1 ]; then
    show_summary
    if [ "$ASSUME_YES" != 1 ]; then
      ask_yesno _go "Iniciar a instalacao agora" 1
      [ "$_go" = 1 ] || { info "Cancelado."; return 0; }
    fi
  fi

  if [ "$DRY_RUN" = 1 ]; then
    ok "Dry-run: nenhuma alteracao feita."
    return 0
  fi

  acquire_lock
  save_config
  if [ ! -x "$ROOT/usr/bin/pacman" ] || [ "$FORCE" = 1 ]; then
    check_space
  else
    info "Rootfs existente: pulando checagem de espaco da instalacao inicial."
  fi
  check_net
  handle_selinux

  prepare_rootfs

  stage_run base cfg_base \
    LAB_HOST LAB_TZ LAB_LANG MIRROR MIRROR_FALLBACKS DNS_SERVERS SELINUX_PERMISSIVE
  do_mounts
  write_resolv
  stage_run packages setup_packages \
    PROFILE PACKAGES ALL_PKGS ENABLE_SSH ENABLE_TAILSCALE
  # Uma senha passada explicitamente sempre deve ser (re)aplicada.
  [ -n "$LAB_PASSWORD" ] && rm -f "$STATE/users"
  stage_run users setup_users \
    LAB_USER SUDO_NOPASSWD LOCK_ROOT BIND_SDCARD
  stage_run ssh setup_ssh \
    ENABLE_SSH SSH_PORT SSH_PASSWORD_AUTH SSH_ALLOW_USERS RESOLVED_KEY

  install_labctl

  if [ "$ENABLE_TAILSCALE" = 1 ]; then
    if [ -n "$TS_AUTHKEY" ] || [ "$INTERACTIVE" = 1 ]; then
      info "Iniciando Tailscale..."
      if ts_start; then
        ts_login || warn "Login do Tailscale falhou; rode depois: archlab tailscale login"
      else
        warn "tailscaled nao subiu; veja $ROOT/var/log/tailscaled.log"
      fi
    else
      warn "Tailscale sem authkey em modo nao-interativo; rode depois: archlab tailscale login"
    fi
  fi

  if [ "$AUTOSTART" = 1 ]; then
    try "ativar autostart" cmd_autostart on
  fi

  wl_on
  start_sshd

  ok "Arch Linux pronto!"
  if [ -n "${GEN_PASS:-}" ]; then
    printf '\n'
    warn "Senha gerada para $LAB_USER: $GEN_PASS"
    warn "Tambem salva em $CRED (modo 600)."
  fi
  show_access
  info "Shell local: su -c \"sh $SELF shell\""
}

# ------------------------------- START/STOP --------------------------------
cmd_start() {
  preflight
  [ -x "$ROOT/usr/bin/pacman" ] || die "Lab nao instalado. Rode: sh $0 install"
  handle_selinux
  do_mounts
  write_resolv
  install_labctl
  wl_on
  start_sshd

  if [ "$ENABLE_TAILSCALE" = 1 ] || [ -f "$STATE/ts_enabled" ]; then
    ts_start || warn "tailscaled nao subiu (veja $ROOT/var/log/tailscaled.log)"
  fi

  show_access
}

cmd_stop() {
  detect_tools
  info "Encerrando processos dentro do chroot..."
  if kill_procs TERM; then
    sleep 3
    kill_procs KILL >/dev/null 2>&1 && sleep 1
  fi
  info "Desmontando..."
  umount_all || die "Nao consegui desmontar tudo (veja $LOG). Se persistir, reinicie o celular."
  wl_off
  rm -f "$STATE/awake"
  ok "Lab parado."
}

cmd_restart() {
  cmd_stop
  cmd_start
}

# ------------------------------- SHELL/EXEC --------------------------------
cmd_shell() {
  preflight
  [ -x "$ROOT/usr/bin/bash" ] || die "Rootfs nao instalado. Rode: sh $0 install"
  is_mounted "$ROOT/proc" || { handle_selinux; do_mounts; write_resolv; }
  _u="${1:-root}"
  if [ "$_u" = root ]; then
    # shellcheck disable=SC2086
    exec $CHROOT "$ROOT" /usr/bin/env -i HOME=/root USER=root LOGNAME=root \
      SHELL=/bin/bash TERM="${TERM:-xterm-256color}" LANG="$LAB_LANG" PATH="$CH_PATH" \
      /usr/bin/bash -l
  fi
  chroot_user "$_u"
}

cmd_exec() {
  preflight
  [ -x "$ROOT/usr/bin/bash" ] || die "Rootfs nao instalado. Rode: sh $0 install"
  is_mounted "$ROOT/proc" || { handle_selinux; do_mounts; write_resolv; }
  [ $# -gt 0 ] || die "Uso: archlab exec -- comando [args]"
  chroot_exec "$@"
}

cmd_pacman() {
  preflight
  [ -x "$ROOT/usr/bin/pacman" ] || die "Rootfs nao instalado."
  is_mounted "$ROOT/proc" || { handle_selinux; do_mounts; write_resolv; }
  [ $# -gt 0 ] || die "Uso: archlab pacman -- -Syu (ou: archlab update)"
  chroot_exec pacman "$@"
}

cmd_update() {
  preflight
  [ -x "$ROOT/usr/bin/pacman" ] || die "Rootfs nao instalado."
  is_mounted "$ROOT/proc" || { handle_selinux; do_mounts; write_resolv; }
  write_resolv
  run_live "pacman -Syu" chroot_exec pacman -Syu --noconfirm
  if [ "$CLEAN_CACHE" = 1 ]; then
    try "limpar cache do pacman" chroot_exec pacman -Sc --noconfirm
  fi
  ok "Sistema atualizado."
}

# ------------------------------- STATUS/INFO -------------------------------
cmd_status() {
  printf '\n%bArchlab %s%b\n' "$C_C" "$VERSION" "$C_N"
  printf 'Device : %s (%s) - Android %s\n' "$DEV_MODEL" "$DEV_NAME" "$DEV_ANDROID"
  printf 'Root   : %s\n' "$ROOT_MANAGER"
  printf 'Base   : %s\n' "$BASE"
  _free=$(df -k "$BASE" 2>/dev/null | tail -n 1 | sed 's/  */ /g' | cut -d' ' -f4)
  case "$_free" in ''|*[!0-9]*) ;; *) printf 'Espaco : %s MB livres\n' "$((_free / 1024))" ;; esac

  if [ -x "$ROOT/usr/bin/pacman" ]; then
    printf 'Rootfs : instalado (%s)\n' "$(cat "$STATE/arch" 2>/dev/null || printf '?')"
  else
    printf 'Rootfs : nao instalado\n'
  fi
  if is_mounted "$ROOT/proc"; then printf 'Chroot : montado\n'; else printf 'Chroot : desmontado\n'; fi

  if [ "$ENABLE_SSH" != 1 ]; then
    printf 'sshd   : desabilitado\n'
  elif is_mounted "$ROOT/proc" && [ -n "$(sshd_pids)" ]; then
    printf 'sshd   : rodando (PID %s, porta %s)\n' "$(sshd_pids | head -n 1)" "$SSH_PORT"
  else
    printf 'sshd   : parado\n'
  fi

  if _p=$(ts_pid); then
    printf 'Tailsc : ativo (%s)\n' "$(ts_ip)"
  else
    printf 'Tailsc : parado\n'
  fi

  _af=$(autostart_file)
  [ -f "$_af" ] && printf 'Boot   : autostart ativo\n' || printf 'Boot   : autostart desativado\n'
  if wl_active; then printf 'Energia: ATIVO (wakelock)\n'; else printf 'Energia: STANDBY\n'; fi

  [ -x "$ROOT/usr/bin/pacman" ] && show_access
  printf '\n'
}

cmd_info() {
  printf '\n%bArchlab %s%b\n' "$C_C" "$VERSION" "$C_N"
  printf 'Device       : %s (%s)\n' "$DEV_MODEL" "$DEV_NAME"
  printf 'Android      : %s (SDK %s)\n' "$DEV_ANDROID" "$DEV_SDK"
  printf 'ABI          : %s\n' "${DEV_ABI:-?}"
  printf 'Root manager : %s\n' "$ROOT_MANAGER"
  printf 'Kernel       : %s\n' "$(uname -r 2>/dev/null)"
  printf 'Arch         : %s\n' "$ARCH"
  printf 'BASE         : %s\n' "$BASE"
  printf 'Rootfs       : %s\n' "$ROOT"
  _free=$(df -k "$BASE" 2>/dev/null | tail -n 1 | sed 's/  */ /g' | cut -d' ' -f4)
  case "$_free" in ''|*[!0-9]*) ;; *) printf 'Espaco       : %s MB livres\n' "$((_free / 1024))" ;; esac
  if [ -x "$ROOT/usr/bin/pacman" ]; then
    _n=$(chroot_exec pacman -Qq 2>/dev/null | wc -l | tr -d ' ')
    case "$_n" in ''|*[!0-9]*) _n="?" ;; esac
    printf 'Pacotes      : %s\n' "$_n"
    printf 'Rootfs arch  : %s\n' "$(cat "$STATE/arch" 2>/dev/null || printf '?')"
  fi
  printf '\n'
}

# ------------------------------- DOCTOR -------------------------------------
d_ok()   { printf '%b[+]%b %s\n' "$C_G" "$C_N" "$*"; }
d_warn() { printf '%b[!]%b %s\n' "$C_Y" "$C_N" "$*"; D_WARN=$((D_WARN + 1)); }
d_fail() { printf '%b[x]%b %s\n' "$C_R" "$C_N" "$*" >&2; D_FAIL=$((D_FAIL + 1)); }

cmd_doctor() {
  D_FAIL=0; D_WARN=0
  printf '\n%bArchlab doctor%b\n' "$C_C" "$C_N"
  hr
  printf 'Device: %s (%s), Android %s\n' "$DEV_MODEL" "$DEV_NAME" "$DEV_ANDROID"
  printf 'Kernel: %s; Arch: %s; Root: %s\n\n' "$(uname -r 2>/dev/null)" "$(uname -m 2>/dev/null)" "$ROOT_MANAGER"

  [ "$(id -u 2>/dev/null)" = 0 ] && d_ok "root: sim" || d_fail "root: NAO (rode com su)"
  case "$(uname -m 2>/dev/null)" in
    aarch64|arm64|armv7l|armv8l|arm) d_ok "arquitetura suportada: $(uname -m)" ;;
    *) d_fail "arquitetura nao suportada: $(uname -m) (use aarch64/armv7)" ;;
  esac

  for _t in mount umount chroot tar grep sed cut sort head tail tr df readlink; do
    command -v "$_t" >/dev/null 2>&1 && d_ok "ferramenta: $_t" || d_warn "ferramenta ausente: $_t"
  done
  [ -n "$BB" ] && d_ok "busybox: $BB" || d_warn "busybox nao encontrado (pode faltar tar/chroot)"
  if have_download; then
    _dn="${CURL:-$WGET}"
    [ -n "$_dn" ] || _dn="$BB wget"
    d_ok "download: $_dn"
  else
    d_fail "sem curl/wget (nem busybox wget) para baixar o rootfs"
  fi
  [ -n "$MD5" ] && d_ok "md5: $MD5" || d_warn "sem md5sum (verificacao do tarball sera pulada)"

  check_kernel_fs
  for _fs in proc sysfs tmpfs devpts; do
    if grep -qw "$_fs" /proc/filesystems 2>/dev/null; then
      d_ok "kernel: $_fs"
    else
      [ "$_fs" = proc ] || [ "$_fs" = sysfs ] && d_fail "kernel sem $_fs" || d_warn "kernel sem $_fs (fallback sera usado)"
    fi
  done

  _dr="$BASE/.doctor"
  rm -rf "$_dr"; mkdir -p "$_dr" 2>/dev/null

  _t="$_dr/tmpfs"; mkdir -p "$_t"
  if mount -t tmpfs tmpfs "$_t" >/dev/null 2>&1; then
    d_ok "mount tmpfs: ok"; umount "$_t" >/dev/null 2>&1
  else
    d_warn "mount tmpfs falhou (SELinux? tente SELINUX_PERMISSIVE=1)"
  fi

  _t="$_dr/bind"; mkdir -p "$_t"
  if mount -o bind "$_t" "$_t" >/dev/null 2>&1; then
    if mount -o remount,bind,suid,dev "$_t" >/dev/null 2>&1 \
       && ! grep " $_t " /proc/mounts 2>/dev/null | grep -q nosuid; then
      d_ok "bind + remount suid: ok (sudo/su devem funcionar)"
    else
      d_fail "remount suid falhou (sudo/su podem nao funcionar)"
    fi
    umount "$_t" >/dev/null 2>&1
  else
    d_fail "bind mount falhou (mount namespace/SELinux?)"
  fi

  _t="$_dr/pts"; mkdir -p "$_t"
  if mount -t devpts devpts "$_t" >/dev/null 2>&1; then
    d_ok "devpts: ok"; umount "$_t" >/dev/null 2>&1
  else
    d_warn "devpts falhou (sera usado bind de /dev/pts do Android)"
  fi

  if [ -x "$ROOT/usr/bin/pacman" ]; then
    if chroot_exec /bin/true >/dev/null 2>&1; then
      d_ok "chroot exec: ok"
    else
      d_fail "chroot exec falhou (veja $LOG)"
    fi
  else
    d_warn "rootfs ainda nao instalado; chroot nao testado"
  fi

  _selfns=$(readlink /proc/self/ns/mnt 2>/dev/null)
  _pid1ns=$(readlink /proc/1/ns/mnt 2>/dev/null)
  if [ -n "$_selfns" ] && [ "$_selfns" = "$_pid1ns" ]; then
    d_ok "mount namespace: global"
  elif [ -n "$NSENTER" ]; then
    d_warn "mount namespace separado; nsenter disponivel (sera usado)"
  else
    d_fail "mount namespace separado e sem nsenter (use su -M / KernelSU)"
  fi

  if command -v getenforce >/dev/null 2>&1; then
    printf 'SELinux: %s\n' "$(getenforce 2>/dev/null)"
  fi
  _ps=$(getconf PAGE_SIZE 2>/dev/null)
  if [ -z "$_ps" ] && [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx getconf; then
    _ps=$("$BB" getconf PAGE_SIZE 2>/dev/null)
  fi
  case "$_ps" in
    16384) d_warn "paginas de 16 KB: alguns binarios ARM podem ter problemas; teste o chroot" ;;
    4096) d_ok "paginas de 4 KB" ;;
  esac

  if command -v ping >/dev/null 2>&1; then
    ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1 && d_ok "rede: ping ok" || d_warn "rede: ping falhou"
  fi
  if have_download; then
    _mok=""; _mbad=""
    for _m in $MIRROR $MIRROR_FALLBACKS; do
      if url_exists "$(mirror_os_url "$_m")"; then _mok="$_m"; break; fi
      _mbad="$_mbad $_m"
    done
    if [ -n "$_mok" ]; then
      if [ "$_mok" = "$MIRROR" ]; then
        d_ok "mirror: $_mok"
      else
        d_warn "tarball fora no mirror principal ($MIRROR); fallback ok: $_mok"
      fi
    else
      d_warn "nenhum mirror respondeu para o tarball (tente --mirror):$_mbad"
    fi
  fi

  _free=$(df -k "$BASE" 2>/dev/null | tail -n 1 | sed 's/  */ /g' | cut -d' ' -f4)
  case "$_free" in
    ''|*[!0-9]*) ;;
    *) [ "$((_free / 1024))" -ge "$RECOMMENDED_FREE_MB" ] \
         && d_ok "espaco: $((_free / 1024)) MB" \
         || d_warn "espaco: $((_free / 1024)) MB (recomendado $RECOMMENDED_FREE_MB MB)" ;;
  esac

  umount "$_dr/tmpfs" >/dev/null 2>&1
  umount "$_dr/pts" >/dev/null 2>&1
  umount "$_dr/bind" >/dev/null 2>&1
  rm -rf "$_dr"
  printf '\n'
  if [ "$D_FAIL" -gt 0 ]; then
    printf '%b%d falha(s), %d aviso(s).%b\n' "$C_R" "$D_FAIL" "$D_WARN" "$C_N"
    return 1
  fi
  printf '%bDoctor: %d aviso(s), nenhuma falha critica.%b\n' "$C_G" "$D_WARN" "$C_N"
  return 0
}

# ------------------------------- MIRROR/CONFIG ------------------------------
cmd_mirror() {
  detect_device
  detect_arch
  case "${1:-list}" in
    list|status)
      printf 'Mirror principal : %s\n' "$MIRROR"
      printf 'Fallbacks        : %s\n' "$MIRROR_FALLBACKS"
      printf 'Rootfs           : %s\n' "$ROOTFS_FILE"
      printf 'Pacman server    : %s\n' "$(pacman_server "$MIRROR")" ;;
    test)
      _u="${2:-$MIRROR}"; _u="${_u%/}"
      url_exists "$(mirror_os_url "$_u")"
      _rc=$?
      [ "$_rc" = 2 ] && die "sem curl/wget para testar o mirror."
      [ "$_rc" = 0 ] && ok "Mirror ok (tarball disponivel): $_u" || die "Mirror nao respondeu (tarball ausente): $_u" ;;
    set)
      [ -n "${2:-}" ] || die "Uso: archlab mirror set URL"
      MIRROR="${2%/}"
      case "$MIRROR" in http://*|https://*) ;; *) die "URL invalida." ;; esac
      save_config
      if [ -x "$ROOT/usr/bin/pacman" ]; then setup_mirrors; fi
      ok "Mirror definido: $MIRROR" ;;
    *) die "Uso: archlab mirror [list|test [URL]|set URL]" ;;
  esac
}

cmd_config() {
  case "${1:-show}" in
    path) printf '%s\n' "$BASE/config.env" ;;
    show)
      printf '# %s\n' "$BASE/config.env"
      for _v in \
        ARCH MIRROR MIRROR_FALLBACKS ROOTFS_URL ROOTFS_TARBALL \
        LAB_USER LAB_HOST LAB_TZ LAB_LANG \
        ENABLE_SSH SSH_PORT SSH_PASSWORD_AUTH SSH_PUBKEY_FILE SSH_ALLOW_USERS \
        PROFILE PACKAGES \
        ENABLE_TAILSCALE TS_HOSTNAME TS_SSH TS_ARGS \
        AUTOSTART BOOT_DELAY WAKELOCK \
        BIND_SDCARD EXTRA_BINDS DNS_SERVERS SELINUX_PERMISSIVE MIN_FREE_MB \
        RECOMMENDED_FREE_MB SUDO_NOPASSWD LOCK_ROOT CLEAN_CACHE KEEP_TARBALL
      do
        eval "_val=\$$_v"
        printf '%s=%s\n' "$_v" "$_val"
      done ;;
    *) die "Uso: archlab config [show|path]" ;;
  esac
}

# ------------------------------- BACKUP/UNINSTALL ---------------------------
cmd_backup() {
  preflight
  [ -x "$ROOT/usr/bin/pacman" ] || die "Rootfs nao instalado."
  [ -n "$TAR" ] || die "tar nao disponivel."
  _out="${1:-$BASE/backup-$(date '+%Y%m%d-%H%M%S').tar.gz}"
  case "$_out" in /*) ;; *) _out="$BASE/$_out" ;; esac
  case "$_out" in
    "$ROOT"/*|"$ROOT") die "Nao coloque o backup dentro do rootfs ($ROOT)." ;;
  esac
  _dir=$(dirname "$_out")
  mkdir -p "$_dir" 2>/dev/null || die "Nao consegui criar $_dir"

  info "Parando o lab para backup consistente..."
  cmd_stop

  _usedk=$(du -sk "$ROOT" 2>/dev/null | cut -f1)
  _freek=$(df -k "$_dir" 2>/dev/null | tail -n 1 | sed 's/  */ /g' | cut -d' ' -f4)
  case "$_usedk" in ''|*[!0-9]*) _usedk=0 ;; esac
  case "$_freek" in ''|*[!0-9]*) _freek=0 ;; esac
  if [ "$_usedk" -gt 0 ] && [ "$_freek" -gt 0 ]; then
    if [ "$_freek" -lt $((_usedk / 2)) ]; then
      die "Espaco insuficiente em $_dir: $((_freek / 1024)) MB livres; rootfs tem $((_usedk / 1024)) MB."
    elif [ "$_freek" -lt "$_usedk" ]; then
      warn "Espaco livre ($((_freek / 1024)) MB) menor que o rootfs ($((_usedk / 1024)) MB); o backup pode nao caber."
    fi
  fi

  info "Criando backup em $_out (pode demorar)..."
  if ! $TAR -czf "$_out" -C "$ROOT" . >>"$LOG" 2>&1; then
    warn "tar -z falhou; tentando com gzip..."
    rm -f "$_out"
    [ -n "$GZIP" ] || die "gzip nao disponivel para o backup."
    { $TAR -cf - -C "$ROOT" . | $GZIP -c >"$_out"; } >>"$LOG" 2>&1 \
      || { rm -f "$_out"; die "Backup falhou (veja $LOG)."; }
  fi
  _sz=$(du -k "$_out" 2>/dev/null | cut -f1)
  case "$_sz" in ''|*[!0-9]*) _sz=0 ;; esac
  ok "Backup criado: $_out ($((_sz / 1024)) MB)"
  info "Para voltar a usar: archlab start"
}

cmd_uninstall() {
  cmd_stop
  if [ "$FORCE" != 1 ]; then
    printf 'Isto APAGA %s (todo o Arch e seus dados). Digite "apagar" para confirmar: ' "$ROOT"
    rd _a
    [ "$_a" = apagar ] || { info "Cancelado."; return 0; }
  fi
  safe_wipe_root
  rm -rf "$STATE"
  rm -f "$(autostart_file)" "$BASE/config.env" "$CRED"
  if [ "$KEEP_TARBALL" != 1 ]; then
    rm -rf "$DL"
  fi
  ok "Removido. Script mantido em $SELF."
  [ "$KEEP_TARBALL" = 1 ] && info "Tarball em cache mantido em $DL."
  rmdir "$BASE" 2>/dev/null
  return 0
}

# ------------------------------- USAGE/MAIN --------------------------------
usage() {
  cat <<EOF
archlab $VERSION - Arch Linux ARM em chroot no Android

Uso: su -c "sh archlab.sh <comando> [opcoes]"

Instalacao:
  install              abre o wizard interativo (estilo archinstall)
  install --yes ...    instalacao nao-interativa com defaults/flags
  install --config F   carrega config; combine com --yes para automatizar
  install --dry-run    mostra o resumo sem instalar
  doctor               diagnostico do device (rode antes de instalar)

Operacao:
  start                monta o chroot e sobe os servicos
  stop                 mata processos e desmonta tudo
  restart              stop + start
  status               estado, IPs e comandos de acesso
  info                 informacoes do device/rootfs
  shell [usuario]      shell no chroot (padrao: root)
  exec -- CMD [args]   executa um comando no chroot
  pacman -- ARGS       roda pacman dentro do chroot
  update               pacman -Syu dentro do chroot
  ip                   mostra como conectar por SSH

Extras:
  tailscale on|off|login|status
  autostart on|off
  wake | standby       wakelock do Android
  mirror list|test|set mostra/testa/troca o mirror
  config show|path     mostra a configuracao
  backup [arquivo]     para o lab e cria um .tar.gz do rootfs
  uninstall            remove o Arch (pede confirmacao)

Opcoes do install (resumo):
  --base DIR           pasta de instalacao (padrao: /data/local/archlab)
  --arch aarch64|armv7
  --mirror URL         mirror ALARM (ex.: http://fl.us.mirror.archlinuxarm.org)
  --rootfs ARQUIVO     tarball local (ou --rootfs-url URL)
  --user NOME --password SENHA --hostname NOME
  --timezone TZ --locale LOCALE
  --profile minimal|dev|server|custom
  --packages "pkg1 pkg2"   pacotes adicionais
  --ssh | --no-ssh          habilita/desabilita SSH
  --ssh-port N --ssh-password yes|no --ssh-key ARQUIVO
  --tailscale | --no-tailscale --ts-authkey KEY --ts-ssh
  --autostart | --no-autostart
  --boot-delay SEG     espera antes de subir no boot (padrao 30)
  --wake | --no-wake
  --bind-sdcard | --no-bind-sdcard --extra-binds "src:dst ..."
  --dns "1.1.1.1 8.8.8.8"
  --selinux auto|1|0
  --min-free MB        espaco minimo exigido em /data
  --sudo-nopasswd      sudo sem senha para o usuario
  --lock-root | --no-lock-root
  --force              apaga o rootfs existente e reinstala
  --clean | --no-clean limpa/nao limpa o cache do pacman
  --keep-tarball | --no-keep-tarball
  --save-secrets       salva TS_AUTHKEY no config (cuidado)
  --yes                nao pergunta nada (gera senha se faltar)
  --interactive        forca o wizard mesmo com --yes (pergunta tudo)
  --no-interactive     modo nao-interativo (implica --yes)
  --no-color

Exemplos:
  su -c "sh archlab.sh install"
  su -c "sh archlab.sh install --yes --profile minimal --no-ssh"
  su -c "sh archlab.sh install --yes --user lab --hostname archlab \\
         --ssh-port 2222 --packages 'nano htop git' --autostart --wake"
  su -c "sh archlab.sh install --config /sdcard/Download/archlab.env --yes"

Variaveis de ambiente equivalentes as flags tambem funcionam:
  ARCHLAB_BASE, LAB_USER, LAB_HOST, LAB_TZ, LAB_LANG, SSH_PORT,
  ENABLE_SSH, PROFILE, PACKAGES, ENABLE_TAILSCALE, TS_AUTHKEY,
  AUTOSTART, WAKELOCK, BIND_SDCARD, MIRROR, FORCE, ...

Requisitos: root, aarch64/armv7, 4-6 GB livres em /data, internet.
Root managers testados: Magisk, KernelSU, APatch.
EOF
}

ensure_global_ns() {
  [ "${ARCHLAB_NS:-0}" = 1 ] && return 0
  [ -f "$SELF" ] || return 0
  _a=$(readlink /proc/self/ns/mnt 2>/dev/null)
  _b=$(readlink /proc/1/ns/mnt 2>/dev/null)
  [ -n "$_a" ] && [ "$_a" = "$_b" ] && return 0
  [ -n "$NSENTER" ] || {
    warn "Mount namespace separado e sem nsenter; mounts podem nao aparecer em outras sessoes."
    return 0
  }
  export ARCHLAB_NS=1
  export ARCHLAB_BASE="$BASE"
  [ -n "$CONFIG_FILE" ] && export ARCHLAB_CONFIG="$CONFIG_FILE"
  # shellcheck disable=SC2086
  $NSENTER -t 1 -m /system/bin/sh "$SELF" "$CMD" "$@"
  exit $?
}

main() {
  CMD="${1:-help}"
  [ $# -gt 0 ] && shift

  case "$CMD" in
    help|-h|--help) usage; exit 0 ;;
    version|--version) printf '%s %s\n' "$PROG" "$VERSION"; exit 0 ;;
  esac

  prescan_args "$@"
  set_paths
  load_config
  set_paths

  if [ "$CMD" = install ]; then
    parse_args "$@"
    set_paths
  fi
  normalize_options
  set_colors

  log_init
  detect_tools

  # Copia persistente: autostart, labctl e nsenter usam $SELF.
  if [ "$(id -u 2>/dev/null)" = 0 ] && [ -f "$0" ] && [ "$0" != "$SELF" ]; then
    mkdir -p "$BASE" 2>/dev/null
    if cp -f "$0" "$SELF" 2>/dev/null; then
      chmod 700 "$SELF" 2>/dev/null
    else
      warn "Nao consegui copiar o script para $SELF (autostart/labctl podem falhar)."
    fi
  fi

  # doctor precisa rodar mesmo em arquitetura nao suportada.
  if [ "$CMD" = doctor ]; then
    detect_device
    case "$(uname -m 2>/dev/null)" in
      aarch64|arm64) ROOTFS_FILE="ArchLinuxARM-aarch64-latest.tar.gz" ;;
      armv7l|armv8l|arm) ROOTFS_FILE="ArchLinuxARM-armv7-latest.tar.gz" ;;
      *) ROOTFS_FILE="ArchLinuxARM-aarch64-latest.tar.gz" ;;
    esac
    cmd_doctor
    exit $?
  fi

  # config/mirror nao precisam de rootfs nem de arquitetura ARM para funcionar.
  case "$CMD" in
    config) cmd_config "$@"; exit $? ;;
    mirror) cmd_mirror "$@"; exit $? ;;
  esac

  finalize_config

  case "$CMD" in
    install)
      need_root
      ensure_global_ns "$@"
      trap cleanup EXIT
      trap 'exit 130' INT
      trap 'exit 143' TERM
      cmd_install ;;
    start)
      need_root; ensure_global_ns "$@"
      trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
      acquire_lock; cmd_start ;;
    stop)
      need_root; ensure_global_ns "$@"
      trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
      acquire_lock; cmd_stop ;;
    restart)
      need_root; ensure_global_ns "$@"
      trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
      acquire_lock; cmd_restart ;;
    status)
      cmd_status ;;
    info)
      cmd_info ;;
    doctor)
      cmd_doctor ;;
    shell)
      need_root; ensure_global_ns "$@"
      cmd_shell "$@" ;;
    exec)
      need_root; ensure_global_ns "$@"
      [ "${1:-}" = "--" ] && shift
      cmd_exec "$@" ;;
    pacman)
      need_root; ensure_global_ns "$@"
      [ "${1:-}" = "--" ] && shift
      trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
      acquire_lock; cmd_pacman "$@" ;;
    update)
      need_root; ensure_global_ns "$@"
      trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
      acquire_lock; cmd_update ;;
    ip)
      show_access ;;
    wake)
      need_root; cmd_wake ;;
    standby)
      need_root; cmd_standby ;;
    tailscale)
      need_root; ensure_global_ns "$@"
      case "${1:-status}" in
        on|off|login)
          trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
          acquire_lock ;;
      esac
      cmd_tailscale "$@" ;;
    autostart)
      need_root
      trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
      acquire_lock; cmd_autostart "$@" ;;
    backup)
      need_root; ensure_global_ns "$@"
      trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
      acquire_lock; cmd_backup "$@" ;;
    uninstall)
      need_root; ensure_global_ns "$@"
      [ "${1:-}" = "--force" ] && { FORCE=1; shift; }
      trap cleanup EXIT; trap 'exit 130' INT; trap 'exit 143' TERM
      acquire_lock; cmd_uninstall ;;
    *)
      err "Comando desconhecido: $CMD"
      usage
      exit 2 ;;
  esac
}

# Permite carregar o script em testes sem executar o main.
if [ "${ARCHLAB_LIB:-0}" != 1 ]; then
  main "$@"
fi




