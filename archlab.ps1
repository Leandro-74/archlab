# =============================================================================
#  archlab.ps1 - bootstrap do archlab no PC (Windows / PowerShell)
#
#  Detecta o device via adb, confere os requisitos, envia o archlab.sh e roda
#  os comandos como root no Android. Nao precisa abrir shell no celular.
#
#  Uso: archlab.cmd [comando] [opcoes]   (-h para a ajuda do host)
# =============================================================================

#Requires -Version 5.1

$ErrorActionPreference = 'Continue'
$VERSION = '2.0.0-dev'

$DEV_DIR       = '/data/local/tmp/archlab'
$UPLOAD_DIR    = "$DEV_DIR/upload"
$REMOTE_SCRIPT = "$DEV_DIR/archlab.sh"
$REMOTE_PRE    = "$DEV_DIR/preflight.sh"
$REMOTE_RUN    = "$DEV_DIR/run.sh"
$REMOTE_TMP    = "$DEV_DIR/pull.tmp"

# Opcoes do host
$optSerial  = $env:ANDROID_SERIAL
$optAdb     = $null
$optScript  = $null
$optNoPush  = $false
$optTty     = $null      # $null = automatico
$showHelp   = $false

$devArgs = New-Object System.Collections.Generic.List[string]

# ------------------------------- SAIDA ---------------------------------------
function Write-Info([string]$m) { Write-Host "==> $m" -ForegroundColor Cyan }
function Write-Ok([string]$m)   { Write-Host "  ok    $m" -ForegroundColor Green }
function Write-Warn([string]$m) { Write-Host "  aviso $m" -ForegroundColor Yellow }
function Write-Bad([string]$m)  { Write-Host "  erro  $m" -ForegroundColor Red }
function Stop-Fail([string]$m) {
  Write-Host ''
  Write-Bad $m
  Write-Host ''
  exit 1
}

# ------------------------------- ARGUMENTOS ----------------------------------
$argv = @($args)
$i = 0
while ($i -lt $argv.Count) {
  $a = [string]$argv[$i]
  if ($a -like '--serial=*') { $optSerial = $a.Substring(9); $i++; continue }
  if ($a -like '--adb=*')    { $optAdb = $a.Substring(6); $i++; continue }
  if ($a -like '--file=*')   { $optScript = $a.Substring(7); $i++; continue }
  if ($a -eq '-s' -or $a -eq '--serial' -or $a -eq '--adb' -or $a -eq '--file') {
    if ($i + 1 -ge $argv.Count) { Stop-Fail "$a exige um valor." }
    $val = [string]$argv[$i + 1]
    if ($a -eq '-s' -or $a -eq '--serial') { $optSerial = $val }
    elseif ($a -eq '--adb')  { $optAdb = $val }
    else                     { $optScript = $val }
    $i += 2; continue
  }
  if ($a -eq '--no-push')  { $optNoPush = $true; $i++; continue }
  if ($a -eq '--tty')      { $optTty = $true; $i++; continue }
  if ($a -eq '--no-tty')   { $optTty = $false; $i++; continue }
  if (($a -eq '-h' -or $a -eq '--help' -or $a -eq '/?') -and $devArgs.Count -eq 0) {
    $showHelp = $true; $i++; continue
  }

  if ($a -match "[`r`n]") { Stop-Fail 'Argumento com quebra de linha nao e suportado.' }
  $devArgs.Add($a)
  $i++
}

