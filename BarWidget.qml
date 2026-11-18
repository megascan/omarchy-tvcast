import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar widget and queue manager for tvcast. Idle, it is just a cast icon. It
// watches tvcast's state files (no timers while idle) and polls
// `tvcast status --json` every two seconds only while a cast is running.
//   Left click: open the queue panel   Middle click: pause/resume
//   Right click: stop (while casting)  Scroll: seek 30 seconds
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
  readonly property bool engaged: casting || hasQueue
  readonly property bool paused: transport === "PAUSED_PLAYBACK"
  readonly property bool playing: casting && !paused
  readonly property string stateGlyph: !casting ? "󰓛" : (paused ? "󰏤" : "󰐊")
  readonly property int maxTitleChars: 26

  function close() { popupOpen = false }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

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
    root.deviceName = root.plain(d.deviceName || "").slice(0, 120)
    root.transcoding = d.transcode === true
    root.transport = root.casting ? String(d.transport || "").slice(0, 32) : ""
    root.position = root.casting ? (Number(d.position) || 0) : 0
    root.duration = root.casting ? (Number(d.duration) || 0) : 0
  }

  // Fill only the placeholders a string has, so translations may drop some.
  function fill(text, values) {
    return String(text).replace(/%([1-9])/g, function(m, n) { return values[n - 1] !== undefined ? values[n - 1] : "" })
  }
  function tooltip() {
    if (!engaged) return strings.t("tooltip.idle")
    var key = casting ? (paused ? "tooltip.paused" : "tooltip.playing") : "tooltip.stopped"
    return fill(strings.t(key), [title, deviceName, duration > 0 ? clock(position) + " / " + clock(duration) : ""])
  }

  function refresh() { if (!statusProcess.running) statusProcess.running = true }

  // Runs the bundled CLI as an argv vector through a login shell (for the
  // session PATH), so nothing is re-tokenized: the arguments are fixed words
  // and integers anyway.
  function run(args) {
    Quickshell.execDetached(["bash", "-lc", 'exec "$@"', "bash", root.tvcast].concat(args.map(String)))
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
    // Idle: just the cast icon, like the neighbouring status icons.
    dimmed: root.engaged && !root.playing
    text: !root.engaged ? "󰄘" : root.stateGlyph + (root.bar && root.bar.vertical ? ""
      : "  " + root.shortTitle(root.title) + (root.count > 1 ? "  (" + (root.currentIndex + 1) + "/" + root.count + ")" : ""))
    tooltipText: root.popupOpen ? "" : root.tooltip()
    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) { if (root.casting) root.run(["stop"]) }
      else if (mouseButton === Qt.MiddleButton) { if (root.engaged) root.run(["toggle"]) }
      else { root.popupOpen = !root.popupOpen; if (root.popupOpen) root.refresh() }
    }
    onWheelMoved: function(delta) { if (root.casting) root.run(["seek", delta > 0 ? "+30" : "-30"]) }
  }

  // Panel text follows the popup palette, as Omarchy's own popups do.
  readonly property color pfg: Commons.Color.popups.text
  readonly property color pdim: Qt.darker(Commons.Color.popups.text, 1.45)

  component PlainLabel: Text {
    textFormat: Text.PlainText
    color: root.pfg
    font.family: Style.font.family
    font.pixelSize: Style.font.body
    elide: Text.ElideRight
    maximumLineCount: 1
  }

  component IconButton: Button {
    foreground: root.pfg
    horizontalPadding: Style.spacing.controlPaddingX
    verticalPadding: Style.spacing.controlPaddingY
    opacity: enabled ? 1.0 : 0.4
  }

  // A full-width menu row with a leading glyph: Omarchy's PopupMenuRow.
  // The leading column every row shares: a glyph plus the gap before its
  // label, measured so queue titles, the TV name and menu labels line up.
  TextMetrics { id: glyphMetrics; font.family: Style.font.family; font.pixelSize: Style.font.body; text: "󰄘   " }
  readonly property real glyphColumn: glyphMetrics.advanceWidth

  component ActionRow: PopupMenuRow {
    property string glyph: ""
    property string label: ""
    text: glyph + "   " + label
  }

  PopupCard {
    id: popup
    anchorItem: root
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.left: parent.left
      anchors.right: parent.right
      spacing: Style.space(8)

      // Header: the title, then the TV row.
      PlainLabel {
        width: parent.width
        text: root.engaged ? root.title : strings.t("panel.idleTitle")
        font.pixelSize: Style.font.subtitle
        font.bold: true
      }

      // TV row: icon and name on the left (elided first), state and the
      // change-TV action on the right. Insets match the menu rows below.
      Item {
        id: deviceRow
        width: parent.width
        height: Math.max(deviceLabel.implicitHeight, changeTv.visible ? changeTv.implicitHeight : 0)

        Text {
          id: deviceGlyph
          anchors.left: parent.left
          anchors.leftMargin: Style.spacing.controlPaddingX
          anchors.verticalCenter: parent.verticalCenter
          width: root.glyphColumn
          textFormat: Text.PlainText
          text: "󰔂"
          color: root.pdim
          font.family: Style.font.family
          font.pixelSize: Style.font.body
        }
        PlainLabel {
          id: deviceLabel
          anchors.left: deviceGlyph.right
          anchors.right: stateLabel.visible ? stateLabel.left : (changeTv.visible ? changeTv.left : parent.right)
          anchors.rightMargin: Style.space(8)
          anchors.verticalCenter: parent.verticalCenter
          color: root.pdim
          font.pixelSize: Style.font.bodySmall
          text: root.deviceName !== "" ? root.deviceName : strings.t("panel.noDevice")
        }
        PlainLabel {
          id: stateLabel
          visible: text !== ""
          anchors.right: changeTv.visible ? changeTv.left : parent.right
          anchors.rightMargin: changeTv.visible ? Style.space(4) : Style.spacing.controlPaddingX
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideNone
          color: root.pdim
          font.pixelSize: Style.font.bodySmall
          text: !root.engaged ? ""
            : (root.casting ? [] : [strings.t("panel.stopped")])
              .concat([strings.t("panel.position").arg(root.currentIndex + 1).arg(root.count)])
              .concat(root.casting && root.transcoding ? [strings.t("panel.transcoding")] : []).join("  ·  ")
        }
        IconButton {
          id: changeTv
          visible: !root.casting
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          iconText: root.deviceName !== "" ? "󰑐" : "󰍉"
          text: root.deviceName !== "" ? "" : strings.t("button.search")
          fontSize: Style.font.bodySmall
          iconSize: Style.font.body
          tooltipText: root.deviceName !== "" ? strings.t("button.changeTv") : strings.t("button.searchTv")
          onClicked: { root.popupOpen = false; root.run(["pick-device"]) }
        }
      }

      // Progress (drag to seek)
      Item {
        width: parent.width
        height: Math.max(posLabel.implicitHeight, seekSlider.implicitHeight)
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
          trackColor: Style.selectedFillFor(root.pfg, Commons.Color.accent)
          fillColor: root.pfg
          knobColor: root.pfg
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
        visible: root.engaged
        anchors.horizontalCenter: parent.horizontalCenter
        spacing: Style.space(2)
        LayoutMirroring.enabled: false
        LayoutMirroring.childrenInherit: true

        IconButton { iconText: "󰒮"; tooltipText: strings.t("button.previous"); enabled: root.currentIndex > 0; onClicked: root.run(["prev"]) }
        IconButton { iconText: "󰶖"; tooltipText: strings.t("button.back30"); enabled: root.casting; onClicked: root.run(["seek", "-30"]) }
        IconButton {
          iconText: root.playing ? "󰏤" : "󰐊"
          tooltipText: root.playing ? strings.t("button.pause") : strings.t("button.play")
          iconSize: Style.font.iconLarge
          horizontalPadding: Style.spacing.panelGap
          onClicked: root.run(["toggle"])
        }
        IconButton { iconText: "󰴆"; tooltipText: strings.t("button.forward30"); enabled: root.casting; onClicked: root.run(["seek", "+30"]) }
        IconButton { iconText: "󰒭"; tooltipText: strings.t("button.next"); enabled: root.currentIndex + 1 < root.count; onClicked: root.run(["next"]) }
        IconButton { iconText: "󰓛"; tooltipText: strings.t("button.stop"); enabled: root.casting; onClicked: root.run(["stop"]) }
      }

      PanelSeparator { foreground: root.pfg; visible: root.hasQueue }

      // Queue
      Flickable {
        id: queueView
        width: parent.width
        height: Math.min(queueColumn.implicitHeight, Style.spacing.popupRowHeight * 8)
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

            Rectangle {
              id: row
              required property var modelData
              required property int index
              readonly property bool current: index === root.currentIndex
              readonly property bool hot: rowHover.hovered

              width: queueColumn.width
              height: Style.spacing.popupRowHeight
              radius: Style.cornerRadius
              color: current ? Style.selectedFillFor(root.pfg, Commons.Color.accent)
                : (hot ? Style.hoverFill : "transparent")

              HoverHandler { id: rowHover }
              MouseArea {
                anchors.fill: parent
                cursorShape: Qt.PointingHandCursor
                onClicked: root.run(["play-index", String(row.index + 1)])
              }

              PlainLabel {
                id: rowNumber
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: root.glyphColumn
                font.pixelSize: Style.font.bodySmall
                color: row.current ? Commons.Color.accent : root.pdim
                text: row.current && root.casting ? root.stateGlyph : String(row.index + 1)
              }
              PlainLabel {
                anchors.left: rowNumber.right
                anchors.right: rowButtons.visible ? rowButtons.left : parent.right
                anchors.rightMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                font.pixelSize: Style.font.bodySmall
                font.bold: row.current
                text: row.modelData.title
              }

              // Per-item actions appear on hover, so the list stays calm.
              Row {
                id: rowButtons
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                visible: row.hot
                IconButton {
                  iconText: "󰁝"; tooltipText: strings.t("button.moveUp"); iconSize: Style.font.bodySmall
                  verticalPadding: 0
                  enabled: row.index > 0
                  onClicked: root.run(["move", String(row.index + 1), "up"])
                }
                IconButton {
                  iconText: "󰁅"; tooltipText: strings.t("button.moveDown"); iconSize: Style.font.bodySmall
                  verticalPadding: 0
                  enabled: row.index + 1 < root.count
                  onClicked: root.run(["move", String(row.index + 1), "down"])
                }
                IconButton {
                  iconText: "󰅖"; tooltipText: strings.t("button.remove"); iconSize: Style.font.bodySmall
                  verticalPadding: 0
                  onClicked: root.run(["remove", String(row.index + 1)])
                }
              }
            }
          }
        }
      }

      PanelSeparator { foreground: root.pfg }

      // Actions, as menu rows
      Column {
        width: parent.width
        spacing: 0

        ActionRow {
          glyph: "󰄘"
          label: root.engaged ? strings.t("action.castReplace") : strings.t("action.cast")
          onTriggered: { root.popupOpen = false; root.run(["cast"]) }
        }
        ActionRow {
          glyph: "󰐕"
          label: strings.t("action.add")
          onTriggered: { root.popupOpen = false; root.run(["add"]) }
        }
        ActionRow {
          visible: root.hasQueue
          glyph: "󰩺"
          label: strings.t("action.clear")
          onTriggered: root.run(["clear"])
        }
      }
    }
  }
}
