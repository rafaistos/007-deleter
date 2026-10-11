# 007 Deleter

Portable Windows privacy cleaner with a simple dark UI (English / Polski). Removes traces of computer use: thumbnails, temp files, recent items, browser cache and more. No installation, runs from a USB drive or a disk and writes nothing to the medium it runs from.

Przenośny czyścik śladów użytkowania Windows z prostym ciemnym interfejsem. Nie wymaga instalacji, działa z pendrive'a i z dysku.

> **Warning / Uwaga:** deletion is permanent. Use "Scan" first. Provided as is, see [LICENSE](LICENSE). / Usuwanie jest nieodwracalne. Zacznij od „Skanuj”. Program dostarczany bez gwarancji.

## English

### Get it
Download `007Deleter.exe` from the latest **Release** (or from **Actions → Build EXE → Artifacts**), or run `007Deleter.ps1` with PowerShell. The exe is built from this repository by GitHub Actions.

### Cleaning tab
Thumbnails and icons, temp files, recent files (Windows and Office), Run/search history, UserAssist and ShellBags traces, Windows activity history, clipboard, browser cache, Chromium history, Firefox history (also deletes bookmarks!), cookies, error reports, DNS cache, Recycle Bin, saved Wi-Fi networks, event logs, Prefetch, TRIM for SSDs, free-space wiping (HDD only).

- **Quick clean** runs the default set in one click.
- **Secure delete** overwrites files with random data before deleting them.
- Headless mode: `007Deleter.ps1 -Quick`.

### Security tab
Shows whether disk encryption (BitLocker), Secure Boot, TRIM, hibernation and page-file clearing are set up, and offers buttons for the ones you can change (administrator needed). Optionally enables an automatic quick clean at sign-in.

### Limits
- The strongest protection is full-disk encryption and a strong sign-in. This tool only complements it.
- On SSDs, overwriting files and free space is not reliable. Use encryption and TRIM.
- Files locked by running programs are skipped. Close browsers first.
- It does not remove cloud copies (Google, Microsoft, OneDrive) or RAM contents.
- It never touches passwords or your documents.
- The exe is not code-signed, so antivirus software may raise a false alarm. The source is fully visible in `007Deleter.ps1`.

## Polski

### Pobranie
Pobierz `007Deleter.exe` z najnowszego **Release** (albo z **Actions → Build EXE → Artifacts**) lub uruchom skrypt `007Deleter.ps1`. Exe jest budowane z tego repozytorium przez GitHub Actions.

### Zakładka „Czyszczenie”
Miniatury i ikony, pliki tymczasowe, ostatnie pliki (Windows i Office), historia „Uruchom” i wyszukiwania, ślady UserAssist i ShellBags, historia aktywności Windows, schowek, pamięć podręczna przeglądarek, historia Chromium, historia Firefoksa (usuwa też zakładki!), ciasteczka, raporty błędów, pamięć DNS, kosz, zapisane sieci Wi-Fi, dzienniki zdarzeń, Prefetch, TRIM dla SSD, nadpisywanie wolnego miejsca (tylko HDD).

- **Szybkie czyszczenie** wykonuje domyślny zestaw jednym kliknięciem.
- **Bezpieczne usuwanie** nadpisuje pliki losowymi danymi przed skasowaniem.
- Tryb bez okna: `007Deleter.ps1 -Quick`.

### Zakładka „Zabezpieczenia”
Pokazuje, czy masz szyfrowanie dysku (BitLocker), Secure Boot, TRIM, hibernację i czyszczenie pliku wymiany, i daje przyciski do zmiany tego, co się da (wymaga administratora). Opcjonalnie włącza automatyczne szybkie czyszczenie przy logowaniu.

### Ograniczenia
- Najpewniejszą ochroną jest szyfrowanie całego dysku i silne logowanie. Program tylko je uzupełnia.
- Na dyskach SSD nadpisywanie plików i wolnego miejsca nie jest pewne. Liczy się szyfrowanie i TRIM.
- Pliki używane przez działające programy są pomijane. Zamknij przeglądarki przed czyszczeniem.
- Nie usuwa kopii w chmurze (Google, Microsoft, OneDrive) ani zawartości pamięci RAM.
- Nigdy nie rusza haseł ani Twoich dokumentów.
- Plik exe nie jest podpisany cyfrowo, więc antywirus może zgłosić fałszywy alarm. Cały kod jest jawny w `007Deleter.ps1`.

## Build

```powershell
Install-Module ps2exe -Scope CurrentUser
Invoke-PS2EXE -inputFile .\007Deleter.ps1 -outputFile .\007Deleter.exe -noConsole -STA -iconFile .\assets\007deleter.ico
```

## License

[MIT](LICENSE)