# ------------------------------- HELP ----------------------------------------
function Show-Help() {
  Write-Host @'
archlab - Arch Linux ARM em chroot no Android (bootstrap via adb)

Uso:
  archlab.cmd                          wizard se nao houver lab; painel se ja houver
  archlab.cmd menu                     abre o painel de operacoes
  archlab.cmd install [opcoes]         instala (wizard, --yes ou --config)
  archlab.cmd status                   estado do lab e como conectar
  archlab.cmd doctor                   diagnostico de requisitos
  archlab.cmd shell                    shell root dentro do chroot
  archlab.cmd exec -- CMD [args]       executa um comando no chroot
  archlab.cmd pacman -- -Syu           pacman no chroot
  archlab.cmd start | stop | restart   liga/desliga o lab
  archlab.cmd wake | standby           wakelock do Android (celular acordado/dormindo)
  archlab.cmd backup [arquivo]         cria backup do rootfs no device
  archlab.cmd pull [arquivo] [local]   baixa o backup para o PC
  archlab.cmd forward [porta]          adb forward para SSH via USB
  archlab.cmd logs [n]                 ultimas n linhas do log (padrao 200)
  archlab.cmd devices                  lista devices e requisitos
  archlab.cmd help                     ajuda completa do archlab.sh (install)

Opcoes do host (nao vao para o device):
  -s, --serial SERIAL   escolhe o device (padrao: unico conectado)
      --adb CAMINHO     caminho do adb (padrao: PATH)
      --file CAMINHO    archlab.sh local a enviar (padrao: ao lado deste)
      --no-push         nao reenvia o archlab.sh (usa o que ja esta no device)
      --tty / --no-tty  forca/desliga terminal interativo
  -h, --help            esta ajuda

Arquivos locais sao enviados sozinhos quando usados como argumento:
  --config ARQ    --ssh-key ARQ    --rootfs ARQ

Qualquer outro argumento e repassado ao archlab.sh no device.
Ex.: archlab.cmd install --yes --config .\meu.env --ssh-key .\id.pub
'@ -ForegroundColor Gray
}

if ($showHelp) { Show-Help; exit 0 }

# ------------------------------- ADB -----------------------------------------
function Find-Adb() {
  if ($optAdb) {
    if (Test-Path -LiteralPath $optAdb) { return (Resolve-Path -LiteralPath $optAdb).Path }
    Stop-Fail "adb nao encontrado em: $optAdb"
  }
  $c = Get-Command adb -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }

  $cands = @(
    (Join-Path $env:LOCALAPPDATA 'Android\Sdk\platform-tools\adb.exe'),
    (Join-Path $env:USERPROFILE 'platform-tools\adb.exe'),
    (Join-Path $env:ProgramFiles 'platform-tools\adb.exe'),
    'C:\platform-tools\adb.exe'
  )
  foreach ($p in $cands) {
    if ($p -and (Test-Path -LiteralPath $p)) { return $p }
  }
  # PATH gravado no registro: pega o caso "adicionei ao PATH mas o console
  # atual ainda nao sabe".
  $persisted = @()
  $persisted += ([Environment]::GetEnvironmentVariable('PATH', 'Machine') -split ';')
  $persisted += ([Environment]::GetEnvironmentVariable('PATH', 'User') -split ';')
  foreach ($dir in $persisted) {
    if (-not $dir) { continue }
    $p = Join-Path $dir 'adb.exe'
    if (Test-Path -LiteralPath $p) { return $p }
  }
  $dl = Join-Path $env:USERPROFILE 'Downloads'
  if (Test-Path -LiteralPath $dl) {
    $f = Get-ChildItem -LiteralPath $dl -Filter 'adb.exe' -Recurse -Depth 6 -ErrorAction SilentlyContinue |
         Select-Object -First 1
    if ($f) { return $f.FullName }
  }
  Stop-Fail "adb nao encontrado. Coloque o platform-tools no PATH ou use --adb CAMINHO."
}

$script:AdbExe = Find-Adb
$script:Serial = $null

function Adb-Run([string[]]$a) {
  # '' | ...: da um stdin proprio ao adb para que comandos de apoio nao
  # consumam a entrada (pipe/redirecionamento) destinada ao comando final.
  '' | & $script:AdbExe @a
  return $LASTEXITCODE
}

function Adb-Out([string[]]$a) {
  $o = '' | & $script:AdbExe @a 2>&1
  $code = $LASTEXITCODE
  return @{ Out = @($o | ForEach-Object { "$_" }); Code = $code }
}

function Get-AdbDevices() {
  $r = Adb-Out @('devices')
  $list = @()
  foreach ($ln in $r.Out) {
    if ($ln -match '^(\S+)\s+(device|unauthorized|offline|no|recovery|sideload|bootloader)\b') {
      $list += [pscustomobject]@{ Serial = $Matches[1]; State = $Matches[2] }
    }
  }
  return @($list)
}

