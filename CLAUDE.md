# Void# – macOS (Apple Silicon)

Nativní orbwalker a autoaim pro League of Legends na macOS 14+ ve Swiftu (zobrazovaný název Void#, balíček
`cz.voidmac.app`, konfigurace v `~/Library/Application Support/VoidMac/`, log `~/Library/Logs/VoidMac.log`). Uživatelské rozhraní, stavy a hlášky aplikace jsou
anglicky; tento README je česky. Žádný zásah do paměti hry: jen snímání obrazu
(ScreenCaptureKit), Live Client API, veřejná data o spellech a syntetický vstup.

## Jádro

| Soubor | Účel |
|---|---|
| `FrameCapture`, `GameSession` | Stream okna hry (nativní rozlišení, 120 fps v zápase, 12 mimo něj), nový snímek probouzí čekající vlákna přes podmínkovou proměnnou |
| `PixelSearch` | Jeden průchod snímkem (každý 9. řádek při 2x, 4. při 1x): červená výplň + obrys nad a pod ní + level box s číslicí, nebo samotný level box u prázdného baru, a zároveň vlastní zelený bar; šířka baru je pevná (100 px × výškové měřítko), výplň se měří uprostřed baru; ~0,4 ms na snímek 3600×2338 |
| `Vision` | Skenuje každý snímek, vede tracky nepřátel (ID přežije 1,5 s bez detekce, počet spatření, rychlost regresí za 160 ms), poslední známý vlastní bar, pohyb terénu při držení aktivace nebo predikci (poslední pohyb, zamčená kamera); jediný zdroj cílů pro orbwalker i autoaim |
| `Orbwalker` | Klik na cíl nebo attack-move, kiting podle oficiálních windupů, cíl = track viděný v aktuálním a aspoň jednom dřívějším snímku, útok jen v dosahu od vlastního baru, lepivý cíl podle identity tracku s hysterezí, hold zóna, reset autoútoku po abilitě, humanizace kliku, Flee, Show Range, Target Champions Only, vrtulník, emote po killu |
| `Aim` | Autoaim: aktivní event tap zadrží Q/W/E/R (a D/F pro Ignite/Exhaust), kurzor na předpovězený cíl s důvěryhodností z linearity pohybu, vektorové spelly dvěma body, klávesa držená jako prst, návrat kurzoru |
| `Combo`, `AbilityHud` | Komba: po potvrzeném autoútoku sešle další zapnutou schopnost v pořadí (na cíl přes autoaim, směrem kurzoru u dashů, bez míření); dostupnost čte z HUDu jen u zapnutých schopností (ikony Q/W/E/R najde jednou za hru šablonou z Data Dragonu — řádek ikon skládá z té čtveřice, která sedí nejlépe dohromady, takže ztmavené Q hledání neblokuje; znovu hledá jen po 30 s bez shody kterékoli ze čtyř ikon; každý snímek pak v okně −10…+14 px vpravo od ikony najde **svislou** linku rámečku a rozhodne podle podílu zlaté: od 0,90 seslatelná, do 0,85 ne, mezi tím platí předchozí stav. Spodní linka se nečte: je zlatá i u schopnosti, kterou seslat nejde — u Ashe je to ukazatel Focus stacků, a než se to zjistilo, hlásil reader Q jako připravené pořád), záložně odhad z vlastních castů, levelu a ability haste, mana z API; vestavěné kombo pro Luciana (Q, W, E směrem kurzoru, E resetuje AA); volba „Combo must not delay the attack“ sešle jen to, čemu se cast lock vejde do mezery mezi útoky (vypnutá smí cast posunout další útok až o 100 ms) |
| `Input`, `InputMonitor` | Syntetický vstup na úrovni session (HID post umí pod zátěží uváznout 20 ms, session 2 ms); jediný aktivní tap jen pro klávesy, pohyb myši naším procesem nikdy neprochází |
| `Clock` | Vlákna orbwalkeru a vision běží s real-time (time-constraint) politikou a čekají přes `mach_wait_until`: procesu na pozadí jinak macOS slučuje časovače až o 100 ms (`kern.timer_coalesce_bg_ns_max`), což dělalo 100ms výpadky v klicích i castech |
| `LiveClient` | Attack speed, dosah, šampion, smrt, spelly z `127.0.0.1:2999` |
| `Spells`, `SpellData`, `ChampionWindups`, `ChampionResets` | Tabulka 692 spellů (typ míření, dosah, rychlost, cast time, cooldown, cena), windupy 173 šampionů, abilities resetující autoútok |

