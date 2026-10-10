# 007 Deleter - portable Windows privacy cleaner / przenośny czyścik śladów użytkowania Windows.
# Runs from USB or disk, no install. Writes nothing to the medium it runs from.
# Does not touch passwords, bookmarks or your documents.
# Headless mode: 007Deleter.ps1 -Quick (cleans the default set and exits).

param([switch]$Quick, [string]$Preview)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$script:ui = $false
$taskName = '007Deleter-logowanie'

# ---------- narzędzia / tools ----------

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

# Overwrites a file with random data, renames it, then deletes it.
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

# ---------- kategorie / categories ----------
# Files = files to delete (size is counted), Extra = extra action (no size)

$categories = @(
    @{ Id = 'thumbs'; Default = $true
       Name = @{ pl = 'Miniatury i ikony'; en = 'Thumbnails and icons' }
       Desc = @{ pl = 'Pokazują, jakie zdjęcia i filmy były w folderach, nawet po ich usunięciu'; en = 'Reveal which photos and videos were in folders, even after they were deleted' }
       Files = {
           Get-Files "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" 'thumbcache_*.db' $false
           Get-Files "$env:LOCALAPPDATA\Microsoft\Windows\Explorer" 'iconcache_*.db' $false
           Get-Files "$env:LOCALAPPDATA" 'IconCache.db' $false
       } },
    @{ Id = 'temp'; Default = $true
       Name = @{ pl = 'Pliki tymczasowe'; en = 'Temporary files' }
       Desc = @{ pl = 'Folder TEMP użytkownika: resztki instalatorów, rozpakowanych plików, dokumentów'; en = 'User TEMP folder: leftovers of installers, unpacked files and documents' }
       Files = { Get-Files $env:TEMP } },
    @{ Id = 'recent'; Default = $true
       Name = @{ pl = 'Ostatnio używane pliki'; en = 'Recent files' }
       Desc = @{ pl = 'Lista „Ostatnie” i skoki na pasku zadań: ujawniają, co otwierano'; en = 'The Recent list and taskbar jump lists: they show what you opened' }
       Files = { Get-Files "$env:APPDATA\Microsoft\Windows\Recent" } },
    @{ Id = 'office'; Default = $true
       Name = @{ pl = 'Ostatnie pliki Office'; en = 'Office recent files' }
       Desc = @{ pl = 'Listy ostatnich dokumentów w Wordzie, Excelu i PowerPoincie'; en = 'Recent document lists in Word, Excel and PowerPoint' }
       Files = { Get-Files "$env:APPDATA\Microsoft\Office\Recent" }
       Extra = {
           foreach ($v in '14.0', '15.0', '16.0') {
               foreach ($a in 'Word', 'Excel', 'PowerPoint') {
                   $b = "HKCU:\Software\Microsoft\Office\$v\$a"
                   Remove-Keys @("$b\File MRU", "$b\Place MRU", "$b\User MRU")
               }
           }
       } },
    @{ Id = 'regmru'; Default = $true
       Name = @{ pl = 'Historia uruchamiania i wyszukiwania'; en = 'Run and search history' }
       Desc = @{ pl = 'Okno „Uruchom”, wpisane ścieżki, wyszukiwania w Eksploratorze'; en = 'The Run box, typed paths, File Explorer searches' }
       Extra = {
           $b = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
           Remove-Keys @("$b\RunMRU", "$b\TypedPaths", "$b\WordWheelQuery", "$b\RecentDocs")
       } },
    @{ Id = 'userassist'; Default = $true
       Name = @{ pl = 'Ślady uruchamianych programów'; en = 'Program launch traces' }
       Desc = @{ pl = 'Rejestr UserAssist: lista programów i liczba ich uruchomień'; en = 'UserAssist registry: which programs were run and how many times' }
       Extra = { Remove-Keys @('HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist') } },
    @{ Id = 'shellbags'; Default = $false
       Name = @{ pl = 'Ślady przeglądanych folderów'; en = 'Browsed folder traces' }
       Desc = @{ pl = 'Rejestr ShellBags: foldery otwierane w Eksploratorze (też z pendrive''ów). Resetuje widok folderów'; en = 'ShellBags registry: folders opened in File Explorer (also on USB drives). Resets folder views' }
       Extra = {
           Remove-Keys @(
               'HKCU:\Software\Microsoft\Windows\Shell\BagMRU', 'HKCU:\Software\Microsoft\Windows\Shell\Bags',
               'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\BagMRU',
               'HKCU:\Software\Classes\Local Settings\Software\Microsoft\Windows\Shell\Bags')
       } },
    @{ Id = 'timeline'; Default = $true
       Name = @{ pl = 'Historia aktywności Windows'; en = 'Windows activity history' }
       Desc = @{ pl = 'Oś czasu: aplikacje i pliki z ostatnich dni (plik może być zajęty przez system)'; en = 'Timeline: apps and files from recent days (the file may be locked by the system)' }
       Files = { Get-Files "$env:LOCALAPPDATA\ConnectedDevicesPlatform" 'ActivitiesCache.db*' } },
    @{ Id = 'clip'; Default = $true
       Name = @{ pl = 'Schowek'; en = 'Clipboard' }
       Desc = @{ pl = 'Skopiowane teksty i dane, także hasła skopiowane z menedżera'; en = 'Copied text and data, including passwords copied from a manager' }
       Extra = { [System.Windows.Forms.Clipboard]::Clear() } },
    @{ Id = 'browsercache'; Default = $true
       Name = @{ pl = 'Pamięć podręczna przeglądarek'; en = 'Browser cache' }
       Desc = @{ pl = 'Chrome, Edge, Brave, Firefox: kopie odwiedzonych stron i obrazów (zamknij przeglądarki)'; en = 'Chrome, Edge, Brave, Firefox: copies of visited pages and images (close browsers first)' }
       Files = {
           foreach ($p in Get-ChromiumProfiles) {
               foreach ($s in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') { Get-Files (Join-Path $p $s) }
           }
           foreach ($p in Get-FirefoxProfiles "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles") { Get-Files (Join-Path $p 'cache2') }
       } },
    @{ Id = 'browserhist'; Default = $false
       Name = @{ pl = 'Historia przeglądarek (Chromium)'; en = 'Browser history (Chromium)' }
       Desc = @{ pl = 'Chrome, Edge, Brave: odwiedzone strony i lista pobranych plików. Zakładki i hasła zostają'; en = 'Chrome, Edge, Brave: visited pages and download list. Bookmarks and passwords stay' }
       Files = {
           foreach ($p in Get-ChromiumProfiles) {
               foreach ($f in 'History', 'History-journal', 'Top Sites', 'Visited Links', 'Network Action Predictor') {
                   $x = Join-Path $p $f
                   if (Test-Path -LiteralPath $x -PathType Leaf) { Get-Item -LiteralPath $x -Force }
               }
           }
       } },
    @{ Id = 'ffhist'; Default = $false
       Name = @{ pl = 'Historia Firefoksa (usuwa też zakładki!)'; en = 'Firefox history (also deletes bookmarks!)' }
       Desc = @{ pl = 'Historia i autouzupełnianie. Firefox trzyma zakładki w tym samym pliku, więc znikną razem z nią'; en = 'History and autofill. Firefox keeps bookmarks in the same file, so they disappear too' }
       Files = {
           foreach ($p in Get-FirefoxProfiles "$env:APPDATA\Mozilla\Firefox\Profiles") {
               foreach ($f in 'places.sqlite', 'places.sqlite-wal', 'places.sqlite-shm', 'formhistory.sqlite') {
                   $x = Join-Path $p $f
                   if (Test-Path -LiteralPath $x -PathType Leaf) { Get-Item -LiteralPath $x -Force }
               }
           }
       } },
    @{ Id = 'cookies'; Default = $false
       Name = @{ pl = 'Ciasteczka przeglądarek (wylogowuje ze stron)'; en = 'Browser cookies (signs you out of sites)' }
       Desc = @{ pl = 'Chrome, Edge, Brave, Firefox: po usunięciu trzeba logować się ponownie'; en = 'Chrome, Edge, Brave, Firefox: you will have to sign in to sites again' }
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
    @{ Id = 'wer'; Default = $true
       Name = @{ pl = 'Raporty błędów Windows'; en = 'Windows error reports' }
       Desc = @{ pl = 'Zrzuty pamięci i raporty awarii aplikacji, mogą zawierać fragmenty danych'; en = 'Memory dumps and crash reports, may contain fragments of your data' }
       Files = {
           Get-Files "$env:LOCALAPPDATA\Microsoft\Windows\WER"
           Get-Files "$env:LOCALAPPDATA\CrashDumps"
       } },
    @{ Id = 'dns'; Default = $true
       Name = @{ pl = 'Pamięć DNS'; en = 'DNS cache' }
       Desc = @{ pl = 'Lista adresów stron odwiedzonych w tej sesji sieciowej'; en = 'List of websites visited in this network session' }
       Extra = { ipconfig /flushdns | Out-Null } },
    @{ Id = 'bin'; Default = $false
       Name = @{ pl = 'Kosz'; en = 'Recycle Bin' }
       Desc = @{ pl = 'Opróżnia kosz na wszystkich dyskach. Tego nie da się cofnąć'; en = 'Empties the Recycle Bin on all drives. This cannot be undone' }
       Extra = { Clear-RecycleBin -Force -ErrorAction SilentlyContinue } },
    @{ Id = 'wifi'; Default = $false; Admin = $true
       Name = @{ pl = 'Zapisane sieci Wi-Fi'; en = 'Saved Wi-Fi networks' }
       Desc = @{ pl = 'Usuwa listę znanych sieci wraz z hasłami. Trzeba będzie połączyć się ponownie'; en = 'Removes known networks and their passwords. You will have to reconnect' }
       Extra = { netsh wlan delete profile name=* i=* | Out-Null } },
    @{ Id = 'eventlog'; Default = $false; Admin = $true
       Name = @{ pl = 'Dzienniki zdarzeń Windows'; en = 'Windows event logs' }
       Desc = @{ pl = 'Logowania, uruchomienia, podłączone urządzenia. Windows zapisze, że dziennik wyczyszczono'; en = 'Sign-ins, startups, connected devices. Windows will record that the log was cleared' }
       Extra = {
           foreach ($n in @(wevtutil el)) {
               wevtutil cl "$n" 2>$null
               if ($script:ui) { [System.Windows.Forms.Application]::DoEvents() }
           }
       } },
    @{ Id = 'prefetch'; Default = $false; Admin = $true
       Name = @{ pl = 'Prefetch'; en = 'Prefetch' }
       Desc = @{ pl = 'Lista programów uruchamianych na tym komputerze wraz z datami'; en = 'List of programs run on this computer with dates' }
       Files = { Get-Files "$env:SystemRoot\Prefetch" '*.pf' $false } },
    @{ Id = 'trim'; Default = $false; Admin = $true
       Name = @{ pl = 'Wyślij TRIM do dysku SSD'; en = 'Send TRIM to the SSD' }
       Desc = @{ pl = 'Prosi SSD o fizyczne wyczyszczenie bloków po usuniętych plikach. Zrób po czyszczeniu'; en = 'Asks the SSD to physically erase blocks of deleted files. Do it after cleaning' }
       Extra = { Optimize-Volume -DriveLetter $env:SystemDrive.TrimEnd(':') -ReTrim -ErrorAction SilentlyContinue | Out-Null } },
    @{ Id = 'freespace'; Default = $false
       Name = @{ pl = 'Wolne miejsce na dysku systemowym'; en = 'Free space on the system drive' }
       Desc = @{ pl = 'Nadpisuje puste miejsce, by usunięte wcześniej pliki nie dały się odzyskać. Tylko HDD. Trwa długo'; en = 'Overwrites empty space so earlier deleted files cannot be recovered. HDD only. Takes long' }
       Extra = { Start-Process cmd.exe -ArgumentList "/c title 007 Deleter & cipher /w:$($env:SystemDrive)\ & pause" } }
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

# ---------- tryb bez okna / headless ----------

if ($Quick) {
    foreach ($c in $categories) {
        if ($c.Default -and (-not $c.Admin -or $isAdmin)) { Invoke-Category $c $false | Out-Null }
    }
    exit
}

# ---------- DPI, motyw / DPI, theme ----------

try {
    Add-Type -Namespace Native -Name Api -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int val, int size);
[DllImport("uxtheme.dll", CharSet = CharSet.Unicode)] public static extern int SetWindowTheme(IntPtr hWnd, string app, string id);
'@
    [void][Native.Api]::SetProcessDPIAware()
} catch { }
[System.Windows.Forms.Application]::EnableVisualStyles()

# ---------- teksty / translations ----------

$I = @{
    pl = @{
        'sub' = 'Zaznacz, co usunąć. „Skanuj” tylko pokazuje rozmiary, niczego nie kasuje.'
        'tab.clean' = 'Czyszczenie'; 'tab.sec' = 'Zabezpieczenia'
        'admin.btn' = 'Uruchom jako administrator'; 'admin.on' = 'Tryb administratora'
        'adm.suffix' = '  ·  wymaga administratora'
        'btn.scan' = 'Skanuj'; 'btn.clean' = 'Wyczyść zaznaczone'; 'btn.quick' = 'Szybkie czyszczenie'; 'btn.all' = 'Zaznacz wszystko'
        'secure' = 'Bezpieczne usuwanie: nadpisz pliki losowymi danymi przed skasowaniem (wolniej)'
        'btn.refresh' = 'Odśwież'; 'btn.enc' = 'Ustawienia szyfrowania'; 'btn.hib' = 'Wyłącz hibernację'
        'btn.page' = 'Czyść plik wymiany'; 'btn.trim' = 'Włącz TRIM'; 'btn.auto' = 'Auto-czyszczenie przy logowaniu: włącz / wyłącz'
        'action' = 'akcja'
        's.bitlocker' = 'Szyfrowanie dysku (BitLocker)'; 's.secureboot' = 'Secure Boot'; 's.disk' = 'Typ dysku systemowego'
        's.trim' = 'TRIM (czyszczenie SSD)'; 's.hibernate' = 'Hibernacja'; 's.pagefile' = 'Czyszczenie pliku wymiany przy wyłączaniu'
        's.autotask' = 'Automatyczne czyszczenie przy logowaniu'
        'tx.en_n' = 'włączone'; 'tx.en_m' = 'włączony'; 'tx.en_f' = 'włączona'
        'tx.dis_n' = 'wyłączone'; 'tx.dis_m' = 'wyłączony'; 'tx.dis_f' = 'wyłączona'
        'tx.susp' = 'wstrzymane'; 'tx.unk' = 'nie udało się sprawdzić'; 'tx.noinfo' = 'brak informacji'; 'tx.na' = 'nie dotyczy'
        'tx.ssd' = 'SSD'; 'tx.hdd' = 'HDD (dysk talerzowy)'; 'tx.disk.unk' = 'nieznany'
        'h.bl.unk' = 'Sprawdź w Ustawieniach: Prywatność i zabezpieczenia, Szyfrowanie urządzenia.'
        'h.bl.on' = 'Dane na dysku są nieczytelne bez Twojego logowania lub klucza.'
        'h.bl.susp' = 'Szyfrowanie jest chwilowo wyłączone. Wznów je w ustawieniach BitLockera.'
        'h.bl.off' = 'Najważniejsze zabezpieczenie. Bez niego dysk można odczytać po wyjęciu z laptopa.'
        'h.sb.unk' = 'Starszy BIOS lub brak UEFI. Włącz Secure Boot w BIOS-ie, jeśli to możliwe.'
        'h.sb.on' = 'Komputer nie uruchomi podejrzanego systemu z pendrive''a.'
        'h.sb.off' = 'Włącz w BIOS-ie. Ustaw też hasło do BIOS-u.'
        'h.disk.ssd' = 'Na SSD nadpisywanie plików nie daje pewności. Polegaj na szyfrowaniu i TRIM.'
        'h.disk.hdd' = 'Na dysku talerzowym nadpisywanie plików działa dobrze.'
        'h.disk.unk' = 'Nie udało się rozpoznać typu dysku.'
        'h.trim.na' = 'TRIM jest potrzebny tylko dla SSD.'
        'h.trim.on' = 'Windows informuje SSD o usuniętych plikach, a dysk je czyści.'
        'h.trim.off' = 'Użyj przycisku „Włącz TRIM” poniżej (administrator).'
        'h.trim.unk' = 'Spróbuj jako administrator.'
        'h.hib.on' = 'Zapisuje całą pamięć RAM na dysk, w tym hasła i otwarte dokumenty.'
        'h.hib.off' = 'Pamięć RAM nie trafia na dysk przy wyłączaniu.'
        'h.pf.on' = 'Plik wymiany jest zerowany przy każdym wyłączeniu (wyłączanie trwa dłużej).'
        'h.pf.off' = 'Plik wymiany może zawierać fragmenty tego, co robiłeś. Włącz czyszczenie poniżej.'
        'h.task.on' = 'Szybkie czyszczenie uruchamia się przy każdym logowaniu.'
        'h.task.off' = 'Opcjonalne. Czyści ślady poprzedniej sesji przy logowaniu.'
        'm.title' = '007 Deleter'
        'm.admin' = 'Ta czynność wymaga administratora. Kliknij „Uruchom jako administrator” u góry okna.'
        'm.nothing' = 'Nic nie zaznaczono.'
        'm.confirm' = "Usunąć bezpowrotnie:`n`n{0}`n`nTego nie da się cofnąć.{1}"
        'm.secnote' = "`n`nTryb bezpieczny: pliki zostaną nadpisane, odzyskanie ich będzie praktycznie niemożliwe."
        'm.browser' = 'Uwaga: przeglądarka jest włączona, część plików będzie zablokowana. Zamknij ją i powtórz.'
        'm.cleaning' = 'Czyszczę: {0}...'
        'm.removed' = '  usunięto {0} plików ({1}), pominięto {2} (w użyciu)'
        'm.err' = '  nie udało się wykonać akcji'
        'm.done' = '  gotowe'
        'm.finished' = 'Koniec. Odzyskano {0}.'
        'm.scanning' = 'Skanowanie...'
        'm.scanrow' = '{0}: {1} plików, {2}'
        'm.total' = 'Razem do usunięcia: {0}'
        'm.ready' = 'Gotowy. Wybierz kategorie i kliknij „Skanuj” albo „Wyczyść zaznaczone”.'
        'm.disk' = 'Dysk systemowy: {0}. Stan zabezpieczeń znajdziesz w zakładce „Zabezpieczenia”.'
        'm.ssdsecure' = "Masz dysk SSD. Nadpisanie plików nie gwarantuje na nim usunięcia danych (kontroler dysku może zostawić stare kopie) i zużywa dysk.`n`nLepsza ochrona to szyfrowanie dysku i TRIM (zakładka Zabezpieczenia).`n`nWłączyć mimo to?"
        'm.ssdfree' = "Masz dysk SSD. Nadpisywanie wolnego miejsca na SSD jest zawodne i zużywa dysk. Lepiej użyć opcji TRIM.`n`nWłączyć mimo to?"
        'm.hib.done' = 'Hibernacja wyłączona (szybkie uruchamianie Windows też przestanie z niej korzystać).'
        'm.page.done' = 'Plik wymiany będzie czyszczony przy wyłączaniu. Zmiana działa po ponownym uruchomieniu komputera.'
        'm.trim.done' = 'TRIM włączony.'
        'm.auto.on' = 'Automatyczne czyszczenie włączone.'
        'm.auto.off' = 'Automatyczne czyszczenie wyłączone, kopia programu usunięta z komputera.'
        'm.auto.confirm' = "Program skopiuje się do folderu:`n{0}`ni przy każdym logowaniu wykona szybkie czyszczenie. To zostawia na komputerze ślad, że używasz tego programu.`n`nWłączyć?"
        'm.auto.fail' = 'Nie udało się zmienić zadania automatycznego.'
        'm.adm.cancel' = 'Anulowano: brak zgody na uruchomienie jako administrator.'
        'm.enc.fail' = 'Nie udało się otworzyć ustawień szyfrowania.'
    }
    en = @{
        'sub' = 'Choose what to remove. "Scan" only shows sizes and deletes nothing.'
        'tab.clean' = 'Cleaning'; 'tab.sec' = 'Security'
        'admin.btn' = 'Run as administrator'; 'admin.on' = 'Administrator mode'
        'adm.suffix' = '  ·  requires administrator'
        'btn.scan' = 'Scan'; 'btn.clean' = 'Clean selected'; 'btn.quick' = 'Quick clean'; 'btn.all' = 'Select all'
        'secure' = 'Secure delete: overwrite files with random data before deleting (slower)'
        'btn.refresh' = 'Refresh'; 'btn.enc' = 'Encryption settings'; 'btn.hib' = 'Turn off hibernation'
        'btn.page' = 'Clear page file'; 'btn.trim' = 'Enable TRIM'; 'btn.auto' = 'Auto-clean at sign-in: on / off'
        'action' = 'action'
        's.bitlocker' = 'Disk encryption (BitLocker)'; 's.secureboot' = 'Secure Boot'; 's.disk' = 'System drive type'
        's.trim' = 'TRIM (SSD cleanup)'; 's.hibernate' = 'Hibernation'; 's.pagefile' = 'Clear page file at shutdown'
        's.autotask' = 'Automatic cleaning at sign-in'
        'tx.en_n' = 'enabled'; 'tx.en_m' = 'enabled'; 'tx.en_f' = 'enabled'
        'tx.dis_n' = 'disabled'; 'tx.dis_m' = 'disabled'; 'tx.dis_f' = 'disabled'
        'tx.susp' = 'suspended'; 'tx.unk' = 'could not check'; 'tx.noinfo' = 'no information'; 'tx.na' = 'not applicable'
        'tx.ssd' = 'SSD'; 'tx.hdd' = 'HDD (spinning disk)'; 'tx.disk.unk' = 'unknown'
        'h.bl.unk' = 'Check in Settings: Privacy and security, Device encryption.'
        'h.bl.on' = 'Data on the disk is unreadable without your sign-in or key.'
        'h.bl.susp' = 'Encryption is temporarily off. Resume it in BitLocker settings.'
        'h.bl.off' = 'The most important protection. Without it the disk can be read after removing it from the laptop.'
        'h.sb.unk' = 'Older BIOS or no UEFI. Enable Secure Boot in BIOS if possible.'
        'h.sb.on' = 'The computer will not boot a suspicious system from a USB drive.'
        'h.sb.off' = 'Enable it in BIOS. Also set a BIOS password.'
        'h.disk.ssd' = 'On an SSD, overwriting files is not reliable. Rely on encryption and TRIM.'
        'h.disk.hdd' = 'On a spinning disk, overwriting files works well.'
        'h.disk.unk' = 'Could not recognise the drive type.'
        'h.trim.na' = 'TRIM is only needed for SSDs.'
        'h.trim.on' = 'Windows tells the SSD about deleted files and the drive cleans them.'
        'h.trim.off' = 'Use the "Enable TRIM" button below (administrator).'
        'h.trim.unk' = 'Try as administrator.'
        'h.hib.on' = 'Writes all RAM to disk, including passwords and open documents.'
        'h.hib.off' = 'RAM is not written to disk on shutdown.'
        'h.pf.on' = 'The page file is zeroed on every shutdown (shutdown takes longer).'
        'h.pf.off' = 'The page file may contain fragments of what you did. Enable clearing below.'
        'h.task.on' = 'Quick clean runs at every sign-in.'
        'h.task.off' = 'Optional. Cleans traces of the previous session at sign-in.'
        'm.title' = '007 Deleter'
        'm.admin' = 'This action needs administrator rights. Click "Run as administrator" at the top of the window.'
        'm.nothing' = 'Nothing selected.'
        'm.confirm' = "Permanently delete:`n`n{0}`n`nThis cannot be undone.{1}"
        'm.secnote' = "`n`nSecure mode: files will be overwritten, recovering them will be practically impossible."
        'm.browser' = 'Warning: a browser is running, some files will be locked. Close it and try again.'
        'm.cleaning' = 'Cleaning: {0}...'
        'm.removed' = '  removed {0} files ({1}), skipped {2} (in use)'
        'm.err' = '  the action failed'
        'm.done' = '  done'
        'm.finished' = 'Finished. Freed {0}.'
        'm.scanning' = 'Scanning...'
        'm.scanrow' = '{0}: {1} files, {2}'
        'm.total' = 'Total to remove: {0}'
        'm.ready' = 'Ready. Choose categories and click "Scan" or "Clean selected".'
        'm.disk' = 'System drive: {0}. Find your security status in the "Security" tab.'
        'm.ssdsecure' = "You have an SSD. Overwriting files does not guarantee deletion on it (the drive controller may keep old copies) and wears the drive.`n`nBetter protection is disk encryption and TRIM (Security tab).`n`nEnable anyway?"
        'm.ssdfree' = "You have an SSD. Overwriting free space on an SSD is unreliable and wears the drive. Use the TRIM option instead.`n`nEnable anyway?"
        'm.hib.done' = 'Hibernation turned off (Windows fast startup will stop using it too).'
        'm.page.done' = 'The page file will be cleared at shutdown. The change takes effect after a restart.'
        'm.trim.done' = 'TRIM enabled.'
        'm.auto.on' = 'Automatic cleaning enabled.'
        'm.auto.off' = 'Automatic cleaning disabled, program copy removed from this computer.'
        'm.auto.confirm' = "The program will copy itself to:`n{0}`nand run a quick clean at every sign-in. This leaves a trace on the computer that you use this program.`n`nEnable?"
        'm.auto.fail' = 'Could not change the automatic task.'
        'm.adm.cancel' = 'Cancelled: administrator permission was not granted.'
        'm.enc.fail' = 'Could not open encryption settings.'
    }
}
$script:lang = $(if ((Get-Culture).TwoLetterISOLanguageName -eq 'pl') { 'pl' } else { 'en' })
function T([string]$k) { return $I[$script:lang][$k] }
function Tc($h) { return $h[$script:lang] }

# ---------- stan zabezpieczeń / security status ----------

function Get-SystemDiskInfo {
    $r = @{ Type = 'unk'; Ssd = $null }
    try {
        $part = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
        $pd = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq "$($part.DiskNumber)" } | Select-Object -First 1
        if ($pd) {
            if ($pd.MediaType -eq 'SSD' -or $pd.BusType -eq 'NVMe') { $r.Type = 'ssd'; $r.Ssd = $true }
            elseif ($pd.MediaType -eq 'HDD') { $r.Type = 'hdd'; $r.Ssd = $false }
        }
    } catch { }
    return $r
}

function Get-AutoTaskInstalled {
    try { return [bool](Get-ScheduledTask -TaskName $taskName -ErrorAction Stop) } catch { return $false }
}

# Returns items with translation KEYS (Text, Hint) so the view can be re-translated.
function Get-SecurityStatus {
    $items = @()
    $disk = Get-SystemDiskInfo
    $script:diskInfo = $disk

    $v = $null
    try { $v = (New-Object -ComObject Shell.Application).NameSpace("$env:SystemDrive\").Self.ExtendedProperty('System.Volume.BitLockerProtection') } catch { }
    if ($null -eq $v) { $st = 'unk'; $tx = 'tx.unk'; $hn = 'h.bl.unk' }
    elseif ($v -eq 1) { $st = 'ok'; $tx = 'tx.en_n'; $hn = 'h.bl.on' }
    elseif ($v -eq 5) { $st = 'warn'; $tx = 'tx.susp'; $hn = 'h.bl.susp' }
    else { $st = 'warn'; $tx = 'tx.dis_n'; $hn = 'h.bl.off' }
    $items += @{ Id = 'bitlocker'; State = $st; Text = $tx; Hint = $hn }

    $sb = $null
    try { $sb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction Stop).UEFISecureBootEnabled } catch { }
    if ($null -eq $sb) { $st = 'unk'; $tx = 'tx.noinfo'; $hn = 'h.sb.unk' }
    elseif ($sb -eq 1) { $st = 'ok'; $tx = 'tx.en_m'; $hn = 'h.sb.on' }
    else { $st = 'warn'; $tx = 'tx.dis_m'; $hn = 'h.sb.off' }
    $items += @{ Id = 'secureboot'; State = $st; Text = $tx; Hint = $hn }

    if ($disk.Ssd -eq $true) { $st = 'warn'; $tx = 'tx.ssd'; $hn = 'h.disk.ssd' }
    elseif ($disk.Ssd -eq $false) { $st = 'ok'; $tx = 'tx.hdd'; $hn = 'h.disk.hdd' }
    else { $st = 'unk'; $tx = 'tx.disk.unk'; $hn = 'h.disk.unk' }
    $items += @{ Id = 'disk'; State = $st; Text = $tx; Hint = $hn }

    $trim = $null
    try { $o = (& fsutil behavior query DisableDeleteNotify 2>&1) -join ' '; if ($o -match 'DisableDeleteNotify\s*=\s*(\d)') { $trim = [int]$Matches[1] } } catch { }
    if ($disk.Ssd -eq $false) { $st = 'ok'; $tx = 'tx.na'; $hn = 'h.trim.na' }
    elseif ($trim -eq 0) { $st = 'ok'; $tx = 'tx.en_m'; $hn = 'h.trim.on' }
    elseif ($trim -eq 1) { $st = 'warn'; $tx = 'tx.dis_m'; $hn = 'h.trim.off' }
    else { $st = 'unk'; $tx = 'tx.unk'; $hn = 'h.trim.unk' }
    $items += @{ Id = 'trim'; State = $st; Text = $tx; Hint = $hn }

    $hib = $null
    try { $hib = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Power' -ErrorAction Stop).HibernateEnabled } catch { }
    if ($hib -eq 1) { $st = 'warn'; $tx = 'tx.en_f'; $hn = 'h.hib.on' }
    elseif ($hib -eq 0) { $st = 'ok'; $tx = 'tx.dis_f'; $hn = 'h.hib.off' }
    else { $st = 'unk'; $tx = 'tx.noinfo'; $hn = '' }
    $items += @{ Id = 'hibernate'; State = $st; Text = $tx; Hint = $hn }

    $pf = $null
    try { $pf = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -ErrorAction Stop).ClearPageFileAtShutdown } catch { }
    if ($pf -eq 1) { $st = 'ok'; $tx = 'tx.en_n'; $hn = 'h.pf.on' }
    else { $st = 'warn'; $tx = 'tx.dis_n'; $hn = 'h.pf.off' }
    $items += @{ Id = 'pagefile'; State = $st; Text = $tx; Hint = $hn }

    if (Get-AutoTaskInstalled) { $st = 'ok'; $tx = 'tx.en_n'; $hn = 'h.task.on' }
    else { $st = 'unk'; $tx = 'tx.dis_n'; $hn = 'h.task.off' }
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

# ---------- wygląd / look ----------

function C($hex) { return [Drawing.ColorTranslator]::FromHtml($hex) }
$cBg = C '#0E1116'; $cCard = C '#171B22'; $cCardHi = C '#1E242D'; $cBorder = C '#262C36'
$cText = C '#E8ECF1'; $cMuted = C '#8A94A3'
$cGreen = C '#1F9D63'; $cRed = C '#D64541'; $cAmber = C '#F0AA3C'; $cOff = C '#3A424E'; $cDis = C '#262B33'
$brCard = New-Object Drawing.SolidBrush($cCard)
$brBg = New-Object Drawing.SolidBrush($cBg)
$brText = New-Object Drawing.SolidBrush($cText)
$brMuted = New-Object Drawing.SolidBrush($cMuted)
$brWhite = New-Object Drawing.SolidBrush([Drawing.Color]::White)
$penBorder = New-Object Drawing.Pen($cBorder, 1)

$fTitle = New-Object Drawing.Font('Segoe UI Semibold', 22)
$fBold = New-Object Drawing.Font('Segoe UI Semibold', 10)
$fNorm = New-Object Drawing.Font('Segoe UI', 10)
$fSmall = New-Object Drawing.Font('Segoe UI', 8.5)
$fBtn = New-Object Drawing.Font('Segoe UI Semibold', 9.5)
$fMono = New-Object Drawing.Font('Consolas', 9.5)

function New-RoundPath([single]$x, [single]$y, [single]$w, [single]$h, [single]$rad) {
    $p = New-Object Drawing.Drawing2D.GraphicsPath
    $d = [Math]::Min($rad * 2, [Math]::Min($w, $h))
    $p.AddArc($x, $y, $d, $d, 180, 90)
    $p.AddArc($x + $w - $d, $y, $d, $d, 270, 90)
    $p.AddArc($x + $w - $d, $y + $h - $d, $d, $d, 0, 90)
    $p.AddArc($x, $y + $h - $d, $d, $d, 90, 90)
    $p.CloseFigure()
    return $p
}

function Set-DoubleBuffer($ctl) {
    try { $ctl.GetType().GetProperty('DoubleBuffered', [Reflection.BindingFlags]'Instance,NonPublic').SetValue($ctl, $true, $null) } catch { }
}

# paints a rounded card (the corners are masked with the page background)
$cardPaint = {
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $sf = $g.DpiX / 96
    $rp = New-RoundPath 0 0 ($s.Width - 1) ($s.Height - 1) (10 * $sf)
    $mask = New-Object Drawing.Drawing2D.GraphicsPath
    $mask.AddRectangle((New-Object Drawing.RectangleF(-1, -1, ($s.Width + 2), ($s.Height + 2))))
    $mask.AddPath($rp, $false)
    $g.FillPath($brBg, $mask)
    $g.DrawPath($penBorder, $rp)
    $mask.Dispose(); $rp.Dispose()
}

$buttonPaint = {
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.TextRenderingHint = 'ClearTypeGridFit'
    $sf = $g.DpiX / 96
    $tag = $s.Tag
    $g.Clear($s.Parent.BackColor)
    switch ($tag.Style) {
        'primary' { $fill = $cGreen }
        'danger' { $fill = $cRed }
        'tab' { $fill = $(if ($tag.Active) { $cCardHi } else { $cBg }) }
        default { $fill = $cCardHi }
    }
    $txt = $cText
    if ($tag.Style -eq 'tab') { $txt = $(if ($tag.Active) { $cGreen } else { $cMuted }) }
    if ($tag.Hover -and $s.Enabled -and -not ($tag.Style -eq 'tab' -and $tag.Active)) { $fill = [Drawing.ControlPaint]::Light($fill, 0.12) }
    if (-not $s.Enabled) { $fill = $cDis; $txt = $cMuted }
    $path = New-RoundPath 0 0 ($s.Width - 1) ($s.Height - 1) (8 * $sf)
    $br = New-Object Drawing.SolidBrush($fill)
    $g.FillPath($br, $path)
    $br.Dispose(); $path.Dispose()
    if ($tag.Style -eq 'tab' -and $tag.Active) {
        $pen = New-Object Drawing.Pen($cGreen, (2 * $sf))
        $g.DrawLine($pen, (12 * $sf), ($s.Height - 3 * $sf), ($s.Width - 12 * $sf), ($s.Height - 3 * $sf))
        $pen.Dispose()
    }
    $fmt = New-Object Drawing.StringFormat
    $fmt.Alignment = 'Center'; $fmt.LineAlignment = 'Center'; $fmt.Trimming = 'EllipsisCharacter'
    $tb = New-Object Drawing.SolidBrush($txt)
    $g.DrawString($s.Text, $s.Font, $tb, (New-Object Drawing.RectangleF(4, 0, ($s.Width - 8), $s.Height)), $fmt)
    $tb.Dispose(); $fmt.Dispose()
}

$togglePaint = {
    param($s, $e)
    $g = $e.Graphics
    $g.SmoothingMode = 'AntiAlias'
    $g.Clear($s.Parent.BackColor)
    $w = $s.Width - 1; $h = $s.Height - 1
    $on = $s.Tag.On
    $track = $(if (-not $s.Enabled) { $cDis } elseif ($on) { $cGreen } else { $cOff })
    $path = New-RoundPath 0 0 $w $h ($h / 2)
    $br = New-Object Drawing.SolidBrush($track)
    $g.FillPath($br, $path)
    $br.Dispose(); $path.Dispose()
    $m = [single]($h * 0.17); $kd = $h - 2 * $m
    $kx = $(if ($on) { $w - $m - $kd } else { $m })
    $kb = $(if ($s.Enabled) { $brWhite } else { $brMuted })
    $g.FillEllipse($kb, $kx, $m, $kd, $kd)
}

function New-Button($key, $x, $y, $w, $h, $style, $parent) {
    $b = New-Object Windows.Forms.Button
    $b.Location = New-Object Drawing.Point($x, $y)
    $b.Size = New-Object Drawing.Size($w, $h)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.UseVisualStyleBackColor = $false
    $b.Font = $fBtn
    $b.Cursor = 'Hand'
    $b.Tag = @{ Key = $key; Style = $style; Hover = $false; Active = $false }
    if ($key) { $b.Text = T $key }
    $b.Add_Paint($buttonPaint)
    $b.Add_MouseEnter({ $this.Tag.Hover = $true; $this.Invalidate() })
    $b.Add_MouseLeave({ $this.Tag.Hover = $false; $this.Invalidate() })
    $b.Add_EnabledChanged({ $this.Invalidate() })
    $parent.Controls.Add($b)
    return $b
}

function New-Toggle($x, $y, $parent, [bool]$on) {
    $t = New-Object Windows.Forms.Panel
    $t.Location = New-Object Drawing.Point($x, $y)
    $t.Size = New-Object Drawing.Size(44, 24)
    $t.Cursor = 'Hand'
    Set-DoubleBuffer $t
    $state = @{ On = $on; Guard = $null; Panel = $t }
    $t.Tag = $state
    $t.Add_Paint($togglePaint)
    $t.Add_Click({ Invoke-Toggle $this.Tag })
    $t.Add_EnabledChanged({ $this.Invalidate() })
    $parent.Controls.Add($t)
    return $t
}

function Get-On($t) { return [bool]$t.Tag.On }
function Set-On($t, [bool]$v) { $t.Tag.On = $v; $t.Invalidate() }

function Invoke-Toggle($state) {
    $t = $state.Panel
    if (-not $t.Enabled) { return }
    $new = -not $state.On
    if ($new -and $state.Guard) { if (-not (& $state.Guard)) { return } }
    Set-On $t $new
}

# ---------- okno / window ----------

$script:diskInfo = @{ Type = 'unk'; Ssd = $null }
$script:secItems = @()
$script:ui = $true

$form = New-Object Windows.Forms.Form
$form.AutoScaleDimensions = New-Object Drawing.SizeF(96, 96)
$form.AutoScaleMode = 'Dpi'
$form.Text = '007 Deleter'
$form.ClientSize = New-Object Drawing.Size(740, 700)
$form.StartPosition = 'CenterScreen'
$form.BackColor = $cBg
$form.ForeColor = $cText
$form.Font = $fNorm
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
Set-DoubleBuffer $form

$form.Add_HandleCreated({
    try {
        $v = 1; [void][Native.Api]::DwmSetWindowAttribute($form.Handle, 20, [ref]$v, 4)
        $cap = 0x16110E; [void][Native.Api]::DwmSetWindowAttribute($form.Handle, 35, [ref]$cap, 4)
        $txt = 0xF1ECE8; [void][Native.Api]::DwmSetWindowAttribute($form.Handle, 36, [ref]$txt, 4)
    } catch { }
})

$title = New-Object Windows.Forms.Label
$title.Text = '007 Deleter'
$title.Font = $fTitle
$title.ForeColor = $cGreen
$title.Location = New-Object Drawing.Point(18, 10)
$title.AutoSize = $true
$form.Controls.Add($title)

$sub = New-Object Windows.Forms.Label
$sub.ForeColor = $cMuted
$sub.Font = $fNorm
$sub.Location = New-Object Drawing.Point(21, 54)
$sub.Size = New-Object Drawing.Size(470, 22)
$form.Controls.Add($sub)

$btnPL = New-Button $null 616 14 50 30 'tab' $form
$btnPL.Text = 'PL'
$btnEN = New-Button $null 670 14 50 30 'tab' $form
$btnEN.Text = 'EN'

$btnAdmin = New-Button 'admin.btn' 500 52 220 30 'ghost' $form
$adminLbl = New-Object Windows.Forms.Label
$adminLbl.Location = New-Object Drawing.Point(500, 54)
$adminLbl.Size = New-Object Drawing.Size(220, 26)
$adminLbl.TextAlign = 'MiddleRight'
$adminLbl.ForeColor = $cGreen
$adminLbl.Font = $fBold
$form.Controls.Add($adminLbl)
$btnAdmin.Visible = -not $isAdmin
$adminLbl.Visible = $isAdmin

$navClean = New-Button 'tab.clean' 20 92 170 38 'tab' $form
$navSec = New-Button 'tab.sec' 196 92 170 38 'tab' $form
$navClean.Tag.Active = $true

$paneClean = New-Object Windows.Forms.Panel
$paneClean.Location = New-Object Drawing.Point(20, 140)
$paneClean.Size = New-Object Drawing.Size(700, 400)
$paneClean.BackColor = $cBg
$form.Controls.Add($paneClean)

$paneSec = New-Object Windows.Forms.Panel
$paneSec.Location = New-Object Drawing.Point(20, 140)
$paneSec.Size = New-Object Drawing.Size(700, 400)
$paneSec.BackColor = $cBg
$paneSec.Visible = $false
$form.Controls.Add($paneSec)

# --- czyszczenie / cleaning pane ---

$list = New-Object Windows.Forms.FlowLayoutPanel
$list.Location = New-Object Drawing.Point(0, 0)
$list.Size = New-Object Drawing.Size(700, 296)
$list.FlowDirection = 'TopDown'
$list.WrapContents = $false
$list.AutoScroll = $true
$list.BackColor = $cBg
$paneClean.Controls.Add($list)
$list.Add_HandleCreated({ try { [void][Native.Api]::SetWindowTheme($list.Handle, 'DarkMode_Explorer', $null) } catch { } })

$rows = @{}
foreach ($c in $categories) {
    $card = New-Object Windows.Forms.Panel
    $card.Size = New-Object Drawing.Size(676, 66)
    $card.BackColor = $cCard
    $card.Margin = New-Object Windows.Forms.Padding(0, 0, 0, 6)
    $card.Cursor = 'Hand'
    Set-DoubleBuffer $card
    $card.Add_Paint($cardPaint)

    $tg = New-Toggle 618 21 $card ([bool]$c.Default)
    $locked = ($c.Admin -and -not $isAdmin)
    if ($locked) { Set-On $tg $false; $tg.Enabled = $false }

    $nm = New-Object Windows.Forms.Label
    $nm.Font = $fBold
    $nm.Location = New-Object Drawing.Point(16, 8)
    $nm.Size = New-Object Drawing.Size(500, 22)
    $nm.BackColor = $cCard
    $nm.ForeColor = $(if ($locked) { $cMuted } else { $cText })
    $nm.Tag = $tg.Tag
    $card.Controls.Add($nm)

    $ds = New-Object Windows.Forms.Label
    $ds.Font = $fSmall
    $ds.ForeColor = $cMuted
    $ds.Location = New-Object Drawing.Point(16, 32)
    $ds.Size = New-Object Drawing.Size(520, 30)
    $ds.BackColor = $cCard
    $ds.Tag = $tg.Tag
    $card.Controls.Add($ds)

    $sz = New-Object Windows.Forms.Label
    $sz.TextAlign = 'MiddleRight'
    $sz.Font = $fBold
    $sz.ForeColor = $cGreen
    $sz.Location = New-Object Drawing.Point(520, 20)
    $sz.Size = New-Object Drawing.Size(90, 24)
    $sz.BackColor = $cCard
    $sz.Tag = $tg.Tag
    $card.Controls.Add($sz)

    $card.Tag = $tg.Tag
    foreach ($ctl in $card, $nm, $ds, $sz) { $ctl.Add_Click({ Invoke-Toggle $this.Tag }) }

    $list.Controls.Add($card)
    $rows[$c.Id] = @{ Toggle = $tg; Name = $nm; Desc = $ds; Size = $sz; Admin = [bool]$c.Admin }
}

$btnScan = New-Button 'btn.scan' 0 308 130 40 'ghost' $paneClean
$btnClean = New-Button 'btn.clean' 140 308 190 40 'danger' $paneClean
$btnQuick = New-Button 'btn.quick' 340 308 190 40 'primary' $paneClean
$btnAll = New-Button 'btn.all' 540 308 160 40 'ghost' $paneClean

$secTg = New-Toggle 0 364 $paneClean $false
$secLbl = New-Object Windows.Forms.Label
$secLbl.Location = New-Object Drawing.Point(54, 364)
$secLbl.Size = New-Object Drawing.Size(646, 24)
$secLbl.TextAlign = 'MiddleLeft'
$secLbl.ForeColor = $cText
$secLbl.Cursor = 'Hand'
$secLbl.Tag = $secTg.Tag
$secLbl.Add_Click({ Invoke-Toggle $this.Tag })
$paneClean.Controls.Add($secLbl)

# --- zabezpieczenia / security pane ---

$secKeys = 'bitlocker', 'secureboot', 'disk', 'trim', 'hibernate', 'pagefile', 'autotask'
$secRows = @{}
$y = 0
foreach ($k in $secKeys) {
    $r = New-Object Windows.Forms.Panel
    $r.Location = New-Object Drawing.Point(0, $y)
    $r.Size = New-Object Drawing.Size(700, 44)
    $r.BackColor = $cCard
    Set-DoubleBuffer $r
    $r.Add_Paint($cardPaint)

    $n = New-Object Windows.Forms.Label
    $n.Font = $fBold
    $n.Location = New-Object Drawing.Point(16, 4)
    $n.Size = New-Object Drawing.Size(400, 20)
    $n.BackColor = $cCard
    $r.Controls.Add($n)

    $t = New-Object Windows.Forms.Label
    $t.Font = $fBold
    $t.TextAlign = 'MiddleRight'
    $t.Location = New-Object Drawing.Point(420, 4)
    $t.Size = New-Object Drawing.Size(266, 20)
    $t.BackColor = $cCard
    $r.Controls.Add($t)

    $h = New-Object Windows.Forms.Label
    $h.Font = $fSmall
    $h.ForeColor = $cMuted
    $h.Location = New-Object Drawing.Point(16, 24)
    $h.Size = New-Object Drawing.Size(670, 17)
    $h.BackColor = $cCard
    $r.Controls.Add($h)

    $paneSec.Controls.Add($r)
    $secRows[$k] = @{ Name = $n; Status = $t; Hint = $h }
    $y += 49
}

$btnRefresh = New-Button 'btn.refresh' 0 350 130 38 'ghost' $paneSec
$btnEnc = New-Button 'btn.enc' 140 350 210 38 'primary' $paneSec
$btnHib = New-Button 'btn.hib' 360 350 170 38 'ghost' $paneSec
$btnPage = New-Button 'btn.page' 540 350 160 38 'ghost' $paneSec
$btnTrim = New-Button 'btn.trim' 0 394 130 38 'ghost' $paneSec
$btnAuto = New-Button 'btn.auto' 140 394 390 38 'ghost' $paneSec
$paneSec.Size = New-Object Drawing.Size(700, 436)
$paneClean.Size = New-Object Drawing.Size(700, 436)

# --- dziennik / log ---

$logCard = New-Object Windows.Forms.Panel
$logCard.Location = New-Object Drawing.Point(20, 586)
$logCard.Size = New-Object Drawing.Size(700, 100)
$logCard.BackColor = $cCard
Set-DoubleBuffer $logCard
$logCard.Add_Paint($cardPaint)
$form.Controls.Add($logCard)

$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.Location = New-Object Drawing.Point(12, 8)
$log.Size = New-Object Drawing.Size(676, 84)
$log.BackColor = $cCard
$log.ForeColor = $cText
$log.BorderStyle = 'None'
$log.Font = $fMono
$logCard.Controls.Add($log)
$log.Add_HandleCreated({ try { [void][Native.Api]::SetWindowTheme($log.Handle, 'DarkMode_Explorer', $null) } catch { } })

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

function Show-Security {
    foreach ($it in $script:secItems) {
        $r = $secRows[$it.Id]
        $r.Status.Text = '● ' + (T $it.Text)
        $r.Status.ForeColor = switch ($it.State) { 'ok' { $cGreen } 'warn' { $cAmber } default { $cMuted } }
        $r.Hint.Text = $(if ($it.Hint) { T $it.Hint } else { '' })
    }
}

function Update-Security {
    $form.Cursor = 'WaitCursor'
    $script:secItems = @(Get-SecurityStatus)
    Show-Security
    $form.Cursor = 'Default'
}

function Switch-Pane($sec) {
    $paneClean.Visible = -not $sec
    $paneSec.Visible = $sec
    $navClean.Tag.Active = -not $sec
    $navSec.Tag.Active = $sec
    $navClean.Invalidate(); $navSec.Invalidate()
    if ($sec) { Update-Security }
}

# retranslates every visible text
function Set-Language($l) {
    $script:lang = $l
    $btnPL.Tag.Active = ($l -eq 'pl'); $btnEN.Tag.Active = ($l -eq 'en')
    $btnPL.Invalidate(); $btnEN.Invalidate()
    $sub.Text = T 'sub'
    $adminLbl.Text = T 'admin.on'
    foreach ($b in $btnAdmin, $navClean, $navSec, $btnScan, $btnClean, $btnQuick, $btnAll, $btnRefresh, $btnEnc, $btnHib, $btnPage, $btnTrim, $btnAuto) {
        $b.Text = T $b.Tag.Key
        $b.Invalidate()
    }
    $secLbl.Text = T 'secure'
    foreach ($c in $categories) {
        $r = $rows[$c.Id]
        $nameText = Tc $c.Name
        if ($c.Admin) { $nameText += (T 'adm.suffix') }
        $r.Name.Text = $nameText
        $r.Desc.Text = Tc $c.Desc
        if ($r.Size.Text -eq $I.pl['action'] -or $r.Size.Text -eq $I.en['action']) { $r.Size.Text = T 'action' }
    }
    foreach ($k in $secKeys) { $secRows[$k].Name.Text = T ("s.$k") }
    Show-Security
}

function Invoke-Selected($chosen) {
    if ($chosen.Count -eq 0) { Write-Log (T 'm.nothing'); return }

    $names = ($chosen | ForEach-Object { '  - ' + (Tc $_.Name) }) -join "`n"
    $note = $(if (Get-On $secTg) { T 'm.secnote' } else { '' })
    $ask = [System.Windows.Forms.MessageBox]::Show(((T 'm.confirm') -f $names, $note), (T 'm.title'), 'YesNo', 'Warning')
    if ($ask -ne 'Yes') { return }

    Set-Busy $true
    $log.Clear()
    if (Test-BrowsersRunning) { Write-Log (T 'm.browser') }

    $freed = 0
    foreach ($c in $chosen) {
        Write-Log ((T 'm.cleaning') -f (Tc $c.Name))
        $res = Invoke-Category $c (Get-On $secTg)
        $freed += $res.Bytes
        $rows[$c.Id].Size.Text = ''
        if ($c.Files) { Write-Log ((T 'm.removed') -f $res.Ok, (Format-Size $res.Bytes), $res.Fail) }
        if ($res.Err) { Write-Log (T 'm.err') }
        elseif (-not $c.Files) { Write-Log (T 'm.done') }
    }
    Write-Log ''
    Write-Log ((T 'm.finished') -f (Format-Size $freed))
    Set-Busy $false
}

# ---------- akcje / actions ----------

$selected = { $categories | Where-Object { Get-On $rows[$_.Id].Toggle } }

$secTg.Tag.Guard = {
    if ($script:diskInfo.Ssd -eq $true) {
        return ([System.Windows.Forms.MessageBox]::Show((T 'm.ssdsecure'), (T 'm.title'), 'YesNo', 'Warning') -eq 'Yes')
    }
    return $true
}
$rows['freespace'].Toggle.Tag.Guard = {
    if ($script:diskInfo.Ssd -eq $true) {
        return ([System.Windows.Forms.MessageBox]::Show((T 'm.ssdfree'), (T 'm.title'), 'YesNo', 'Warning') -eq 'Yes')
    }
    return $true
}

$btnPL.Add_Click({ Set-Language 'pl' })
$btnEN.Add_Click({ Set-Language 'en' })
$navClean.Add_Click({ Switch-Pane $false })
$navSec.Add_Click({ Switch-Pane $true })

$btnAll.Add_Click({
    foreach ($c in $categories) {
        $t = $rows[$c.Id].Toggle
        if ($t.Enabled -and $c.Id -notin 'freespace', 'ffhist', 'wifi') { Set-On $t $true }
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
    } catch { Write-Log (T 'm.adm.cancel') }
})

$btnScan.Add_Click({
    Set-Busy $true
    $log.Clear()
    Write-Log (T 'm.scanning')
    $total = 0
    foreach ($c in (& $selected)) {
        if ($c.Files) {
            $files = @(& $c.Files)
            $bytes = ($files | Measure-Object -Property Length -Sum).Sum
            if (-not $bytes) { $bytes = 0 }
            $total += $bytes
            $rows[$c.Id].Size.Text = Format-Size $bytes
            Write-Log ((T 'm.scanrow') -f (Tc $c.Name), $files.Count, (Format-Size $bytes))
        } else {
            $rows[$c.Id].Size.Text = T 'action'
        }
    }
    Write-Log ((T 'm.total') -f (Format-Size $total))
    Set-Busy $false
})

$btnClean.Add_Click({ Invoke-Selected @(& $selected) })

$btnQuick.Add_Click({
    Invoke-Selected @($categories | Where-Object { $_.Default -and (-not $_.Admin -or $isAdmin) })
})

$btnRefresh.Add_Click({ Update-Security })

$btnEnc.Add_Click({
    try { Start-Process 'ms-settings:deviceencryption' }
    catch { try { Start-Process control.exe -ArgumentList '/name Microsoft.BitLockerDriveEncryption' } catch { Write-Log (T 'm.enc.fail') } }
})

$btnHib.Add_Click({
    if (-not $isAdmin) { [void][System.Windows.Forms.MessageBox]::Show((T 'm.admin'), (T 'm.title'), 'OK', 'Information'); return }
    powercfg /h off | Out-Null
    Write-Log (T 'm.hib.done')
    Update-Security
})

$btnPage.Add_Click({
    if (-not $isAdmin) { [void][System.Windows.Forms.MessageBox]::Show((T 'm.admin'), (T 'm.title'), 'OK', 'Information'); return }
    Set-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' -Name ClearPageFileAtShutdown -Value 1 -Type DWord
    Write-Log (T 'm.page.done')
    Update-Security
})

$btnTrim.Add_Click({
    if (-not $isAdmin) { [void][System.Windows.Forms.MessageBox]::Show((T 'm.admin'), (T 'm.title'), 'OK', 'Information'); return }
    fsutil behavior set DisableDeleteNotify 0 | Out-Null
    Write-Log (T 'm.trim.done')
    Update-Security
})

$btnAuto.Add_Click({
    if (-not $isAdmin) { [void][System.Windows.Forms.MessageBox]::Show((T 'm.admin'), (T 'm.title'), 'OK', 'Information'); return }
    try {
        if (Get-AutoTaskInstalled) {
            Disable-AutoTask
            Write-Log (T 'm.auto.off')
        } else {
            $a = [System.Windows.Forms.MessageBox]::Show(((T 'm.auto.confirm') -f "$env:LOCALAPPDATA\007Deleter"), (T 'm.title'), 'YesNo', 'Question')
            if ($a -ne 'Yes') { return }
            Enable-AutoTask
            Write-Log (T 'm.auto.on')
        }
    } catch { Write-Log (T 'm.auto.fail') }
    Update-Security
})

$script:diskInfo = Get-SystemDiskInfo
Set-Language $script:lang
Write-Log (T 'm.ready')
Write-Log ((T 'm.disk') -f (T ('tx.' + $(if ($script:diskInfo.Type -eq 'unk') { 'disk.unk' } else { $script:diskInfo.Type }))))

# ---------- podgląd (do testów) / preview (for tests) ----------

if ($Preview) {
    function Save-Shot($path) {
        [System.Windows.Forms.Application]::DoEvents()
        $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height)
        $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
        $bmp.Save($path, [Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
    }
    $form.Show()
    foreach ($id in 'thumbs', 'temp', 'recent', 'browsercache') { $rows[$id].Size.Text = '12,4 MB' }
    foreach ($l in 'pl', 'en') {
        Set-Language $l
        Switch-Pane $false
        Save-Shot "$Preview-$l-clean.png"
        Switch-Pane $true
        Save-Shot "$Preview-$l-security.png"
    }
    $form.Close()
    exit
}

[void]$form.ShowDialog()