function Select-Device() {
  $devs = Get-AdbDevices
  if ($optSerial) {
    $d = $devs | Where-Object { $_.Serial -eq $optSerial } | Select-Object -First 1
    if (-not $d) { Stop-Fail "Device '$optSerial' nao encontrado. Rode: archlab.cmd devices" }
    if ($d.State -ne 'device') {
      Stop-Fail "Device '$optSerial' esta '$($d.State)'. Autorize a depuracao USB no celular e tente de novo."
    }
    $script:Serial = $optSerial
    return
  }
  $ready = @($devs | Where-Object { $_.State -eq 'device' })
  if ($ready.Count -eq 1) { $script:Serial = $ready[0].Serial; return }
  if ($ready.Count -gt 1) {
    Write-Bad 'Mais de um device conectado. Escolha um com -s SERIAL:'
    $ready | ForEach-Object { Write-Host "    $($_.Serial)" }
    Write-Host ''
    exit 1
  }
  if ($devs.Count -gt 0) {
    Write-Bad 'Device encontrado, mas nao esta pronto:'
    $devs | ForEach-Object { Write-Host "    $($_.Serial)  $($_.State)" }
    Write-Host ''
    Write-Host 'Autorize a depuracao USB no celular (aceite o aviso) e rode de novo.'
    exit 1
  }
  Stop-Fail 'Nenhum device conectado. Ligue a depuracao USB e autorize o PC.'
}

# ------------------------------- UTIL ----------------------------------------
function Write-DeviceFile([string]$path, [string]$text) {
  $uni = New-Object System.Text.UTF8Encoding($false)
  [IO.File]::WriteAllText($path, ($text -replace "`r`n", "`n"), $uni)
}

function Quote-Sh([string]$s) {
  return "'" + $s.Replace("'", "'\''") + "'"
}

