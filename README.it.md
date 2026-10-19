# escpr-mac

Versione nativa per Apple Silicon del driver open source **Epson ESC/P-R**, per le vecchie stampanti a getto d'inchiostro Epson che sui Mac M1 e successivi non hanno più un driver funzionante.

Un solo script scarica il codice sorgente del driver Epson, lo corregge per il compilatore di macOS, lo compila in modo nativo per arm64, lo installa e crea la coda di stampa. Niente Rosetta, niente programmi Intel.

[Read in English](README.md)

## Perché

Molte stampanti Epson di qualche anno fa funzionano ancora benissimo, ma Epson non ha mai rilasciato driver per Apple Silicon. Il Mac vede la stampante sulla USB e poi non riesce a comunicarci. Epson però ha pubblicato per Linux un driver open source (ESC/P-R) che copre centinaia di questi modelli: questo progetto lo fa compilare e funzionare su macOS.

## Stampanti supportate

Il driver copre **620 modelli Epson a getto d'inchiostro**, tra cui:

- Stylus, Stylus Photo e Stylus Office (serie SX, TX, NX, BX, DX e altre)
- Expression (serie XP)
- WorkForce (serie WF e WP)
- EcoTank (serie ET e L)
- Artisan, PictureMate, ME Office e le serie PX ed EP vendute in Giappone

Per controllare il tuo modello:

```
bash install.sh --list sx218
bash install.sh --list "xp 6"
```

Non sono supportate le stampanti laser Epson, i modelli Epson recenti che usano il driver ESC/P-R2 e le stampanti di altre marche.

**Provato su:** Epson Stylus SX218 via USB con un MacBook Pro M5. Gli altri modelli usano lo stesso codice e dovrebbero funzionare, ma non sono stati provati. Le segnalazioni nelle issue sono benvenute.

## Requisiti

- Un Mac con chip Apple (M1 o successivi)
- Gli Strumenti da riga di comando di Xcode: se mancano, lo script propone di installarli
- Una connessione a internet durante l'installazione
- La password di amministratore

## Installazione

Collega la stampante con il cavo USB, accendila e poi:

```
git clone https://github.com/mdigital94/escpr-mac.git
cd escpr-mac
bash install.sh
```

Lo script trova la stampante Epson sulla USB, sceglie il file del modello giusto, compila il driver, rimuove le vecchie code della stessa stampante che non riuscivano a stampare, crea la nuova coda e propone una pagina di prova.

### Opzioni

| Comando | Cosa fa |
|---|---|
| `bash install.sh` | Riconosce la stampante Epson sulla USB e configura tutto |
| `bash install.sh --model "XP-600"` | Usa questo modello invece del riconoscimento automatico |
| `bash install.sh --model "XP-600" --uri "socket://192.168.1.50"` | Configura una stampante di rete a quell'indirizzo |
| `bash install.sh --model "XP-600" --driver-only` | Installa solo il driver; la stampante si aggiunge poi da Impostazioni di Sistema |
| `bash install.sh --list [filtro]` | Elenca i modelli supportati |
| `bash install.sh --uninstall` | Rimuove driver, file dei modelli e le code che ha creato |

Con `--driver-only`, vai in Impostazioni di Sistema, Stampanti e scanner, aggiungi la stampante e scegli il driver chiamato `<modello>, ESC/P-R (Apple Silicon)`.

## Disinstallazione

```
bash install.sh --uninstall
```

Rimuove `/Library/Printers/ESCPR`, `/Library/Printers/PPDs/Contents/Resources/ESCPR` e tutte le code di stampa che usano questo driver.

## Come funziona

Lo script scarica ESC/P-R 1.8.9 da una revisione fissata e ne verifica l'impronta SHA-256 prima di compilarlo. Poi applica quattro piccole correzioni al codice, necessarie perché era scritto solo per Linux:

1. **Funzioni non dichiarate.** Alcune funzioni vengono usate senza prototipo. Il compilatore Apple lo considera un errore, e su arm64 può corrompere i valori restituiti. Lo script aggiunge i prototipi corretti.
2. **Variabile globale doppia.** `jobFnc` è definita sia nel filtro sia nella libreria. Il linker di Apple la rifiuta, quindi ora il filtro usa quella della libreria.
3. **Codice solo per Unix.** La parte che gestisce memoria, tempi e sincronizzazione viene compilata solo se è definita la macro `unix`, che il compilatore Apple non definisce. Lo script aggiunge `__APPLE__` a quelle condizioni.
4. **Lettura del PPD.** Il filtro chiedeva il file di configurazione al server di stampa, cosa che dentro la sandbox dei filtri di macOS può fallire. Ora legge il percorso che CUPS gli passa nella variabile `PPD`.

Infine compila programmi arm64 statici, li installa in `/Library/Printers/ESCPR/filter` (di proprietà di root, come richiede CUPS) e modifica il PPD del modello perché CUPS chiami il filtro con il percorso completo. Le cartelle di sistema protette da macOS non vengono mai toccate.

## Problemi comuni

**La compilazione si ferma con un errore.** Lo script salva il log completo in `~/Downloads/escpr_make.log`. Allegalo a una issue.

**La pagina di prova resta in coda.** Controlla il log del sistema di stampa:

```
grep -i "escpr\|sandbox" /var/log/cups/error_log | tail -n 40
```

Se compaiono blocchi della sandbox, è la sandbox dei filtri di macOS che ferma il driver. Apri una issue con quelle righe.

**Il mio modello non viene trovato sulla USB.** Esegui `lpinfo -v` per vedere come macOS chiama la stampante, poi indica il modello a mano con `--model`.

**Scansione.** Questo progetto riguarda solo la stampa. Per lo scanner di una multifunzione prova prima Acquisizione Immagine o Anteprima, che spesso funzionano con il supporto scanner integrato di Apple.

## Crediti e licenza

- Il driver è **Epson Inkjet Printer Driver (ESC/P-R) for Linux** di Seiko Epson Corporation, rilasciato con licenza GNU GPL versione 2 o successive.
- Il sorgente viene scaricato dal mirror [vmartins/epson-inkjet-printer-escpr](https://github.com/vmartins/epson-inkjet-printer-escpr), fissato a una singola revisione e verificato con l'impronta.
- Questo progetto è rilasciato con la stessa licenza, **GPL-2.0-or-later**. Vedi [LICENSE](LICENSE).

## Avvertenze

Progetto non ufficiale, non affiliato né approvato da Seiko Epson Corporation o da Apple. Epson, Stylus, Expression, WorkForce ed EcoTank sono marchi di Seiko Epson Corporation. Lo usi a tuo rischio.
