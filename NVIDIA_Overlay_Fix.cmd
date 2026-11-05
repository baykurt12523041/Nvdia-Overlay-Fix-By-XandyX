@echo off
setlocal EnableExtensions
title NVIDIA Overlay Fix v2
set "NVIDIA_FIX_SELF=%~f0"

rem ============================================================
rem  NVIDIA OVERLAY FIX v2
rem  NVIDIA App oyun ici overlay bozulmasi (yatay cizgiler) icin
rem  Windows + overlay ayar duzeltici.
rem
rem  Tasinabilir tek dosyadir. Kurulum gerektirmez.
rem  Cift tikla -> UAC izni -> menu.
rem
rem  Yaptigi isler:
rem   1) Overlay genisliginin 1 px azaltilmasini kapatir
rem   2) MPO (Multi-Plane Overlay) kapatir
rem   3) HAGS kapatir (istege bagli geri acilabilir)
rem   4) NVIDIA Overlay.exe yuksek performansli GPU'ya atar
rem
rem  Geri almak icin menu 3.
rem  Rapor: masaustune NVIDIA_Overlay_Rapor_<tarih>.txt
rem ============================================================

net session >nul 2>&1
if %errorlevel%==0 goto elevated

echo.
echo Yonetici izni isteniyor...
if "%~1"=="" (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
)
exit /b

:elevated
set "NVIDIA_FIX_MODE="
if /I "%~1"=="report" set "NVIDIA_FIX_MODE=report"
if /I "%~1"=="apply"  set "NVIDIA_FIX_MODE=apply"
if /I "%~1"=="revert" set "NVIDIA_FIX_MODE=revert"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%~f0'; $s=[IO.File]::ReadAllText($p); $i=$s.LastIndexOf('#PSSTART'); iex $s.Substring($i)"
if not defined NVIDIA_FIX_MODE pause
exit /b

#PSSTART
$ErrorActionPreference = 'Stop'

$script:Version = 'v2'
$script:Log = New-Object System.Collections.Generic.List[string]

function Add-Log {
    param([string]$Text = '')
    $script:Log.Add($Text)
    Write-Host $Text
}

function Add-Section {
    param([string]$Title)
    Add-Log ''
    Add-Log ('=' * 72)
    Add-Log $Title
    Add-Log ('=' * 72)
}

function Get-RegValue {
    param([string]$Path, [string]$Name)
    try {
        $item = Get-ItemProperty -Path $Path -Name $Name -ErrorAction Stop
        return $item.$Name
    } catch {
        return $null
    }
}

function Get-RegexValue {
    param([string]$Path, [string]$Pattern, [int]$Group = 1)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    try {
        $m = Select-String -Path $Path -Pattern $Pattern -ErrorAction SilentlyContinue | Select-Object -Last 1
        if (-not $m) { return $null }
        $mm = [regex]::Match($m.Line, $Pattern)
        if (-not $mm.Success) { return $null }
        if ($mm.Groups.Count -gt $Group) { return $mm.Groups[$Group].Value }
        return $mm.Value
    } catch {
        return $null
    }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $pr = New-Object Security.Principal.WindowsPrincipal($id)
    return $pr.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------------------------------------------------------------- yollar
$gfxKey      = 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers'
$dwmKey      = 'HKLM:\SOFTWARE\Microsoft\Windows\Dwm'
$overlayDir  = Join-Path $env:LOCALAPPDATA 'NVIDIA Corporation\NVIDIA Overlay'
$overlayFile = Join-Path $overlayDir 'overrides.json'
$stateDir    = Join-Path $env:LOCALAPPDATA 'NVIDIAOverlayFix'
$stateFile   = Join-Path $stateDir 'state.json'
$gpuPrefKey  = 'HKCU:\Software\Microsoft\DirectX\UserGpuPreferences'
$desktop     = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { $desktop = Join-Path $env:USERPROFILE 'Desktop' }

$debugLog   = Join-Path $overlayDir 'debug.log'
$consoleLog = Join-Path $overlayDir 'console.log'
$nativeLog  = Join-Path $overlayDir 'CxNative_NVIDIA Overlay.log'
$debugBak   = Join-Path $overlayDir 'debug.log.bak'
$consoleBak = Join-Path $overlayDir 'console.log.bak'
$nativeOld  = Join-Path $overlayDir 'CxNative_NVIDIA Overlay.1.log'

# ---------------------------------------------------------------- overlay exe bul
function Find-OverlayExe {
    $cands = New-Object System.Collections.Generic.List[string]
    if ($env:ProgramFiles) {
        $cands.Add((Join-Path $env:ProgramFiles 'NVIDIA Corporation\NVIDIA App\CEF\NVIDIA Overlay.exe'))
    }
    $pf86 = ${env:ProgramFiles(x86)}
    if ($pf86) {
        $cands.Add((Join-Path $pf86 'NVIDIA Corporation\NVIDIA App\CEF\NVIDIA Overlay.exe'))
    }
    try {
        $procPath = Get-Process 'NVIDIA Overlay' -ErrorAction SilentlyContinue |
                    Select-Object -First 1 -ExpandProperty Path
        if ($procPath) { $cands.Add($procPath) }
    } catch { }

    foreach ($c in $cands) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }

    $root = $null
    if ($env:ProgramFiles) { $root = Join-Path $env:ProgramFiles 'NVIDIA Corporation' }
    if ($root -and (Test-Path -LiteralPath $root)) {
        try {
            $f = Get-ChildItem -LiteralPath $root -Recurse -Filter 'NVIDIA Overlay.exe' -ErrorAction SilentlyContinue |
                 Select-Object -First 1
            if ($f) { return $f.FullName }
        } catch { }
    }
    return $null
}

