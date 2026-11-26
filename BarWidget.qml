import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import qs.Commons as Commons

// Omarchy Assistant in the bar. Follows `omarchy-assistant watch` (one JSON object
// per line from the service), reconnects when the service restarts, and offers
// setup when the assistant hasn't been set up yet.
BarWidget {
  id: root
  moduleName: "io.github.sdosmany.assistant"

  readonly property string pluginDir: Qt.resolvedUrl(".").toString().replace(/^file:\/\//, "").replace(/\/$/, "")
  readonly property string cli: pluginDir + "/bin/omarchy-assistant"
  readonly property string configFile: Quickshell.env("HOME") + "/.config/omarchy-assistant/config.json"
  property string assistantState: "offline"
  property string assistantName: "Assistant"
  property bool configured: true
  readonly property bool busy: assistantState === "listening" || assistantState === "transcribing"
                               || assistantState === "thinking" || assistantState === "speaking"
  readonly property string shownState: configured ? assistantState : "setup"

  // Material Design glyphs from the Nerd Font the bar already uses.
  readonly property var glyphs: ({
    "idle": 0xF05CB,          // account-voice
    "listening": 0xF036C,     // microphone
    "transcribing": 0xF036C,
    "thinking": 0xF07C3,      // dots-horizontal-circle
    "speaking": 0xF057E,      // volume-high
    "muted": 0xF036D,         // microphone-off
    "offline": 0xF036D,
    "setup": 0xF0493          // cog
  })

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  Commons.Translations { id: strings; directory: Qt.resolvedUrl("i18n") }

  function send(cmd) { Quickshell.execDetached([root.cli, cmd]) }
  function openTerminal(args) {
    root.bar.run("omarchy-launch-floating-terminal-with-presentation " + root.cli + " " + args)
  }

  FileView {
    path: root.configFile
    watchChanges: true
    printErrors: false
    onLoaded: {
      root.configured = true
      try {
        var name = String(JSON.parse(text()).name || "")
        if (/^[A-Za-z][A-Za-z '\-]{0,30}$/.test(name)) root.assistantName = name
      } catch (e) {}
    }
    onLoadFailed: root.configured = false
    onFileChanged: reload()
  }

  Process {
    id: watcher
    command: [root.cli, "watch"]
    running: true
    stdout: SplitParser {
      onRead: function(line) {
        try {
          var s = JSON.parse(line)
          var known = ["idle", "listening", "transcribing", "thinking", "speaking", "muted"]
          root.assistantState = known.indexOf(s.state) >= 0 ? s.state : "idle"
        } catch (e) {}
      }
    }
    onExited: { root.assistantState = "offline"; reconnect.start() }
  }

  Timer {
    id: reconnect
    interval: 3000
    onTriggered: watcher.running = true
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: String.fromCodePoint(root.glyphs[root.shownState] || root.glyphs.idle)
    active: root.busy
    useActiveColor: true
    activeColor: root.assistantState === "speaking" ? Color.accent : Color.bar.active
    foreground: root.shownState === "muted" || root.shownState === "offline" ? Color.muted : Color.bar.text
    // The name is validated above, so it is plain letters.
    tooltipText: {
      var s = strings.t(root.shownState)
      return s.indexOf("%1") >= 0 ? s.arg(root.assistantName) : s
    }

    // Slow breathe while thinking (constant motion, so a sine, not an ease-in).
    SequentialAnimation on opacity {
      running: root.assistantState === "thinking" || root.assistantState === "transcribing"
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { to: 0.35; duration: Style.duration(600); easing.type: Easing.InOutSine }
      NumberAnimation { to: 1.0; duration: Style.duration(600); easing.type: Easing.InOutSine }
    }

    onPressed: function(b) {
      if (!root.configured) { root.openTerminal("setup"); return }
      if (b === Qt.MiddleButton) root.openTerminal("logs")
      else if (b === Qt.RightButton) root.send("toggle-mute")
      else if (root.assistantState === "offline") root.send("restart")
      else root.send("toggle")
    }
  }
}
