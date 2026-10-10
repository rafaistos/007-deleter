# 007 Deleter - przenośny czyścik śladów użytkowania Windows.
# Działa z pendrive'a i z dysku, bez instalacji. Niczego nie zapisuje na nośniku.
# Nie rusza haseł, ciasteczek, zakładek ani dokumentów.

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

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
       Files = {
           Get-Files "$env:APPDATA\Microsoft\Windows\Recent"
       } },
    @{ Id = 'regmru'; Name = 'Historia uruchamiania i wyszukiwania'; Desc = 'Okno „Uruchom”, wpisane ścieżki, wyszukiwania w Eksploratorze'; Default = $true
       Extra = {
           $b = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer'
           Remove-Keys @("$b\RunMRU", "$b\TypedPaths", "$b\WordWheelQuery", "$b\RecentDocs")
       } },
    @{ Id = 'clip'; Name = 'Schowek'; Desc = 'Skopiowane teksty i dane, także hasła skopiowane z menedżera'; Default = $true
       Extra = { [System.Windows.Forms.Clipboard]::Clear() } },
    @{ Id = 'browsercache'; Name = 'Pamięć podręczna przeglądarek'; Desc = 'Chrome, Edge, Brave, Firefox: kopie odwiedzonych stron i obrazów (zamknij przeglądarki)'; Default = $true
       Files = {
           foreach ($p in Get-ChromiumProfiles) {
               foreach ($s in 'Cache', 'Code Cache', 'GPUCache', 'Service Worker\CacheStorage') { Get-Files (Join-Path $p $s) }
           }
           $ff = "$env:LOCALAPPDATA\Mozilla\Firefox\Profiles"
           if (Test-Path -LiteralPath $ff) {
               Get-ChildItem -LiteralPath $ff -Directory -ErrorAction SilentlyContinue | ForEach-Object { Get-Files (Join-Path $_.FullName 'cache2') }
           }
       } },
    @{ Id = 'browserhist'; Name = 'Historia przeglądarek (Chromium)'; Desc = 'Chrome, Edge, Brave: historia odwiedzin. Zakładki, hasła i ciasteczka zostają. Firefox pominięty'; Default = $false
       Files = {
           foreach ($p in Get-ChromiumProfiles) {
               foreach ($f in 'History', 'History-journal', 'Top Sites', 'Visited Links', 'Network Action Predictor') {
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
    @{ Id = 'freespace'; Name = 'Wolne miejsce na dysku systemowym'; Desc = 'Nadpisuje puste miejsce, by wcześniej usunięte pliki nie dały się odzyskać. Trwa długo, otwiera okno'; Default = $false
       Extra = { Start-Process cmd.exe -ArgumentList "/c title 007 Deleter - nadpisywanie wolnego miejsca & cipher /w:$($env:SystemDrive)\ & pause" } },
    @{ Id = 'prefetch'; Name = 'Prefetch (wymaga administratora)'; Desc = 'Lista programów uruchamianych na tym komputerze wraz z datami'; Default = $false; Admin = $true
       Files = { Get-Files "$env:SystemRoot\Prefetch" '*.pf' $false } }
)

# ---------- okno ----------

$bg = [Drawing.Color]::FromArgb(18, 21, 26)
$panel = [Drawing.Color]::FromArgb(27, 32, 39)
$green = [Drawing.Color]::FromArgb(31, 157, 99)
$red = [Drawing.Color]::FromArgb(214, 69, 65)
$text = [Drawing.Color]::FromArgb(236, 240, 244)
$muted = [Drawing.Color]::FromArgb(140, 150, 162)

$form = New-Object Windows.Forms.Form
$form.Text = '007 Deleter'
$form.ClientSize = New-Object Drawing.Size(720, 640)
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

$adminLbl = New-Object Windows.Forms.Label
$adminLbl.Location = New-Object Drawing.Point(480, 24)
$adminLbl.Size = New-Object Drawing.Size(220, 24)
$adminLbl.TextAlign = 'MiddleRight'
if ($isAdmin) { $adminLbl.Text = 'Tryb administratora'; $adminLbl.ForeColor = $green }
else { $adminLbl.Text = 'Tryb zwykły'; $adminLbl.ForeColor = $muted }
$form.Controls.Add($adminLbl)

$list = New-Object Windows.Forms.FlowLayoutPanel
$list.Location = New-Object Drawing.Point(20, 84)
$list.Size = New-Object Drawing.Size(680, 316)
$list.FlowDirection = 'TopDown'
$list.WrapContents = $false
$list.AutoScroll = $true
$list.BackColor = $bg
$form.Controls.Add($list)

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

function New-Button($label, $x, $w, $color) {
    $b = New-Object Windows.Forms.Button
    $b.Text = $label
    $b.Location = New-Object Drawing.Point($x, 412)
    $b.Size = New-Object Drawing.Size($w, 40)
    $b.FlatStyle = 'Flat'
    $b.FlatAppearance.BorderSize = 0
    $b.BackColor = $color
    $b.ForeColor = [Drawing.Color]::White
    $b.Font = New-Object Drawing.Font('Segoe UI Semibold', 10)
    $b.Cursor = 'Hand'
    $form.Controls.Add($b)
    return $b
}

$btnScan = New-Button 'Skanuj' 20 150 $panel
$btnClean = New-Button 'Wyczyść zaznaczone' 180 210 $red
$btnAdmin = New-Button 'Uruchom jako administrator' 400 210 $panel
$btnAdmin.Visible = -not $isAdmin
$btnAll = New-Button 'Zaznacz wszystko' 560 140 $panel
$btnAll.Font = New-Object Drawing.Font('Segoe UI', 9)
$btnAdmin.Font = New-Object Drawing.Font('Segoe UI', 9)

$chkSecure = New-Object Windows.Forms.CheckBox
$chkSecure.Text = 'Bezpieczne usuwanie: nadpisz pliki losowymi danymi przed skasowaniem (wolniej)'
$chkSecure.Location = New-Object Drawing.Point(20, 458)
$chkSecure.Size = New-Object Drawing.Size(680, 24)
$chkSecure.ForeColor = $text
$form.Controls.Add($chkSecure)

$log = New-Object Windows.Forms.TextBox
$log.Multiline = $true
$log.ReadOnly = $true
$log.ScrollBars = 'Vertical'
$log.Location = New-Object Drawing.Point(20, 490)
$log.Size = New-Object Drawing.Size(680, 136)
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
    foreach ($b in $btnScan, $btnClean, $btnAll) { $b.Enabled = -not $busy }
    $form.Cursor = $(if ($busy) { 'WaitCursor' } else { 'Default' })
}

function Test-BrowsersRunning {
    $names = 'chrome', 'msedge', 'brave', 'firefox'
    return [bool](Get-Process -Name $names -ErrorAction SilentlyContinue)
}

$selected = { $categories | Where-Object { $rows[$_.Id].Check.Checked } }

# ---------- akcje ----------

$btnAll.Add_Click({
    foreach ($c in $categories) { if ($rows[$c.Id].Check.Enabled) { $rows[$c.Id].Check.Checked = $true } }
})

$btnAdmin.Add_Click({
    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File `"$PSCommandPath`""
        $form.Close()
    } catch { Write-Log 'Anulowano: brak zgody na uruchomienie jako administrator.' }
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

$btnClean.Add_Click({
    $chosen = @(& $selected)
    if ($chosen.Count -eq 0) { Write-Log 'Nic nie zaznaczono.'; return }

    $names = ($chosen | ForEach-Object { '  - ' + $_.Name }) -join "`n"
    $ask = [System.Windows.Forms.MessageBox]::Show("Usunąć bezpowrotnie:`n`n$names`n`nTego nie da się cofnąć.$(if ($chkSecure.Checked) { "`n`nTryb bezpieczny: pliki zostaną nadpisane, odzyskanie ich będzie praktycznie niemożliwe." })", '007 Deleter', 'YesNo', 'Warning')
    if ($ask -ne 'Yes') { return }

    Set-Busy $true
    $log.Clear()
    if (Test-BrowsersRunning) { Write-Log 'Uwaga: przeglądarka jest włączona, część plików będzie zablokowana. Zamknij ją i powtórz.' }

    $freed = 0
    foreach ($c in $chosen) {
        Write-Log "Czyszczę: $($c.Name)..."
        $ok = 0; $fail = 0; $bytes = 0
        if ($c.Files) {
            foreach ($f in @(& $c.Files)) {
                try {
                    $len = $f.Length
                    if ($chkSecure.Checked) { Remove-Secure $f.FullName } else { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop }
                    $ok++; $bytes += $len
                } catch { $fail++ }
                if (($ok + $fail) % 200 -eq 0) { [System.Windows.Forms.Application]::DoEvents() }
            }
        }
        if ($c.Extra) { try { & $c.Extra } catch { Write-Log '  nie udało się wykonać akcji' } }
        $freed += $bytes
        $rows[$c.Id].Size.Text = ''
        if ($c.Files) { Write-Log ("  usunięto {0} plików ({1}), pominięto {2} (w użyciu)" -f $ok, (Format-Size $bytes), $fail) }
        else { Write-Log '  gotowe' }
    }
    Write-Log ''
    Write-Log ("Koniec. Odzyskano {0}." -f (Format-Size $freed))
    Set-Busy $false
})

Write-Log 'Gotowy. Wybierz kategorie i kliknij „Skanuj” albo „Wyczyść zaznaczone”.'
[void]$form.ShowDialog()