# ---------------------------------------------------------------- sistem bilgisi
function Get-SystemInfo {
    $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)

    $display = $null
    foreach ($g in $gpus) {
        if ($g.CurrentHorizontalResolution -and [int]$g.CurrentHorizontalResolution -gt 0) {
            $display = $g
            break
        }
    }

    $nvidia = @($gpus | Where-Object { $_.Name -match 'NVIDIA' })
    $intel  = @($gpus | Where-Object { $_.Name -match 'Intel' })
    $amd    = @($gpus | Where-Object { $_.Name -match 'AMD|Radeon' })

    $dispName = ''
    $w = 0; $h = 0; $hz = 0
    if ($display) {
        $dispName = [string]$display.Name
        $w  = [int]$display.CurrentHorizontalResolution
        $h  = [int]$display.CurrentVerticalResolution
        $hz = [int]$display.CurrentRefreshRate
    }

    $hybrid = ($nvidia.Count -gt 0 -and $display -ne $null -and $dispName -notmatch 'NVIDIA')

    [pscustomobject]@{
        Gpus        = $gpus
        Count       = $gpus.Count
        HasNvidia   = ($nvidia.Count -gt 0)
        HasIntel    = ($intel.Count -gt 0)
        HasAmd      = ($amd.Count -gt 0)
        NvidiaName  = $(if ($nvidia.Count -gt 0) { [string]$nvidia[0].Name } else { '' })
        DisplayName = $dispName
        Width       = $w
        Height      = $h
        Refresh     = $hz
        Hybrid      = $hybrid
    }
}

$script:Info = Get-SystemInfo
$overlayExe  = Find-OverlayExe

# ---------------------------------------------------------------- rapor parcalari
function Add-ReportHeader {
    Add-Log 'NVIDIA OVERLAY TANI VE DUZELTME RAPORU'
    Add-Log ('Arac       : NVIDIA_Overlay_Fix.cmd {0}' -f $script:Version)
    Add-Log ('Tarih      : {0}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'))
    Add-Log ('Kullanici  : {0}' -f $env:USERNAME)
    Add-Log ('Bilgisayar : {0}' -f $env:COMPUTERNAME)
    Add-Log 'Not        : Bu arac cozunurlukten ve markadan bagimsizdir.'
}

