# 007 Deleter - przenośny czyścik śladów użytkowania Windows.
# Działa z pendrive'a i z dysku, bez instalacji. Nie zapisuje nic na nośniku.
# Nie rusza haseł, zakładek ani dokumentów.
# Tryb bez okna: 007Deleter.ps1 -Quick (czyści domyślny zestaw i kończy).

param([switch]$Quick)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:ui = $false
$taskName = '007Deleter-logowanie'

# ---------- narzędzia ----------

function Get-Files($path, [string]$filter = '*', [bool]$recurse = $true) {
    if (-not (Test-Path -LiteralPath $path)) { return }
    Get-ChildItem -LiteralPath $path -Filter $filter -Force -File -Recurse:$recurse -ErrorAction SilentlyContinue
}

function Get-ChromiumProfiles {
    $roots = @(
        "$env:LOCALAPPDATA\Google\Chrome\User Data",
        "$env:LOCALAPPDATA\Microsoft\Edge\User Data",
        "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"
    )
    foreach ($r in $roots) {
        if (Test-Path -LiteralPath $r) {
            Get-ChildItem -LiteralPath $r -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' } |
                ForEach-Object { $_.FullName }
        }
    }
}

function Get-FirefoxProfiles($base) {
    if (Test-Path -LiteralPath $base) {
        Get-ChildItem -LiteralPath $base -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
    }
}

function Format-Size([double]$b) {
    if ($b -ge 1GB) { return ('{0:N1} GB' -f ($b / 1GB)) }
    if ($b -ge 1MB) { return ('{0:N1} MB' -f ($b / 1MB)) }
    if ($b -ge 1KB) { return ('{0:N0} KB' -f ($b / 1KB)) }
    return ('{0:N0} B' -f $b)
}

