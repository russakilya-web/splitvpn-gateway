# setup-vbox.ps1 - deploys OpenWRT 23.05.6 in VirtualBox on Windows.
# Counterpart of setup-vbox.sh for macOS/Linux.
#
# Run (PowerShell, no admin needed):
#   cd C:\path\to\openwrt\test
#   powershell -ExecutionPolicy Bypass -File .\setup-vbox.ps1
#
# Creates:
#   - VM "openwrt-gw" with two NICs: nic1=intnet 'splitlan' (LAN), nic2=NAT (WAN)
#   - LAN: 192.168.1.1, WAN: DHCP from VirtualBox NAT

$ErrorActionPreference = 'Stop'

# === Settings (override if needed) ===
$VmName      = 'openwrt-gw'
$OwrtVersion = '23.05.6'
$Workdir     = "$env:USERPROFILE\splitvpn-vbox"
$Intnet      = 'splitlan'

# === Internal ===
$ImgUrl  = "https://downloads.openwrt.org/releases/$OwrtVersion/targets/x86/64/openwrt-$OwrtVersion-x86-64-generic-ext4-combined.img.gz"
$ImgGz   = "$Workdir\openwrt-$OwrtVersion.img.gz"
$ImgRaw  = "$Workdir\openwrt-$OwrtVersion.img"
$Vdi     = "$Workdir\$VmName.vdi"

function Log($msg) { Write-Host "[setup-vbox] $msg" -ForegroundColor Cyan }
function Die($msg) { Write-Host "[setup-vbox] ERROR: $msg" -ForegroundColor Red; exit 1 }

# === Find VBoxManage ===
$VBox = $null
$candidates = @(
    "$env:ProgramFiles\Oracle\VirtualBox\VBoxManage.exe",
    "${env:ProgramFiles(x86)}\Oracle\VirtualBox\VBoxManage.exe",
    'VBoxManage'
)
foreach ($c in $candidates) {
    if (Get-Command $c -ErrorAction SilentlyContinue) { $VBox = $c; break }
    if (Test-Path $c) { $VBox = $c; break }
}
if (-not $VBox) { Die "VBoxManage not found. Install VirtualBox from https://www.virtualbox.org/" }
Log "VBoxManage: $VBox"

# === Workdir ===
if (-not (Test-Path $Workdir)) { New-Item -ItemType Directory -Path $Workdir | Out-Null }

# === 1. Download image ===
if (-not (Test-Path $ImgRaw)) {
    if (-not (Test-Path $ImgGz)) {
        Log "Downloading $ImgUrl"
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ImgUrl -OutFile $ImgGz
        $ProgressPreference = 'Continue'
    }
    Log "Extracting $ImgGz"
    $in  = [System.IO.File]::OpenRead($ImgGz)
    $out = [System.IO.File]::Create($ImgRaw)
    $gz  = New-Object System.IO.Compression.GzipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
    $gz.CopyTo($out)
    $gz.Close(); $in.Close(); $out.Close()
}

# === 2. Convert to VDI ===
if (-not (Test-Path $Vdi)) {
    Log "Converting to VDI: $Vdi"
    & $VBox convertfromraw --format VDI "$ImgRaw" "$Vdi"
    if ($LASTEXITCODE -ne 0) { Die "convertfromraw failed" }
    Log "Resizing to 256 MB"
    & $VBox modifymedium disk "$Vdi" --resize 256 | Out-Null
}

# === 3. Remove old VM ===
$existing = & $VBox list vms 2>$null
if ($existing -match "`"$VmName`"") {
    Log "Removing old VM $VmName"
    & $VBox controlvm "$VmName" poweroff 2>$null
    Start-Sleep -Seconds 1
    & $VBox unregistervm "$VmName" --delete 2>$null
}

# === 4. Create VM ===
Log "Creating VM $VmName"
& $VBox createvm --name "$VmName" --ostype Linux26_64 --register | Out-Null
& $VBox modifyvm "$VmName" --memory 256 --cpus 1 --boot1 disk | Out-Null

# Storage
& $VBox storagectl "$VmName" --name "SATA" --add sata --controller IntelAhci | Out-Null
& $VBox storageattach "$VmName" --storagectl "SATA" --port 0 --type hdd --medium "$Vdi" | Out-Null

# Network: nic1 = LAN (intnet), nic2 = WAN (NAT)
& $VBox modifyvm "$VmName" --nic1 intnet --intnet1 "$Intnet" --nictype1 virtio | Out-Null
& $VBox modifyvm "$VmName" --nic2 nat   --nictype2 virtio | Out-Null

# Console serial for headless logs
& $VBox modifyvm "$VmName" --uart1 0x3F8 4 --uartmode1 file "$Workdir\$VmName.console.log" | Out-Null

Write-Host ""
Log "=== Done ==="
Write-Host "Start VM:"
Write-Host "    & '$VBox' startvm $VmName --type gui       # with window"
Write-Host "    & '$VBox' startvm $VmName --type headless  # headless (logs: $Workdir\$VmName.console.log)"
Write-Host ""
Write-Host "After boot (~30s):"
Write-Host "  - Start a second VM in the same intnet '$Intnet' (Ubuntu / Windows / another OpenWRT)"
Write-Host "  - SSH from there:  ssh root@192.168.1.1   (no password set; run passwd on first login)"
Write-Host ""
Write-Host "Install splitvpn:"
Write-Host "  wget -O- https://raw.githubusercontent.com/russakilya-web/splitvpn-gateway/master/openwrt/install.sh | sh"
