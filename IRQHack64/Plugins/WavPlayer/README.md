# WavPlayer Plugin Dokumentáció

## 1. Áttekintés

A `WavPlayer` egy nagy teljesítményű audio lejátszó plugin az IRQHack64/EasySD környezethez. Képes 8-bites, mono WAV fájlok valós idejű lejátszására a C64-en, közvetlenül az SD kártyáról streamelve. A plugin rugalmasan támogatja mind a C64 beépített hangchipjének (SID) korlátozott, mind a külső, User Port-ra csatlakoztatott DAC hardverek (mint a Digimax) fejlettebb képességeit.

## 2. Főbb Jellemzők

- **Valós idejű streaming:** Az audio adatokat közvetlenül az SD kártyáról olvassa, nincs szükség a teljes fájl memóriába töltésére.
- **Magas hangminőség:** ~11 kHz-es mintavételezési frekvenciát használ, ami tiszta és érthető hangvisszaadást tesz lehetővé.
- **Dupla pufferelés:** Akadozásmentes lejátszást biztosít egy hatékony dupla pufferes mechanizmus segítségével, ami elnyeli az adatfolyam esetleges ingadozásait.
- **Rugalmas hardvertámogatás:**
  - **SID Chip:** Képes a lejátszásra alap C64-en is, a SID chip fő hangerő-regiszterét 4-bites DAC-ként használva.
  - **Digimax (User Port DAC):** Teljes mértékben támogatja a User Portra csatlakoztatott 8-bites DAC-okat, kihasználva a hardver nyújtotta jobb, 8-bites hangminőséget.
- **Teljesítmény-optimalizálás:** A lejátszás idejére kikapcsolja a képernyőt, hogy a CPU minden erőforrását a hangfeldolgozásra fordíthassa.
- **Tiszta integráció:** Zökkenőmentesen működik együtt az IRQHack64 menürendszerével, a lejátszás végén pedig korrekten visszaállítja a gép eredeti állapotát.

## 3. Működési Elv

A plugin egy nagy frekvenciájú, CIA időzítő által vezérelt interruptra épül, ami a hangmintákat a megfelelő ütemben "löki ki" a kiválasztott audio hardverre.

### 3.1. Adatfolyam és Pufferelés

A lejátszás motorja egy 128 bájtos dupla puffer (`READBUFFER`) köré épül. Az `SafeStream_Impl` könyvtári rutin folyamatosan tölti a puffert az SD kártyáról, miközben az interrupt rutin a puffer másik feléből olvassa ki a lejátszandó hangmintákat. A `PLAYSTATE` változó tartja nyilván, hogy a puffer melyik 64 bájtos fele van feltöltés vagy lejátszás alatt. Ez a technika kulcsfontosságú a folyamatos, megszakítás nélküli hangzáshoz.

### 3.2. SID Lejátszás (4-bit)

Alapértelmezett C64-en a plugin a "SID DAC" vagy "Volume DAC" néven ismert trükköt alkalmazza.
1.  Az interrupt rutin beolvas egy 8-bites mintát a pufferből.
2.  A `SHIFT4BIT` nevű, előre generált táblázat segítségével a 8-bites értéket egy pillanat alatt 4-bitesre konvertálja.
3.  Ezt a 4-bites értéket beírja a SID chip fő hangerő-regiszterébe (`$D418`).
4.  A hangerő-regiszter értékének rendkívül gyors (másodpercenként ~11070-szeri) változtatása hozza létre a kívánt analóg hullámformát.

### 3.3. Digimax Lejátszás (8-bit)

Ha Digimax-kompatibilis hardver van csatlakoztatva, a plugin a lényegesen jobb minőségű, 8-bites lejátszási módot használja.
1.  A `NMIDIGI_InitNew` rutin a CIA 2 "B" portját (`$DD01`, azaz a User Port) kimenetként konfigurálja.
2.  Az interrupt rutin (`PlayDigimax`) beolvas egy 8-bites mintát a pufferből.
3.  A mintát **konverzió nélkül**, teljes 8-bites felbontásában írja ki a `$DD01`-es portra, amit a külső DAC hardver alakít analóg jellé.

## 4. Teljesítmény

- **Mintavételezési frekvencia:** ~11.07 kHz (PAL)
- **Felbontás:** 4-bit (SID), 8-bit (Digimax)
- **CPU terhelés:** Nagyon magas. A stabil működéshez a lejátszás alatt a képernyő-megjelenítés ki van kapcsolva.

## 5. Függőségek

A plugin a központi `IRQHack64` programkönyvtárakra támaszkodik a hardveres kommunikáció és a streaming megvalósításához. Főbb függőségei:
- `CartLib.s`
- `CartLibStream.s`
- `SafeStreamImpl.s`
- `CartLibDebug.s`