function Remove-Keys($keys) {
    foreach ($k in $keys) {
        if (Test-Path -LiteralPath $k) { Remove-Item -LiteralPath $k -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Nadpisuje plik losowymi danymi, zmienia jego nazwę i dopiero usuwa.
function Remove-Secure([string]$path) {
    $item = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
        Remove-Item -LiteralPath $path -Force -ErrorAction Stop
        return
    }
    $item.Attributes = 'Normal'
    $len = $item.Length
    if ($len -gt 0) {
        $buf = New-Object byte[] 1048576
        $rng = New-Object Security.Cryptography.RNGCryptoServiceProvider
        $fs = [IO.File]::Open($path, 'Open', 'Write', 'None')
        try {
            $left = $len
            while ($left -gt 0) {
                $n = [int][Math]::Min($left, $buf.Length)
                $rng.GetBytes($buf)
                $fs.Write($buf, 0, $n)
                $left -= $n
            }
            $fs.Flush($true)
        } finally { $fs.Dispose(); $rng.Dispose() }
    }
    $newName = [IO.Path]::GetRandomFileName()
    try { Rename-Item -LiteralPath $path -NewName $newName -Force -ErrorAction Stop; $path = Join-Path $item.DirectoryName $newName } catch { }
    Remove-Item -LiteralPath $path -Force -ErrorAction Stop
}

# ---------- kategorie ----------
# Files = lista plików do usunięcia (liczy rozmiar), Extra = dodatkowa akcja (bez rozmiaru)

$categories = @(
    @{ Id = 'thumbs'; Name = 'Miniatury i ikony'; Desc = 'Pokazują, jakie zdjęcia i filmy były w folderach, nawet po ich usunięciu'; Default = $true
       Files = {
           Get-Files "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" 'thumbcache_*.db' $false
           Get-Files "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" 'iconcache_*.db' $false
           Get-Files "$env:LOCALAPPDATA" 'IconCache.db' $false
       } },
    @{ Id = 'temp'; Name = 'Pliki tymczasowe'; Desc = 'Folder TEMP użytkownika: resztki instalatorów, rozpakowanych plików, dokumentów'; Default = $true
       Files = { Get-Files $env:TEMP } },
    @{ Id = 'recent'; Name = 'Ostatnio używane pliki'; Desc = 'Lista „Ostatnie” i skoki na pasku zadań: ujawniają, co otwierano'; Default = $true
       Files = { Get-Files "$env:APPDATA\Microsoft\Windows\Recent" } },
    @{ Id = 'office'; Name = 'Ostatnie pliki Office'; Desc = 'Listy ostatnich dokumentów w Wordzie, Excelu i PowerPoincie'; Default = $true
       Files = { Get-Files "$env:APPDATA\Microsoft\Office\Recent" }
       Extra = {
           foreach ($v in '14.0', '15.0', '16.0') {
               foreach ($a in 'Word', 'Excel', 'PowerPoint') {
                   $b = "HKCU:\Software\Microsoft\Office\$v\$a"
                   Remove-Keys @("$b\File MRU", "$b\Place MRU", "$b\User MRU")
               }
           }
       } },
    @{ Id = 'regmru'; Name = 'Historia uruchamiania i wyszukiwania'; Desc = 'Okno „Uruchom”, wpisane ścieżki, wyszukiwania w Eksploratorze'; Default = $true
       Extra = {
           $b = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
           Remove-Keys @("$b\RunMRU", "$b\TypedPaths", "$b\WordWheelQuery", "$b\RecentDocs")
       } },
    @{ Id = 'userassist'; Name = 'Ślady uruchamianych programów'; Desc = 'Rejestr UserAssist: lista programów i liczba ich uruchomień'; Default = $true
       Extra = { Remove-Keys @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist') } },
    @{ Id = 'shellbags'; Name = 'Ślady przeglądanych folderów'; Desc = 'Rejestr ShellBags: foldery otwierane w Eksploratorze (też usunięte lub z pendrive''ów). Resetuje widok folderów'; Default = $false
       Extra = {
           Remove-Keys @(
               'HKCU:\Software\Microsoft\Windows\Shell\BagMRU', 'HKCU:\Software\Microsoft\Windows\Shell\Bags',
               'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU',
               'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags')
       } },
    @{ Id = 'timeline'; Name = 'Historia aktywności Windows'; Desc = 'Oś czasu: aplikacje i pliki z ostatnich dni (plik może być zajęty przez system)'; Default = $true
       Files = { Get-Files "$env:LOCALAPPDATA\ConnectedDevicesPlatform" 'ActivitiesCache.db*' } },
    @{ Id = 'clip'; Name = 'Schowek'; Desc = 'Skopiowane teksty i dane, także hasła skopiowane z menedżera'; Default = $true
       Extra = { [System.Windows.Forms.Clipboard]::Clear() } },
    @{ Id = 'browsercache'; Name = 'Pamięć podręczna przeglądarek'; Desc = 'Chrome, Edge, Brave, Firefox: kopie odwiedzonych stron i obrazów (zamknij przeglądarki)'; Default = $true
       Files = {
           foreach ($p in Get-ChromiumProfiles) {
               foreach ($s in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') { Get-Files (Join-Path $p $s) }
           }
           foreach ($p in Get-FirefoxProfiles "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles") { Get-Files (Join-Path $p 'cache2') }
       } },
    @{ Id = 'browserhist'; Name = 'Historia przeglądarek (Chromium)'; Desc = 'Chrome, Edge, Brave: odwiedzone strony i lista pobranych plików. Zakładki i hasła zostają'; Default = $false
       Files = {
           foreach ($p in Get-ChromiumProfiles) {
               foreach ($f in 'History', 'History-journal', 'Top Sites', 'Visited Links', 'Network Action Predictor') {
                   $x = Join-Path $p $f
                   if (Test-Path -LiteralPath $x -PathType Leaf) { Get-Item -LiteralPath $x -Force }
               }
           }
       } },
    @{ Id = 'ffhist'; Name = 'Historia Firefoksa (usuwa też zakładki!)'; Desc = 'Historia i autouzupełnianie. Firefox trzyma zakładki w tym samym pliku, więc znikną razem z nią'; Default = $false
       Files = {
           foreach ($p in Get-FirefoxProfiles "$env:APPDATA\Mozilla\Firefox\Profiles") {
               foreach ($f in 'places.sqlite', 'places.sqlite-wal', 'places.sqlite-shm', 'formhistory.sqlite') {
                   $x = Join-Path $p $f
                   if (Test-Path -LiteralPath $x -PathType Leaf) { Get-Item -LiteralPath $x -Force }
               }
           }
       } },
    @{ Id = 'cookies'; Name = 'Ciasteczka przeglądarek (wylogowuje ze stron)'; Desc = 'Chrome, Edge, Brave, Firefox: po usunięciu trzeba logować się ponownie'; Default = $false
       Files = {
           foreach ($p in Get-ChromiumProfiles) {
               foreach ($f in 'Network\Cookies', 'Network\Cookies-journal', 'Cookies', 'Cookies-journal') {
                   $x = Join-Path $p $f
                   if (Test-Path -LiteralPath $x -PathType Leaf) { Get-Item -LiteralPath $x -Force }
               }
           }
           foreach ($p in Get-FirefoxProfiles "$env:APPDATA\Mozilla\Firefox\Profiles") {
               foreach ($f in 'cookies.sqlite', 'cookies.sqlite-wal', 'cookies.sqlite-shm') {
                   $x = Join-Path $p $f
                   if (Test-Path -LiteralPath $x -PathType Leaf) { Get-Item -LiteralPath $x -Force }
               }
           }
       } },
    @{ Id = 'wer'; Name = 'Raporty błędów Windows'; Desc = 'Zrzuty pamięci i raporty awarii aplikacji, mogą zawierać fragmenty danych'; Default = $true
       Files = {
           Get-Files "$env:LOCALAPPDATA\Microsoft\Windows\WER"
           Get-Files "$env:LOCALAPPDATA\CrashDumps"
       } },
    @{ Id = 'dns'; Name = 'Pamięć DNS'; Desc = 'Lista adresów stron odwiedzonych w tej sesji sieciowej'; Default = $true
       Extra = { ipconfig /flushdns | Out-Null } },
    @{ Id = 'bin'; Name = 'Kosz'; Desc = 'Opróżnia kosz na wszystkich dyskach. Tego nie da się cofnąć'; Default = $false
       Extra = { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } },
    @{ Id = 'wifi'; Name = 'Zapisane sieci Wi-Fi (wymaga administratora)'; Desc = 'Usuwa listę znanych sieci wraz z hasłami. Trzeba będzie połączyć się ponownie'; Default = $false; Admin = $true
       Extra = { netsh wlan delete profile name=* i=* | Out-Null } },
    @{ Id = 'eventlog'; Name = 'Dzienniki zdarzeń Windows (wymaga administratora)'; Desc = 'Logowania, uruchomienia, podłączone urządzenia. Windows zapisze, że dziennik wyczyszczono'; Default = $false; Admin = $true
       Extra = { wevtutil el | ForEach-Object { wevtutil cl "$_" 2>$null } } },
    @{ Id = 'prefetch'; Name = 'Prefetch (wymaga administratora)'; Desc = 'Lista programów uruchamianych na tym komputerze wraz z datami'; Default = $false; Admin = $true
       Files = { Get-Files "$env:SystemRoot\Prefetch" '*.pf' $false } },
    @{ Id = 'trim'; Name = 'Wyślij TRIM do dysku SSD (wymaga administratora)'; Desc = 'Prosi SSD o fizyczne wyczyszczenie bloków po usuniętych plikach. Zrób po czyszczeniu'; Default = $false; Admin = $true
       Extra = { Optimize-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ReTrim -ErrorAction SilentlyContinue | Out-Null } },
    @{ Id = 'freespace'; Name = 'Wolne miejsce na dysku systemowym'; Desc = 'Nadpisuje puste miejsce, by usunięte wcześniej pliki nie dały się odzyskać. Tylko HDD. Trwa długo'; Default = $false
       Extra = { Start-Process cmd.exe -ArgumentList "/c title 007 Deleter - nadpisywanie wolnego miejsca & cipher /w:$($env:SystemDrive)\ & pause" } }
)

function Invoke-Category($c, [bool]$secure) {
    $ok = 0; $fail = 0; $bytes = 0; $err = $false
    if ($c.Files) {
        foreach ($f in @(& $c.Files)) {
            try {
                $len = $f.Length
                if ($secure) { Remove-Secure $f.FullName } else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
                $ok++; $bytes += $len
            } catch { $fail++ }
            if ($script:ui -and (($ok + $fail) % 200 -eq 0)) { [System.Windows.Forms.Application]::DoEvents() }
        }
    }
    if ($c.Extra) { try { & $c.Extra | Out-Null } catch { $err = $true } }
    return @{ Ok = $ok; Fail = $fail; Bytes = $bytes; Err = $err }
}

# ---------- tryb bez okna ----------

if ($Quick) {
    foreach ($c in $categories) {
        if ($c.Default -and (-not $c.Admin -or $isAdmin)) { Invoke-Category $c $false | Out-Null }
    }
    exit
}

# ---------- stan zabezpieczeń ----------

function Get-SystemDiskInfo {
    $r = @{ Type = 'nieznany'; Ssd = $null }
    try {
        $part = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" } | Select-Object -First 1
        if ($pd) {
            if ($pd.MediaType -eq 'SSD' -or $pd.BusType -eq 'NVMe') { $r.Type = 'SSD'; $r.Ssd = $true }
            elseif ($pd.MediaType -eq 'HDD') { $r.Type = 'HDD (dysk talerzowy)'; $r.Ssd = $false }
        }
    } catch { }
    return $r
}

function Get-AutoTaskInstalled {
    try { return [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction Stop) } catch { return $false }
}

function Get-SecurityStatus {
    $items = @()
    $disk = Get-SystemDiskInfo
    $script:diskInfo = $disk

    # szyfrowanie dysku (BitLocker)
    $v = $null
    try { $v = (New-Object -ComObject Shell.Application).NameSpace("$env:SystemDrive\").Self.ExtendedProperty('System.Volume.BitLockerProtection') } catch { }
    if ($null -eq $v) { $st = 'unk'; $tx = 'nie udało się sprawdzić'; $hn = 'Sprawdź w Ustawieniach: Prywatność i zabezpieczenia, Szyfrowanie urządzenia.' }
    elseif ($v -eq 1) { $st = 'ok'; $tx = 'włączone'; $hn = 'Dane na dysku są nieczytelne bez Twojego logowania lub klucza.' }
    elseif ($v -eq 5) { $st = 'warn'; $tx = 'wstrzymane'; $hn = 'Szyfrowanie jest chwilowo wyłączone. Wznów je w ustawieniach BitLockera.' }
    else { $st = 'warn'; $tx = 'wyłączone'; $hn = 'Najważniejsze zabezpieczenie. Bez niego dysk można odczytać po wyjęciu z laptopa.' }
    $items += @{ Id = 'bitlocker'; State = $st; Text = $tx; Hint = $hn }

    # Secure Boot
    $sb = $null
    try { $sb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled } catch { }
    if ($null -eq $sb) { $st = 'unk'; $tx = 'brak informacji'; $hn = 'Starszy BIOS lub brak UEFI. Włącz Secure Boot w ustawieniach BIOS-u, jeśli to możliwe.' }
    elseif ($sb -eq 1) { $st = 'ok'; $tx = 'włączony'; $hn = 'Komputer nie uruchomi podejrzanego systemu z pendrive''a.' }
    else { $st = 'warn'; $tx = 'wyłączony'; $hn = 'Włącz w BIOS-ie. Ustaw też hasło do BIOS-u.' }
    $items += @{ Id = 'secureboot'; State = $st; Text = $tx; Hint = $hn }

    # typ dysku
    if ($disk.Ssd -eq $true) { $st = 'warn'; $hn = 'Na SSD nadpisywanie plików nie daje pewności. Polegaj na szyfrowaniu i TRIM.' }
    elseif ($disk.Ssd -eq $false) { $st = 'ok'; $hn = 'Na dysku talerzowym nadpisywanie plików działa dobrze.' }
    else { $st = 'unk'; $hn = 'Nie udało się rozpoznać typu dysku.' }
    $items += @{ Id = 'disk'; State = $st; Text = $disk.Type; Hint = $hn }

    # TRIM
    $trim = $null
    try { $o = (& fsutil behavior query DisableDeleteNotify 2>&1) -join ' '; if ($o -match 'DisableDeleteNotify\s*=\s*(\d)') { $trim = [int]$Matches[1] } } catch { }
    if ($disk.Ssd -eq $false) { $st = 'ok'; $tx = 'nie dotyczy'; $hn = 'TRIM jest potrzebny tylko dla SSD.' }
    elseif ($trim -eq 0) { $st = 'ok'; $tx = 'włączony'; $hn = 'Windows informuje SSD o usuniętych plikach, a dysk je czyści.' }
    elseif ($trim -eq 1) { $st = 'warn'; $tx = 'wyłączony'; $hn = 'Użyj przycisku „Włącz TRIM” poniżej (administrator).' }
    else { $st = 'unk'; $tx = 'nie udało się sprawdzić'; $hn = 'Spróbuj jako administrator.' }
    $items += @{ Id = 'trim'; State = $st; Text = $tx; Hint = $hn }

    # hibernacja
    $hib = $null
    try { $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled } catch { }
    if ($hib -eq 1) { $st = 'warn'; $tx = 'włączona'; $hn = 'Zapisuje całą pamięć RAM na dysk, w tym hasła i otwarte dokumenty.' }
    elseif ($hib -eq 0) { $st = 'ok'; $tx = 'wyłączona'; $hn = 'Pamięć RAM nie trafia na dysk przy wyłączaniu.' }
    else { $st = 'unk'; $tx = 'brak informacji'; $hn = '' }
    $items += @{ Id = 'hibernate'; State = $st; Text = $tx; Hint = $hn }

    # plik wymiany
    $pf = $null
    try { $pf = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -ErrorAction Stop).ClearPageFileAtShutdown } catch { }
    if ($pf -eq 1) { $st = 'ok'; $tx = 'włączone'; $hn = 'Plik wymiany jest zerowany przy każdym wyłączeniu (wyłączanie trwa dłużej).' }
    else { $st = 'warn'; $tx = 'wyłączone'; $hn = 'Plik wymiany może zawierać fragmenty tego, co robiłeś. Włącz czyszczenie poniżej.' }
    $items += @{ Id = 'pagefile'; State = $st; Text = $tx; Hint = $hn }

    # zadanie automatyczne
    if (Get-AutoTaskInstalled) { $st = 'ok'; $tx = 'włączone'; $hn = 'Szybkie czyszczenie uruchamia się przy każdym logowaniu.' }
    else { $st = 'unk'; $tx = 'wyłączone'; $hn = 'Opcjonalne. Czyści ślady poprzedniej sesji przy logowaniu.' }
    $items += @{ Id = 'autotask'; State = $st; Text = $tx; Hint = $hn }

    return $items
}

function Get-SelfPath {
    if ($PSCommandPath) { return $PSCommandPath }
    return [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
}

function Enable-AutoTask {
    $dir = Join-Path $env:LOCALAPPDATA '007Deleter'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $self = Get-SelfPath
    $dest = Join-Path $dir (Split-Path $self -Leaf)
    Copy-Item -LiteralPath $self -Destination $dest -Force
    if ($PSCommandPath) {
        $exe = 'powershell.exe'
        $taskArgs = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$dest`" -Quick"
    } else {
        $exe = $dest
        $taskArgs = '-Quick'
    }
    $action = New-ScheduledTaskAction -Execute $exe -Argument $taskArgs
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User "$env:USERDOMAIN\$env:USERNAME"
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Force | Out-Null
}

function Disable-AutoTask {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $env:LOCALAPPDATA '007Deleter') -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------- okno ----------

$script:ui = $true
$script:diskInfo = @{ Type = 'nieznany'; Ssd = $null }

$bg = [Drawing.Color]::FromArgb(18, 21, 26)
$panel = [Drawing.Color]::FromArgb(27, 32, 39)
$green = [Drawing.Color]::FromArgb(31, 157, 99)
$red = [Drawing.Color]::FromArgb(214, 69, 65)
$amber = [Drawing.Color]::FromArgb(240, 170, 60)
$text = [Drawing.Color]::FromArgb(236, 240, 244)
$muted = [Drawing.Color]::FromArgb(140, 150, 162)

$form = New-Object Windows.Forms.Form
$form.Text = '007 Deleter'
$form.ClientSize = New-Object Drawing.Size(740, 700)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $bg
$form.ForeColor = $text
$form.Font = New-Object Drawing.Font('Segoe UI', 10)
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false

$title = New-Object Windows.Forms.Label
$title.Text = '007 Deleter'
$title.Font = New-Object Drawing.Font('Segoe UI Semibold', 20)
$title.ForeColor = $green
$title.Location = New-Object Drawing.Point(20, 12)
$title.AutoSize = $true
$form.Controls.Add($title)

$sub = New-Object Windows.Forms.Label
$sub.Text = 'Zaznacz, co usunąć. „Skanuj” tylko pokazuje rozmiary, niczego nie kasuje.'
$sub.ForeColor = $muted
$sub.Location = New-Object Drawing.Point(22, 54)
$sub.AutoSize = $true
$form.Controls.Add($sub)

function New-FlatButton($label, $x, $y, $w, $color, $parent) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $label
    $b.Location = New-Object Drawing.Point($x, $y)
    $b.Size = New-Object Drawing.Size($w, 38)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $color
    $b.ForeColor = [Drawing.Color]::White
    $b.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
    $b.Cursor = 'Hand'
    $parent.Controls.Add($b)
    return $b
}

$btnAdmin = New-FlatButton 'Uruchom jako administrator' 510 14 210 $panel $form
$btnAdmin.Height = 32
$adminLbl = New-Object Windows.Forms.Label
$adminLbl.Location = New-Object Drawing.Point(510, 18)
$adminLbl.Size = New-Object Drawing.Size(210, 24)
$adminLbl.TextAlign = 'MiddleRight'
$adminLbl.Text = 'Tryb administratora'
$adminLbl.ForeColor = $green
$form.Controls.Add($adminLbl)
$btnAdmin.Visible = -not $isAdmin
$adminLbl.Visible = $isAdmin

$navClean = New-FlatButton 'Czyszczenie' 20 84 160 $green $form
$navSec = New-FlatButton 'Zabezpieczenia' 190 84 160 $panel $form
$navClean.Height = 34
$navSec.Height = 34

$paneClean = New-Object Windows.Forms.Panel
$paneClean.Location = New-Object Drawing.Point(20, 126)
$paneClean.Size = New-Object Drawing.Size(700, 390)
$form.Controls.Add($paneClean)

$paneSec = New-Object Windows.Forms.Panel
$paneSec.Location = New-Object Drawing.Point(20, 126)
$paneSec.Size = New-Object Drawing.Size(700, 390)
$paneSec.Visible = $false
$form.Controls.Add($paneSec)

# --- panel czyszczenia ---

$list = New-Object Windows.Forms.FlowLayoutPanel
$list.Location = New-Object Drawing.Point(0, 0)
$list.Size = New-Object Drawing.Size(700, 296)
$list.FlowDirection = 'TopDown'
$list.WrapContents = $false
$list.AutoScroll = $true
$list.BackColor = $bg
$paneClean.Controls.Add($list)

$rows = @{}
foreach ($c in $categories) {
    $row = New-Object Windows.Forms.Panel
    $row.Size = New-Object Drawing.Size(655, 50)
    $row.BackColor = $panel
    $row.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 4)

    $cb = New-Object Windows.Forms.CheckBox
    $cb.Text = $c.Name
    $cb.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $cb.Location = New-Object Drawing.Point(10, 4)
    $cb.Size = New-Object Drawing.Size(520, 22)
    $cb.Checked = [bool]$c.Default
    if ($c.Admin -and -not $isAdmin) { $cb.Checked = $false; $cb.Enabled = $false }
    $row.Controls.Add($cb)

    $d = New-Object Windows.Forms.Label
    $d.Text = $c.Desc
    $d.ForeColor = $muted
    $d.Font = New-Object Drawing.Font('Segoe UI', 8.5)
    $d.Location = New-Object Drawing.Point(30, 27)
    $d.Size = New-Object Drawing.Size(530, 18)
    $row.Controls.Add($d)

    $sz = New-Object Windows.Forms.Label
    $sz.Text = ''
    $sz.TextAlign = 'MiddleRight'
    $sz.ForeColor = $green
    $sz.Location = New-Object Drawing.Point(545, 12)
    $sz.Size = New-Object Drawing.Size(100, 24)
    $row.Controls.Add($sz)

    $list.Controls.Add($row)
    $rows[$c.Id] = @{ Check = $cb; Size = $sz }
}

$btnScan = New-FlatButton 'Skanuj' 0 306 120 $panel $paneClean
$btnClean = New-FlatButton 'Wyczyść zaznaczone' 130 306 190 $red $paneClean
$btnQuick = New-FlatButton 'Szybkie czyszczenie' 330 306 190 $green $paneClean
$btnAll = New-FlatButton 'Zaznacz wszystko' 530 306 170 $panel $paneClean

$chkSecure = New-Object Windows.Forms.CheckBox
$chkSecure.Text = 'Bezpieczne usuwanie: nadpisz pliki losowymi danymi przed skasowaniem (wolniej)'
$chkSecure.Location = New-Object Drawing.Point(0, 354)
$chkSecure.Size = New-Object Drawing.Size(700, 24)
$chkSecure.ForeColor = $text
$paneClean.Controls.Add($chkSecure)

# --- panel zabezpieczeń ---

$secDefs = @(
    @{ Id = 'bitlocker'; Name = 'Szyfrowanie dysku (BitLocker)' },
    @{ Id = 'secureboot'; Name = 'Secure Boot' },
    @{ Id = 'disk'; Name = 'Typ dysku systemowego' },
    @{ Id = 'trim'; Name = 'TRIM (czyszczenie SSD)' },
    @{ Id = 'hibernate'; Name = 'Hibernacja' },
    @{ Id = 'pagefile'; Name = 'Czyszczenie pliku wymiany przy wyłączaniu' },
    @{ Id = 'autotask'; Name = 'Automatyczne czyszczenie przy logowaniu' }
)
$secRows = @{}
$y = 0
foreach ($s in $secDefs) {
    $r = New-Object Windows.Forms.Panel
    $r.Location = New-Object Drawing.Point(0, $y)
    $r.Size = New-Object Drawing.Size(700, 36)
    $r.BackColor = $panel

    $n = New-Object Windows.Forms.Label
    $n.Text = $s.Name
    $n.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
    $n.Location = New-Object Drawing.Point(10, 2)
    $n.Size = New-Object Drawing.Size(400, 18)
    $r.Controls.Add($n)

    $t = New-Object Windows.Forms.Label
    $t.Text = '...'
    $t.Font = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
    $t.TextAlign = 'MiddleRight'
    $t.Location = New-Object Drawing.Point(450, 2)
    $t.Size = New-Object Drawing.Size(240, 18)
    $r.Controls.Add($t)

    $h = New-Object Windows.Forms.Label
    $h.Text = ''
    $h.ForeColor = $muted
    $h.Font = New-Object Drawing.Font('Segoe UI', 8.5)
    $h.Location = New-Object Drawing.Point(10, 19)
    $h.Size = New-Object Drawing.Size(680, 16)
    $r.Controls.Add($h)

    $paneSec.Controls.Add($r)
    $secRows[$s.Id] = @{ Status = $t; Hint = $h }
    $y += 40
}

$btnRefresh = New-FlatButton 'Odśwież' 0 292 140 $panel $paneSec
$btnEnc = New-FlatButton 'Ustawienia szyfrowania' 150 292 200 $green $paneSec
$btnHib = New-FlatButton 'Wyłącz hibernację' 360 292 160 $panel $paneSec
$btnPage = New-FlatButton 'Czyść plik wymiany' 530 292 170 $panel $paneSec
$btnTrim = New-FlatButton 'Włącz TRIM' 0 336 140 $panel $paneSec
$btnAuto = New-FlatButton 'Włącz / wyłącz auto-czyszczenie przy logowaniu' 150 336 370 $panel $paneSec

# --- dziennik ---

$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.Location = New-Object Drawing.Point(20, 528)
$log.Size = New-Object Drawing.Size(700, 158)
$log.BackColor = $panel
$log.ForeColor = $text
$log.BorderStyle = 'None'
$log.Font = New-Object Drawing.Font('Consolas', 9.5)
$form.Controls.Add($log)

function Write-Log($msg) {
    $log.AppendText("$msg`r`n")
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Busy($busy) {
    foreach ($b in $btnScan, $btnClean, $btnQuick, $btnAll) { $b.Enabled = -not $busy }
    $form.Cursor = $(if ($busy) { 'WaitCursor' } else { 'Default' })
}

function Test-BrowsersRunning {
    return [bool](Get-Process -Name 'chrome', 'msedge', 'brave', 'firefox' -ErrorAction SilentlyContinue)
}

function Update-Security {
    $form.Cursor = 'WaitCursor'
    foreach ($it in (Get-SecurityStatus)) {
        $r = $secRows[$it.Id]
        $r.Status.Text = $it.Text
        $r.Status.ForeColor = switch ($it.State) { 'ok' { $green } 'warn' { $amber } default { $muted } }
        $r.Hint.Text = $it.Hint
    }
    $form.Cursor = 'Default'
}

function Test-AdminOrWarn {
    if ($isAdmin) { return $true }
    [void][System.Windows.Forms.MessageBox]::Show('Ta czynność wymaga administratora. Kliknij „Uruchom jako administrator” u góry okna.', '007 Deleter', 'OK', 'Information')
    return $false
}

function Switch-Pane($sec) {
    $paneClean.Visible = -not $sec
    $paneSec.Visible = $sec
    $navClean.BackColor = $(if ($sec) { $panel } else { $green })
    $navSec.BackColor = $(if ($sec) { $green } else { $panel })
    if ($sec) { Update-Security }
}

function Invoke-Selected($chosen) {
    if ($chosen.Count -eq 0) { Write-Log 'Nic nie zaznaczono.'; return }

    $names = ($chosen | ForEach-Object { '  - ' + $_.Name }) -join "`n"
    $note = ''
    if ($chkSecure.Checked) { $note = "`n`nTryb bezpieczny: pliki zostaną nadpisane, odzyskanie ich będzie praktycznie niemożliwe." }
    $ask = [System.Windows.Forms.MessageBox]::Show("Usunąć bezpowrotnie:`n`n$names`n`nTego nie da się cofnąć.$note", '007 Deleter', 'YesNo', 'Warning')
    if ($ask -ne 'Yes') { return }

    Set-Busy $true
    $log.Clear()
    if (Test-BrowsersRunning) { Write-Log 'Uwaga: przeglądarka jest włączona, część plików będzie zablokowana. Zamknij ją i powtórz.' }

    $freed = 0
    foreach ($c in $chosen) {
        Write-Log "Czyszczę: $($c.Name)..."
        $res = Invoke-Category $c $chkSecure.Checked
        $freed += $res.Bytes
        $rows[$c.Id].Size.Text = ''
        if ($c.Files) { Write-Log ("  usunięto {0} plików ({1}), pominięto {2} (w użyciu)" -f $res.Ok, (Format-Size $res.Bytes), $res.Fail) }
        if ($res.Err) { Write-Log '  nie udało się wykonać akcji' }
        elseif (-not $c.Files) { Write-Log '  gotowe' }
    }
    Write-Log ''
    Write-Log ("Koniec. Odzyskano {0}." -f (Format-Size $freed))
    Set-Busy $false
}

# ---------- akcje ----------

$selected = { $categories | Where-Object { $rows[$_.Id].Check.Checked } }

$navClean.Add_Click({ Switch-Pane $false })
$navSec.Add_Click({ Switch-Pane $true })

$btnAll.Add_Click({
    foreach ($c in $categories) {
        if ($rows[$c.Id].Check.Enabled -and $c.Id -notin 'freespace', 'ffhist', 'wifi') { $rows[$c.Id].Check.Checked = $true }
    }
})

$btnAdmin.Add_Click({
    try {
        $self = Get-SelfPath
        if ($PSCommandPath) {
            Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$self`""
        } else {
            Start-Process $self -Verb RunAs
        }
        $form.Close()
    } catch { Write-Log 'Anulowano: brak zgody na uruchomienie jako administrator.' }
})

$chkSecure.Add_CheckedChanged({
    if ($chkSecure.Checked -and $script:diskInfo.Ssd -eq $true) {
        $a = [System.Windows.Forms.MessageBox]::Show("Masz dysk SSD. Nadpisanie plików nie gwarantuje na nim usunięcia danych (kontroler dysku może zostawić stare kopie) i zużywa dysk.`n`nLepsza ochrona to szyfrowanie dysku i TRIM (zakładka Zabezpieczenia).`n`nWłączyć mimo to?", '007 Deleter', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { $chkSecure.Checked = $false }
    }
})

$rows['freespace'].Check.Add_CheckedChanged({
    if ($rows['freespace'].Check.Checked -and $script:diskInfo.Ssd -eq $true) {
        $a = [System.Windows.Forms.MessageBox]::Show("Masz dysk SSD. Nadpisywanie wolnego miejsca na SSD jest zawodne i zużywa dysk. Lepiej użyć opcji TRIM.`n`nWłączyć mimo to?", '007 Deleter', 'YesNo', 'Warning')
        if ($a -ne 'Yes') { $rows['freespace'].Check.Checked = $false }
    }
})

$btnScan.Add_Click({
    Set-Busy $true
    $log.Clear()
    Write-Log 'Skanowanie...'
    $total = 0
    foreach ($c in (& $selected)) {
        if ($c.Files) {
            $files = @(& $c.Files)
            $bytes = ($files | Measure-Object -Property Length -Sum).Sum
            if (-not $bytes) { $bytes = 0 }
            $total += $bytes
            $rows[$c.Id].Size.Text = Format-Size $bytes
            Write-Log ("{0}: {1} plików, {2}" -f $c.Name, $files.Count, (Format-Size $bytes))
        } else {
            $rows[$c.Id].Size.Text = 'akcja'
        }
    }
    Write-Log ("Razem do usunięcia: {0}" -f (Format-Size $total))
    Set-Busy $false
})

$btnClean.Add_Click({ Invoke-Selected @(& $selected) })

$btnQuick.Add_Click({
    Invoke-Selected @($categories | Where-Object { $_.Default -and (-not $_.Admin -or $isAdmin) })
})

$btnRefresh.Add_Click({ Update-Security })

$btnEnc.Add_Click({
    try { Start-Process 'ms-settings:deviceencryption' }
    catch { try { Start-Process control.exe -ArgumentList '/name Microsoft.BitLockerDriveEncryption' } catch { Write-Log 'Nie udało się otworzyć ustawień szyfrowania.' } }
})

$btnHib.Add_Click({
    if (-not (Test-AdminOrWarn)) { return }
    powercfg /h off | Out-Null
    Write-Log 'Hibernacja wyłączona (szybkie uruchamianie Windows też przestanie z niej korzystać).'
    Update-Security
})

$btnPage.Add_Click({
    if (-not (Test-AdminOrWarn)) { return }
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name ClearPageFileAtShutdown -Value 1 -Type DWord
    Write-Log 'Plik wymiany będzie czyszczony przy wyłączaniu. Zmiana działa po ponownym uruchomieniu komputera.'
    Update-Security
})

$btnTrim.Add_Click({
    if (-not (Test-AdminOrWarn)) { return }
    fsutil behavior set DisableDeleteNotify 0 | Out-Null
    Write-Log 'TRIM włączony.'
    Update-Security
})

$btnAuto.Add_Click({
    if (-not (Test-AdminOrWarn)) { return }
    try {
        if (Get-AutoTaskInstalled) {
            Disable-AutoTask
            Write-Log 'Automatyczne czyszczenie wyłączone, kopia programu usunięta z komputera.'
        } else {
            $a = [System.Windows.Forms.MessageBox]::Show("Program skopiuje się do folderu:`n$env:LOCALAPPDATA\007Deleter`ni przy każdym logowaniu wykona szybkie czyszczenie. To zostawia na komputerze ślad, że używasz tego programu.`n`nWłączyć?", '007 Deleter', 'YesNo', 'Question')
            if ($a -ne 'Yes') { return }
            Enable-AutoTask
            Write-Log 'Automatyczne czyszczenie włączone.'
        }
    } catch { Write-Log 'Nie udało się zmienić zadania automatycznego.' }
    Update-Security
})

$diskStart = Get-SystemDiskInfo
$script:diskInfo = $diskStart
Write-Log 'Gotowy. Wybierz kategorie i kliknij „Skanuj” albo „Wyczyść zaznaczone”.'
Write-Log "Dysk systemowy: $($diskStart.Type). Stan zabezpieczeń znajdziesz w zakładce „Zabezpieczenia”."
[void]$form.ShowDialog()
