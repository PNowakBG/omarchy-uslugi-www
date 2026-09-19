import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Lokalne usługi WWW w pasku. Dane robi ~/.local/bin/uslugi-www-stan (JSON),
// ten plik tłumaczy klucze na język systemu (PL/EN) i otwiera URL-e.
// Historia CPU (mini-wykres) trzymamy w pamięci widgetu — ostatnie 12 próbek.
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
  readonly property string fontFamily: Style.font.family

  property var uslugi: []
  // port → tablica ostatnich odczytów CPU (liczby albo -1 = brak danych)
  property var cpuHist: ({})
  property string loadError: ""
  property string updatedAt: ""
  // sortowanie listy: "name" | "ram" | "cpu"
  property string sortBy: "cpu"
  // widok: "full" (wszystko) | "compact" (jedna linijka na usługę);
  // nadpisWidoku = chwilowy przełącznik w panelu, baza = ustawienie widgetu
  property var nadpisWidoku: null
  readonly property bool kompakt: (nadpisWidoku !== null ? nadpisWidoku
                                   : String(setting("display", "full"))) === "compact"

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

  readonly property var posortowane: {
    var lista = uslugi.slice()
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
      lines.push(u.nazwa + " (" + tSrod(u.srodowisko) + ") · " + u.url)
    }
    return lines.join("\n")
  }

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function applyStatus(text) {
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

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) {
    if (panelFlick) panelFlick.contentY = 0
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
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
        color: root.loadError !== "" ? (root.bar ? root.bar.urgent : Color.urgent) : root.foreground
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
    contentWidth: panel.fittedContentWidth(Style.space(480))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
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

          Repeater {
            model: root.posortowane

            delegate: CursorSurface {
              id: wiersz
              required property var modelData
              width: parent.width
              implicitHeight: wew.implicitHeight + Style.space(root.kompakt ? 8 : 16)
              height: implicitHeight
              foreground: root.foreground

              Column {
                id: wew
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Style.space(12)
                rightPadding: Style.space(12)
                spacing: root.kompakt ? Style.space(2) : Style.space(4)

                // nazwa + środowisko (Docker / background service / venv…)
                Text {
                  textFormat: Text.RichText
                  text: wiersz.modelData.nazwa
                        + "  <span style='color:" + root.dim + "'>· " + root.tSrod(wiersz.modelData.srodowisko) + "</span>"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                Text {
                  visible: !root.kompakt
                  textFormat: Text.PlainText
                  text: wiersz.modelData.url
                        + (wiersz.modelData.tech && root.tTech(wiersz.modelData.tech, wiersz.modelData.tech_param) !== wiersz.modelData.nazwa
                           ? "  ·  " + root.tTech(wiersz.modelData.tech, wiersz.modelData.tech_param) : "")
                  color: root.dim
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
                        color: v < 0 ? Qt.lighter(root.dim, 2.5) : (v > 50 ? (root.bar ? root.bar.urgent : Color.urgent) : root.foreground)
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

              MouseArea {
                id: mysz
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.otworz(wiersz.modelData.url)
              }
            }
          }

          Text {
            width: parent.width
            visible: root.uslugi.length > 0
            textFormat: Text.PlainText
            text: i18n("Klik wiersza otwiera w przeglądarce. Nazwy i środowiska portów: ~/.config/local-www.map",
                    "Click a row to open it in the browser. Friendly port names: ~/.config/local-www.map")
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