## Spuštění a ovládání

```bash
cd VoidMac
./run.sh            # zkompiluje, zabalí build/VoidMac.app a spustí
```

- **Mezerník** držet ve hře = orbwalker aktivní (útok → windup bez pohybu → move-clicky → útok po 1/AS).
- **Q/W/E/R** se zapnutým autoaimem = spell se namíří na nepřítele, kurzor se vrátí.
- **Komba** zapnutá = při držení mezerníku AA → Q → AA → W → AA → E …, schopnost jde po windupu autoútoku, ale jen když se stihne
  doseslat do splatnosti dalšího útoku; jinak se přeskočí, aby nerozbila kadenci.
- **Pravý ⌘** otevře / zavře panel nad hrou (Esc zavře); s otevřeným panelem je vše pozastavené.

## Menu ve hře

Ve hře (okno hry zachyceno a v popředí) otevře klávesa panelu nebo tlačítko **V#** v levém horním rohu hry kompaktní menu ve stylu
injectovaných skriptů: jeden strom sekcí (Orbwalker, Autoaim, Combos, Drawings, Detection, Extra, Status) se sbalováním, tlačítko ⧉
vytáhne sekci do samostatného okénka, které si přetáhneš kamkoli po obrazovce hry (okna nejdou vytáhnout ven z okna hry, tlačítko ⇱
je vrátí zpět). Rozložení (pozice menu a okének, sbalené sekce) se ukládá do `layout` v konfiguraci. Nápověda k řádkům je v tooltipu.
Dokud je kurzor nad některým z okének, orbwalker nekliká (stav „paused (menu open)“). K tomu klikatelné HUD: pilulky se stavem
orbwalkeru / autoaimu / komb nahoře uprostřed, attack timer pod šampionem (oranžová = windup, modrá = čekání na další útok, zelená =
připraveno) a jméno rozpoznaného cíle nad jeho barem; každou část lze vypnout v sekci Drawings. Mimo hru (nebo z menu v liště) se otevírá
původní velký panel níže.

## Panel

Panel se otevírá jen ve hře (nalezené okno hry) klávesou panelu nebo z menu baru a při tažení se zastaví o okraje okna hry,
nejde vytáhnout mimo ně; když se okno hry posune nebo změní, panel se posune s ním. Mimo hru se otevře jen tehdy, když chybí
některé oprávnění.

| Záložka | Obsah |
|---|---|
| Orbwalker | Způsob útoku, výběr cíle, Show Range, Attack Champion Only (klávesa / prostřední tlačítko), chytré cílení (dosah, lepivý cíl, hold zóna, resety, humanizace, Flee), kiting (move-clicky, extra windup), klávesy |
| Autoaim | Zapnutí, quick cast / klávesa + klik, výběr cíle, predikce, kontrola dosahu, klávesy Q/W/E/R/D/F, časování, kalibrace z kruhu dosahu (stav: elipsa, nohy, poměr kruhu, px/jednotka, perspektiva) a záložní měřítko, spelly šampiona s ikonami a přepsáním typu |
| Komba | Zapnutí, jedna schopnost na útok, pořadí a způsob míření každé schopnosti šampiona (ikony, cast, CD, cena), stav cooldownů a many |
| Extra | Vrtulník (klávesa, rychlost, poloměr), emote po killu |
| Detekce | Režim a rychlost snímání, rozpoznávání šampionů podle jména nad barem, výška kliku na modelu, posun kliknutí pro nerozpoznané jednotky, náhled snímku s kandidáty, cílem a mým barem |
| Stav | Live Client, okno hry, capture, sken, stav enginu, oprávnění, konfigurace |

## Jak to funguje

