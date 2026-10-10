# 007 Deleter

Przenośny program do czyszczenia śladów użytkowania Windows. Nie wymaga instalacji.

## Uruchomienie
1. Skopiuj cały folder `007-deleter` na pendrive'a albo zostaw na dysku.
2. Kliknij dwa razy `Uruchom 007 Deleter.bat`.
3. Kliknij „Skanuj”, żeby zobaczyć, ile czego jest. Potem „Wyczyść zaznaczone”.

Program czyści komputer, na którym go uruchomisz, i nie zapisuje nic na pendrive'ie.

## Co czyści
Miniatury i ikony, pliki tymczasowe, ostatnio używane pliki, historię okna „Uruchom”, schowek, pamięć podręczną przeglądarek, historię Chrome/Edge/Brave (opcjonalnie), raporty błędów, pamięć DNS, kosz, Prefetch (po uruchomieniu jako administrator).

## Bezpieczne usuwanie
- Pole „Bezpieczne usuwanie” nadpisuje każdy plik losowymi danymi, zmienia jego nazwę i dopiero go kasuje. Jest wolniejsze, ale usunięte tak pliki praktycznie nie dają się odzyskać.
- Kategoria „Wolne miejsce” uruchamia systemowe `cipher /w`, które nadpisuje puste miejsce na dysku i zaciera ślady wcześniejszych, zwykłych usunięć. Trwa długo (nawet godziny na dużym dysku).
- Na dyskach SSD i pendrive'ach nadpisywanie nie daje pewności, bo kontroler sam decyduje, gdzie fizycznie zapisuje dane. Tam najpewniejsze jest szyfrowanie dysku (BitLocker) od początku używania.

## Czego nie rusza
Haseł, ciasteczek, zakładek i Twoich dokumentów.

## Ograniczenia
- Pliki używane przez działający program (np. włączoną przeglądarkę) są pomijane. Zamknij przeglądarki przed czyszczeniem.
- Usunięte pliki na zwykłym dysku mogą dać się odzyskać specjalnym oprogramowaniem. Dla pełnej pewności używa się szyfrowania dysku (BitLocker).
- Historia Firefoksa jest pominięta, bo leży w jednym pliku z zakładkami.
