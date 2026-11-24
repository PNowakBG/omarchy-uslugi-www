import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Lokalne usługi WWW w pasku. Dane robi ~/.local/bin/uslugi-www-stan (JSON),
// ten plik tłumaczy klucze na język systemu (PL/EN) i otwiera URL-e.
// Historia CPU (mini-wykres) trzymamy w pamięci widgetu — ostatnie 12 próbek.
//
// Każda usługa ma rodzaj (STAŁA / TEST agenta / RĘCZNA / NARZĘDZIE), opis kto
// ją wystawił, od kiedy i kiedy był restart, oraz własną nazwę ustawianą
// ołówkiem przy nazwie. Wszystkie teksty z danych idą przez Text.PlainText —
// nazwę wpisuje człowiek, więc nie może być interpretowana jako HTML.
Panel {
  id: root
  moduleName: "pablo.uslugi"
  ipcTarget: "pablo.uslugi"
  manageIpc: false

  readonly property string helper: Quickshell.env("HOME") + "/.local/bin/uslugi-www-stan"
  readonly property int refreshSec: Math.max(5, Number(setting("refreshIntervalSec", 15)))
  readonly property int histMax: 12

  // kolory z MOTYWU (nie z paska) — czytelne na jasnym i ciemnym tle;
  // przygaszony tekst przez przezroczystość (Qt.darker daje czerń na ciemnym)
  readonly property color foreground: Color.foreground
  readonly property color dim: Qt.alpha(Color.foreground, 0.55)
  readonly property color urgent: root.bar ? root.bar.urgent : Color.urgent
  readonly property string fontFamily: Style.font.family

  property var uslugi: []
  // port → tablica ostatnich odczytów CPU (liczby albo -1 = brak danych)
  property var cpuHist: ({})
  property string loadError: ""
  property string updatedAt: ""
  // sortowanie listy: "name" | "ram" | "cpu"
  property string sortBy: "cpu"
  // filtr rodzaju: "" = wszystkie, albo stala | test | reczna | narzedzie | nieznana
  property string filtr: ""
  // widok: "full" (wszystko) | "compact" (jedna linijka na usługę);
  // nadpisWidoku = chwilowy przełącznik w panelu, baza = ustawienie widgetu
  property var nadpisWidoku: null
  readonly property bool kompakt: (nadpisWidoku !== null ? nadpisWidoku
                                   : String(setting("display", "full"))) === "compact"

  // edycja nazwy: klucz edytowanej usługi ("" = brak edycji)
  property string edytowany: ""
  property string edycjaTekst: ""
  property string edycjaPoczatek: ""
  property string edycjaAuto: ""
  // paleta kolorów otwarta dla usługi o tym kluczu ("" = zamknięta)
  property string kolorowany: ""

  // Kolory do oznaczania usług: nasycone, czytelne na jasnym i ciemnym motywie.
  // Klucze muszą się zgadzać z KOLORY w skanerze (on je weryfikuje).
  readonly property var kolejnoscKolorow: ["czerwony", "pomaranczowy", "zolty", "zielony", "turkusowy",
                                           "niebieski", "fioletowy", "rozowy", "szary"]
  readonly property var slownikKolorow: ({
    "czerwony":     { rgb: "#e5534b", pl: "czerwony",     en: "red" },
    "pomaranczowy": { rgb: "#e8873a", pl: "pomarańczowy", en: "orange" },
    "zolty":        { rgb: "#d4b13c", pl: "żółty",        en: "yellow" },
    "zielony":      { rgb: "#57ab5a", pl: "zielony",      en: "green" },
    "turkusowy":    { rgb: "#39a6a3", pl: "turkusowy",    en: "teal" },
    "niebieski":    { rgb: "#4c8fe0", pl: "niebieski",    en: "blue" },
    "fioletowy":    { rgb: "#a371f7", pl: "fioletowy",    en: "purple" },
    "rozowy":       { rgb: "#e06c9f", pl: "różowy",       en: "pink" },
    "szary":        { rgb: "#8b949e", pl: "szary",        en: "grey" }
  })

  function rgbKoloru(klucz) {
    var w = root.slownikKolorow[klucz]
    return w ? w.rgb : "transparent"
  }

  function ustawKolor(klucz, kolor) {
    root.kolorowany = ""
    if (kolorProcess.running) return
    kolorProcess.command = [root.helper, "kolor", klucz, kolor]
    kolorProcess.running = true
  }

  // ── i18n: język z LANG systemu (pl_* → polski, reszta → angielski) ──────
  readonly property string langOpcja: String(setting("language", "auto")).toLowerCase()
  readonly property string lang: langOpcja === "pl" || langOpcja === "en"
    ? langOpcja
    : ((Quickshell.env("LANG") || "en").toLowerCase().startsWith("pl") ? "pl" : "en")
  function i18n(pl, en) { return root.lang === "pl" ? pl : en }

  readonly property var slownikSrodowisk: ({
    "docker":      { pl: "Docker",             en: "Docker" },
    "kubernetes":  { pl: "Kubernetes",         en: "Kubernetes" },
    "podman":      { pl: "Podman",             en: "Podman" },
    "service":     { pl: "usługa w tle",       en: "background service" },
    "root-service":{ pl: "usługa systemowa",   en: "system service" },
    "venv":        { pl: "venv",               en: "Python venv" },
    "devtools":    { pl: "devtools",           en: "automation browser" },
    "flatpak":     { pl: "Flatpak",            en: "Flatpak" },
    "snap":        { pl: "Snap",               en: "Snap" },
    "appimage":    { pl: "AppImage",           en: "AppImage" },
    "vm":          { pl: "maszyna wirtualna",  en: "virtual machine" },
    "lxc":         { pl: "kontener LXC",       en: "LXC container" },
    "java":        { pl: "aplikacja Java",     en: "Java app" },
    "node":        { pl: "Node.js",            en: "Node.js" },
    "python":      { pl: "Python",             en: "Python" },
    "process":     { pl: "proces lokalny",     en: "local process" }
  })

  // Rodzaj usługi: odznaka (wielkie litery) i nazwa w filtrze (liczba mnoga).
  readonly property var slownikRodzajow: ({
    "stala":     { pl: "STAŁA",     en: "PERMANENT", plF: "stałe",     enF: "permanent" },
    "test":      { pl: "TEST",      en: "TEST",      plF: "testy",     enF: "tests" },
    "reczna":    { pl: "RĘCZNA",    en: "MANUAL",    plF: "ręczne",    enF: "manual" },
    "narzedzie": { pl: "NARZĘDZIE", en: "TOOL",      plF: "narzędzia", enF: "tools" },
    "nieznana":  { pl: "?",         en: "?",         plF: "nieznane",  enF: "unknown" }
  })
  readonly property var kolejnoscRodzajow: ["stala", "test", "reczna", "narzedzie", "nieznana"]

  // Dlaczego taki rodzaj — klucze ze skanera, %1 = parametr.
  readonly property var slownikPowodow: ({
    "agent-sam":       { pl: "to port samego agenta %1",          en: "%1's own port" },
    "agent-przodek":   { pl: "uruchomił ją agent %1",             en: "started by agent %1" },
    "agent-znacznik":  { pl: "ma ślad sesji agenta %1",           en: "carries a %1 session marker" },
    "worktree":        { pl: "z worktree %1",                     en: "from worktree %1" },
    "osierocona":      { pl: "jej folder już nie istnieje",       en: "its folder no longer exists" },
    "unit-stala":      { pl: "systemd uruchamia ją sam (%1)",     en: "systemd starts it (%1)" },
    "unit-reczna":     { pl: "jednostka %1 nie startuje sama",    en: "unit %1 does not start on its own" },
    "unit-tymczasowa": { pl: "jednostka tymczasowa %1",           en: "transient unit %1" },
    "docker-stala":    { pl: "Docker uruchamia ją sam (%1)",      en: "Docker restarts it (%1)" },
    "docker-reczna":   { pl: "Docker nie uruchomi jej sam",       en: "Docker won't restart it" },
    "mapa":            { pl: "zadeklarowana w local-www.map",     en: "declared in local-www.map" },
    "menedzer":        { pl: "pilnuje jej %1",                    en: "kept alive by %1" },
    "terminal":        { pl: "uruchomiona ręcznie w %1",          en: "started by hand in %1" },
    "odlaczona":       { pl: "odłączona od terminala w %1 (nohup/setsid)", en: "detached from a terminal in %1 (nohup/setsid)" },
    "narzedzie":       { pl: "część narzędzia %1",                en: "part of %1" }
  })

  function tSrod(klucz) {
    var wpis = root.slownikSrodowisk[klucz]
    return wpis ? wpis[root.lang] : klucz  // nadpisy z mapy pokazujemy dosłownie
  }

  function tTech(klucz, param) {
    if (klucz === "compose") return i18n("docker compose: ", "docker compose: ") + param
    if (klucz === "docker") return "Docker"
    if (klucz === "root-service") return i18n("usługa systemowa (root)", "system service (root)")
    if (klucz === "devtools-browser") return i18n("devtools (przeglądarka)", "automation browser")
    if (klucz === "exe") return param
    return param || klucz
  }

  function etykietaRodzaju(u) {
    if (u.rodzaj === "test" && u.kto && u.kto.agent) return i18n("TEST AGENTA", "AGENT TEST")
    var w = root.slownikRodzajow[u.rodzaj]
    return w ? w[root.lang] : "?"
  }

  function kolorRodzaju(u) {
    if (u.osierocona) return root.urgent
    if (u.rodzaj === "test") return Color.accent
    if (u.rodzaj === "stala") return root.foreground
    return root.dim
  }

  function tPowod(p) {
    var w = root.slownikPowodow[p[0]]
    if (!w) return String(p[0])
    var param = p[1] || (p[0] === "terminal" ? i18n("terminalu", "a terminal") : "?")
    return w[root.lang].replace("%1", param)
  }

  function tPowody(u) {
    var lista = u.powody || []
    var out = []
    for (var i = 0; i < lista.length; i++) out.push(tPowod(lista[i]))
    return out.length ? i18n("dlaczego: ", "why: ") + out.join(" · ") : ""
  }

  function tKto(u) {
    var k = u.kto || {}
    var czesci = []
    if (k.agent) czesci.push(k.gospodarz && k.gospodarz !== k.agent
                             ? i18n("%1 w %2", "%1 in %2").arg(k.agent).arg(k.gospodarz) : k.agent)
    else if (k.jednostka) czesci.push("systemd: " + k.jednostka + (k.menedzer === "user" ? " (--user)" : ""))
    else if (k.compose) czesci.push("docker compose: " + k.compose)
    else if (k.gospodarz) czesci.push(k.gospodarz)
    if (k.projekt) czesci.push(k.projekt)
    if (k.uzytkownik) czesci.push(k.uzytkownik)
    return czesci.length ? i18n("kto: ", "by: ") + czesci.join(" · ") : ""
  }

  function fmtCzas(t, zGodzina) {
    if (!t) return "—"
    var d = new Date(t * 1000)
    var teraz = new Date()
    var loc = Qt.locale(root.lang === "pl" ? "pl_PL" : "en_US")
    var dzis = new Date(teraz.getFullYear(), teraz.getMonth(), teraz.getDate())
    var dzien = new Date(d.getFullYear(), d.getMonth(), d.getDate())
    var dni = Math.round((dzis - dzien) / 86400000)
    var godz = d.toLocaleTimeString(loc, "HH:mm")
    if (dni === 0) return i18n("dziś ", "today ") + godz
    if (dni === 1) return i18n("wczoraj ", "yesterday ") + godz
    var data = d.toLocaleDateString(loc, d.getFullYear() === teraz.getFullYear() ? "d MMM" : "d MMM yyyy")
    return zGodzina ? data + " " + godz : data
  }

  function tCzas(u) {
    var s = i18n("wystawiona ", "exposed ")
    var takSamo = u.od && u.start && Math.abs(u.start - u.od) < 60
    s += (takSamo ? "" : i18n("od ", "since ")) + fmtCzas(u.od, takSamo)
    if (u.start && !takSamo) s += i18n(" · ostatni start ", " · last start ") + fmtCzas(u.start, true)
    if (u.restarty > 0) s += i18n(" · restartów: ", " · restarts: ") + u.restarty
    if (u.sam_wstaje) s += i18n(" · wstaje sama po restarcie komputera", " · comes back after a reboot")
    return s
  }

  function ileUslug(n) {
    if (root.lang === "pl") {
      if (n === 1) return "1 usługa"
      if (n >= 2 && n <= 4) return n + " usługi"
      return n + " usług"
    }
    return n === 1 ? "1 service" : n + " services"
  }

  function formatUptime(s) {
    if (s === null || s === undefined) return "—"
    if (s < 60) return s + " s"
    if (s < 3600) return Math.floor(s / 60) + " min"
    if (s < 86400) return Math.floor(s / 3600) + " h " + String(Math.floor(s % 3600 / 60)).padStart(2, "0") + " min"
    return Math.floor(s / 86400) + " d " + Math.floor(s % 86400 / 3600) + " h"
  }

  readonly property var sortOpcje: [
    { klucz: "name", etykieta: i18n("Nazwa", "Name"), klawisz: "n" },
    { klucz: "cpu", etykieta: "CPU", klawisz: "c" },
    { klucz: "ram", etykieta: "RAM", klawisz: "m" }
  ]

  // Filtr: „wszystkie” + każdy rodzaj, który faktycznie występuje (lub jest wybrany).
  readonly property var filtry: {
    var ile = {}
    for (var i = 0; i < uslugi.length; i++) ile[uslugi[i].rodzaj] = (ile[uslugi[i].rodzaj] || 0) + 1
    var lista = [{ klucz: "", etykieta: i18n("wszystkie", "all"), ile: uslugi.length }]
    for (var j = 0; j < kolejnoscRodzajow.length; j++) {
      var r = kolejnoscRodzajow[j]
      if ((ile[r] || 0) > 0 || r === filtr)
        lista.push({ klucz: r, etykieta: slownikRodzajow[r][lang === "pl" ? "plF" : "enF"], ile: ile[r] || 0 })
    }
    return lista
  }

  function nastepnyFiltr() {
    for (var i = 0; i < filtry.length; i++) {
      if (filtry[i].klucz === filtr) { filtr = filtry[(i + 1) % filtry.length].klucz; return }
    }
    filtr = ""
  }

  readonly property var posortowane: {
    var lista = []
    for (var i = 0; i < uslugi.length; i++)
      if (filtr === "" || uslugi[i].rodzaj === filtr) lista.push(uslugi[i])
    var k = sortBy
    lista.sort(function(a, b) {
      if (k === "name") return a.nazwa.localeCompare(b.nazwa, "pl")
      if (k === "ram") return (b.mem_mb || 0) - (a.mem_mb || 0)
      return (b.cpu || 0) - (a.cpu || 0)
    })
    return lista
  }

  readonly property string podsumowanie: {
    var cpu = 0, mem = 0
    for (var i = 0; i < uslugi.length; i++) {
      cpu += uslugi[i].cpu || 0
      mem += uslugi[i].mem_mb || 0
    }
    var memTxt = mem >= 1024 ? (mem / 1024).toFixed(1) + " GB" : Math.round(mem) + " MB"
    return ileUslug(uslugi.length) + " · CPU " + cpu.toFixed(1) + "% · RAM " + memTxt
  }

  function histDla(port) {
    return root.cpuHist[port] || []
  }

  function tooltipText() {
    if (loadError !== "") return i18n("Usługi: ", "Services: ") + loadError
    if (uslugi.length === 0) return i18n("Brak lokalnych usług WWW", "No local web services")
    var lines = []
    for (var i = 0; i < uslugi.length; i++) {
      var u = uslugi[i]
      lines.push(u.nazwa + " (" + tSrod(u.srodowisko) + ", " + etykietaRodzaju(u) + ") · " + u.url)
    }
    return lines.join("\n")
  }

  function refresh() {
    // W trakcie wpisywania nazwy nie przebudowujemy listy pod palcami.
    if (root.edytowany !== "") return
    if (!statusProcess.running) statusProcess.running = true
  }

  function applyStatus(text) {
    // Skan, który ruszył tuż przed kliknięciem ołówka, nie może przebudować
    // wierszy pod polem edycji (zgubiłby fokus) — tę próbkę pomijamy.
    if (root.edytowany !== "") return
    try {
      var data = JSON.parse(text)
      if (!data.ok) { loadError = data.error || "error"; return }
      loadError = ""
      uslugi = data.uslugi || []
      updatedAt = data.updatedAt || ""
      var h = {}
      for (var i = 0; i < uslugi.length; i++) {
        var u = uslugi[i]
        var arr = (root.cpuHist[u.port] || []).slice(-(root.histMax - 1))
        arr.push(u.cpu === null || u.cpu === undefined ? -1 : u.cpu)
        h[u.port] = arr
      }
      cpuHist = h
    } catch (e) {
      loadError = i18n("nieczytelny wynik skryptu", "unreadable script output")
    }
  }

  function otworz(url) {
    Quickshell.execDetached(["bash", "-lc", 'omarchy-launch-browser "$1"', "browser", url])
    close()
  }

  readonly property int maksNazwa: 60

  function zacznijEdycje(u) {
    root.kolorowany = ""
    root.edycjaPoczatek = u.nazwa
    root.edycjaAuto = u.nazwa_auto || ""
    root.edycjaTekst = u.nazwa
    root.edytowany = u.klucz
  }

  function zakonczEdycje(zapisz) {
    if (root.edytowany === "") return
    var klucz = root.edytowany
    var tekst = root.edycjaTekst.trim()
    // pole przycina do maksNazwa znaków — Enter bez zmian nie zapisuje uciętej nazwy
    var bezZmian = tekst === root.edycjaPoczatek
      || tekst === root.edycjaPoczatek.substring(0, root.maksNazwa).trim()
    // nazwa równa automatycznej = brak nazwy własnej (automat dalej się aktualizuje)
    if (tekst === root.edycjaAuto) tekst = ""
    root.edytowany = ""
    root.edycjaTekst = ""
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    if (!zapisz || bezZmian || nazwaProcess.running) { refresh(); return }
    // argumenty idą osobno (bez powłoki); pusta nazwa = wróć do automatycznej
    nazwaProcess.command = [root.helper, "nazwa", klucz, tekst]
    nazwaProcess.running = true
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      if (panelFlick) panelFlick.contentY = 0
      refresh()
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else {
      root.kolorowany = ""
      if (root.edytowany !== "") zakonczEdycje(false)
    }
  }

  Component.onCompleted: refresh()

  Timer {
    interval: root.refreshSec * 1000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Process {
    id: statusProcess
    running: false
    command: [root.helper, "status"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
  }

  Process {
    id: nazwaProcess
    running: false
    onExited: root.refresh()
  }

  Process {
    id: kolorProcess
    running: false
    onExited: root.refresh()
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // --- pasek ---------------------------------------------------------------

  Item {
    id: button
    anchors.fill: parent
    implicitWidth: barRow.implicitWidth + Style.space(14)
    implicitHeight: root.bar ? root.bar.barSize : Style.space(26)

    Row {
      id: barRow
      anchors.centerIn: parent
      spacing: Style.space(8)

      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: "󰌘"
        color: root.uslugi.length > 0 ? root.foreground : Qt.darker(root.foreground, 1.5)
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
      }

      Text {
        visible: root.bar && !root.bar.vertical
        anchors.verticalCenter: parent.verticalCenter
        textFormat: Text.PlainText
        text: root.loadError !== "" ? "!" : String(root.uslugi.length)
        color: root.loadError !== "" ? root.urgent : root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.body
      }
    }

    MouseArea {
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      acceptedButtons: Qt.LeftButton | Qt.MiddleButton
      onClicked: function(mouse) {
        if (root.bar) root.bar.hideTooltip(button)
        if (mouse.button === Qt.MiddleButton) root.refresh()
        else root.toggle()
      }
      onEntered: if (root.bar && !root.opened) root.bar.showTooltip(button, root.tooltipText())
      onExited: if (root.bar) root.bar.hideTooltip(button)
    }
  }

  // --- popup ---------------------------------------------------------------

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(560))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // pole nazwy dostaje klawisze samo (Esc/Enter obsługuje ono, nie panel)
      blocked: root.edytowany !== ""
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height, panelFlick.contentY + dy * Style.space(60)))
      }
      onTextKey: function(t) {
        if (t === "r" || t === "R") root.refresh()
        else if (t === "n" || t === "N") root.sortBy = "name"
        else if (t === "c" || t === "C") root.sortBy = "cpu"
        else if (t === "m" || t === "M") root.sortBy = "ram"
        else if (t === "d" || t === "D") root.nadpisWidoku = root.kompakt ? "full" : "compact"
        else if (t === "f" || t === "F") root.nastepnyFiltr()
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          PanelHero {
            width: parent.width
            title: i18n("Usługi WWW", "Local Web Services")
            meta: root.loadError !== "" ? root.loadError
              : (root.uslugi.length === 0 ? i18n("brak nasłuchujących usług", "no listening services")
                 : root.podsumowanie + " · " + root.updatedAt)
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconComponent: Component {
              Text {
                text: "󰌘"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              PanelActionButton {
                iconText: "󰑐"
                tooltipText: i18n("Odśwież (r)", "Refresh (r)")
                foreground: root.foreground
                onClicked: root.refresh()
              }
            }
          }

          // sortowanie: Nazwa / CPU / RAM
          Row {
            width: parent.width
            spacing: Style.space(10)

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: i18n("Sortuj:", "Sort:")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.sortOpcje

              delegate: Text {
                required property var modelData
                readonly property bool aktywny: root.sortBy === modelData.klucz
                anchors.verticalCenter: parent.verticalCenter
                textFormat: Text.PlainText
                text: modelData.etykieta
                color: aktywny ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.underline: aktywny

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.sortBy = parent.modelData.klucz
                }
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: root.kompakt ? i18n("Zwięzły", "Compact") : i18n("Pełny", "Detailed")
              color: root.foreground
              opacity: 0.85
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.underline: true

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.nadpisWidoku = root.kompakt ? "full" : "compact"
              }
            }

            Text {
              anchors.verticalCenter: parent.verticalCenter
              textFormat: Text.PlainText
              text: i18n("(klawisze n / c / m)", "(keys n / c / m)")
              color: root.dim
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // filtr rodzaju: wszystkie / stałe / testy / ręczne / narzędzia
          Flow {
            width: parent.width
            spacing: Style.space(10)
            visible: root.uslugi.length > 0

            Text {
              textFormat: Text.PlainText
              text: i18n("Pokaż:", "Show:")
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Repeater {
              model: root.filtry

              delegate: Text {
                required property var modelData
                readonly property bool aktywny: root.filtr === modelData.klucz
                textFormat: Text.PlainText
                text: modelData.etykieta + " " + modelData.ile
                color: aktywny ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.underline: aktywny

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.filtr = parent.modelData.klucz
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: i18n("(klawisz f)", "(key f)")
              color: root.dim
              opacity: 0.7
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          Repeater {
            model: root.posortowane

            delegate: CursorSurface {
              id: wiersz
              required property var modelData
              readonly property bool edycja: root.edytowany !== "" && root.edytowany === modelData.klucz
              readonly property real szerokoscTresci: width - Style.space(24)
              width: parent.width
              implicitHeight: wew.implicitHeight + Style.space(root.kompakt ? 8 : 16)
              height: implicitHeight
              foreground: root.foreground

              // klik w wiersz otwiera usługę — pod treścią, żeby ołówek i pole
              // nazwy dostawały własne kliknięcia
              MouseArea {
                id: mysz
                anchors.fill: parent
                hoverEnabled: true
                enabled: !wiersz.edycja
                cursorShape: Qt.PointingHandCursor
                onClicked: root.otworz(wiersz.modelData.url)
              }

              // pasek koloru usługi — widać go z daleka, także w widoku zwięzłym
              Rectangle {
                visible: wiersz.modelData.kolor !== ""
                anchors.left: parent.left
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.topMargin: Style.space(3)
                anchors.bottomMargin: Style.space(3)
                width: Style.space(4)
                radius: width / 2
                color: root.rgbKoloru(wiersz.modelData.kolor)
              }

              Column {
                id: wew
                anchors.verticalCenter: parent.verticalCenter
                width: parent.width
                leftPadding: Style.space(12)
                rightPadding: Style.space(12)
                spacing: root.kompakt ? Style.space(2) : Style.space(4)

                // nazwa · środowisko · RODZAJ · ołówek  (albo pole edycji)
                Row {
                  id: linia1
                  visible: !wiersz.edycja
                  spacing: Style.space(6)

                  // kropka koloru: pełna = nadany kolor, pusta obwódka = bez koloru;
                  // klik otwiera paletę
                  Rectangle {
                    id: kropka
                    anchors.verticalCenter: parent.verticalCenter
                    width: Style.space(11)
                    height: width
                    radius: width / 2
                    color: wiersz.modelData.kolor !== "" ? root.rgbKoloru(wiersz.modelData.kolor) : "transparent"
                    border.width: wiersz.modelData.kolor !== "" ? 0 : 1
                    border.color: kropkaMysz.containsMouse ? root.foreground : root.dim

                    MouseArea {
                      id: kropkaMysz
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.kolorowany = root.kolorowany === wiersz.modelData.klucz ? "" : wiersz.modelData.klucz
                    }
                  }

                  Text {
                    id: nazwaTxt
                    anchors.verticalCenter: parent.verticalCenter
                    width: Math.min(implicitWidth, wiersz.szerokoscTresci - kropka.width - srodTxt.implicitWidth
                                    - odznaka.width - olowek.implicitWidth - 4 * linia1.spacing)
                    elide: Text.ElideRight
                    textFormat: Text.PlainText
                    text: wiersz.modelData.nazwa
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Text {
                    id: srodTxt
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "· " + root.tSrod(wiersz.modelData.srodowisko)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Rectangle {
                    id: odznaka
                    anchors.verticalCenter: parent.verticalCenter
                    readonly property color kolor: root.kolorRodzaju(wiersz.modelData)
                    width: odznakaTxt.implicitWidth + Style.space(10)
                    height: odznakaTxt.implicitHeight + Style.space(2)
                    radius: Style.space(3)
                    color: Qt.alpha(kolor, 0.16)

                    Text {
                      id: odznakaTxt
                      anchors.centerIn: parent
                      textFormat: Text.PlainText
                      text: root.etykietaRodzaju(wiersz.modelData)
                      color: odznaka.kolor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      font.bold: true
                    }
                  }

                  Text {
                    id: olowek
                    anchors.verticalCenter: parent.verticalCenter
                    text: "󰏫"
                    color: olowekMysz.containsMouse ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption

                    MouseArea {
                      id: olowekMysz
                      anchors.fill: parent
                      anchors.margins: -Style.space(4)
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.zacznijEdycje(wiersz.modelData)
                    }
                  }
                }

                // paleta kolorów (po kliknięciu kropki)
                Flow {
                  visible: root.kolorowany === wiersz.modelData.klucz && !wiersz.edycja
                  width: wiersz.szerokoscTresci
                  spacing: Style.space(8)

                  Repeater {
                    model: root.kolejnoscKolorow

                    delegate: Rectangle {
                      required property var modelData
                      readonly property bool wybrany: wiersz.modelData.kolor === modelData
                      width: Style.space(18)
                      height: width
                      radius: width / 2
                      color: root.rgbKoloru(modelData)
                      border.width: wybrany || probkaMysz.containsMouse ? 2 : 0
                      border.color: root.foreground

                      MouseArea {
                        id: probkaMysz
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.ustawKolor(wiersz.modelData.klucz, parent.modelData)
                      }
                    }
                  }

                  Text {
                    height: Style.space(18)
                    verticalAlignment: Text.AlignVCenter
                    textFormat: Text.PlainText
                    text: i18n("✕ bez koloru", "✕ no colour")
                    color: bezKoloruMysz.containsMouse ? root.foreground : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption

                    MouseArea {
                      id: bezKoloruMysz
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.ustawKolor(wiersz.modelData.klucz, "")
                    }
                  }
                }

                TextField {
                  id: pole
                  visible: wiersz.edycja
                  width: wiersz.szerokoscTresci
                  foreground: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  horizontalPadding: Style.space(4)
                  verticalPadding: Style.space(1)
                  maximumLength: root.maksNazwa
                  placeholderText: wiersz.modelData.nazwa_auto
                  onVisibleChanged: if (visible) {
                    text = root.edycjaTekst
                    forceActiveFocus()
                    selectAll()
                  }
                  onTextChanged: if (wiersz.edycja) root.edycjaTekst = text
                  onAccepted: root.zakonczEdycje(true)
                  onActiveFocusChanged: if (!activeFocus && wiersz.edycja) root.zakonczEdycje(false)
                  Keys.onEscapePressed: function(event) {
                    root.zakonczEdycje(false)
                    event.accepted = true
                  }
                }

                Text {
                  visible: wiersz.edycja
                  width: wiersz.szerokoscTresci
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: i18n("Enter zapisuje · Esc anuluje · pusta nazwa przywraca automatyczną: %1",
                             "Enter saves · Esc cancels · an empty name restores the automatic one: %1")
                        .arg(wiersz.modelData.nazwa_auto)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: !root.kompakt
                  width: wiersz.szerokoscTresci
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: wiersz.modelData.url
                        + (wiersz.modelData.tech && root.tTech(wiersz.modelData.tech, wiersz.modelData.tech_param) !== wiersz.modelData.nazwa
                           ? "  ·  " + root.tTech(wiersz.modelData.tech, wiersz.modelData.tech_param) : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // kto wystawił: agent w gospodarzu / systemd / docker compose · projekt · użytkownik
                Text {
                  visible: !root.kompakt && text !== ""
                  width: wiersz.szerokoscTresci
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: root.tKto(wiersz.modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // od kiedy wystawiona, ostatni start, restarty, czy wstaje sama
                Text {
                  visible: !root.kompakt
                  width: wiersz.szerokoscTresci
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: root.tCzas(wiersz.modelData)
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Text {
                  visible: !root.kompakt && text !== ""
                  width: wiersz.szerokoscTresci
                  wrapMode: Text.Wrap
                  textFormat: Text.PlainText
                  text: root.tPowody(wiersz.modelData)
                  color: wiersz.modelData.osierocona ? root.urgent : root.dim
                  opacity: 0.85
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                // metryki: mini-wykres CPU · RAM · od kiedy — stały rozmiar
                Row {
                  spacing: Style.space(10)

                  Row {
                    visible: !root.kompakt
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: 2

                    Repeater {
                      model: root.histMax

                      Rectangle {
                        required property int index
                        readonly property var hist: root.histDla(wiersz.modelData.port)
                        readonly property real v: index < hist.length ? Math.max(0, hist[index]) : -1
                        width: 3
                        radius: 1
                        anchors.bottom: parent.bottom
                        height: v < 0 ? 2 : Math.max(2, Math.min(10, 2 + v / 12))
                        color: v < 0 ? Qt.lighter(root.dim, 2.5) : (v > 50 ? root.urgent : root.foreground)
                        opacity: v < 0 ? 0.5 : (0.45 + 0.55 * index / root.histMax)
                      }
                    }
                  }

                  Text {
                    visible: !root.kompakt
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: wiersz.modelData.cpu === null ? "CPU —" : "CPU " + wiersz.modelData.cpu + "%"
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: wiersz.modelData.mem_mb === null ? "" : "RAM " + (wiersz.modelData.mem_mb >= 1024 ? (wiersz.modelData.mem_mb / 1024).toFixed(1) + " GB" : Math.round(wiersz.modelData.mem_mb) + " MB")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  Text {
                    anchors.verticalCenter: parent.verticalCenter
                    textFormat: Text.PlainText
                    text: "↑ " + formatUptime(wiersz.modelData.uptime_s)
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.uslugi.length > 0 && root.posortowane.length === 0
            textFormat: Text.PlainText
            text: i18n("Brak usług tego rodzaju.", "No services of this kind.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Text {
            width: parent.width
            visible: root.uslugi.length > 0
            textFormat: Text.PlainText
            text: i18n("Klik wiersza otwiera w przeglądarce. Kropka ○ nadaje kolor, ołówek 󰏫 zmienia nazwę. Własni agenci: ~/.config/uslugi-www/agenci.conf",
                    "Click a row to open it in the browser. The dot ○ sets a colour, the pencil 󰏫 renames. Extra agents: ~/.config/uslugi-www/agenci.conf")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
