# pablo.uslugi — „Usługi WWW" dla Omarchy

Widget paska Omarchy (Quickshell), który pokazuje **lokalne usługi WWW
nasłuchujące na tej maszynie** — z dockera, procesów użytkownika i usług
systemowych — z adresami i portami. Klik w wiersz otwiera usługę
w przeglądarce. Nic oficjalnego w katalogu Omarchy tego nie robiło, więc
powstała ta wtyczka.

![koncepcja] w pasku: ikona + liczba usług · klik → panel z listą · klik
wiersza → `omarchy-launch-browser <url>`

## Instalacja

```bash
omarchy plugin add https://github.com/PNowakBG/omarchy-uslugi-www --enable
```

Instalator Omarchy sklonuje wtyczkę do `~/.config/omarchy/plugins/pablo.uslugi`.
Helper skanujący musi jeszcze trafić do `~/.local/bin` (Panel.qml woła go
stamtąd):

```bash
ln -sf ~/.config/omarchy/plugins/pablo.uslugi/bin/uslugi-www-stan ~/.local/bin/uslugi-www-stan
```

Aktualizacje: `omarchy plugin update pablo.uslugi`.

## Skąd pochodzą dane

Helper `bin/uslugi-www-stan status` (python3, stdlib) scala dwa źródła:

- **`docker ps`** — porty publikowane przez kontenery → etykieta `docker`,
- **`ss -tlnp`** — gniazda nasłuchujące:
  - proces użytkownika → etykieta `proces` (lub `venv`, gdy w cmdline jest
    „venv"),
  - **proces roota/systemowy bez nazwy** (minio, sunshine…) → pokazany
    WYŁĄCZNIE, jeśli port zadeklarujesz w mapie (etykieta `system`).

Rozpoznawane środowiska (etykieta dla ludzi): **Docker** (z projektem
compose), **Kubernetes** (cgroup `kubepods`), **Podman**, **maszyna
wirtualna** (libvirt/QEMU), **kontener LXC**, **usługa w tle** (unit
systemd), **Flatpak**, **Snap**, **AppImage**, **venv**, **devtools**
(przeglądarka pod zdalnym sterowaniem), **aplikacja Java**, **Node.js**,
**Python**, **proces lokalny**. Wszystko da się nadpisać w mapie.

Porty systemowe (DNS 53, CUPS 631, Sunshine 47984–48010, SSH…) są pomijane.

## Przyjazne nazwy i ukrywanie: `~/.config/local-www.map`

```text
# port nazwa        → port pokazywany pod tą nazwą (nadpisuje nazwę procesu)
# port !            → port ukryty
9000 minio-s3
9001 minio-konsola
9222 lasvegas       # przeglądarka automatyzacji z DevTools
```

Przeglądarki z `--remote-debugging-port` dostają nazwę z katalogu profilu
(`~/.hermes/lv-browser-profile` → `lv-browser`), więc nie widzisz gołych
„chromium".

## Ustawienia widgetu (ikona zębatki w ustawieniach paska)

| klucz | domyślnie | opis |
|---|---|---|
| `refreshIntervalSec` | 15 | co ile sekund skanować (min. 5) |

## Język / Language

Widget mówi językiem systemu (od `LANG`): polski dla `pl_*`, angielski dla
reszty. Wymuszenie: ustawienia widgetu → **Language** → `pl` / `en` / `auto`.
Etykiety środowisk (Docker, usługa w tle, background service…) tłumaczy
warstwa QML — skaner zwraca neutralne klucze.

## Pliki

- `manifest.json` — manifest wtyczki (id `pablo.uslugi`, bar-widget),
- `Panel.qml` — widget paska + panel z listą,
- `bin/uslugi-www-stan` — skaner (python3),
- `install.sh` — dowiązanie helpera do `~/.local/bin` (idempotentne).
