import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar widget and queue manager for tvcast. Idle, it is just a cast icon. It
// watches tvcast's state files (no timers while idle) and polls
// `tvcast status --json` while a cast is running (2 s with the panel open, 10 s closed).
// Volume and mute are read only while the panel is open or a volume change is settling.
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
  // Seek in flight: the knob holds this position (seconds) until the TV
  // reports it, or seekHold times out, so it doesn't snap back meanwhile.
  property int seekTarget: -1
  readonly property int shownPosition: seekTarget >= 0 ? seekTarget : position
  // TV volume (0-100). The slider shows volumeTarget/muteTarget until the TV
  // reports them, or volumeHold times out, so it never snaps back.
  property bool volumeControl: false
  // True once a reply carrying the volume arrived since the panel opened (or
  // since a poll without one): until then the row is greyed out, so a scroll
  // can't send a level computed from an old reading.
  property bool volumeFresh: false
  property int volume: 0
  property bool muted: false
  property int volumeTarget: -1
  property int muteTarget: -1
  readonly property int shownVolume: volumeTarget >= 0 ? volumeTarget : volume
  readonly property bool shownMuted: muteTarget >= 0 ? muteTarget === 1 : muted
  property int currentIndex: 0
  property var items: []
  property string itemsKey: ""
  property int itemOffset: 0
  property int queueCount: 0
  property bool refreshPending: false
  property int seekSteps: 0
  property real wheelAccum: 0
  property bool popupOpen: false
  onPopupOpenChanged: if (popupOpen) volumeFresh = false
  // A slider drag that arrived while a relative seek was still being sent.
  property int pendingSeekTo: -1
  readonly property color fg: bar ? bar.foreground : Commons.Color.foreground
  readonly property string fontFam: bar ? bar.fontFamily : Style.font.family

  readonly property int count: queueCount
  readonly property bool hasQueue: count > 0
  readonly property bool engaged: casting || hasQueue
  readonly property bool paused: transport === "PAUSED_PLAYBACK"
  // The TV takes seeks only once a file has loaded (LG webOS hangs otherwise).
  readonly property bool canSeek: casting && duration > 0 && !/TRANSITIONING|STOPPED|NO_MEDIA|OTHER/.test(transport)
  readonly property bool playing: casting && !paused
  readonly property string stateGlyph: !casting ? "󰓛" : (paused ? "󰏤" : "󰐊")
  readonly property int maxTitleChars: 26

  function close() { popupOpen = false }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  // File names are untrusted: every sink is Text.PlainText, so they only need
  // to be single-line, bounded and free of control, bidi and invisible characters.
  function cut(s, n) {
    if (s.length <= n) return s
    var c = s.charCodeAt(n - 1)
    return s.slice(0, c >= 0xD800 && c <= 0xDBFF ? n - 1 : n)
  }
  function plain(s) {
    return cut(String(s || "")
      .replace(/[\t\n\v\f\r\u2028\u2029]/g, " ")
      .replace(/[\u0000-\u001f\u007f-\u009f\u061c\u200b-\u200f\u202a-\u202e\u2060-\u2064\u2066-\u2069\ufeff]/g, ""), 200)
  }
  function shortTitle(s) {
    var t = plain(s)
    return t.length > maxTitleChars ? cut(t, maxTitleChars - 1) + "…" : t
  }
  function clock(sec) {
    sec = Math.max(0, sec | 0)
    var h = Math.floor(sec / 3600), m = Math.floor(sec % 3600 / 60), s = sec % 60
    return (h > 0 ? h + ":" + (m < 10 ? "0" : "") : "") + m + ":" + (s < 10 ? "0" : "") + s
  }

  readonly property int maxRows: 500
  function applyStatus(text) {
    var d
    if (!String(text || "").trim()) return
    try { d = JSON.parse(text) } catch (e) { return }
    if (!d || typeof d !== "object" || typeof d.active !== "boolean") return
    var all = Array.isArray(d.items) ? d.items : []
    var index = Math.max(0, Math.min(Math.floor(Number(d.index) || 0), Math.max(0, all.length - 1)))
    var offset = all.length > maxRows ? Math.max(0, Math.min(index - Math.floor(maxRows / 2), all.length - maxRows)) : 0
    var list = all.slice(offset, offset + maxRows).map(function(it) {
      var k = String(it && it.key || "")
      return { title: root.plain(it && it.title), kind: String(it && it.kind || "").slice(0, 10), key: /^[A-Za-z0-9-]{1,80}$/.test(k) ? k : "" }
    })
    var key = offset + "\n" + JSON.stringify(list)
    if (key !== root.itemsKey) {
      root.itemOffset = offset
      root.items = list
      root.itemsKey = key
    }
    root.queueCount = all.length
    root.currentIndex = index
    root.casting = d.active === true
    root.title = root.plain(d.title || (all[index] ? all[index].title : ""))
    root.deviceName = root.cut(root.plain(d.deviceName || ""), 120)
    root.transcoding = d.transcode === true
    root.transport = root.casting ? String(d.transport || "").slice(0, 32) : ""
    root.position = root.casting ? (Number(d.position) || 0) : 0
    root.duration = root.casting ? (Number(d.duration) || 0) : 0
    if (root.seekTarget >= 0 && (!root.casting || Math.abs(root.position - root.seekTarget) <= 3)) root.seekTarget = -1
    root.volumeFresh = root.casting && typeof d.volumeControl === "boolean"
    if (!root.casting || typeof d.volumeControl === "boolean") {
      root.volumeControl = root.casting && d.volumeControl === true
      root.volume = root.volumeControl ? Math.max(0, Math.min(100, Number(d.volume) || 0)) : 0
      root.muted = root.volumeControl && d.muted === true
      if (root.volumeTarget >= 0 && !volumeSend.running && (!root.volumeControl || Math.abs(root.volume - root.volumeTarget) <= 1)) root.volumeTarget = -1
      if (root.muteTarget >= 0 && (!root.volumeControl || (root.muteTarget === 1) === root.muted)) root.muteTarget = -1
    }
  }

  // One SetVolume per pause in dragging or scrolling (150 ms), not per step.
  function setVolume(v) {
    root.volumeTarget = Math.max(0, Math.min(100, Math.round(v)))
    volumeHold.restart()
    volumeSend.restart()
  }
  function toggleMute() {
    root.muteTarget = root.shownMuted ? 0 : 1
    volumeHold.restart()
    root.run(["mute", root.muteTarget === 1 ? "on" : "off"])
  }

  function seekBy(steps) {
    if (!root.canSeek || steps === 0) return
    var limit = Math.max(1, Math.ceil(root.duration / 30))
    root.seekSteps = Math.max(-limit, Math.min(limit, root.seekSteps + steps))
    root.seekTarget = Math.max(0, Math.min(Math.max(0, root.duration - 1), root.shownPosition + steps * 30))
    seekHold.restart()
    seekSend.restart()
  }
  function wheelSeek(delta) {
    if (!delta) return
    root.wheelAccum += delta
    var steps = root.wheelAccum > 0 ? Math.floor(root.wheelAccum / 120) : Math.ceil(root.wheelAccum / 120)
    if (steps === 0 && Math.abs(delta) >= 120) steps = delta > 0 ? 1 : -1
    if (steps === 0) { wheelReset.restart(); return }
    root.wheelAccum = 0
    root.seekBy(steps)
  }
  function flushSeek() {
    if (root.pendingSeekTo >= 0 && !seekProcess.running) {
      root.run(["seek-to", root.pendingSeekTo])
      root.pendingSeekTo = -1
      return
    }
    if (root.seekSteps === 0 || seekProcess.running) return
    if (!root.canSeek) { root.seekSteps = 0; return }
    var secs = root.seekSteps * 30
    root.seekSteps = 0
    seekProcess.command = ["bash", "-lc", 'exec "$@"', "bash", root.tvcast, "seek", (secs > 0 ? "+" : "") + secs]
    seekProcess.running = true
  }

  // A drag waits for a relative seek still on its way, so it lands last.
  function seekTo(sec) {
    root.seekSteps = 0
    seekSend.stop()
    root.seekTarget = Math.max(0, Math.min(Math.max(0, root.duration - 1), 999999999, Math.round(Number(sec) || 0)))
    seekHold.restart()
    if (seekProcess.running) { root.pendingSeekTo = root.seekTarget; return }
    root.pendingSeekTo = -1
    root.run(["seek-to", root.seekTarget])
  }
  // Row actions name the item by position and by key: the CLI acts on the
  // item with that key wherever it is now, or on nothing if it is gone.
  function rowArgs(args, item) {
    var k = String(item && item.key || "")
    return /^[A-Za-z0-9-]{1,80}$/.test(k) ? args.concat([k]) : args
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

  function refresh() {
    if (statusProcess.running) { root.refreshPending = true; return }
    var withVolume = root.popupOpen || root.volumeTarget >= 0 || root.muteTarget >= 0
    statusProcess.command = [root.tvcast, "status", "--json"].concat(withVolume ? ["--volume"] : [])
    statusProcess.running = true
  }

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
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyStatus(text) }
    onExited: if (root.refreshPending) { root.refreshPending = false; Qt.callLater(root.refresh) }
  }

  Process {
    id: seekProcess
    onExited: { refreshSoon.restart(); if (root.seekSteps !== 0 || root.pendingSeekTo >= 0) Qt.callLater(root.flushSeek) }
  }

  Timer {
    // Slower with the panel closed and nothing unsettled: track changes arrive through the file watches.
    interval: root.popupOpen || !root.canSeek || root.seekTarget >= 0 || root.volumeTarget >= 0 ? 2000 : 10000
    repeat: true
    // Paused while the seek knob is held, so a poll can't move it.
    running: root.casting && !root.scrubbing
    onTriggered: root.refresh()
  }

  property bool scrubbing: false
  Timer { id: seekHold; interval: 6000; onTriggered: root.seekTarget = -1 }

  Timer { id: refreshSoon; interval: 700; onTriggered: root.refresh() }
  Timer { id: seekSend; interval: 150; onTriggered: root.flushSeek() }
  Timer { id: wheelReset; interval: 400; onTriggered: root.wheelAccum = 0 }
  Timer { id: volumeSend; interval: 150; onTriggered: if (root.volumeTarget >= 0) root.run(["volume", root.volumeTarget]) }
  Timer { id: volumeHold; interval: 5000; onTriggered: { root.volumeTarget = -1; root.muteTarget = -1 } }

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
    onWheelMoved: function(delta) { if (root.canSeek) root.wheelSeek(delta) }
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

      // Progress: click or drag to seek. The slider spans the full row height
      // for a bigger hit area. Greyed out when the TV reports no duration
      // (images, some streams) or is still loading.
      Item {
        id: progressRow
        readonly property bool seekable: root.duration > 0
        width: parent.width
        height: Math.max(posLabel.implicitHeight, seekSlider.implicitHeight, Style.space(30))
        visible: root.casting
        enabled: root.canSeek
        opacity: root.canSeek ? 1 : 0.4

        PlainLabel {
          id: posLabel
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          font.pixelSize: Style.font.caption
          text: progressRow.seekable ? root.clock(seekSlider.dragging ? seekSlider.liveValue : root.shownPosition) : "–:––"
        }
        PanelSlider {
          id: seekSlider
          bar: root.bar
          anchors.left: posLabel.right
          anchors.right: durLabel.left
          anchors.leftMargin: Style.space(8)
          anchors.rightMargin: Style.space(8)
          anchors.top: parent.top
          anchors.bottom: parent.bottom
          minimum: 0
          maximum: Math.max(1, root.duration)
          step: 30
          integer: true
          value: progressRow.seekable ? root.shownPosition : 0
          onDraggingChanged: root.scrubbing = dragging
          trackColor: Style.selectedFillFor(root.pfg, Commons.Color.accent)
          fillColor: root.pfg
          knobColor: root.pfg
          onReleased: function(v) { root.seekTo(v) }
        }
        PlainLabel {
          id: durLabel
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          font.pixelSize: Style.font.caption
          text: progressRow.seekable ? root.clock(root.duration) : "–:––"
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
        IconButton { iconText: "󰶖"; tooltipText: strings.t("button.back30"); enabled: root.canSeek; onClicked: root.seekBy(-1) }
        IconButton {
          iconText: root.playing ? "󰏤" : "󰐊"
          tooltipText: root.playing ? strings.t("button.pause") : strings.t("button.play")
          iconSize: Style.font.iconLarge
          horizontalPadding: Style.spacing.panelGap
          onClicked: root.run(["toggle"])
        }
        IconButton { iconText: "󰴆"; tooltipText: strings.t("button.forward30"); enabled: root.canSeek; onClicked: root.seekBy(1) }
        IconButton { iconText: "󰒭"; tooltipText: strings.t("button.next"); enabled: root.currentIndex + 1 < root.count; onClicked: root.run(["next"]) }
        IconButton { iconText: "󰓛"; tooltipText: strings.t("button.stop"); enabled: root.casting; onClicked: root.run(["stop"]) }
      }

      // Volume: the speaker toggles mute, the slider (and scrolling over it)
      // sets the TV's volume. Greyed out when the TV offers no volume control.
      Item {
        id: volumeRow
        width: parent.width
        height: Math.max(muteButton.implicitHeight, volumeSlider.implicitHeight)
        visible: root.casting
        enabled: root.volumeControl && root.volumeFresh
        opacity: root.volumeControl && root.volumeFresh ? 1 : 0.4

        IconButton {
          id: muteButton
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
          opacity: 1
          iconText: root.shownMuted ? "󰝟" : (root.shownVolume === 0 ? "󰕿" : (root.shownVolume < 50 ? "󰖀" : "󰕾"))
          tooltipText: !root.volumeControl ? strings.t("panel.noVolume") : (root.shownMuted ? strings.t("button.unmute") : strings.t("button.mute"))
          onClicked: root.toggleMute()
        }
        PanelSlider {
          id: volumeSlider
          bar: root.bar
          // Same track span as the progress slider above.
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.leftMargin: Math.max(muteButton.width + Style.space(4), seekSlider.x)
          anchors.rightMargin: Math.max(volLabel.implicitWidth + Style.space(8), progressRow.width - seekSlider.x - seekSlider.width)
          anchors.verticalCenter: parent.verticalCenter
          minimum: 0
          maximum: 100
          step: 5
          integer: true
          value: root.volumeControl ? root.shownVolume : 0
          opacity: root.shownMuted ? 0.5 : 1
          trackColor: Style.selectedFillFor(root.pfg, Commons.Color.accent)
          fillColor: root.pfg
          knobColor: root.pfg
          onMoved: function(v) { root.setVolume(v) }
          onReleased: function(v) { root.setVolume(v) }
          onRightClicked: root.toggleMute()
        }
        PlainLabel {
          id: volLabel
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          elide: Text.ElideNone
          font.pixelSize: Style.font.caption
          text: root.volumeControl ? String(root.shownVolume) : "–"
        }
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
              readonly property int queuePos: root.itemOffset + index
              readonly property bool current: queuePos === root.currentIndex
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
                onClicked: root.run(root.rowArgs(["play-index", String(row.queuePos + 1)], row.modelData))
              }

              PlainLabel {
                id: rowNumber
                anchors.left: parent.left
                anchors.leftMargin: Style.spacing.controlPaddingX
                anchors.verticalCenter: parent.verticalCenter
                width: root.glyphColumn
                font.pixelSize: Style.font.bodySmall
                color: row.current ? Commons.Color.accent : root.pdim
                text: row.current && root.casting ? root.stateGlyph : String(row.queuePos + 1)
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
                  enabled: row.queuePos > 0
                  onClicked: root.run(root.rowArgs(["move", String(row.queuePos + 1), "up"], row.modelData))
                }
                IconButton {
                  iconText: "󰁅"; tooltipText: strings.t("button.moveDown"); iconSize: Style.font.bodySmall
                  verticalPadding: 0
                  enabled: row.queuePos + 1 < root.count
                  onClicked: root.run(root.rowArgs(["move", String(row.queuePos + 1), "down"], row.modelData))
                }
                IconButton {
                  iconText: "󰅖"; tooltipText: strings.t("button.remove"); iconSize: Style.font.bodySmall
                  verticalPadding: 0
                  onClicked: root.run(root.rowArgs(["remove", String(row.queuePos + 1)], row.modelData))
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
