# EasySD – Kommentelési és commit szabályzat (2026)

Ez a dokumentum röviden, közérthetően összefoglalja a kód kommentelésének és commit üzenetek írásának fő szabályait.

## Kommentelés
- Minden fontosabb blokk, függvény, elágazás előtt rövid, magyar vagy angol nyelvű magyarázat
- A komment legyen tömör, világos, ténylegesen a működést írja le
- Ne kommentelj olyat, ami magától értetődő a kódból
- Hibakezelésnél, trükkös megoldásnál mindig magyarázd el, miért úgy van

## Commit üzenetek
- Minden commit röviden, de érthetően írja le, mi változott és miért
- Ha hibajavítás, írd le a hiba lényegét is
- Ha új funkció, írd le, mire jó, hol használható
- Ne használj általános üzeneteket (pl. "update", "fix"), hanem mindig konkrétan fogalmazz

## Példák
- "Plugin API: hibakezelés javítása nagy fájloknál"
- "Menü: könyvtárlista gyorsítása, felesleges ciklus eltávolítva"
- "Cartridge protokoll: új hibaüzenet támogatás"

---
Ez a leírás kizárólag a jelenlegi fejlesztési gyakorlatra vonatkozik.