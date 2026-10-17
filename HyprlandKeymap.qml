import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// Reads and writes Hyprland's global keyboard options (`input:kb_options`).
//
// Hyprland 0.5x+ parses its config with Lua: the legacy `hyprctl keyword`
// path prints "keyword can't work with non-legacy parsers" and silently does
// nothing, while `hyprctl eval` runs a Lua snippet that updates the value and
// schedules the input-device refresh which rebuilds the XKB keymap. Older
// installs are the other way round, so a write is attempted through eval and
// then through keyword, and either way the result is confirmed by reading the
// option back.
Item {
  id: root

  // Last value observed from Hyprland's config (whatever it was before this
  // plugin touched anything).
  property bool ready: false
  property string configured: ""
  property string lastError: ""

  property bool busy: false
  property string inFlightOptions: ""
  property bool fallbackTried: false
  property bool pendingPresent: false
  property string pendingOptions: ""

  signal readFinished(string options)
  signal writeFinished(string options, string error)

  // -------------------------------------------------------------- reading

  function read() {
    if (readProc.running) return
    readProc.running = true
  }

  Process {
    id: readProc
    command: ["hyprctl", "-j", "getoption", "input:kb_options"]

    stdout: StdioCollector {
      id: readOut
      waitForEnd: true
      onStreamFinished: {
        var value = root.parseOptions(readOut.text)
        if (value === null) return
        root.configured = value
        root.ready = true
        root.lastError = ""
        root.readFinished(value)
      }
    }

    onExited: function(exitCode) {
      if (root.ready) return
      root.lastError = "hyprctl could not read input:kb_options (is Hyprland running?)"
      retryTimer.restart()
    }
  }

  function parseOptions(text) {
    try {
      var parsed = JSON.parse(String(text || ""))
      if (!parsed || parsed.option !== "input:kb_options") return null
      return typeof parsed.str === "string" ? parsed.str : ""
    } catch (error) {
      return null
    }
  }

  // -------------------------------------------------------------- writing

  function write(options) {
    var next = options === undefined || options === null ? "" : String(options)
    if (root.busy) {
      root.pendingPresent = true
      root.pendingOptions = next
      return
    }
    root.startWrite(next)
  }

  function startWrite(options) {
    root.busy = true
    root.inFlightOptions = options
    root.fallbackTried = false
    writeProc.command = ["hyprctl", "eval", Model.luaSetOptions(options)]
    writeProc.running = true
  }

  Process {
    id: writeProc
    // The exit code alone is not enough: legacy `hyprctl keyword` exits 0
    // even when it refuses to run under the Lua parser. Confirm the value by
    // reading it back instead, and fall back to the keyword form only after
    // the eval form demonstrably failed.
    onExited: function(exitCode) { verifyTimer.restart() }
  }

  Timer {
    id: verifyTimer
    interval: 80
    repeat: false
    onTriggered: root.startVerify()
  }

  function startVerify() {
    if (verifyProc.running) {
      verifyTimer.restart()
      return
    }
    verifyProc.running = true
  }

  Process {
    id: verifyProc
    command: ["hyprctl", "-j", "getoption", "input:kb_options"]

    stdout: StdioCollector {
      id: verifyOut
      waitForEnd: true
      onStreamFinished: root.finishVerify(root.parseOptions(verifyOut.text))
    }
  }

  function finishVerify(value) {
    if (value !== null && Model.optionsEqual(value, root.inFlightOptions)) {
      finishWrite(true, "")
      return
    }

    if (!root.fallbackTried) {
      root.fallbackTried = true
      writeProc.command = ["hyprctl", "keyword", "input:kb_options", root.inFlightOptions]
      writeProc.running = true
      return
    }

    finishWrite(false, "Hyprland did not apply the keyboard options")
  }

  function finishWrite(ok, message) {
    root.busy = false
    var done = root.inFlightOptions
    root.inFlightOptions = ""
    root.lastError = ok ? "" : message
    root.writeFinished(done, ok ? "" : message)

    if (root.pendingPresent) {
      var next = root.pendingOptions
      root.pendingPresent = false
      root.pendingOptions = ""
      root.startWrite(next)
    }
  }

  Timer {
    id: retryTimer
    interval: 5000
    repeat: false
    onTriggered: if (!root.ready) root.read()
  }
}
