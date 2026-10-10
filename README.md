# 007 Deleter

Przenośny program do czyszczenia śladów użytkowania Windows. Działa bez instalacji, z pendrive'a i z dysku. Nie zapisuje nic na nośniku, z którego działa.

## Uruchomienie
**Plik exe:** w GitHubie wejdź w Actions → „Build EXE” → Run workflow. Po kilku minutach pobierz 007Deleter.exe z sekcji Artifacts.
**Skrypt:** kliknij dwa razy `Uruchom 007 Deleter.bat`.

Pierwszy raz użyj „Skanuj”, które tylko pokazuje rozmiary. Przy „Uruchom jako administrator” (przycisk u góry) odblokowują się dodatkowe opcje.

## Zakładka „Czyszczenie”
Miniatury i ikony, pliki tymczasowe, ostatnie pliki (Windows i Office), historia okna „Uruchom”, ślady uruchamianych programów (UserAssist), ślady przeglądanych folderów (ShellBags), oś czasu Windows, schowek, pamięć podręczna i historia przeglądarek, ciasteczka, raporty błędów, pamięć DNS, kosz, zapisane sieci Wi-Fi, dzienniki zdarzeń, Prefetch, TRIM dla SSD, nadpisywanie wolnego miejsca (tylko HDD).

- **Szybkie czyszczenie** wykonuje domyślny zestaw jednym kliknięciem.
- **Bezpieczne usuwanie** nadpisuje pliki losowymi danymi przed skasowaniem.
- Wersja bez okna: `007Deleter.ps1 -Quick` (czyści domyślny zestaw i kończy).

## Zakładka „Zabezpieczenia”
Pokazuje, czy masz szyfrowanie dysku, Secure Boot, TRIM, hibernację i czyszczenie pliku wymiany, i podpowiada, co poprawić. Dla części ustawień są przyciski (administrator). Opcjonalnie włącza automatyczne szybkie czyszczenie przy logowaniu.

## Czego nie rusza
Haseł, zakładek (poza opcją Firefoksa, która to jasno mówi) i Twoich dokumentów.

## Ograniczenia
- Najpewniejszą ochroną jest szyfrowanie dysku (BitLocker) i silne logowanie. Ten program je tylko uzupełnia.
- Na dysku SSD nadpisywanie plików i wolnego miejsca nie daje gwarancji. Tam liczy się szyfrowanie i TRIM.
- Pliki używane przez działające programy są pomijane. Zamknij przeglądarki przed czyszczeniem.
- Nie wyczyści kopii w chmurze (konto Google, Microsoft, OneDrive) ani pamięci RAM.
- Program nie ma podpisu cyfrowego, więc antywirus (np. Bitdefender) może zgłaszać fałszywy alarm, zwłaszcza dla pliku exe i launchera .bat.
