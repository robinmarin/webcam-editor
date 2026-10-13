import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import QtMultimedia
import qs.Ui
import qs.Commons

// Webcam controls (exposure, white balance, focus, ...) for V4L2/UVC cameras.
// All camera I/O goes through the bundled `webcam-tuner` script (reads/saves)
// and `v4l2-ctl` (writes), so the panel itself holds no camera logic.
Panel {
  id: root
  moduleName: "badger.webcam"
  ipcTarget: "badger.webcam"

  readonly property string device: root.setting("device", "/dev/video0")
  readonly property string tuner: String(Qt.resolvedUrl("webcam-tuner")).replace(/^file:\/\//, "")

  property bool present: false
  property string card: ""
  property bool hasProfile: false
  property var groups: []
  property string status: ""

  // Flat list of navigable rows: the action row, then one per control.
  readonly property var rows: {
    var list = ["__actions"]
    for (var g = 0; g < groups.length; g++)
      for (var c = 0; c < groups[g].controls.length; c++)
        list.push(groups[g].controls[c].name)
    return list
  }
  readonly property var actions: ["preview", "save", "reset"]
  property int cursorRow: 0
  property int cursorAction: 0
  property bool cursorActive: false

  // Pending slider writes: name -> value, flushed by setTimer.
  property var pending: ({})

  // Live preview inside the panel, started after a fresh read of the controls.
  property bool previewEnabled: true
  property bool freshRead: false
  property string previewError: ""
  readonly property bool previewActive: opened && present && previewEnabled && freshRead
  readonly property var cameraDevice: {
    var inputs = mediaDevices.videoInputs
    for (var i = 0; i < inputs.length; i++)
      if (inputs[i].description === root.card) return inputs[i]
    return mediaDevices.defaultVideoInput
  }

  // Set when the device disappears, so a replug restores the saved profile.
  property bool wasMissing: false

  function control(name) {
    for (var g = 0; g < groups.length; g++)
      for (var c = 0; c < groups[g].controls.length; c++)
        if (groups[g].controls[c].name === name) return groups[g].controls[c]
    return null
  }

  function refresh() {
    if (!readProc.running) readProc.running = true
  }

  function setControl(name, value) {
    var p = root.pending
    p[name] = Math.round(value)
    root.pending = p
    setTimer.restart()
  }

  function flushPending() {
    if (writeProc.running) { setTimer.restart(); return }
    var args = []
    var modeChange = false
    for (var name in root.pending) {
      args.push("-c", name + "=" + root.pending[name])
      var ctl = control(name)
      if (ctl && ctl.type !== "int") modeChange = true
    }
    if (!args.length) return
    root.pending = ({})
    writeProc.refreshAfter = modeChange
    writeProc.command = ["v4l2-ctl", "-d", root.device].concat(args)
    writeProc.running = true
  }

  function runTuner(args, message) {
    root.status = message
    tunerProc.command = [root.tuner, "-d", root.device].concat(args)
    if (!tunerProc.running) tunerProc.running = true
  }

  function togglePreview() {
    root.previewEnabled = !root.previewEnabled
    root.previewError = ""
  }

  // Writes every control at once; `pick(ctl)` returns the value to write, or
  // undefined to skip it.
  function writeAll(pick, refreshAfter) {
    var args = []
    // Auto modes first so dependent manual values are accepted.
    var autos = ["auto_exposure", "white_balance_automatic", "focus_automatic_continuous"]
    for (var g = 0; g < groups.length; g++)
      for (var c = 0; c < groups[g].controls.length; c++) {
        var ctl = groups[g].controls[c]
        var v = pick(ctl)
        if (v === undefined) continue
        if (autos.indexOf(ctl.name) >= 0) args.unshift("-c", ctl.name + "=" + v)
        else args.push("-c", ctl.name + "=" + v)
      }
    if (!args.length || writeProc.running) return
    writeProc.command = ["v4l2-ctl", "-d", root.device].concat(args)
    writeProc.refreshAfter = refreshAfter
    writeProc.running = true
  }

  function resetDefaults() {
    root.status = "Reset to camera defaults"
    writeAll(function(ctl) { return ctl["default"] }, true)
  }

  function runAction(name) {
    if (name === "preview") togglePreview()
    else if (name === "save") runTuner(["--save"], "Profile saved")
    else if (name === "reset") resetDefaults()
  }

  // ---- keyboard cursor ----
  function moveCursor(dy) {
    // Skip inactive controls; stay put if only inactive rows lie ahead.
    var next = cursorRow + dy
    while (next >= 0 && next < rows.length) {
      var ctl = control(rows[next])
      if (!ctl || !ctl.inactive) { cursorRow = next; return }
      next += dy
    }
  }

  function adjustCursor(dx) {
    var name = rows[cursorRow]
    if (name === "__actions") {
      cursorAction = Math.max(0, Math.min(actions.length - 1, cursorAction + dx))
      return
    }
    var ctl = control(name)
    if (!ctl || ctl.inactive) return
    if (ctl.type === "bool") {
      setControl(name, dx > 0 ? 1 : 0)
    } else if (ctl.type === "menu") {
      var idx = -1
      for (var i = 0; i < ctl.options.length; i++)
        if (Number(ctl.options[i].value) === ctl.value) idx = i
      idx = Math.max(0, Math.min(ctl.options.length - 1, idx + dx))
      ctl.value = Number(ctl.options[idx].value)
      setControl(name, ctl.value)
      groupsChanged()
    } else {
      var step = Math.max(ctl.step, Math.round((ctl.max - ctl.min) / 50 / ctl.step) * ctl.step)
      ctl.value = Math.max(ctl.min, Math.min(ctl.max, ctl.value + dx * step))
      setControl(name, ctl.value)
      groupsChanged()
    }
  }

  function activateCursor() {
    var name = rows[cursorRow]
    if (name === "__actions") { runAction(actions[cursorAction]); return }
    var ctl = control(name)
    if (ctl && ctl.type === "bool" && !ctl.inactive) setControl(name, ctl.value ? 0 : 1)
  }

  function hoverRow(name) {
    var i = rows.indexOf(name)
    if (i < 0) return
    cursorActive = true
    cursorRow = i
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Component.onCompleted: {
    // Cameras forget their settings on unplug/reboot; restore on shell start.
    applyProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      refresh()
      cursorActive = false
      cursorRow = 0
      status = ""
      freshRead = false
      previewError = ""
    }
  }

  // Hotplug watch: cheap existence check; restores the profile on replug.
  Timer {
    interval: 5000
    running: true
    repeat: true
    onTriggered: if (!presenceProc.running) presenceProc.running = true
  }

  Process {
    id: presenceProc
    command: ["test", "-e", root.device]
    onExited: function(code) {
      if (code !== 0) {
        root.wasMissing = true
        root.present = false
      } else if (root.wasMissing) {
        root.wasMissing = false
        // Give the UVC driver a moment to finish probing.
        replugDelay.restart()
      }
    }
  }

  Timer {
    id: replugDelay
    interval: 1500
    onTriggered: applyProc.running = true
  }

  Process {
    id: applyProc
    command: [root.tuner, "-d", root.device, "--apply"]
    onExited: if (root.opened) root.refresh()
  }

  Process {
    id: readProc
    command: [root.tuner, "-d", root.device, "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var data = JSON.parse(String(text || "{}"))
          root.present = !!data.present
          root.card = data.card || ""
          root.hasProfile = !!data.hasProfile
          root.groups = data.groups || []
          root.freshRead = true
        } catch (e) {
          root.present = false
          root.groups = []
        }
      }
    }
  }

  Timer {
    id: setTimer
    interval: 80
    onTriggered: root.flushPending()
  }

  Process {
    id: writeProc
    property bool refreshAfter: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text || "").trim() !== "") root.status = String(text).trim()
    }
    // Re-read after mode switches so the active/inactive state updates.
    // Slider writes skip it: rebuilding the rows would cut a drag short.
    onExited: if (refreshAfter) root.refresh()
  }

  Process {
    id: tunerProc
    onExited: function(code) {
      if (code !== 0) root.status = "Failed"
      root.refresh()
    }
  }

  MediaDevices { id: mediaDevices }

  // Created only while the preview shows: Qt keeps streaming after
  // `active` goes false, which would lock other apps out of the camera, so
  // the whole session is destroyed on close instead.
  Loader {
    id: cameraLoader
    active: root.previewActive
    sourceComponent: CaptureSession {
      camera: Camera {
        id: camera
        cameraDevice: root.cameraDevice
        active: true
        // Known quirk: while streaming, Qt rewrites the exposure one step
        // lower after each change (157 -> 156). Too small to see.
        // 720p MJPEG keeps 30 fps; raw YUYV at 720p drops to 10 fps.
        function pickFormat() {
          var best = null
          var formats = cameraDevice.videoFormats
          for (var i = 0; i < formats.length; i++) {
            var f = formats[i]
            if (f.resolution.width !== 1280 || f.resolution.height !== 720) continue
            if (!best || f.maxFrameRate > best.maxFrameRate) best = f
          }
          if (best) cameraFormat = best
        }
        Component.onCompleted: pickFormat()
        onErrorOccurred: function(error, message) {
          root.previewError = message || "Camera unavailable (in use by another app?)"
        }
      }
      videoOutput: videoOut
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖠"
    onPressed: function(b) { root.toggle() }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(400))
    contentHeight: panel.fittedContentHeight(panelColumn.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onMoveRequested: function(dx, dy) {
        if (!root.cursorActive) { root.cursorActive = true; return }
        if (dy !== 0) root.moveCursor(dy)
        else if (dx !== 0) root.adjustCursor(dx)
      }
      onActivateRequested: if (root.cursorActive) root.activateCursor()
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff

        Column {
          id: panelColumn
          width: scrollArea.availableWidth
          spacing: Style.space(12)

          // ---------- Hero ----------
          PanelHero {
            title: "Webcam"
            meta: root.present ? root.card.toUpperCase() : "NOT CONNECTED"
            detail: root.status
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            iconComponent: Component {
              Text {
                text: "󰖠"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          // ---------- Actions ----------
          Row {
            id: actionRow
            width: parent.width
            spacing: Style.spacing.xs
            readonly property real cellWidth: (width - spacing * 2) / 3

            Repeater {
              model: [
                { id: "preview", label: "Preview", tip: "Show or hide the live preview. Hide it to tweak while another app uses the camera" },
                { id: "save", label: "Save", tip: "Save as profile; restored on login and replug" },
                { id: "reset", label: "Defaults", tip: "Reset camera to factory defaults" }
              ]
              Button {
                required property var modelData
                required property int index
                width: actionRow.cellWidth
                text: modelData.label
                tooltipText: modelData.tip
                enabled: root.present || modelData.id !== "reset"
                fontSize: Style.font.caption
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                bordered: true
                active: (modelData.id === "save" && root.hasProfile)
                        || (modelData.id === "preview" && root.previewEnabled)
                hasCursor: root.cursorActive && root.rows[root.cursorRow] === "__actions" && root.cursorAction === index
                onClicked: root.runAction(modelData.id)
                onHovered: function(on) {
                  if (!on) return
                  root.hoverRow("__actions")
                  root.cursorAction = index
                }
              }
            }
          }

          // ---------- Live preview ----------
          Rectangle {
            visible: root.present && root.previewEnabled
            width: parent.width
            height: Math.round(width * 9 / 16)
            color: Qt.darker(root.bar.background, 1.3)
            radius: Style.cornerRadius
            clip: true

            VideoOutput {
              id: videoOut
              anchors.fill: parent
              fillMode: VideoOutput.PreserveAspectFit
            }

            Text {
              anchors.centerIn: parent
              width: parent.width - Style.space(24)
              visible: root.previewError !== "" || cameraLoader.status !== Loader.Ready
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.WordWrap
              text: root.previewError !== "" ? root.previewError : "Starting camera…"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
          }

          // ---------- Control groups ----------
          Repeater {
            model: root.present ? root.groups : []

            Column {
              required property var modelData
              width: panelColumn.width
              spacing: Style.space(8)

              PanelSeparator { foreground: root.bar.foreground }

              PanelSectionHeader {
                text: modelData.title.toUpperCase()
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
              }

              Repeater {
                model: modelData.controls
                ControlRow {
                  required property var modelData
                  ctl: modelData
                  width: panelColumn.width
                }
              }
            }
          }

          Item { width: parent.width; height: Style.space(4) }
        }
      }
    }
  }

  // One control: slider (int), switch (bool) or pill group (menu).
  component ControlRow: CursorSurface {
    id: row
    required property var ctl
    // Local copy so a slider keeps its position without a full re-read.
    property int current: ctl.value

    readonly property bool hasRowCursor: root.cursorActive && root.rows[root.cursorRow] === ctl.name
    hasCursor: hasRowCursor && ctl.type === "int"
    outline: true
    foreground: root.bar.foreground
    enabled: !ctl.inactive
    opacity: ctl.inactive ? 0.4 : 1.0
    implicitHeight: body.implicitHeight + Style.spacing.controlGap

    HoverHandler {
      onHoveredChanged: if (hovered && !row.ctl.inactive) root.hoverRow(row.ctl.name)
    }

    Column {
      id: body
      anchors.left: parent.left
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      anchors.leftMargin: Style.space(6)
      anchors.rightMargin: Style.space(6)
      spacing: Style.space(4)

      Item {
        width: parent.width
        implicitHeight: Math.max(label.implicitHeight,
                                 toggle.visible ? toggle.implicitHeight : 0,
                                 pills.visible ? pills.implicitHeight : 0)

        Text {
          id: label
          textFormat: Text.PlainText
          text: row.ctl.label + (row.ctl.inactive ? "  ·  auto" : "")
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
          anchors.left: parent.left
          anchors.verticalCenter: parent.verticalCenter
        }

        Text {
          visible: row.ctl.type === "int"
          textFormat: Text.PlainText
          text: Math.round(slider.dragging ? slider.liveValue : row.current)
          color: Qt.darker(root.bar.foreground, 1.4)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
        }

        ToggleSwitch {
          id: toggle
          visible: row.ctl.type === "bool"
          checked: !!row.ctl.value
          hasCursor: row.hasRowCursor
          foreground: root.bar.foreground
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onHovered: function(on) { if (on) root.hoverRow(row.ctl.name) }
          onToggled: root.setControl(row.ctl.name, row.ctl.value ? 0 : 1)
        }

        ButtonGroup {
          id: pills
          visible: row.ctl.type === "menu"
          options: row.ctl.options
          value: String(row.ctl.value)
          focusable: false
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          fontSize: Style.font.caption
          cursorIndex: {
            if (!row.hasRowCursor) return -1
            for (var i = 0; i < row.ctl.options.length; i++)
              if (Number(row.ctl.options[i].value) === row.ctl.value) return i
            return -1
          }
          anchors.right: parent.right
          anchors.verticalCenter: parent.verticalCenter
          onChanged: function(v) { root.setControl(row.ctl.name, Number(v)) }
          onHovered: function(index, on) { if (on) root.hoverRow(row.ctl.name) }
        }
      }

      PanelSlider {
        id: slider
        visible: row.ctl.type === "int"
        width: parent.width
        bar: root.bar
        minimum: row.ctl.min
        maximum: row.ctl.max
        step: row.ctl.step
        integer: true
        value: row.current
        onMoved: function(v) { root.setControl(row.ctl.name, v) }
        onReleased: function(v) {
          row.current = Math.round(v)
          row.ctl.value = row.current
          root.setControl(row.ctl.name, row.current)
        }
        onRightClicked: {
          row.current = row.ctl["default"]
          row.ctl.value = row.current
          root.setControl(row.ctl.name, row.current)
        }
      }
    }
  }
}
