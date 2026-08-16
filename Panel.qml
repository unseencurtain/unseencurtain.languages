import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "unseencurtain.languages"
  ipcTarget: "unseencurtain.languages"
  manageIpc: false

  property string activeIm: "keyboard-us"
  property bool busy: false
  property string lastError: ""
  property int cursorIndex: -1
  property bool cursorActive: false
  property bool cursorFromPointer: false
  property int pendingSwitch: -1
  property bool katakana: false
  property string lastActiveIm: "keyboard-us"
  property string lastIm: "mozc"

  readonly property var languages: [
    { im: "keyboard-us", short: "EN", name: "English", detail: "US keyboard" },
    { im: "mozc", short: "あ", name: "Japanese", detail: "Mozc" },
    { im: "pinyin", short: "中", name: "Chinese", detail: "Pinyin" },
    { im: "hangul", short: "한", name: "Korean", detail: "Hangul" }
  ]

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property color dim: Qt.darker(foreground, 1.55)

  readonly property int activeIndex: {
    for (var i = 0; i < languages.length; i++) {
      if (languages[i].im === activeIm) return i
    }
    return 0
  }

  readonly property string barLabel: {
    if (activeIm === "mozc") return root.katakana ? "ア" : "あ"
    return languages[activeIndex].short
  }

  readonly property string mozcShort: root.katakana ? "ア" : "あ"
  readonly property string mozcDetail: root.katakana ? "Katakana" : "Hiragana"

  // One panel instance loads per monitor bar, but IPC (Alt+U) only reaches a
  // single instance. The katakana mode is therefore persisted to a small state
  // file that every instance polls, so all bars agree. The toggle atomically
  // flips the file and synthesizes the matching key, so the file is the single
  // source of truth for both the labels and mozc's real mode.
  readonly property string kanaStateFile: "$HOME/.local/state/unseencurtain.languages/katakana"
  readonly property string kanaReadCmd: "cat \"" + root.kanaStateFile + "\" 2>/dev/null || printf '0'"
  readonly property string kanaToggleCmd:
    "f=\"$HOME/.local/state/unseencurtain.languages/katakana\"; " +
    "mkdir -p \"$HOME/.local/state/unseencurtain.languages\"; " +
    "if [ \"$(cat \"$f\" 2>/dev/null)\" = \"1\" ]; then " +
    "  printf '0' > \"$f\"; wtype -k Hiragana; " +
    "else " +
    "  printf '1' > \"$f\"; wtype -k Katakana; " +
    "fi"

  // Alt+I hotkey toggles back to the previously used input method (English
  // included), so from EN it jumps to the last CJK IM and from a CJK IM it
  // returns to EN. The "previous" IM is tracked from transitions and persisted
  // so a shell restart keeps it.
  readonly property string lastImStateFile: "$HOME/.local/state/unseencurtain.languages/lastim"
  readonly property string lastImReadCmd:
    "cat \"" + root.lastImStateFile + "\" 2>/dev/null || printf 'mozc'"

  function refresh() {
    if (root.opened) return
    if (!queryProc.running) queryProc.running = true
  }

  function moveCursor(dy) {
    cursorActive = true
    cursorFromPointer = false
    if (cursorIndex < 0) cursorIndex = activeIndex
    else cursorIndex = Math.max(0, Math.min(languages.length - 1, cursorIndex + dy))
  }

  function switchTo(index) {
    if (index < 0 || index >= languages.length || actionProc.running) return
    busy = true
    lastError = ""
    root.activeIm = languages[index].im
    pendingSwitch = index
    root.close()
  }

  function switchPanel(direction) {
    if (bar && typeof bar.switchPanelFrom === "function") return bar.switchPanelFrom(root, direction)
    return false
  }

  // Alt+U hotkey (Hyprland) toggles Japanese hiragana/katakana mode. The state
  // file is flipped atomically with the Hiragana/Katakana key that mozc's
  // default keymap maps to a direct composition-mode switch, so the real mode
  // changes even though fcitx5-remote has no API for it. The label is flipped
  // optimistically for instant feedback; every bar reconciles from the file.
  function toggleKana() {
    if (root.opened || activeIm !== "mozc") return
    root.katakana = !root.katakana
    kanaProc.command = ["sh", "-c", root.kanaToggleCmd]
    kanaProc.running = true
  }

  // Alt+I hotkey (Hyprland) switches back to the previously used IM (English
  // included). The optimistic activeIm update makes the tracking flip lastIm to
  // the IM we just left, so toggling again swaps back. The dropdown's switchTo
  // and this toggle both flow through the same actionProc + focusTimer path.
  function toggleLast() {
    if (root.opened || actionProc.running || root.busy) return
    var target = root.lastIm
    if (target === root.activeIm) return
    busy = true
    lastError = ""
    root.activeIm = target
    actionProc.command = target === "keyboard-us"
      ? ["sh", "-c", "fcitx5-remote -s keyboard-us && fcitx5-remote -c"]
      : ["sh", "-c", "fcitx5-remote -s " + target + " && fcitx5-remote -o"]
    actionProc.running = true
  }

  function persistLastIm() {
    var cmd = "f=\"$HOME/.local/state/unseencurtain.languages/lastim\"; " +
              "mkdir -p \"$HOME/.local/state/unseencurtain.languages\"; " +
              "printf '%s' \"" + root.lastIm + "\" > \"$f\""
    lastImWriteProc.command = ["sh", "-c", cmd]
    lastImWriteProc.running = true
  }

  function syncKatakana() {
    if (stateReadProc.running) return
    stateReadProc.command = ["sh", "-c", root.kanaReadCmd]
    stateReadProc.running = true
  }

  onActiveImChanged: {
    var prev = root.lastActiveIm
    root.lastActiveIm = root.activeIm
    if (prev !== "" && prev !== root.activeIm && prev !== root.lastIm) {
      root.lastIm = prev
      root.persistLastIm()
    }
  }

  Component.onCompleted: {
    refresh()
    syncKatakana()
    lastImReadProc.command = ["sh", "-c", root.lastImReadCmd]
    lastImReadProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      lastError = ""
      cursorActive = false
      cursorIndex = -1
      cursorFromPointer = false
      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
    } else if (pendingSwitch >= 0) {
      var im = languages[pendingSwitch].im
      pendingSwitch = -1
      actionProc.command = im === "keyboard-us"
        ? ["sh", "-c", "fcitx5-remote -s keyboard-us && fcitx5-remote -c"]
        : ["sh", "-c", "fcitx5-remote -s " + im + " && fcitx5-remote -o"]
      focusTimer.restart()
    }
  }

  Process {
    id: queryProc
    command: ["fcitx5-remote", "-n"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var current = String(text || "").trim()
        if (current !== "") root.activeIm = current
      }
    }
  }

  Process {
    id: actionProc
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var err = String(text || "").trim()
        if (err !== "") root.lastError = err
      }
    }
    onExited: function(exitCode) {
      root.busy = false
      if (exitCode !== 0 && root.lastError === "") {
        root.lastError = "fcitx5-remote failed"
      }
      refreshTimer.restart()
    }
  }

  Process {
    id: kanaProc
  }

  Process {
    id: stateReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = String(text || "").trim()
        var target = v === "1"
        if (target !== root.katakana) {
          root.katakana = target
        }
      }
    }
  }

  Process {
    id: lastImReadProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var v = String(text || "").trim()
        if (v !== "") root.lastIm = v
      }
    }
  }

  Process {
    id: lastImWriteProc
  }

  IpcHandler {
    target: "unseencurtain.languages"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleKana(): void { root.toggleKana() }
    function toggleLast(): void { root.toggleLast() }
  }

  Timer {
    id: focusTimer
    interval: 200
    onTriggered: actionProc.running = true
  }

  Timer {
    id: refreshTimer
    interval: 300
    onTriggered: root.refresh()
  }

  Timer {
    interval: 2000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  Timer {
    interval: 500
    running: true
    repeat: true
    onTriggered: root.syncKatakana()
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.barLabel
    fontSize: Style.font.body
    horizontalMargin: 7
    tooltipText: "Input method: " + root.languages[root.activeIndex].name
    onPressed: root.toggle()

    labelVisible: false

    Text {
      anchors.centerIn: parent
      anchors.verticalCenterOffset: 1
      text: root.barLabel
      color: button.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
      font.bold: true
      renderType: Text.NativeRendering
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(300))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveCursor(dy) }
      onActivateRequested: {
        if (root.cursorActive && root.cursorIndex >= 0) root.switchTo(root.cursorIndex)
        else root.switchTo(root.activeIndex)
      }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(8)

        PanelSectionHeader {
          text: "INPUT METHOD"
          foreground: root.foreground
          fontFamily: root.fontFamily
        }

        Column {
          width: column.width
          spacing: Style.space(2)

          Repeater {
            model: root.languages

            delegate: CursorSurface {
              id: row
              required property int index
              required property var modelData
              readonly property bool isActive: modelData.im === root.activeIm

              width: parent.width
              height: Style.space(38)
              foreground: root.foreground
              hasCursor: root.cursorActive && root.cursorIndex === row.index
              current: isActive

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.switchTo(row.index)
                onContainsMouseChanged: {
                  if (containsMouse) {
                    root.cursorActive = true
                    root.cursorIndex = row.index
                    root.cursorFromPointer = true
                  } else if (root.cursorFromPointer && root.cursorIndex === row.index) {
                    root.cursorActive = false
                    root.cursorIndex = -1
                    root.cursorFromPointer = false
                  }
                }
              }

              Text {
                id: shortLabel
                anchors.left: parent.left
                anchors.leftMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                width: Style.space(32)
                text: row.modelData.im === "mozc" ? root.mozcShort : row.modelData.short
                color: row.isActive ? Color.accent : root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                horizontalAlignment: Text.AlignHCenter
              }

              Column {
                anchors.left: shortLabel.right
                anchors.leftMargin: Style.space(10)
                anchors.right: check.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                spacing: 0

                Text {
                  width: parent.width
                  text: row.modelData.name
                  color: row.isActive ? root.foreground : root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  width: parent.width
                  text: row.modelData.im === "mozc" ? root.mozcDetail : row.modelData.detail
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  elide: Text.ElideRight
                }
              }

              Text {
                id: check
                anchors.right: parent.right
                anchors.rightMargin: Style.space(10)
                anchors.verticalCenter: parent.verticalCenter
                visible: row.isActive
                text: "✓"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }
          }
        }

        Text {
          width: column.width
          visible: root.lastError !== ""
          text: root.lastError
          color: root.bar ? root.bar.urgent : Color.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          wrapMode: Text.WordWrap
        }
      }
    }
  }
}