function Add-SystemSection {
    $i = $script:Info
    Add-Section '1) SISTEM BILGILERI'

    try {
        $cs = Get-CimInstance Win32_ComputerSystem
        Add-Log ("Uretici / Model : {0} / {1}" -f $cs.Manufacturer, $cs.Model)
        Add-Log ("RAM             : {0:N1} GB" -f ($cs.TotalPhysicalMemory / 1GB))
        Add-Log ("Tur             : {0}" -f $(if ($cs.PCSystemType -eq 2) { 'Dizustu (laptop)' } else { 'Masaustu' }))
    } catch { Add-Log ("ComputerSystem okunamadi: {0}" -f $_.Exception.Message) }

    try {
        $os = Get-CimInstance Win32_OperatingSystem
        Add-Log ("Windows         : {0} {1} (Build {2})" -f $os.Caption, $os.Version, $os.BuildNumber)
    } catch { Add-Log ("OS okunamadi: {0}" -f $_.Exception.Message) }

    try {
        $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
        Add-Log ("CPU             : {0}" -f $cpu.Name)
    } catch { Add-Log ("CPU okunamadi: {0}" -f $_.Exception.Message) }

    Add-Log ''
    Add-Log 'Ekran adaptorleri:'
    foreach ($g in $i.Gpus) {
        Add-Log ("  - {0}" -f $g.Name)
        Add-Log ("    Surucu        : {0}" -f $g.DriverVersion)
        Add-Log ("    Cozunurluk    : {0}x{1} @ {2} Hz" -f $g.CurrentHorizontalResolution, $g.CurrentVerticalResolution, $g.CurrentRefreshRate)
    }
    if ($i.Count -eq 0) { Add-Log '  (adaptor okunamadi)' }

    Add-Log ''
    Add-Log 'NVIDIA / Intel yazilimlari:'
    try {
        $uninstall = @(
            'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        Get-ItemProperty $uninstall -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -match 'NVIDIA App|NVIDIA Grafik|NVIDIA Graphics|Intel.*Graphics|AMD Software' } |
            Sort-Object DisplayName |
            ForEach-Object { Add-Log ("  - {0} : {1}" -f $_.DisplayName, $_.DisplayVersion) }
    } catch { Add-Log ("Yazilim listesi okunamadi: {0}" -f $_.Exception.Message) }

    Add-Log ''
    Add-Log 'nvidia-smi:'
    try {
        $smiCmd  = Get-Command nvidia-smi -ErrorAction SilentlyContinue
        $smiPath = $null
        if ($smiCmd) { $smiPath = $smiCmd.Source }
        if (-not $smiPath) {
            foreach ($c in @("$env:ProgramFiles\NVIDIA Corporation\NVSMI\nvidia-smi.exe", "$env:SystemRoot\System32\nvidia-smi.exe")) {
                if (Test-Path -LiteralPath $c) { $smiPath = $c; break }
            }
        }
        if ($smiPath) {
            & $smiPath 2>$null | ForEach-Object { Add-Log ('  ' + $_) }
        } else {
            Add-Log '  nvidia-smi bulunamadi.'
        }
    } catch { Add-Log ("  nvidia-smi calistirilamadi: {0}" -f $_.Exception.Message) }
}

function Add-SettingsSection {
    $i = $script:Info
    Add-Section '2) EKRAN VE OVERLAY AYARLARI'

    Add-Log ("Ekrani suren adaptor : {0}" -f $(if ($i.DisplayName) { $i.DisplayName } else { 'bilinmiyor' }))
    Add-Log ("Cozunurluk           : {0}x{1} @ {2} Hz" -f $i.Width, $i.Height, $i.Refresh)
    Add-Log ("Hibrit (Optimus)     : {0}" -f $(if ($i.Hybrid) { 'EVET' } else { 'HAYIR' }))

    if ($i.Width -gt 0) {
        $full = $i.Width * 4
        $red  = ($i.Width - 1) * 4
        Add-Log ''
        Add-Log ("Tam genislik satir araligi    : {0} bayt  (256 ile bolum {1})" -f $full, ($full % 256))
        Add-Log ("1 px azaltilmis satir araligi : {0} bayt  (256 ile bolum {1})" -f $red, ($red % 256))
    }

    Add-Log ''
    Add-Log ("HAGS (HwSchMode)       : {0}   (2=acik, 1=kapali)" -f (Get-RegValue $gfxKey 'HwSchMode'))
    Add-Log ("MPO  (OverlayTestMode) : {0}   (5=kapali, bos=varsayilan)" -f (Get-RegValue $dwmKey 'OverlayTestMode'))

    if (Test-Path -LiteralPath $overlayFile) {
        Add-Log ("overrides.json         : {0}" -f ((Get-Content -LiteralPath $overlayFile -Raw).Trim()))
        Add-Log ("overrides.json readonly: {0}" -f (Get-Item -LiteralPath $overlayFile).IsReadOnly)
    } else {
        Add-Log 'overrides.json         : bulunamadi (NVIDIA App bir kez acilmamis olabilir)'
    }

    Add-Log ("Overlay exe            : {0}" -f $(if ($overlayExe) { $overlayExe } else { 'bulunamadi' }))
    if ($overlayExe) {
        $pref = Get-RegValue $gpuPrefKey $overlayExe
        Add-Log ("Overlay GPU tercihi    : {0}" -f $(if ($pref) { $pref } else { 'ayarlanmamis' }))
    }
}

function Add-OverlayLogSection {
    Add-Section '3) OVERLAY LOGLARI'

    if (Test-Path -LiteralPath $debugLog) {
        Add-Log ''
        Add-Log '--- debug.log (hibrit / boyut / olcek) ---'
        try {
            Select-String -Path $debugLog -Pattern 'hybrid|window size|stream initialized|display change|reduced|zoom' -ErrorAction SilentlyContinue |
                Select-Object -Last 30 | ForEach-Object { Add-Log $_.Line }
        } catch { Add-Log ("debug.log okunamadi: {0}" -f $_.Exception.Message) }
    } else {
        Add-Log 'debug.log bulunamadi.'
    }

    if (Test-Path -LiteralPath $consoleLog) {
        Add-Log ''
        Add-Log '--- console.log (oscWidthReduction / genislik / HDR) ---'
        try {
            Select-String -Path $consoleLog -Pattern 'oscWidthReduction|"width"|hdrMode|overlayLogicalWidth' -ErrorAction SilentlyContinue |
                Select-Object -Last 30 | ForEach-Object { Add-Log $_.Line }
        } catch { Add-Log ("console.log okunamadi: {0}" -f $_.Exception.Message) }
    } else {
        Add-Log 'console.log bulunamadi.'
    }

    if (Test-Path -LiteralPath $nativeLog) {
        Add-Log ''
        Add-Log '--- CxNative log: HDR / hata satirlari ---'
        try {
            Select-String -Path $nativeLog -Pattern 'HDR|Hdr|IsHdrActive|GetAIHDR|failed|0x800|error' -ErrorAction SilentlyContinue |
                Select-Object -Last 25 | ForEach-Object { Add-Log $_.Line }
        } catch { Add-Log ("CxNative log okunamadi: {0}" -f $_.Exception.Message) }
    }

    Add-Log ''
    Add-Log '--- ESKI OTURUM (sorunun yasandigi saat) ---'

    if (Test-Path -LiteralPath $consoleBak) {
        Add-Log 'console.log.bak - hdrMode:'
        try {
            Select-String -Path $consoleBak -Pattern 'hdrMode' -ErrorAction SilentlyContinue |
                Select-Object -Last 10 | ForEach-Object { Add-Log $_.Line }
        } catch { }
    }

    if (Test-Path -LiteralPath $debugBak) {
        Add-Log 'debug.log.bak - hibrit / boyut:'
        try {
            Select-String -Path $debugBak -Pattern 'hybrid|stream initialized|reduced|window size' -ErrorAction SilentlyContinue |
                Select-Object -Last 10 | ForEach-Object { Add-Log $_.Line }
        } catch { }
    }

    if (Test-Path -LiteralPath $nativeOld) {
        Add-Log 'CxNative (eski) - HDR / hata:'
        try {
            Select-String -Path $nativeOld -Pattern 'HDR|Hdr|IsHdrActive|GetAIHDR|failed|0x800|error' -ErrorAction SilentlyContinue |
                Select-Object -Last 15 | ForEach-Object { Add-Log $_.Line }
        } catch { }
    }
}

function Add-Diagnosis {
    $i = $script:Info
    Add-Section '4) TESPIT / ONERI'

    $hdrMode    = Get-RegexValue $consoleLog '"hdrMode":\s*([01])'
    $oscRed     = Get-RegexValue $consoleLog '"oscWidthReduction":\s*(true|false)'
    $reducedWin = Get-RegexValue $debugLog 'reduced window size (enabled|disabled)'
    $ovWidth    = Get-RegexValue $debugLog 'window size:\s*(\d+)'
    $hybridFlag = Get-RegexValue $debugLog 'hybrid:\s*(\d)'

    if ($i.Hybrid) {
        Add-Log '[!] Hibrit grafik tespit edildi.'
        Add-Log ("    Ekran {0} uzerinden suruluyor, NVIDIA GPU ayri." -f $i.DisplayName)
        Add-Log '    Oyun NVIDIA GPU uzerinde calisirken overlay capraz adaptor'
        Add-Log '    uzerinden birlestiriliyor. Bu durum bozulmayi artirabilir.'
    } elseif ($i.HasNvidia -and $i.DisplayName -match 'NVIDIA') {
        Add-Log '[i] Ekran dogrudan NVIDIA GPU uzerinden suruluyor (hibrit degil).'
        Add-Log '    Genislik/MPO duzeltmesi yine de uygulanabilir.'
    } else {
        Add-Log '[!] NVIDIA ekran karti veya surucusu tespit edilemedi.'
    }

    if ($i.Width -gt 0) {
        $full = $i.Width * 4
        $red  = ($i.Width - 1) * 4
        Add-Log ''
        Add-Log ("Cozunurluk {0}x{1}:" -f $i.Width, $i.Height)
        if (($full % 256 -eq 0) -and ($red % 256 -ne 0)) {
            Add-Log ("[!] Genislik 1 px azaltilinca satir hizasi bozuluyor ({0} bayt)." -f $red)
            Add-Log '    Overlay yatay cizgili/parcali cizilebilir. Bu arac bunu kapatir.'
        } elseif (($red % 256) -ne 0) {
            Add-Log ("[i] Azaltilmis genislik hizasiz ({0} bayt); tam genislik daha guvenli." -f $red)
        } else {
            Add-Log '[i] Bu cozunurlukte satir hizasi sorunu gorunmuyor.'
        }
    }

    Add-Log ''
    Add-Log 'Overlay son durumu (logdan):'
    Add-Log ("  Pencere genisligi     : {0}" -f $(if ($ovWidth) { $ovWidth } else { 'bilinmiyor' }))
    Add-Log ("  Genislik azaltma      : {0}" -f $(if ($reducedWin) { $reducedWin } else { 'bilinmiyor' }))
    Add-Log ("  Hibrit bayragi        : {0}" -f $(if ($hybridFlag) { $hybridFlag } else { 'bilinmiyor' }))
    Add-Log ("  oscWidthReduction     : {0}  (uzak yapilandirma; etkin durum debug.log)" -f $(if ($oscRed) { $oscRed } else { 'bilinmiyor' }))
    Add-Log ("  HDR (hdrMode)         : {0}" -f $(if ($hdrMode) { $hdrMode } else { 'bilinmiyor' }))

    Add-Log ''
    Add-Log 'Isaretler:'

    $hasProblem = $false
    if ($reducedWin -eq 'enabled') {
        Add-Log '[!] Overlay hala "reduced window size" kullaniyor.'
        $hasProblem = $true
    }
    if ($ovWidth -and $i.Width -gt 0 -and [int]$ovWidth -eq ($i.Width - 1)) {
        Add-Log ("[!] Overlay genisligi tam cozunurlukten 1 px kucuk ({0} yerine {1})." -f $i.Width, $ovWidth)
        $hasProblem = $true
    }
    if ($hybridFlag -eq '1') {
        Add-Log '[!] Overlay hibrit modda (capraz adaptor kopyalamasi).'
        $hasProblem = $true
    }
    if ($reducedWin -eq 'disabled' -and $hybridFlag -eq '0') {
        Add-Log '[OK] Genislik azaltma kapali ve overlay hibrit modda degil.'
    }
    if ($hdrMode -eq '1') {
        Add-Log '[!] Oyun oturumunda HDR ACIK. HDR + hibrit grafik bozulmayi artirabilir.'
        Add-Log '    Windows HDR, oyun ici HDR ve NVIDIA RTX HDR kapatilip test edilmeli.'
        $hasProblem = $true
    }
    if (-not $hasProblem) {
        Add-Log '[OK] Loglarda bilinen bozulma isareti yok.'
        Add-Log '     Sorun devam ediyorsa tam ekran / kenarliksiz pencere ve'
        Add-Log '     yenileme hizi (Hz) kombinasyonlarini da test et.'
    }

    Add-Log ''
    Add-Log 'ONERILEN SIRA:'
    Add-Log '  1) Menu 1 (TANI + DUZELT), sonra yeniden baslat.'
    Add-Log '  2) Hala bozuksa HDR kapat (menu 5) ve tekrar dene.'
    Add-Log '  3) Devam ederse ekran karti suruculerini guncelle.'
    Add-Log '  4) Sonuc ne olursa olsun raporu paylas.'
}

function Get-Report {
    Add-ReportHeader
    Add-SystemSection
    Add-SettingsSection
    Add-OverlayLogSection
    Add-Diagnosis
}

# ---------------------------------------------------------------- islemler
function Apply-Fixes {
    Add-Section '5) UYGULANAN DUZELTMELER'

    if (-not (Test-Path -LiteralPath $stateDir)) {
        New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath $stateFile)) {
        $state = [ordered]@{
            Version         = $script:Version
            HwSchMode       = Get-RegValue $gfxKey 'HwSchMode'
            OverlayTestMode = Get-RegValue $dwmKey 'OverlayTestMode'
            OverlayGpuPref  = $(if ($overlayExe) { Get-RegValue $gpuPrefKey $overlayExe } else { $null })
            OverlayExe      = $overlayExe
            SavedAt         = (Get-Date).ToString('s')
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath $stateFile -Encoding UTF8
        Add-Log ("Eski degerler yedeklendi: {0}" -f $stateFile)
    } else {
        Add-Log ("Yedek zaten var, korunuyor: {0}" -f $stateFile)
    }

    Set-ItemProperty -Path $gfxKey -Name 'HwSchMode' -Value 1 -Type DWord
    Add-Log 'HAGS kapatildi (HwSchMode=1).'

    if (-not (Test-Path -LiteralPath $dwmKey)) {
        New-Item -Path $dwmKey -Force | Out-Null
    }
    Set-ItemProperty -Path $dwmKey -Name 'OverlayTestMode' -Value 5 -Type DWord
    Add-Log 'MPO kapatildi (OverlayTestMode=5).'

    if (Test-Path -LiteralPath $overlayFile) {
        if (-not (Test-Path -LiteralPath "$overlayFile.bak")) {
            Copy-Item -LiteralPath $overlayFile -Destination "$overlayFile.bak" -Force
        }
        try {
            $json = Get-Content -LiteralPath $overlayFile -Raw | ConvertFrom-Json
            if (-not ($json.PSObject.Properties.Name -contains 'switches')) {
                $json | Add-Member -MemberType NoteProperty -Name switches -Value @() -Force
            }
            $sw  = @(@($json.switches) | Where-Object { $_ -and $_ -notmatch '^nv-osc-width' })
            $sw += 'nv-osc-width=false'
            $json.switches = @($sw)
            $out = $json | ConvertTo-Json -Compress
            (Get-Item -LiteralPath $overlayFile).IsReadOnly = $false
            [IO.File]::WriteAllText($overlayFile, $out, (New-Object Text.UTF8Encoding($false)))
            (Get-Item -LiteralPath $overlayFile).IsReadOnly = $true
            Add-Log 'Overlay genislik azaltmasi kapatildi (nv-osc-width=false); dosya salt-okunur.'
        } catch {
            Add-Log ("overrides.json duzenlenemedi: {0}" -f $_.Exception.Message)
        }
    } else {
        Add-Log 'overrides.json bulunamadi; genislik ayari atlandi.'
        Add-Log 'NVIDIA App bir kez acilip overlay olusturulduktan sonra tekrar calistir.'
    }

    if ($overlayExe) {
        if (-not (Test-Path -LiteralPath $gpuPrefKey)) {
            New-Item -Path $gpuPrefKey -Force | Out-Null
        }
        New-ItemProperty -Path $gpuPrefKey -Name $overlayExe -Value 'GpuPreference=2;' -PropertyType String -Force | Out-Null
        Add-Log 'NVIDIA Overlay.exe yuksek performansli GPU tercihine alindi.'
    } else {
        Add-Log 'NVIDIA Overlay.exe bulunamadi; GPU tercihi atlandi.'
    }

    Add-Log ''
    Add-Log 'NOT: Degisiklikler icin bilgisayari yeniden baslat.'

    Add-Section '6) DOGRULAMA'
    Add-Log ("HwSchMode       : {0}" -f (Get-RegValue $gfxKey 'HwSchMode'))
    Add-Log ("OverlayTestMode : {0}" -f (Get-RegValue $dwmKey 'OverlayTestMode'))
    if (Test-Path -LiteralPath $overlayFile) {
        Add-Log ("overrides.json  : {0}" -f ((Get-Content -LiteralPath $overlayFile -Raw).Trim()))
    }
    if ($overlayExe) {
        Add-Log ("GPU tercihi     : {0}" -f (Get-RegValue $gpuPrefKey $overlayExe))
    }
    Add-Log ''
    Add-Log 'Yeniden baslatmadan sonra logda su degerler gorulmeli:'
    Add-Log '  reduced window size disabled'
    Add-Log '  hybrid: 0'
    Add-Log '  window size: <tam genislik> <yukseklik>'
}

function Revert-Fixes {
    Add-Section '5) GERI ALMA'
    if (Test-Path -LiteralPath $stateFile) {
        $s = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
        if ($null -ne $s.HwSchMode) {
            Set-ItemProperty -Path $gfxKey -Name 'HwSchMode' -Value ([int]$s.HwSchMode) -Type DWord
        }
        if ($null -ne $s.OverlayTestMode) {
            Set-ItemProperty -Path $dwmKey -Name 'OverlayTestMode' -Value ([int]$s.OverlayTestMode) -Type DWord
        } else {
            Remove-ItemProperty -Path $dwmKey -Name 'OverlayTestMode' -ErrorAction SilentlyContinue
        }
        if ($s.OverlayGpuPref -and $overlayExe) {
            New-ItemProperty -Path $gpuPrefKey -Name $overlayExe -Value $s.OverlayGpuPref -PropertyType String -Force | Out-Null
        } elseif ($overlayExe) {
            Remove-ItemProperty -Path $gpuPrefKey -Name $overlayExe -ErrorAction SilentlyContinue
        }
        Add-Log 'HAGS, MPO ve GPU tercihi eski degerlerine donduruldu.'
    } else {
        Add-Log 'Yedek bulunamadi; varsayilan degerler uygulaniyor.'
        Set-ItemProperty -Path $gfxKey -Name 'HwSchMode' -Value 2 -Type DWord
        Remove-ItemProperty -Path $dwmKey -Name 'OverlayTestMode' -ErrorAction SilentlyContinue
        if ($overlayExe) {
            Remove-ItemProperty -Path $gpuPrefKey -Name $overlayExe -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath "$overlayFile.bak") {
        if (Test-Path -LiteralPath $overlayFile) {
            (Get-Item -LiteralPath $overlayFile).IsReadOnly = $false
        }
        Copy-Item -LiteralPath "$overlayFile.bak" -Destination $overlayFile -Force
        (Get-Item -LiteralPath $overlayFile).IsReadOnly = $false
        Add-Log 'overrides.json yedeginden geri yuklendi.'
    } else {
        Add-Log 'overrides.json yedegi yok; genislik ayari degistirilmedi.'
    }

    Add-Log ''
    Add-Log 'NOT: Degisiklikler icin bilgisayari yeniden baslat.'
}

function Enable-Hags {
    Add-Section '5) HAGS ACILDI (DLSS FRAME GENERATION)'
    Set-ItemProperty -Path $gfxKey -Name 'HwSchMode' -Value 2 -Type DWord
    Add-Log 'HAGS acildi (HwSchMode=2).'
    Add-Log 'MPO kapali, overlay genisligi ve GPU tercihi AYNEN KALDI.'
    Add-Log ''
    Add-Log 'DLSS Frame Generation icin HAGS gerekir; bu ayar onu geri acar.'
    Add-Log 'Yeniden baslat, sonra overlay + Frame Generation birlikte test et.'
    Add-Log 'Overlay tekrar bozulursa menu 1 ile HAGS tekrar kapatilir.'
}

function Save-Report {
    $name = 'NVIDIA_Overlay_Rapor_{0}.txt' -f (Get-Date -Format 'yyyyMMdd_HHmmss')
    $path = Join-Path $desktop $name
    $script:Log -join "`r`n" | Set-Content -LiteralPath $path -Encoding UTF8
    Write-Host ''
    Write-Host ("RAPOR: {0}" -f $path) -ForegroundColor Green
    return $path
}

# ---------------------------------------------------------------- paylasim paketi
function New-SharePackage {
    Add-Section '5) PAYLASIM PAKETI'

    $self = $env:NVIDIA_FIX_SELF
    if (-not $self -or -not (Test-Path -LiteralPath $self)) {
        $guess = Join-Path $desktop 'NVIDIA_Overlay_Fix.cmd'
        if (Test-Path -LiteralPath $guess) { $self = $guess }
    }

    $folder = Join-Path $desktop 'NVIDIA_Overlay_Fix_Paylasim'
    if (-not (Test-Path -LiteralPath $folder)) {
        New-Item -ItemType Directory -Path $folder -Force | Out-Null
    }

    if ($self -and (Test-Path -LiteralPath $self)) {
        Copy-Item -LiteralPath $self -Destination (Join-Path $folder 'NVIDIA_Overlay_Fix.cmd') -Force
        Add-Log 'Arac dosyasi kopyalandi.'
    } else {
        Add-Log 'UYARI: Arac dosyasinin yolu bulunamadi; sadece kilavuz olusturuldu.'
    }

    $readme = @'
NVIDIA OVERLAY FIX v2 - KULLANIM KILAVUZU
=========================================

NE ISE YARAR?
NVIDIA App oyun ici overlay'i (Alt+Z / Alt+F3 / Alt+R) bazi sistemlerde
yatay cizgiler, parcalanma veya bozuk renklerle cizilir. Bu sorun en cok
hibrit grafikli (Intel + NVIDIA) laptoplerde gorulur; masaustu kartlarda da
gorulebilir. Genellikle bir surucu guncellemesinden sonra baslar.

NVIDIA overlay, genisligi 1 piksel azaltarak cizer (or. 1920 -> 1919).
Bu durumda satir araligi 256 bayta tam bolunmez ve goruntu bozulur.
Bu arac o azaltmayi kapatir, ayrica MPO ve HAGS ayarlarini duzenler.

YAPTIGI ISLER
1) Overlay genisliginin 1 px azaltilmasini kapatir (nv-osc-width=false)
2) MPO (Multi-Plane Overlay) kapatir
3) HAGS (Hardware-Accelerated GPU Scheduling) kapatir
4) NVIDIA Overlay.exe dosyasini yuksek performansli GPU'ya atar

