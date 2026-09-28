# raw-backup

Automatisk backup av `~/WORK/Raw` till ett USB-minne (`USB_1TB`) på macOS. Backupen startar av sig själv när minnet sätts i, och varje kopierad fil kontrolleras med SHA-256 mot originalet.

## Vad den gör

1. **Startar automatiskt** när USB-minnet monteras (launchd, `StartOnMount`). Andra diskar ignoreras.
2. **Kopierar bara nytt och ändrat** – jämför storlek och ändringstid mot kopian på minnet.
3. **Verifierar varje kopierad fil** – SHA-256 på originalet och på kopian måste stämma, annars görs ett nytt försök. Filer skrivs först till ett temporärt namn och byter namn först när de är kompletta, så ett utryckt minne lämnar inga halva filer.
4. **Sparar checksummor på minnet** (`USB_1TB/.raw-backup/manifest.sha256`).
5. **Fullständig kontroll var 30:e dag** – läser tillbaka hela kopian och jämför mot checksummorna. Skadade filer kopieras om automatiskt från originalet.
6. **Förloppsindikator** med procent, hastighet och beräknad tid kvar. I bakgrunden kommer notiser vid 25, 50 och 75 % (för jobb över 2 GB), och `--status` visar läget när som helst.
7. **Notiser** när backupen är klar eller om något gått fel. Logg i `~/Library/Logs/raw-backup.log`.

Skriptet **raderar aldrig** något på USB-minnet. Filer du tar bort i Raw ligger kvar på minnet.

## Installation

```bash
git clone https://github.com/westruplabs/raw-backup.git
cd raw-backup
bash install.sh
```

Testa sedan utan att kopiera något (med minnet isatt):

```bash
bash ~/Library/Scripts/raw-backup.sh --dry-run
```

### Behörighet i macOS (viktigt)

macOS kan blockera bakgrundsskript från att läsa USB-minnen. Om loggen visar `Operation not permitted`:

**Systeminställningar → Integritet och säkerhet → Fullständig skivåtkomst** → `+` → tryck `⌘⇧G`, skriv `/bin/bash` → lägg till och slå på.

Mata sedan ut minnet och sätt i det igen. (Det ger bash-skript full diskåtkomst generellt – det är standardlösningen för launchd-skript, men värt att känna till.)

## Användning

| Kommando | Vad det gör |
|---|---|
| `raw-backup.sh` | Kopiera nytt/ändrat och verifiera (körs automatiskt) |
| `raw-backup.sh --dry-run` | Visa vad som skulle kopieras |
| `raw-backup.sh --verify-all` | Kontrollera hela kopian nu och reparera fel |
| `raw-backup.sh --status` | Visa hur långt en pågående backup har kommit |

Skriptet ligger i `~/Library/Scripts/`. Kör det med `bash` framför, t.ex. `bash ~/Library/Scripts/raw-backup.sh --status`.

Kör du skriptet i Terminal visas en förloppsrad som uppdateras löpande:

```
Kopierar [##########---------------]  41%  84.2 GB av 205.0 GB  96.3 MB/s  ca 21 min kvar  (1203/2950 filer)
```

## Inställningar

Ändra i `~/.config/raw-backup.conf` (skapas vid installationen):

| Inställning | Standard | |
|---|---|---|
| `SRC` | `~/WORK/Raw` | Källmapp |
| `VOLUME_NAME` | `USB_1TB` | Minnets namn |
| `DEST_SUBDIR` | `Raw` | Mapp på minnet |
| `FULL_VERIFY_DAYS` | `30` | Fullständig kontroll var N:e dag, `0` = av |
| `EJECT_WHEN_DONE` | `false` | Mata ut minnet efter lyckad backup |
| `NOTIFY` | `true` | macOS-notiser |

## Bra att veta

- **Vänta på notisen** innan du drar ur minnet. Drar du ur mitt i avbryts körningen säkert och fortsätter nästa gång.
- **Kontrollen direkt efter kopiering** kan i vissa fall läsa kopian från macOS minnescache i stället för från USB-minnet. Den månatliga fullständiga kontrollen körs direkt när minnet sätts i och läser då från själva minnet – det är den som fångar fel som uppstått på minnet över tid.
- **Den fullständiga kontrollen tar tid** – ungefär lika länge som det tar att läsa hela minnet (för ett billigt USB-minne kan 500 GB ta en timme eller mer).
- **Ett USB-minne är ingen fullständig backup.** Minnen går sönder och tappas bort. Ha minst en kopia till på annan plats (t.ex. NAS eller moln).
- Fungerar med minnen formaterade som APFS, Mac OS Extended och exFAT.

## Avinstallera

```bash
bash uninstall.sh
```

## Licens

MIT
