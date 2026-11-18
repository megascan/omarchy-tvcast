import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar widget and queue manager for tvcast. Hidden while nothing is queued or
// casting. It watches tvcast's state files (no timers while idle) and polls
// `tvcast status --json` every two seconds only while a cast is running.
//   Left click: open the queue panel   Middle click: pause/resume
//   Right click: stop                  Scroll: seek 30 seconds
BarWidget {
  id: root
  moduleName: "megascan.tvcast"

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/tvcast"
  readonly property string stateDir: (Quickshell.env("XDG_STATE_HOME") || home + "/.local/state") + "/tvcast"
  // The CLI ships inside the plugin folder, so the widget works without install.sh.
  readonly property string tvcast: decodeURIComponent(String(Qt.resolvedUrl("bin/tvcast")).replace(/^file:\/\//, ""))

  property bool casting: false
  property string title: ""
  property string deviceName: ""
  property string transport: ""
  property bool transcoding: false
  property int position: 0
  property int duration: 0
  property int currentIndex: 0
  property var items: []
  property bool popupOpen: false
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFam: bar ? bar.fontFamily : Style.font.family

  readonly property int count: items.length
  readonly property bool hasQueue: count > 0
  readonly property bool shown: casting || hasQueue
  readonly property bool paused: transport === "PAUSED_PLAYBACK"
  readonly property bool playing: casting && !paused
  readonly property string stateGlyph: !casting ? "󰓛" : (paused ? "󰏤" : "󰐊")
  readonly property int maxTitleChars: 26

  function close() { popupOpen = false }

  visible: shown
  implicitWidth: shown ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight
  onShownChanged: if (!shown) popupOpen = false

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // File names are untrusted: plain, single-line and bounded wherever shown.
  function plain(s) {
    return String(s || "").replace(/[<>&]/g, function(c) { return c === "<" ? "‹" : (c === ">" ? "›" : "+") }).replace(/[\r\n\t]/g, " ").slice(0, 200)
  }
  function shortTitle(s) {
    var t = plain(s)
    return t.length > maxTitleChars ? t.slice(0, maxTitleChars - 1) + "…" : t
  }
  function clock(sec) {
    sec = Math.max(0, sec | 0)
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60
    return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s
  }

  function applyStatus(text) {
    var d
    try { d = JSON.parse(text || "{}") } catch (e) { return }
    if (!d || typeof d !== "object") return
    var list = Array.isArray(d.items) ? d.items.slice(0, 500) : []
    root.items = list.map(function(it) { return { title: root.plain(it && it.title), kind: String(it && it.kind || "").slice(0, 10) } })
    root.currentIndex = Math.max(0, Math.min(Number(d.index) || 0, Math.max(0, list.length - 1)))
    root.casting = d.active === true
    root.title = root.plain(d.title || (list[root.currentIndex] ? list[root.currentIndex].title : ""))
    root.deviceName = root.plain(d.deviceName || "TV").slice(0, 60)
    root.transcoding = d.transcode === true
    root.transport = root.casting ? String(d.transport || "").slice(0, 32) : ""
    root.position = root.casting ? (Number(d.position) || 0) : 0
    root.duration = root.casting ? (Number(d.duration) || 0) : 0
  }

  function refresh() { if (!statusProcess.running) statusProcess.running = true }

  // Fixed words and integers only; nothing user-controlled reaches the shell.
  function run(args) {
    if (!root.bar) return
    root.bar.run([root.tvcast].concat(args).map(function(a) { return "'" + String(a).replace(/[^A-Za-z0-9+:._-]/g, "") + "'" }).join(" "))
    refreshSoon.restart()
  }

  FileView {
    path: root.stateDir + "/queue.json"
    watchChanges: true
    printErrors: false
    onLoaded: root.refresh()
    onFileChanged: { reload(); root.refresh() }
  }

  FileView {
    path: root.cacheDir + "/state.json"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.refresh() }
  }

  Process {
    id: statusProcess
    command: [root.tvcast, "status", "--json"]
    stdout: StdioCollector { onStreamFinished: root.applyStatus(text) }
  }

  Timer {
    interval: 2000
    repeat: true
    running: root.casting
    onTriggered: root.refresh()
  }

  Timer { id: refreshSoon; interval: 700; onTriggered: root.refresh() }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    dimmed: !root.playing
    text: root.stateGlyph + (root.bar && root.bar.vertical ? ""
      : "  " + root.shortTitle(root.title) + (root.count > 1 ? "  (" + (root.currentIndex + 1) + "/" + root.count + ")" : ""))
    tooltipText: root.popupOpen ? "" : strings.t(root.casting ? (root.paused ? "tooltip.paused" : "tooltip.playing") : "tooltip.stopped")
      .arg(root.title).arg(root.deviceName).arg(root.duration > 0 ? root.clock(root.position) + " / " + root.clock(root.duration) : "")
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.run(["stop"])
      else if (mouseButton === Qt.MiddleButton) root.run(["toggle"])
      else { root.popupOpen = !root.popupOpen; if (root.popupOpen) root.refresh() }
    }
    onWheelMoved: function(delta) { if (root.casting) root.run(["seek", delta > 0 ? "+30" : "-30"]) }
  }

  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.fg
    font.family: root.fontFam
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
  }

  component IconButton: Button {
    foreground: root.fg
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    opacity: enabled ? 1.0 : 0.4
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(380))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(10)

      // Now playing
      Column {
        width: parent.width
        spacing: Style.space(3)

        PlainLabel {
          width: parent.width
          text: root.title || strings.t("panel.empty")
          font.pixelSize: Style.font.subtitle
          font.bold: true
        }
        PlainLabel {
          width: parent.width
          color: Qt.darker(root.fg, 1.4)
          font.pixelSize: Style.font.bodySmall
          text: (root.casting ? (root.paused ? strings.t("panel.paused") : strings.t("panel.playing")) : strings.t("panel.stopped"))
            .arg(root.deviceName).arg(root.currentIndex + 1).arg(root.count)
            + (root.casting && root.transcoding ? "  ·  " + strings.t("panel.transcoding") : "")
        }
      }

      // Progress (drag to seek)
      Item {
        width: parent.width
        height: Style.space(22)
        visible: root.casting && root.duration > 0

        PlainLabel {
          id: posLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          font.pixelSize: Style.font.caption
          text: root.clock(seekSlider.dragging ? seekSlider.value : root.position)
        }
        PanelSlider {
          id: seekSlider
          bar: root.bar
          anchors.left: posLabel.right
          anchors.right: durLabel.left
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          minimum: 0
          maximum: Math.max(1, root.duration)
          step: 1
          integer: true
          value: root.position
          onReleased: function(v) { root.run(["seek", String(Math.round(v))]) }
        }
        PlainLabel {
          id: durLabel
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          font.pixelSize: Style.font.caption
          text: root.clock(root.duration)
        }
      }

      // Transport controls; media controls keep their order in every language.
      Row {
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(4)
        LayoutMirroring.enabled: false
        LayoutMirroring.childrenInherit: true

        IconButton { iconText: "󰒮"; tooltipText: strings.t("button.previous"); enabled: root.currentIndex > 0; onClicked: root.run(["prev"]) }
        IconButton { iconText: "󰶖"; tooltipText: strings.t("button.back30"); enabled: root.casting; onClicked: root.run(["seek", "-30"]) }
        IconButton {
          iconText: root.playing ? "󰏤" : "󰐊"
          tooltipText: root.playing ? strings.t("button.pause") : strings.t("button.play")
          iconSize: Style.font.iconLarge
          horizontalPadding: Style.spacing.panelGap
          enabled: root.hasQueue || root.casting
          onClicked: root.run(["toggle"])
        }
        IconButton { iconText: "󰴆"; tooltipText: strings.t("button.forward30"); enabled: root.casting; onClicked: root.run(["seek", "+30"]) }
        IconButton { iconText: "󰒭"; tooltipText: strings.t("button.next"); enabled: root.currentIndex + 1 < root.count; onClicked: root.run(["next"]) }
        IconButton { iconText: "󰓛"; tooltipText: strings.t("button.stop"); enabled: root.casting; onClicked: root.run(["stop"]) }
      }

      PanelSeparator { foreground: root.fg; visible: root.hasQueue }

      // Queue
      Flickable {
        id: queueView
        width: parent.width
        height: Math.min(queueColumn.implicitHeight, Style.space(300))
        contentHeight: queueColumn.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        visible: root.hasQueue

        Column {
          id: queueColumn
          width: queueView.width
          spacing: Style.space(2)

          Repeater {
            model: root.items

            BorderSurface {
              id: row
              required property var modelData
              required property int index
              readonly property bool current: index === root.currentIndex
              readonly property bool hot: rowMouse.containsMouse

              width: queueColumn.width
              height: Math.max(rowLabel.implicitHeight, rowButtons.implicitHeight) + Style.space(6)
              radius: Style.spacing.labelGap
              color: current ? Style.selectedFillFor(root.fg, Commons.Color.accent)
                : (hot ? Style.normalFillFor(root.fg, Commons.Color.accent) : "transparent")
              borderSpec: current ? Border.controlSpec("normal", root.fg, Commons.Color.accent) : Border.none()

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.run(["play-index", String(row.index + 1)])
              }

              PlainLabel {
                id: rowLabel
                anchors.left: parent.left
                anchors.right: rowButtons.left
                anchors.leftMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Style.font.bodySmall
                font.bold: row.current
                text: (row.current && root.casting ? root.stateGlyph + "  " : (row.index + 1) + ".  ")
                  + row.modelData.title
              }

              Row {
                id: rowButtons
                anchors.right: parent.right
                anchors.rightMargin: Style.space(2)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0
                opacity: row.hot || row.current || rowButtons.childHovered ? 1 : 0.35
                property bool childHovered: false

                IconButton {
                  iconText: "󰁝"; tooltipText: strings.t("button.moveUp"); iconSize: Style.font.body
                  enabled: row.index > 0
                  onClicked: root.run(["move", String(row.index + 1), "up"])
                  onHovered: function(h) { rowButtons.childHovered = h }
                }
                IconButton {
                  iconText: "󰁅"; tooltipText: strings.t("button.moveDown"); iconSize: Style.font.body
                  enabled: row.index + 1 < root.count
                  onClicked: root.run(["move", String(row.index + 1), "down"])
                  onHovered: function(h) { rowButtons.childHovered = h }
                }
                IconButton {
                  iconText: "󰅖"; tooltipText: strings.t("button.remove"); iconSize: Style.font.body
                  onClicked: root.run(["remove", String(row.index + 1)])
                  onHovered: function(h) { rowButtons.childHovered = h }
                }
              }
            }
          }
        }
      }

      Row {
        anchors.right: parent.right
        spacing: Style.space(6)

        Button {
          text: strings.t("button.add")
          iconText: "󰐕"
          foreground: root.fg
          onClicked: { root.popupOpen = false; root.run(["add"]) }
        }
        Button {
          text: strings.t("button.clear")
          iconText: "󰩺"
          foreground: root.fg
          visible: root.hasQueue
          onClicked: root.run(["clear"])
        }
      }
    }
  }
}