GEREKSINIMLER
- Windows 10 veya 11 (64 bit)
- NVIDIA ekran karti + NVIDIA App (overlay)
- Yonetici yetkisi (arac kendisi ister)

NASIL KULLANILIR
1) NVIDIA_Overlay_Fix.cmd dosyasina cift tikla.
2) UAC izin istegine "Evet" de.
3) Menuden 1'i sec (TANI + DUZELT).
4) Bilgisayari yeniden baslat.
5) Oyunda Alt+Z / Alt+F3 / Alt+R ile test et.
6) Sorun devam ederse menuden 2'yi sec ve olusan rapor TXT'sini paylas.

MENU
1) TANI + DUZELT       : Tum duzeltmeleri uygular, rapor yazar
2) SADECE RAPOR        : Hicbir sey degistirmez, sadece tani raporu
3) GERI AL             : Onceki ayarlara doner
4) DURUM               : Mevcut ayarlari gosterir + rapor
5) HDR AYARLARI        : Windows HDR ayar sayfasini acar
6) HAGS AC             : DLSS Frame Generation icin HAGS'i geri acar
7) PAYLASIM PAKETI     : Bu araci + kilavuzu tek zip olarak olusturur

ONEMLI NOTLAR
- HAGS kapatilirsa DLSS Frame Generation oyunda kaybolabilir.
  Geri istersen menu 6 kullan; diger duzeltmeler kalir.