- **Kdo je za barem**: systémové rozpoznávání textu (Vision) přečte jméno nad nepřátelským barem a číslo v level boxu
  (výřez ~34 bodů nad barem, na pozadí, max. jedno čtení najednou, neznámý track každých 350 ms, pak každé 3 s, známý každých 6 s)
  a porovná je se seznamem nepřátel z Live Client API (Riot ID, summoner name, jméno šampiona; shoda ≥ 0,6 s náskokem 0,15, jinak
  jediný nepřítel daného levelu, když jméno nejde přečíst). Štítek „Target Dummy“ je panák i mezi boty; bez nepřátel v API je panák
  každý bar. Tabulka `ChampionModelData.swift` (Tools/generate_champions.py, CommunityDragon) dává pro každého šampiona výšku modelu
  (vrchol meshe × skinScale), výběrový válec a gameplay radius. Bar je vykreslen pevných 61 bodů nad vrškem modelu (změřeno na
  Lucianovi, Ziggsovi a panákovi), nohy cizí jednotky = bar + 61 bodů + promítnutá výška modelu (svisle 0,72 × kx na jednotku, změřeno
  na Lucianovi, Sionovi, panákovi a minionech; samotný sklon kamery by dal 0,556). Některé postavy stojí ve hře výš, než říká jejich
  mesh (Ziggs 2,4×, `ChampionModels.measuredScales`). Skutečnou výšku těla se program učí sám z kliků (`BodyLearner`): zásah
  (bar cíle kdykoli během okna klesne pod výplň při kliku — sleduje se **nejnižší viděná výplň**, ne jeden snímek na jeho konci, a
  měří se až od windupu toho kliku, aby se nepřipsal zásah předchozího útoku) **tělo neprodlužuje**: změřeno na 2 676 klicích, že
  pokles pruhu na hloubce kliku vůbec nezávisí — sondy míří o 84 jednotek hlouběji než běžné kliky a potvrdí se stejně často
  (bez poklesu 15,9 % proti 13,4 %), takže ten pokles dělá okolní poškození boje, ne náš klik. Informativní jsou proto jen
  **minutí**, která tělo zkracují; odhad nikdy nepřeroste tabulkovou výšku. Dvě minutí na stejné hloubce dávají horní mez;
  každý čtvrtý útok je sonda o kus níž (u usazeného těla 0,9 × odhad, jinak
  1,3× poslední zásah, nejméně 0,85 × odhad, případně půlení mezi zásahem a minutím) — vždy ale **nejvýš do odhadnuté výšky těla**,
  sonda tedy nikdy nemíří pod nohy. Běžné kliky zůstávají na ověřeném těle. Nohy jsou usazené, když se meze sejdou na 25 %, typicky za 12 až 24 útoků; koeficient výška/mesh se uloží do
  `heightFactors` a příště se jen jednou za 25 útoků přezkouší. V logu „body of <jméno>: …“, u útoku „N u below the head of M (probe)“.
  Vlastní nohy dál dává kruh dosahu.
- **Klik na cíl**: osa modelu je pod středem level boxu + baru, tj. 0,4 šířky baru od začátku výplně; rozpoznaný šampion a panák se
  klikají `clickHeight` % výšky modelu nad nohama (výchozí 55 % = hrudník; Ziggs ~120 bodů pod barem, Lucian ~115, Sion ~140),
  panáci mají při výběru cíle vždy nejnižší prioritu (0 HP by jinak vyhrávalo režim „nejnižší HP“),
  nerozpoznaná jednotka `clickOffsetY` pod horní hranou baru (výchozí 74 bodů). Klik je předběhnutý o rychlost
  cíle na obrazovce × (stáří snímku + 12 ms), max 30 px, pravý klik, návrat až po snímku hry vykresleném po kliku (10–25 ms); cíl je
  v overlay označen bílým kroužkem. V okně, kdy je kurzor na cíli, se systému na nic neptáme (dotaz na pozici kurzoru i post přes HID
  umí pod zátěží zadrhnout 20–30 ms); návrat se posílá na úrovni session s deltami spočítanými z toho, co známe.
  Nikdy `CGWarpMouseCursorPosition`: po warpu macOS na 150–250 ms zahazuje myš.
- **Autoaim**: klávesa se hře nepředá, kurzor se událostí přesune na cíl, počká se na dva nové snímky hry, pošle se stisk; drží
  se, dokud držíš fyzickou klávesu (kurzor sleduje cíl), po puštění a dvou snímcích se kurzor vrátí. Bez cíle v dosahu klávesa
  projde beze změny a důvod je v logu a na záložce Autoaim.
