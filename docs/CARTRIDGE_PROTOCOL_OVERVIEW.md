# EasySD – Cartridge protokoll összefoglaló (2026)

Ez a dokumentum röviden, közérthetően bemutatja a C64 és az Arduino közötti kommunikációs protokoll főbb jellemzőit.

## Fő elv
- A C64 és az Arduino egyedi soros protokollon keresztül kommunikál
- Az adatátvitel bájtonként, szoftveres ellenőrzéssel történik

## Főbb parancsok
- Könyvtárlista lekérése
- Fájl betöltés kérése
- Plugin indítás
- Hibaüzenet küldése

## Időzítés és megbízhatóság
- Az Arduino minden parancsra visszajelzést küld
- Hibás átvitel esetén újraküldés, vagy hibaüzenet

## Hibakezelés
- Minden parancs után ellenőrizni kell a visszajelzést
- Ha hiba történik, a C64 újrapróbálkozhat vagy visszatér a menübe

## További információk
- Részletes protokollleírás: forráskód és CartLib.s
- Fejlesztéshez, hibakereséshez lásd a debug buildet

---
Ez a leírás kizárólag a jelenlegi, működő rendszerre vonatkozik.