- Arac hicbir dosyayi silmez.
- Degistirdigi ayarlarin yedegi:
  %LOCALAPPDATA%\NVIDIAOverlayFix\state.json
- overrides.json salt-okunur yapilir; NVIDIA App geri yazamaz.
- Cozunurlukten bagimsizdir (1080p, 1440p, 4K, ultrawide ...).
- Geri almak icin menu 3.

ENGLISH (SHORT)
Fixes corrupted NVIDIA App in-game overlay (horizontal lines or artifacts),
typically on hybrid-graphics laptops. It disables the 1-pixel overlay width
reduction, turns off MPO and HAGS, and assigns the overlay to the
high-performance GPU. Run as administrator, choose 1, reboot, test with Alt+Z.
Choose 3 to revert. Choose 6 to re-enable HAGS for DLSS Frame Generation.

RAPOR
Her islem sonunda masaustune NVIDIA_Overlay_Rapor_<tarih>.txt yazilir.
Bu dosyayi oldugu gibi paylasabilirsiniz.

SORUN BILDIRIRKEN
Rapor TXT dosyasini ve su bilgileri ekleyin:
- Overlay hangi oyunda bozuluyor
- Cozunurluk ve yenileme hizi (Hz)
- Windows ve NVIDIA surucu surumu
'@

    $readmePath = Join-Path $folder 'OKU_BENI.txt'
    $readme | Set-Content -LiteralPath $readmePath -Encoding UTF8
    Add-Log ("Kilavuz yazildi: {0}" -f $readmePath)

    $zip = Join-Path $desktop 'NVIDIA_Overlay_Fix_Paylasim.zip'
    try {
        if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
        Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $zip -Force
        Add-Log ("Paylasim zip: {0}" -f $zip)
        Add-Log 'Bu zip dosyasini ihtiyaci olan kisilere gonderebilirsin.'
    } catch {
        Add-Log ("Zip olusturulamadi: {0}" -f $_.Exception.Message)
        Add-Log ("Klasoru oldugu gibi paylasabilirsin: {0}" -f $folder)
    }
}

