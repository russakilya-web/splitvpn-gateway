# setup-vbox.ps1 — разворачивает OpenWRT 23.05.6 в VirtualBox на Windows.
# Аналог setup-vbox.sh для macOS/Linux.
#
# Запуск (PowerShell, можно НЕ от админа):
#   cd C:\path\to\openwrt\test
#   powershell -ExecutionPolicy Bypass -File .\setup-vbox.ps1
#
# Что создаёт:
#   - VM "openwrt-gw" с двумя NIC: nic1=intnet 'splitlan' (LAN), nic2=NAT (WAN)
#   - LAN: 192.168.1.1, WAN: DHCP от VirtualBox NAT

$ErrorActionPreference = 'Stop'

# === Параметры (можно поменять) ===
$VmName      = 'openwrt-gw'
$OwrtVersion = '23.05.6'
$Workdir     = "$env:USERPROFILE\splitvpn-vbox"
$Intnet      = 'splitlan'

# === Внутреннее ===
$ImgUrl  = "https://downloads.openwrt.org/releases/$OwrtVersion/targets/x86/64/openwrt-$OwrtVersion-x86-64-generic-ext4-combined.img.gz"
$ImgGz   = "$Workdir\openwrt-$OwrtVersion.img.gz"
$ImgRaw  = "$Workdir\openwrt-$OwrtVersion.img"
$Vdi     = "$Workdir\$VmName.vdi"

function Log($msg) { Write-Host "[setup-vbox] $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Host "[setup-vbox] ERROR: $msg" -ForegroundColor Red; exit 1 }

# === Найти VBoxManage ===
$VBox = $null
$candidates = @(
    "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
    "$env:ProgramFiles(x86)\Oracle\VirtualBox\VBoxManage.exe",
    'VBoxManage'  # если в PATH
)
foreach ($c in $candidates) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { $VBox = $c; break }
    if (Test-Path $c) { $VBox = $c; break }
}
if (-not $VBox) { Die "VBoxManage не найден. Установи VirtualBox с https://www.virtualbox.org/" }
Log "VBoxManage: $VBox"

# === Создать workdir ===
if (-not (Test-Path $Workdir)) { New-Item -ItemType Directory -Path $Workdir | Out-Null }

# === 1. Скачать образ ===
if (-not (Test-Path $ImgRaw)) {
    if (-not (Test-Path $ImgGz)) {
        Log "Скачиваю $ImgUrl"
        # Invoke-WebRequest на старых PS медленный из-за progress bar — отключаем
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ImgUrl -OutFile $ImgGz
        $ProgressPreference = 'Continue'
    }
    Log "Распаковываю $ImgGz"
    # Powershell не имеет встроенного gunzip — используем .NET
    $in  = [System.IO.File]::OpenRead($ImgGz)
    $out = [System.IO.File]::Create($ImgRaw)
    $gz  = New-Object System.IO.Compression.GzipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    $gz.CopyTo($out)
    $gz.Close(); $in.Close(); $out.Close()
}

# === 2. Конвертировать в VDI ===
if (-not (Test-Path $Vdi)) {
    Log "Конвертирую в VDI: $Vdi"
    & $VBox convertfromraw --format VDI "$ImgRaw" "$Vdi"
    if ($LASTEXITCODE -ne 0) { Die "convertfromraw провалился" }
    Log "Расширяю до 256 MB"
    & $VBox modifymedium disk "$Vdi" --resize 256 | Out-Null
}

# === 3. Удалить старую VM ===
$existing = & $VBox list vms 2>$null
if ($existing -match "`"$VmName`"") {
    Log "Удаляю старую VM $VmName"
    & $VBox controlvm "$VmName" poweroff 2>$null
    Start-Sleep -Seconds 1
    & $VBox unregistervm "$VmName" --delete 2>$null
}

# === 4. Создать VM ===
Log "Создаю VM $VmName"
& $VBox createvm --name "$VmName" --ostype Linux26_64 --register | Out-Null
& $VBox modifyvm "$VmName" --memory 256 --cpus 1 --boot1 disk | Out-Null

# Storage
& $VBox storagectl "$VmName" --name "SATA" --add sata --controller IntelAhci | Out-Null
& $VBox storageattach "$VmName" --storagectl "SATA" --port 0 --type hdd --medium "$Vdi" | Out-Null

# Network: nic1 = LAN (intnet), nic2 = WAN (NAT)
& $VBox modifyvm "$VmName" --nic1 intnet --intnet1 "$Intnet" --nictype1 virtio | Out-Null
& $VBox modifyvm "$VmName" --nic2 nat   --nictype2 virtio | Out-Null

# Console serial для логов
& $VBox modifyvm "$VmName" --uart1 0x3F8 4 --uartmode1 file "$Workdir\$VmName.console.log" | Out-Null

Write-Host ""
Log "=== Готово ==="
Write-Host "Запуск VM:"
Write-Host "    & '$VBox' startvm $VmName --type gui       # с окном"
Write-Host "    & '$VBox' startvm $VmName --type headless  # без окна (логи: $Workdir\$VmName.console.log)"
Write-Host ""
Write-Host "После старта (~30s):"
Write-Host "  - Подними вторую VM в той же intnet '$Intnet' (Ubuntu / Windows / другой OpenWRT)"
Write-Host "  - С неё SSH:  ssh root@192.168.1.1   (пароль не задан, при первом входе задай passwd)"
Write-Host ""
Write-Host "Установка splitvpn:"
Write-Host "  wget -O- https://raw.githubusercontent.com/russakilya-web/splitvpn-gateway/master/openwrt/install.sh | sh"