- **Predikce**: rychlost cíle ve světě = rychlost baru na obrazovce minus pohyb terénu, krát `cast time + vzdálenost / rychlost střely`.
- **Potvrzení útoku** (náhrada za OnProcessSpellCast/OnAfterAttack z LeagueSharpu, které zvenku nevidíme): po kliku na cíl se
  nesmí move-clickovat, dokud útok neproběhl. Proběhl, když bar cíle klesl, nebo když postava po kliku stála celý windup
  (při zamčené kameře to říká pohyb terénu měřený každý snímek; postava, která ještě dochází k cíli, se hýbe, a windup začíná až
  zastavením). Tento posun začátku je ale **omezený rezervou windupu (60 ms)**: zašuměné měření terénu tak už nemůže posunout hodiny
  útoku o stovky milisekund dopředu, jak se dřív dělo (naměřeno 1164 ms mezera místo 812 ms, a to i s vypnutými komby). Bez měřitelného
  terénu platí odhad windup + latence (nastavitelná, 80 ms); po max(600 ms, windup + 450 ms) bez potvrzení se
  kiting uvolní. Attack timer se posune na skutečný začátek útoku, nejvýš však o tu rezervu.
- **Komba**: schopnost, která resetuje attack timer (tabulka resetů, Lucian E), se sešle hned po potvrzení útoku a další
  útok jde okamžitě po jejím castu. Ostatní timer neresetují (wiki: Lucian Q cast 0,4–0,25 s, W 0,25 s, reset jen E), další
  útok smí až 1/AS po předchozím; ve výchozím režimu „těsně před útokem“ se proto sešlou tak, aby cast (+ jeden snímek rezervy)
  skončil přesně v momentě splatnosti dalšího útoku: kiting → W → AA bez mezery (uživatel ověřil ve hře, že AA cancel u Q/W není).
  Pokud už se cast do zbývající mezery nevejde, **nesešle se vůbec** — smí útok zdržet nejvýš o 100 ms, aby komba nerozhodila
  kadenci autoútoků. Do rozpočtu se počítá **celá cena castu**, ne jen zámek kouzla: u kroku mířeného na cíl i cesta kurzoru,
  usazení a čekání na dva snímky před stiskem klávesy, plus snímek, který zámku přidává `beginCastLock`. Než se to začalo
  započítávat, brána cenu podhodnocovala o 24–64 ms a skutečné přetažení bylo až ~164 ms. Ta hodnota je změřená na 1204 castech z odehraných sezení: udrží 82 % castů při průměrné ceně 39 ms, kdežto
  přísnějších 60 ms by zahodilo 40 % komb (v některých sezeních až 98 %) a volnějších 250 ms by cenu zvedlo na 60 ms průměrně.
  Volitelně „hned po útoku“: AA → W a kiting do dalšího útoku; schopnost, která zesvítí mezi útoky, jde hned, pokud se stihne
  docastit. Vždy jen naučená, podle HUDu seslatelná a zaplatitelná, jedna na útok.
  Dash „směrem kurzoru“ (Lucian E) jde ke kurzoru jen když cíl zůstane v dosahu autoútoku, jinak bokem po straně kurzoru;
  když cíl neudrží žádný směr, přeskočí se.
- **Zámek po castu**: od stisku klávesy až do konce castu se nekliká vůbec (útok ani pohyb). Attack timer přitom **běží dál**, takže
  útok splatný během castu vyletí v ten okamžik, kdy zámek skončí. Délka vychází z CommunityDragonu (větší z `mCastTime` a
  `spellCastTime`) plus jeden snímek na doručení vstupu a doměřuje se z HUDu: ikona zhasne, když začne cooldown (řádek
  `cast Q: HUD went on cooldown N ms after the key press`; u Lucian Q/E při začátku castu, u W na jeho konci). Naměřené hodnotě se
  věří **jen když se poslední čtyři zhasnutí shodnou do 120 ms** — cast lock je pevná vlastnost kouzla, takže rozházené čtení se
  zahodí a použije se tabulka. U kouzel s **nulovým cooldownem** (Ashe Q) se z HUDu neučí vůbec: ikona tam tmavne při spotřebě
  nábojů, ne na konci sesílání. Platí i pro ručně stisknuté spelly, které se teď logují řádkem `manual Q: …`. „Na cíl“ jde přes plán
  autoaimu (stejná kalibrace, predikce, kontrola dosahu), „směr kurzoru“ jen stiskne klávesu. Další autoútok jde, jakmile to dovolí
  attack timer; po schopnosti z tabulky resetů (Lucian E) hned. Ruční stisk schopnosti se do odhadu cooldownu započítá jen tehdy,
  když byla podle odhadu připravená.
