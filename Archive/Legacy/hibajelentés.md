Jelentés a Build Hibákról és Javításaikról

**Bevezetés:**
A felhasználó jelentette, hogy az EasySD Gemini projekt build szkriptjei (batch fájlok) nem működnek. Az alábbiakban részletezzük a felmerült hibákat és azok kijavítását.

**1. Hiba: `CartZpMap.inc` include hiányzik**
*   **Hiba leírása:** A `PreBuild.bat` ellenőrzése során az `ERROR: CartZpMap.inc include count is 0 (expected: 1)` üzenet jelent meg, ami azt jelezte, hogy a `CartZpMap.inc` fájl nem szerepel a `Loader\CartLibStream.s` fájlban, holott ez elvárás.
*   **Oka:** A `Loader\CartLibStream.s` fájlból hiányzott a `.include "CartZpMap.inc"` direktíva.
*   **Javítás:** A `.include "CartZpMap.inc"` sort hozzáadtuk a `IRQHack64\Loader\CartLibStream.s` fájlhoz.

**2. Hiba: `CartLibCommon.s` duplikált beillesztés**
*   **Hiba leírása:** Az első hiba javítása után a build `ERROR: CartLibCommon.s include count is 2 (expected: 1)` hibát jelzett. A `PreBuild.bat` szabálya szerint a `CartLibCommon.s` fájlt pontosan egyszer, és csak a `Loader\CartLib.s` fájlból szabad beilleszteni.
*   **Oka:** A `CartLibStream.s` fájl is tartalmazta a `.include "CartLibCommon.s"` direktívát, így a build során duplikált beillesztés történt.
*   **Javítás:** A `.include "CartLibCommon.s"` sort eltávolítottuk a `IRQHack64\Loader\CartLibStream.s` fájlból.

**3. Hiba: Duplikált definíciók a `WavPlayer.s` és `MusPlayer.s` fájlokban**
*   **Hiba leírása:** A build ekkor `duplicate definition` (duplikált definíció) hibákat kezdett jelezni, főként a `WavPlayer.s` és `MusPlayer.s` plugineknél, olyan szimbólumokra hivatkozva, mint `COMMAND_READ_FILE`, `IRQ_WaitProcessing`, stb. Ez azt jelentette, hogy a `CartLibHi.s` fájl többször is be lett illesztve.
*   **Oka:** A `WavPlayer.s` és `MusPlayer.s` fájlok közvetlenül is tartalmazták a `.include "../../Loader/CartLibHi.s"` direktívát, miközben a `CartLibStream.s` fájl is beillesztette a `CartLibHi.s`-t. Ez duplikált beillesztéshez vezetett.
*   **Javítás:** Eltávolítottuk a `.include "../../Loader/CartLibHi.s"` direktívát mind a `IRQHack64\Plugins\WavPlayer\WavPlayer.s`, mind a `IRQHack64\Plugins\MusPlayer\MusPlayer.s` fájlokból.

**4. Hiba: Nem definiált szimbólumok a `CartLibStream.s` fájlban (Zero-page címek)**
*   **Hiba leírása:** A `WavPlayer.s` plugin fordításakor olyan hibák merültek fel, mint `not defined symbol 'STREAM_FILE_SIZE_0'` és `not defined symbol 'STREAM_BYTES_REMAIN_0'` a `CartLibStream.s` fájlban.
*   **Oka:** A `CartLibStream.s` helyben definiált néhány zero-page címet (`$90`-tól `$95`-ig), amelyek nem voltak összhangban a `CartZpMap.inc` központosított zero-page térképével. A `STREAM_FILE_SIZE_X` változók nem voltak definiálva, és a `STREAM_BYTES_REMAIN_X` változók hivatkozásai sem a `CartZpMap.inc`-ből származtak.
*   **Javítás:**
    *   Hozzáadtuk a `ZP_STREAM_TARGET_ADDR_LO/HI` és `ZP_STREAM_BYTES_REMAIN_0-3` definíciókat a `CartZpMap.inc` fájlhoz, a `CartLibStream.s` által használt `$90`-`$95` címeket felhasználva.
    *   Eltávolítottuk a `CartLibStream.s` fájlból a helyi zero-page cím definíciókat.
    *   Létrehoztuk a `STREAM_FILE_SIZE_X = ZP_STREAM_BYTES_REMAIN_X` aliasokat a `CartLibStream.s` fájlban.
    *   Minden `STREAM_TARGET_ADDR_LO/HI` és `STREAM_BYTES_REMAIN_X` hivatkozást `ZP_` előtaggal ellátott megfelelőjére cseréltünk a `CartLibStream.s` fájlban.

**5. Hiba: Nem definiált `SafeStream` szimbólum a `WavPlayer.s` fájlban**
*   **Hiba leírása:** A `WavPlayer.s` fordítása `not defined symbol 'SafeStream'` hibát jelzett.
*   **Oka:** A `WavPlayer.s` a `SafeStream` rutint hívta, de a `SafeStreamImpl.s` fájlban a rutin neve `SafeStream_Impl` volt.
*   **Javítás:** A `WavPlayer.s` fájlban a `JSR SafeStream` hívást `JSR SafeStream_Impl` hívásra módosítottuk. Ezenkívül a `SafeStreamImpl.s` fájlt is beillesztettük a `WavPlayer.s` és `MusPlayer.s` fájlokba, hogy a streaming funkciók elérhetők legyenek.

**Összegzés:**
A fenti hibajavítások elvégzése után a teljes build folyamat sikeresen lefutott, és a projekt buildelhetővé vált. A "build batchek nem müködnek" probléma megoldódott.