# ---------------------------------------------------------------- menu
function Show-Menu {
    Clear-Host
    $i = $script:Info
    Write-Host '======================================================' -ForegroundColor Cyan
    Write-Host ('   NVIDIA OVERLAY FIX {0}' -f $script:Version) -ForegroundColor Cyan
    Write-Host '   Oyun ici overlay bozulmasi duzeltici' -ForegroundColor DarkGray
    Write-Host '======================================================' -ForegroundColor Cyan
    if ($i.DisplayName) {
        Write-Host ('   Sistem: {0} | {1}x{2} @ {3} Hz | Hibrit: {4}' -f $i.DisplayName, $i.Width, $i.Height, $i.Refresh, $(if ($i.Hybrid) { 'EVET' } else { 'HAYIR' })) -ForegroundColor DarkGray
    } else {
        Write-Host '   Sistem bilgisi okunamadi.' -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host ' 1) TANI + DUZELT (onerilen, rapor olusturur)'
    Write-Host ' 2) Sadece TANI / RAPOR (degisiklik yapmaz)'
    Write-Host ' 3) GERI AL (eski ayarlara don)'
    Write-Host ' 4) DURUM goster + rapor'
    Write-Host ' 5) HDR ayarlarini ac'
    Write-Host ' 6) HAGS AC (DLSS Frame Generation icin)'
    Write-Host ' 7) PAYLASIM PAKETI olustur (zip + kilavuz)'
    Write-Host ' 8) Cikis'
    Write-Host ''
}

# ---------------------------------------------------------------- otomatik modlar
if ($env:NVIDIA_FIX_MODE -eq 'report') {
    $script:Log.Clear()
    Get-Report
    $null = Save-Report
    exit 0
}

if ($env:NVIDIA_FIX_MODE -eq 'apply') {
    $script:Log.Clear()
    Get-Report
    Apply-Fixes
    $null = Save-Report
    exit 0
}

if ($env:NVIDIA_FIX_MODE -eq 'revert') {
    $script:Log.Clear()
    Get-Report
    Revert-Fixes
    $null = Save-Report
    exit 0
}

if ($env:NVIDIA_FIX_MODE -eq 'share') {
    $script:Log.Clear()
    Get-Report
    New-SharePackage
    $null = Save-Report
    exit 0
}

if (-not (Test-Admin)) {
    Write-Host ''
    Write-Host 'Bu islem icin yonetici yetkisi gerekiyor.' -ForegroundColor Red
    Write-Host 'Dosyaya sag tik > "Yonetici olarak calistir" ile ac.' -ForegroundColor Yellow
    Write-Host ''
    Read-Host 'Cikmak icin Enter'
    exit 1
}

if (-not $script:Info.HasNvidia) {
    Write-Host ''
    Write-Host 'UYARI: NVIDIA ekran karti tespit edilemedi.' -ForegroundColor Yellow
    Write-Host 'Bu arac NVIDIA App overlay sorunu icindir; yine de devam edebilirsin.' -ForegroundColor Yellow
    Write-Host ''
}

do {
    Show-Menu
    $choice = Read-Host 'Secim (1-8)'
    switch ($choice) {
        '1' {
            Write-Host ''
            Write-Host 'HAGS ve MPO kapatilacak, overlay genisligi ve GPU tercihi ayarlanacak.' -ForegroundColor Yellow
            Write-Host 'HDR ayarina dokunulmaz (menu 5).' -ForegroundColor Yellow
            $ok = Read-Host 'Devam edilsin mi? (E/H)'
            if ($ok -notmatch '^[EeYy]') { continue }

            $script:Log.Clear()
            Get-Report
            Apply-Fixes
            $null = Save-Report

            Write-Host ''
            Write-Host 'Yeniden baslat, sonra oyunda Alt+Z / Alt+F3 / Alt+R ile test et.' -ForegroundColor Yellow
            Write-Host 'Sorun devam ederse menu 2 ile rapor olusturup paylas.' -ForegroundColor Yellow
            Read-Host 'Devam etmek icin Enter'
        }
        '2' {
            $script:Log.Clear()
            Get-Report
            $null = Save-Report
            Write-Host ''
            Write-Host 'Rapor hazir. Bu dosyayi paylasabilirsin.' -ForegroundColor Yellow
            Read-Host 'Devam etmek icin Enter'
        }
        '3' {
            $script:Log.Clear()
            Get-Report
            Revert-Fixes
            $null = Save-Report
            Write-Host ''
            Write-Host 'Geri alma tamam. Yeniden baslatip test et.' -ForegroundColor Yellow
            Read-Host 'Devam etmek icin Enter'
        }
        '4' {
            $script:Log.Clear()
            Get-Report
            $null = Save-Report
            Read-Host 'Devam etmek icin Enter'
        }
        '5' {
            Start-Process 'ms-settings:display-advanced'
            Write-Host ''
            Write-Host 'HDR ayarlari acildi. "HDR kullan" secenegini KAPAT.' -ForegroundColor Yellow
            Write-Host 'Oyun ici HDR ve NVIDIA App > RTX HDR ayarini da kapat.' -ForegroundColor Yellow
            Read-Host 'Devam etmek icin Enter'
        }
        '6' {
            Write-Host ''
            Write-Host 'HAGS acilacak; MPO kapali ve overlay duzeltmeleri kalacak.' -ForegroundColor Yellow
            Write-Host 'Amac: DLSS Frame Generation geri gelsin. Yeniden baslatma gerekir.' -ForegroundColor Yellow
            $ok = Read-Host 'Devam edilsin mi? (E/H)'
            if ($ok -notmatch '^[EeYy]') { continue }

            $script:Log.Clear()
            Get-Report
            Enable-Hags
            $null = Save-Report

            Write-Host ''
            Write-Host 'Yeniden baslat, sonra overlay + Frame Generation birlikte test et.' -ForegroundColor Yellow
            Read-Host 'Devam etmek icin Enter'
        }
        '7' {
            $script:Log.Clear()
            Get-Report
            New-SharePackage
            $null = Save-Report
            Read-Host 'Devam etmek icin Enter'
        }
        '8' { return }
        default {
            Write-Host 'Gecersiz secim.' -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
} while ($true)