- **Prodleva po aktivaci** (výchozí 150 ms, posuvník v Orbwalkeru): stisk aktivační klávesy se bere z tapu na milisekundu přesně
  (LoL při Mezerníku centruje kameru), do konce prodlevy `Vision` zahazuje tracky nepřátel i pohyb terénu a orbwalker nekliká; cíl
  pak vzniká jen ze snímků po prodlevě (dvě spatření), takže stará poloha z doby před posunem kamery nikdy nedostane klik.
- Orbwalker sám nic neskenuje: když je útok splatný, počká (max 12 ms) na nejnovější snímek z `Vision` a vybere cíl mezi tracky
  viděnými v tomto snímku a aspoň jednou předtím, kdekoli v obraze. Jednorázový červený flek nikdy nespustí klik.
- **Dosah přes perspektivu**: kamera LoL míří 56,25° pod horizont, takže jednotka má nahoře na obrazovce ~0,72× a dole ~1,2× tolik
  pixelů co ve středu; `GroundProjection` (px/jednotka ve středu, perspektiva `c`, nohy) převádí body obrazovky na herní jednotky
  a zpět. Se zapnutým „Ukázat attack range“ hledá `Vision` každých 200 ms kruh dosahu (tyrkysovo-bílý pruh, 72 paprsků, RANSAC
  osově souměrné elipsy, 1–2 ms) a z vodorovné poloosy spočítá px/jednotka a z posunu středu elipsy polohu nohou postavy
  (`RangeRing`; perspektiva je konstanta kamery svázaná s měřítkem, `c = kx·0,472/výška snímku`, řešení z tvaru elipsy bylo
  špatně podmíněné); poloměr v jednotkách je attack range + 65 (vlastní gameplay poloměr; ověřeno ve hře, cíl
  těsně za kruhem je ještě zasažitelný, protože stačí, aby se kruhu dotýkal jeho okraj). Kalibrace z rychlosti chůze byla
  zkoušena a zavržena: zamčená kamera při krátkých krocích kitingu dohání postavu se zpožděním, tok terénu vychází o ~11 % pomalejší.
  Na vyvýšeném terénu se kruh zvětší a postava posune výš, model to převezme z dalšího nálezu kruhu. Bez kruhu (Show Range
  vypnuté) platí poslední naměřené hodnoty (ukládají se do configu každých 20 s) a výška terénu se odvodí z posunu postavy
  proti její kalibrované poloze na obrazovce (kamera výšku nesleduje: posun nahoru = kx·h·cos 56°, měřítko roste o R0/(R0 − h/sin 56°)).
- **Kreslit dosah** (Orbwalker): při držení aktivace vykreslí click-through okno nad hrou přesný dosah autoútoku z téhož modelu
  (plná čára = střed 65j cíle ještě v dosahu, čárkovaná = brána s tolerancí) a volitelně dosahy spellů Q/W/E/R z tabulky,
  každý s vlastní barvou; okno hry se snímá zvlášť, takže
  kresba do detekce nezasahuje. Okno má jen velikost elipsy, kreslí se vrstvami CAShapeLayer a mění se jen když se elipsa pohne
  (zamčená kamera = statické), aby WindowServer nepřekresloval celé okno hry a hra neztrácela FPS. Barva je volitelná (výběr barvy
  pod přepínačem, ukládá se jako `#RRGGBB`).
- Útok se neodešle na snímek starší než 100 ms ani na cíl mimo dosah: vzdálenost nohy–nohy (nohy nepřítele = horní hrana baru +
  vlastní vzdálenost bar→nohy; bar drží stálou vzdálenost od nohou, model se s perspektivou zmenšuje směrem nahoru) ≤ `attack range + 2×65` (edge range: oba gameplay poloměry) + tolerance;
  lepivý cíl drží stejný track, dokud jiný není výrazně lepší
  (o 15 % HP, o 30 % blíž); hold zóna brání cukání na místě, abilities z tabulky resetů pustí další útok hned, klik má ±3 px humanizace.
- Okno hry na macOS mění velikost i měřítko (1800×1169 @2× v okně, 1920×1200 @1× při přechodu do popředí/borderless); při
  změně velikosti snímku `Vision` zahodí tracky i kalibraci v pixelech (px/jednotka, nohy, kruh) a začne z uložených hodnot
  nezávislých na rozlišení, HUD si ikony najde znovu; `GameSession` restartuje snímání až když je nový rámec okna stejný ve dvou
  po sobě jdoucích výpisech (animace okna dřív spouštěla restart každou sekundu).
