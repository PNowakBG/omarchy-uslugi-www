import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Lokalne usługi WWW w pasku. Dane robi ~/.local/bin/uslugi-www-stan (JSON),
// ten plik tylko wyświetla i otwiera URL w przeglądarce.
Panel {
  id: root
  moduleName: "pablo.uslugi"
  ipcTarget: "pablo.uslugi"
  manageIpc: false

  readonly property string helper: Quickshell.env("HOME") + "/.local/bin/uslugi-www-stan"
  readonly property int refreshSec: Math.max(5, Number(setting("refreshIntervalSec", 15)))

  property var uslugi: []
  property string loadError: ""
  property string updatedAt: ""

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function etykietaZrodla(z) {
    if (z === "docker") return "docker"
    if (z === "venv") return "venv"
    if (z === "system") return "system"
    return "proces"
  }

  function ileUslug(n) {
    if (n === 1) return "1 usługa"
    if (n >= 2 && n <= 4) return n + " usługi"
    return n + " usług"
  }

  function tooltipText() {
    if (loadError !== "") return "Usługi: " + loadError
    if (uslugi.length === 0) return "Brak lokalnych usług WWW"
    var lines = []
    for (var i = 0; i < uslugi.length; i++) {
      var u = uslugi[i]
      lines.push(u.nazwa + " · " + u.url + " (" + etykietaZrodla(u.zrodlo) + ")")
    }
    return lines.join("\n")
  }

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  function applyStatus(text) {
    try {
      var data = JSON.parse(text)
      if (!data.ok) { loadError = data.error || "błąd"; return }
      loadError = ""
      uslugi = data.uslugi || []
      updatedAt = data.updatedAt || ""
    } catch (e) {
      loadError = "nieczytelny wynik skryptu"
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
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(520))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) {
        panelFlick.contentY = Math.max(0, Math.min(panelFlick.contentHeight - panelFlick.height, panelFlick.contentY + dy * Style.space(60)))
      }
      onTextKey: function(t) { if (t === "r" || t === "R") root.refresh() }

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
            title: "Usługi WWW"
            meta: root.loadError !== "" ? root.loadError
              : (root.uslugi.length === 0 ? "brak nasłuchujących usług"
                 : ileUslug(root.uslugi.length) + " · odświeżono " + root.updatedAt)
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
                tooltipText: "Odśwież (r)"
                foreground: root.foreground
                onClicked: root.refresh()
              }
            }
          }

          Repeater {
            model: root.uslugi

            delegate: Rectangle {
              required property var modelData
              width: parent.width
              height: row.implicitHeight + Style.space(16)
              radius: Style.cornerRadius
              color: mouse.containsMouse ? Qt.lighter(Color.background, 1.15) : Color.background

              Row {
                id: row
                anchors.verticalCenter: parent.verticalCenter
                leftPadding: Style.space(12)
                rightPadding: Style.space(12)
                spacing: Style.space(10)

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: root.etykietaZrodla(modelData.zrodlo)
                  color: modelData.zrodlo === "docker" ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                Column {
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(2)

                  Text {
                    textFormat: Text.PlainText
                    text: modelData.nazwa
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.url
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }
                }
              }

              MouseArea {
                id: mouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.otworz(modelData.url)
              }
            }
          }

          Text {
            width: parent.width
            visible: root.uslugi.length > 0
            textFormat: Text.PlainText
            text: "Klik wiersza otwiera w przeglądarce. Przyjazne nazwy portów: ~/.config/local-www.map"
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