function Push-File([string]$local, [string]$remote, [switch]$Progress) {
  if ($Progress) {
    '' | & $script:AdbExe -s $script:Serial push $local $remote
    if ($LASTEXITCODE -ne 0) { Stop-Fail "Falha ao enviar $local para o device." }
  } else {
    $r = Adb-Out @('-s', $script:Serial, 'push', $local, $remote)
    if ($r.Code -ne 0) { Stop-Fail "Falha ao enviar $local para o device.`n$($r.Out -join "`n")" }
  }
}

function Ensure-Remote() {
  $r = Adb-Out @('-s', $script:Serial, 'shell', "mkdir -p $DEV_DIR $UPLOAD_DIR")
  if ($r.Code -ne 0) {
    Stop-Fail "Nao consegui preparar $DEV_DIR no device.`n$($r.Out -join "`n")"
  }
}

function Invoke-RootScript([string]$localFile, [string]$remoteFile) {
  Push-File $localFile $remoteFile
  return (Adb-Run @('-s', $script:Serial, 'shell', "su -c 'sh $remoteFile'"))
}

# ------------------------------- PREFLIGHT -----------------------------------
$preflightText = @'
#!/system/bin/sh
# gerado por archlab.ps1 - apenas leitura
p() { printf '%s=%s\n' "$1" "$2"; }
p UID      "$(id -u 2>/dev/null)"
p MODEL    "$(getprop ro.product.model 2>/dev/null)"
p DEVICE   "$(getprop ro.product.device 2>/dev/null)"
p ANDROID  "$(getprop ro.build.version.release 2>/dev/null)"
p SDK      "$(getprop ro.build.version.sdk 2>/dev/null)"
p ABI      "$(getprop ro.product.cpu.abilist 2>/dev/null)"
p ARCH     "$(uname -m 2>/dev/null)"
p FREE_KB  "$(df -k /data 2>/dev/null | tail -n 1 | tr -s ' ' | cut -d' ' -f4)"
p PAGESIZE "$(getconf PAGE_SIZE 2>/dev/null)"
p SELINUX  "$(getenforce 2>/dev/null)"

BB=""
for b in /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox /data/adb/magisk/busybox \
         /data/adb/modules/busybox-ndk/system/bin/busybox /system/xbin/busybox /system/bin/busybox; do
  if [ -x "$b" ]; then BB="$b"; break; fi
done
p BUSYBOX "$BB"

if command -v tar >/dev/null 2>&1; then p TAR yes; else p TAR no; fi
if command -v gzip >/dev/null 2>&1; then p GZIP yes; else p GZIP no; fi

CH=none
if command -v chroot >/dev/null 2>&1; then
  CH=system
elif [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx chroot; then
  CH=busybox
fi
p CHROOT "$CH"

DL=none
if command -v curl >/dev/null 2>&1; then
  DL=curl
elif command -v wget >/dev/null 2>&1; then
  DL=wget
elif [ -n "$BB" ] && "$BB" --list 2>/dev/null | grep -qx wget; then
  DL="busybox wget"
fi
p DOWNLOAD "$DL"

if [ -d /data/adb/ksu ] || [ -d /data/adb/ksunext ]; then
  RM=KernelSU
elif [ -d /data/adb/ap ] || [ -d /data/adb/apatch ]; then
  RM=APatch
elif [ -d /data/adb/magisk ]; then
  RM=Magisk
elif command -v su >/dev/null 2>&1; then
  RM=su
else
  RM=nenhum
fi
p ROOTMGR "$RM"

if [ -f /data/local/archlab/rootfs/usr/bin/pacman ]; then p INSTALLED yes; else p INSTALLED no; fi

# usuario/porta SSH do lab, para o painel abrir o terminal ja conectado
LABCFG=/data/local/archlab/config.env
p LAB_USER "$(grep '^LAB_USER=' "$LABCFG" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'")"
p SSH_PORT "$(grep '^SSH_PORT=' "$LABCFG" 2>/dev/null | head -n1 | cut -d= -f2- | tr -d "'")"

if [ -f /data/local/archlab/state/awake ]; then p AWAKE yes; else p AWAKE no; fi
if [ -f /data/adb/service.d/99-archlab.sh ]; then p AUTOSTART yes; else p AUTOSTART no; fi
'@

function Get-Probe() {
  $tmp = Join-Path $env:TEMP 'archlab-preflight.sh'
  Write-DeviceFile $tmp $preflightText
  Push-File $tmp $REMOTE_PRE

  $r = Adb-Out @('-s', $script:Serial, 'shell', "su -c 'sh $REMOTE_PRE'")
  $h = @{}
  foreach ($ln in $r.Out) {
    $idx = $ln.IndexOf('=')
    if ($idx -gt 0) { $h[$ln.Substring(0, $idx)] = $ln.Substring($idx + 1) }
  }
  if ($h.Count -eq 0 -or -not $h.ContainsKey('UID')) {
    $msg = ($r.Out | Where-Object { $_ -match '\S' }) -join "`n"
    if ($msg -match 'su: (inaccessible|not found|denied)') {
      Stop-Fail "O su do device recusou o pedido. Abra o gerenciador de root e autorize o shell/adb.`n$msg"
    }
    Stop-Fail "Nao consegui rodar o preflight como root.`n$msg"
  }
  return $h
}

function Show-Probe($h) {
  $freeMb = 0
  if ($h['FREE_KB'] -match '^\d+$') { $freeMb = [int]([double]$h['FREE_KB'] / 1024) }

  Write-Host ("Device : {0} ({1}) - Android {2} (SDK {3})" -f $h['MODEL'], $h['DEVICE'], $h['ANDROID'], $h['SDK'])
  Write-Host ("Serial : {0}" -f $script:Serial)
  Write-Host ("Root   : {0} (uid {1})" -f $h['ROOTMGR'], $h['UID'])
  Write-Host ("Arch   : {0} ({1})" -f $h['ARCH'], $h['ABI'])

  $ok = $true

  if ($h['UID'] -eq '0') {
    Write-Ok 'root disponivel'
  } else {
    Write-Bad 'sem root (uid != 0)'
    Write-Host '        Habilite Magisk/KernelSU/APatch e autorize o su para o shell.'
    $ok = $false
  }

  if ($h['ARCH'] -in @('aarch64', 'arm64', 'armv7l', 'armv8l', 'arm')) {
    Write-Ok "arquitetura suportada ($($h['ARCH']))"
  } else {
    Write-Bad "arquitetura nao suportada: $($h['ARCH']) (use aarch64/armv7)"
    $ok = $false
  }

  if ($h['CHROOT'] -ne 'none') {
    Write-Ok "chroot disponivel ($($h['CHROOT']))"
  } else {
    Write-Bad 'chroot nao encontrado (instale busybox com applet chroot)'
    $ok = $false
  }

  if ($h['TAR'] -eq 'yes') {
    Write-Ok 'tar disponivel'
  } else {
    Write-Bad 'tar nao encontrado (instale busybox)'
    $ok = $false
  }

  if ($freeMb -ge 4096) {
    Write-Ok ("espaco em /data: {0:N1} GB livres" -f ($freeMb / 1024))
  } else {
    Write-Warn ("espaco em /data: {0} MB (recomendado 6 GB; minimo 4 GB)" -f $freeMb)
  }

  if ($h['DOWNLOAD'] -ne 'none') {
    Write-Ok "download: $($h['DOWNLOAD'])"
  } else {
    Write-Warn 'sem curl/wget; use --rootfs com um tarball local'
  }

  if ($h['GZIP'] -ne 'yes' -and $h['DOWNLOAD'] -eq 'none') {
    Write-Warn 'sem gzip e sem download: o tarball precisa estar descompactavel'
  }

  if ($h['SELINUX']) { Write-Host ("SELinux: {0}" -f $h['SELINUX']) }
  if ($h['INSTALLED'] -eq 'yes') { Write-Host 'Lab    : instalado em /data/local/archlab' }
  if ($h['PAGESIZE'] -eq '16384') { Write-Warn 'paginas de 16 KB (alguns binarios podem falhar)' }

  return $ok
}

# ------------------------------- ARQUIVOS LOCAIS ------------------------------
function Resolve-RemotePath([string]$value, [string]$remoteName, [switch]$Big) {
  if ([string]::IsNullOrWhiteSpace($value)) { return $value }
  if ($value.StartsWith('/')) { return $value }              # ja e caminho do device
  if (-not (Test-Path -LiteralPath $value -PathType Leaf)) {
    return $value                                            # deixa o archlab reclamar
  }
  $item = Get-Item -LiteralPath $value
  $remote = "$UPLOAD_DIR/$remoteName"

  if ($Big) {
    $r = Adb-Out @('-s', $script:Serial, 'shell', "wc -c < $remote 2>/dev/null")
    $remoteSize = ($r.Out -join '').Trim()
    if ($remoteSize -eq "$($item.Length)") {
      Write-Info "Tarball ja esta no device ($([math]::Round($item.Length / 1MB, 1)) MB)"
      return $remote
    }
    Write-Info ("Enviando {0} ({1:N1} MB)... isso pode demorar" -f $item.Name, ($item.Length / 1MB))
    Push-File $item.FullName $remote -Progress
    return $remote
  }

  Push-File $item.FullName $remote
  return $remote
}

function Convert-LocalArgs([string[]]$in) {
  $out = New-Object System.Collections.Generic.List[string]
  $j = 0
  while ($j -lt $in.Count) {
    $a = $in[$j]
    $handled = $false

    foreach ($spec in @(
      @{ Flag = '--config';  Name = 'config.env'; Big = $false },
      @{ Flag = '--ssh-key'; Name = 'ssh.pub';    Big = $false },
      @{ Flag = '--pubkey';  Name = 'ssh.pub';    Big = $false },
      @{ Flag = '--rootfs';  Name = $null;        Big = $true  }
    )) {
      $flag = $spec.Flag
      if ($a -eq $flag) {
        if ($j + 1 -ge $in.Count) { Stop-Fail "$flag exige um valor." }
        $val = $in[$j + 1]
        $name = $spec.Name
        if (-not $name) { $name = [IO.Path]::GetFileName($val) }
        $remote = Resolve-RemotePath $val $name -Big:$spec.Big
        $out.Add($flag); $out.Add($remote)
        $j += 2; $handled = $true; break
      }
      if ($a -like "$flag=*") {
        $val = $a.Substring($flag.Length + 1)
        $name = $spec.Name
        if (-not $name) { $name = [IO.Path]::GetFileName($val) }
        $remote = Resolve-RemotePath $val $name -Big:$spec.Big
        $out.Add("$flag=$remote")
        $j++; $handled = $true; break
      }
    }
    if ($handled) { continue }

    $out.Add($a)
    $j++
  }
  return @($out)
}

# ------------------------------- ACOES ---------------------------------------
$script:LastCode = 0

function Test-NeedsInput {
  param([string]$Cmd, [string[]]$A)
  if ($Cmd -eq 'shell') { return $true }
  if ($Cmd -eq 'uninstall' -and -not ($A -contains '--force')) { return $true }
  if ($Cmd -eq 'install') {
    if ($A -contains '--interactive' -or $A -contains '-i') { return $true }
    if (-not ($A -contains '--yes' -or $A -contains '-y' -or $A -contains '--no-interactive')) { return $true }
  }
  if ($Cmd -eq 'tailscale' -and ($A -contains 'login')) { return $true }
  return $false
}

# Envia um run.sh com os argumentos ja escapados e executa no device.
# NeedsInput: o comando pode ler do stdin (wizard, shell, uninstall). Sem isso o
# adb recebe um stdin proprio, para nao consumir a entrada do painel/pipeline.
function Invoke-Lab {
  param([string[]]$LabArgs, [bool]$NeedsInput = $false)

  $converted = Convert-LocalArgs $LabArgs
  $quoted = @()
  foreach ($a in $converted) { $quoted += (Quote-Sh $a) }
  $runBody = "#!/system/bin/sh`n# gerado por archlab.ps1`nexec sh $REMOTE_SCRIPT $($quoted -join ' ')`n"
  $tmpRun = Join-Path $env:TEMP 'archlab-run.sh'
  Write-DeviceFile $tmpRun $runBody
  Push-File $tmpRun $REMOTE_RUN

  $useTty = ($NeedsInput -and -not [Console]::IsInputRedirected)
  if ($optTty -ne $null) { $useTty = ([bool]$optTty -and -not [Console]::IsInputRedirected) }

  $shellArgs = @('-s', $script:Serial, 'shell')
  if ($useTty) { $shellArgs += '-t' }
  $shellArgs += "su -c 'sh $REMOTE_RUN'"

  if ($NeedsInput) {
    & $script:AdbExe @shellArgs
  } else {
    '' | & $script:AdbExe @shellArgs
  }
  $script:LastCode = $LASTEXITCODE
}

function Invoke-Forward {
  param([string]$Port = '2222')
  Select-Device
  if (-not $Port) { $Port = '2222' }
  if ($Port -notmatch '^\d+$') { Write-Bad 'forward: porta invalida (use um numero).'; $script:LastCode = 1; return }
  $r = Adb-Out @('-s', $script:Serial, 'forward', "tcp:$Port", "tcp:$Port")
  if ($r.Code -ne 0) {
    Write-Bad "adb forward falhou.`n$($r.Out -join "`n")"
    $script:LastCode = 1
    return
  }
  Write-Ok "USB: localhost:$Port -> device:$Port"
  Write-Host ''
  Write-Host "  ssh -p $Port <usuario>@127.0.0.1"
  $script:LastCode = 0
}

function Connect-Ssh {
  param($Probe)
  Select-Device
  $port = $Probe['SSH_PORT']; if (-not $port) { $port = '2222' }
  $user = $Probe['LAB_USER']; if (-not $user) { $user = 'root' }

  $r = Adb-Out @('-s', $script:Serial, 'forward', "tcp:$port", "tcp:$port")
  if ($r.Code -ne 0) {
    Write-Bad "adb forward falhou.`n$($r.Out -join "`n")"
    $script:LastCode = 1
    return
  }
  if (-not (Get-Command ssh -CommandType Application -ErrorAction SilentlyContinue)) {
    Write-Bad 'ssh nao encontrado no Windows. Instale o OpenSSH Client (Configuracoes > Apps > Recursos opcionais).'
    $script:LastCode = 1
    return
  }

  # Janela separada para o SSH (o painel continua utilizavel). cmd /k mantem a
  # janela aberta se a conexao falhar, para dar tempo de ler o erro.
  $cmdLine = "ssh -p $port $user@127.0.0.1"
  Write-Info "Abrindo terminal: $cmdLine"
  Start-Process -FilePath 'cmd.exe' -ArgumentList '/k', $cmdLine
  $script:LastCode = 0
}

function Show-Logs {
  param([string]$N = '200')
  Select-Device
  if (-not $N) { $N = '200' }
  if ($N -notmatch '^\d+$') { Write-Bad 'logs: quantidade invalida (use um numero).'; $script:LastCode = 1; return }
  & $script:AdbExe -s $script:Serial shell "su -c 'tail -n $N /data/local/archlab/archlab.log'"
  $script:LastCode = $LASTEXITCODE
}

function Invoke-Pull {
  param([string]$Remote = '', [string]$Local = '')
  Select-Device

  if (-not $Remote) {
    $r = Adb-Out @('-s', $script:Serial, 'shell', "su -c 'ls -t /data/local/archlab/backup-*.tar.gz 2>/dev/null | head -n 1'")
    $Remote = (($r.Out | Where-Object { $_ -match '\S' }) | Select-Object -First 1)
    if (-not $Remote) {
      Write-Bad 'Nenhum backup encontrado em /data/local/archlab. Rode antes: archlab.cmd backup'
      $script:LastCode = 1
      return
    }
  }
  if (-not $Local) { $Local = [IO.Path]::GetFileName($Remote) }

  $tmpSh = Join-Path $env:TEMP 'archlab-pull.sh'
  $script = @"
#!/system/bin/sh
cp $(Quote-Sh $Remote) $REMOTE_TMP || exit 1
chmod 644 $REMOTE_TMP
"@
  Write-DeviceFile $tmpSh $script
  $code = Invoke-RootScript $tmpSh "$DEV_DIR/pull.sh"
  if ($code -ne 0) {
    Write-Bad "Nao consegui preparar $Remote para copia (arquivo existe?)."
    $script:LastCode = 1
    return
  }

  Write-Info "Baixando $Remote"
  $code = Adb-Run @('-s', $script:Serial, 'pull', $REMOTE_TMP, $Local)
  Adb-Run @('-s', $script:Serial, 'shell', "rm -f $REMOTE_TMP $DEV_DIR/pull.sh") | Out-Null
  if ($code -ne 0) { Write-Bad 'adb pull falhou.'; $script:LastCode = 1; return }
  Write-Host ''
  Write-Ok "Salvo em: $(Resolve-Path -LiteralPath $Local -ErrorAction SilentlyContinue)"
  $script:LastCode = 0
}

function Show-Menu {
  while ($true) {
    $probe = Get-Probe
    Write-Host ''
    Write-Host ("Archlab {0} - painel  [{1}]" -f $VERSION, $script:Serial) -ForegroundColor Cyan
    Write-Host ("Lab: instalado | energia: {0} | autostart: {1}" -f `
      $(if ($probe['AWAKE'] -eq 'yes') { 'ATIVO (wakelock)' } else { 'standby' }), `
      $(if ($probe['AUTOSTART'] -eq 'yes') { 'on' } else { 'off' }))
    Write-Host '------------------------------------------------------------'
    Write-Host '  1) status          estado, IPs e acesso SSH'
    Write-Host '  2) shell           shell root no chroot'
    Write-Host '  3) exec            rodar um comando no chroot'
    Write-Host '  4) pacman          instalar/atualizar pacotes'
    Write-Host '  5) doctor          diagnostico do device'
    Write-Host '  6) logs            ultimas linhas do log'
    Write-Host '  7) backup          cria um .tar.gz do rootfs'
    Write-Host '  8) pull            baixa o backup mais recente'
    Write-Host '  9) start/stop      liga, desliga ou reinicia o lab'
    Write-Host ' 10) reconfigurar    wizard de install (mantem os dados)'
    Write-Host ' 11) ssh usb         abre um terminal SSH via USB (nova janela)'
    Write-Host ' 12) uninstall       remove o Arch do device'
    Write-Host ' 13) energia/boot    wakelock (Enter alterna), autostart, tailscale'
    Write-Host '  0) sair'
    Write-Host ''
    $c = Read-Host 'Opcao'
    if ($null -eq $c) { return }
    $c = $c.Trim()

    switch ($c) {
      '0' { return }
      ''  { return }
      '1' { Invoke-Lab @('status') }
      '2' { Invoke-Lab -LabArgs @('shell') -NeedsInput $true }
      '3' {
        $line = Read-Host 'Comando (ex.: uname -a)'
        if ($line) { Invoke-Lab -LabArgs (@('exec', '--', 'sh', '-c', $line)) }
      }
      '4' {
        $line = Read-Host 'Args do pacman (ex.: -Syu | -S vim)'
        if ($line) { Invoke-Lab -LabArgs (@('pacman', '--') + ($line -split '\s+')) }
      }
      '5' { Invoke-Lab @('doctor') }
      '6' { Show-Logs '30' }
      '7' {
        Write-Info 'Criando backup (pode demorar)...'
        Invoke-Lab @('backup')
        if ($script:LastCode -eq 0) { Write-Host 'Use 9) start para religar o lab.' }
      }
      '8' { Invoke-Pull }
      '9' {
        $s = Read-Host 'start / stop / restart [start]'
        if (-not $s) { $s = 'start' }
        $s = $s.Trim()
        if (@('start', 'stop', 'restart') -contains $s) { Invoke-Lab -LabArgs @($s) }
        else { Write-Bad "opcao invalida: $s" }
      }
      '10' { Invoke-Lab -LabArgs @('install') -NeedsInput $true }
      '11' { Connect-Ssh $probe }
      '12' {
        Invoke-Lab -LabArgs @('uninstall') -NeedsInput $true
        if ((Get-Probe)['INSTALLED'] -ne 'yes') {
          Write-Host ''
          Write-Info 'Lab removido. Rode "archlab.cmd" de novo para instalar.'
          return
        }
      }
      '13' {
        $line = Read-Host 'Enter alterna o wakelock | wake/standby | autostart on|off | tailscale on|off|status'
        if (-not $line) { $line = if ($probe['AWAKE'] -eq 'yes') { 'standby' } else { 'wake' } }
        $parts = @($line.Trim() -split '\s+')
        if (@('wake', 'standby', 'autostart', 'tailscale') -contains $parts[0]) {
          Invoke-Lab -LabArgs $parts
        } else {
          Write-Bad "opcao invalida: $line"
        }
      }
      default { Write-Bad "opcao invalida: $c" }
    }

    if ($c -ne '0') {
      Write-Host ''
      Read-Host 'Enter para voltar ao painel' | Out-Null
    }
  }
}

# ------------------------------- COMANDOS DO HOST ----------------------------
$noArgs = ($devArgs.Count -eq 0)
$cmd = if ($noArgs) { 'install' } else { [string]$devArgs[0] }
$rest = @()
if ($devArgs.Count -gt 1) { $rest = @($devArgs.GetRange(1, $devArgs.Count - 1)) }

if ($cmd -eq 'devices' -or $cmd -eq 'device') {
  Select-Device
  Ensure-Remote
  Show-Probe (Get-Probe) | Out-Null
  exit 0
}

if ($cmd -eq 'forward') {
  Invoke-Forward -Port ([string]($rest | Select-Object -First 1))
  exit $script:LastCode
}

if ($cmd -eq 'logs') {
  Show-Logs -N ([string]($rest | Select-Object -First 1))
  exit $script:LastCode
}

if ($cmd -eq 'pull') {
  $r1 = ''; $r2 = ''
  if ($rest.Count -ge 1) { $r1 = [string]$rest[0] }
  if ($rest.Count -ge 2) { $r2 = [string]$rest[1] }
  Invoke-Pull -Remote $r1 -Local $r2
  exit $script:LastCode
}

# ------------------------------- FLUXO PRINCIPAL -----------------------------
Select-Device
Ensure-Remote

if (-not $optNoPush) {
  if (-not $optScript) {
    $optScript = Join-Path $PSScriptRoot 'archlab.sh'
  }
  if (-not (Test-Path -LiteralPath $optScript)) {
    Stop-Fail "archlab.sh nao encontrado em: $optScript (use --file CAMINHO)"
  }
  Push-File (Resolve-Path -LiteralPath $optScript).Path $REMOTE_SCRIPT
}

$probe = Get-Probe

# Sem lab instalado: wizard direto. Com lab: painel de operacoes.
if ($cmd -eq 'menu' -or $cmd -eq 'painel' -or ($noArgs -and $probe['INSTALLED'] -eq 'yes')) {
  if ($probe['INSTALLED'] -ne 'yes') {
    Stop-Fail 'Nenhum lab instalado neste device. Rode: archlab.cmd install'
  }
  Show-Menu
  exit 0
}

$essential = @('install', 'start', 'stop', 'restart', 'shell', 'exec', 'pacman',
               'update', 'backup', 'uninstall', 'tailscale', 'autostart', 'wake', 'standby')

$needCheck = ($cmd -eq 'install' -and -not ($devArgs -contains '--help' -or $devArgs -contains '-h'))
$needRoot  = ($essential -contains $cmd)

if ($needCheck) {
  Write-Info 'Conferindo requisitos do device'
  $ok = Show-Probe $probe
  Write-Host ''
  if (-not $ok) {
    Stop-Fail 'Requisitos minimos nao atendidos. Rode "archlab.cmd doctor" para detalhes.'
  }
} elseif ($needRoot -and $probe['UID'] -ne '0') {
  Stop-Fail 'Sem root no device (uid != 0). Habilite Magisk/KernelSU/APatch e autorize o su.'
}

$finalArgs = @($cmd) + $rest
$wantsInput = (Test-NeedsInput $cmd $finalArgs) -or ($optTty -eq $true)
Invoke-Lab -LabArgs $finalArgs -NeedsInput $wantsInput
exit $script:LastCode