- **Okno hry se ze seznamu ScreenCaptureKit ztrácí, i když ve hře jsi**: fullscreen League na jiném Space hlásí
  `isOnScreen = false`, takže ho `SCShareableContent(onScreenWindowsOnly: true)` do výpisu vůbec nedá a `pickGameWindow` ho
  navíc zahazoval vlastní podmínkou `isOnScreen`. Změřeno naživo: s `true` 26 oken a jediné Riot (launcher), s `false` 212 oken
  včetně `GameClient 1800×1169 layer 1000`. Proto se vypisuje s `onScreenWindowsOnly: false` a bez podmínky `isOnScreen`;
  běžící snímání se zastaví až po **třech** po sobě jdoucích nenalezeních. Jedno minutí dřív shodilo capture a s ním celý
  „jsem ve hře“ stav — panel pak hlásil „out of game“ a držel data posledního championa.
- Každých 30 s útoku (a bez nepřítele nejvýš jednou za 5 min) uloží vlákno na pozadí snímek do `~/Library/Logs/VoidMac-frames/`
  (posledních 10) pro ladění detekce na reálných datech; horká vlákna nikdy nekódují PNG.
- Vrtulník krouží v herních jednotkách kolem bodu 10 j pod nohama (kruh v pixelech obrazovky driftoval nahoru: jeho horní body jsou
  ve světě dál než dolní, postava k nim ušla víc).
- Inspirace: LeagueSharp `Orbwalking.cs` (AttackResets, HoldZone, Flee), `Prediction.cs` (hitchance podle přímosti pohybu),
  EloBuddy orbwalker (sticky target, range gate).

## Diagnostika

- **Rozbor logu jedním příkazem**: `Tools/analyze-log.py [log] [--last N]` vypíše po jednotlivých sezeních kadenci útoků
  (`late` medián a p90), druhy pomalých potvrzení, komba a jejich slack, velikosti poklesu pruhu podle hloubky kliku, pohyby
  učení těla, změny identity tracku, minutí po šampionech, smity, zamítnutí kvůli dosahu a ztráty okna hry. Sezení **nikdy
  nemíchá**: časy se přes dny opakují a ID tracků se každým spuštěním resetují od jedničky, takže cokoli klíčovaného přes ID
  nebo čas je při slučování nesmysl.

- Log `~/Library/Logs/VoidMac.log`: každý útok (`attack #<track>`: rozpoznaný šampion, bar, výplň, klik, windup, doba kurzoru
  mimo ruku, stáří snímku, sken), každé rozpoznání jména (`enemy #<track>: … via name/level`), každé namíření spellu, každých 5 s bez
  cíle výpis tracků a vlastní pozice. Snímky `~/Library/Logs/VoidMac-frames/`: `champion-<jméno>-*.png` při prvním útoku na
  každého šampiona (drží se 12), `miss-*.png` po pravděpodobném minutí (max 1 za 30 s), `notarget-*.png`, `frame-*-hit-*.png`
  (8 od každého druhu), `hud-suspect-*.png` (3).

```bash
B=.build/release/VoidMac
$B --windows               # okna na obrazovce s bundle ID
$B --dump                  # uloží snímek okna hry na Desktop
$B --analyze a.png --hud Lucian   # offline: najde ikony Q/W/E/R v HUDu a vypíše jejich dostupnost
$B --ui-shot složka               # offline: vyrenderuje menu ve hře, okénka a tlačítko do PNG (kontrola vzhledu bez hry)
Tools/reset-permissions.sh         # smaže udělená oprávnění (Accessibility, Screen Recording, Input Monitoring)
Tools/hud-regression-check/check.sh # přehraje označené snímky přes skutečné čtení HUDu a ověří verdikty (PASS/FAIL)
python3 Tools/generate_spells.py   # znovu vygeneruje SpellData.swift z aktuálního patche
python3 Tools/generate_champions.py # znovu vygeneruje ChampionModelData.swift (výšky modelů a barů, výběrové válce)
```

Konfigurace: `~/Library/Application Support/VoidMac/config.json` (skupina `aim`), ukládá se automaticky.
