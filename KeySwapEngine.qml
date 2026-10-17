import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Io
import "Model.js" as Model

// The whole plugin in one object: config document, focused-window tracking,
// and the Hyprland key-option writes that make the swap real.
//
// Mounted once by Service.qml (the shell runs a plugin's service whenever the
// plugin is enabled). BarWidget.qml is only a view over the instance it finds
// through the shell's plugin API.
Item {
  id: root

  // The shell mounts Service.qml exactly once whenever the plugin is enabled,
  // so that instance owns the IPC target. Kept as a property because the
  // engine is also usable on its own from a scratch QML file, where there is
  // no service to hand IPC to.
  property bool ipcEnabled: true

  property var shell: null

  readonly property alias config: store.config
  readonly property bool storeReady: store.ready
  readonly property bool keymapReady: keymap.ready
  readonly property bool ready: storeReady && keymapReady

  readonly property bool pluginEnabled: config.enabled === true
  readonly property string mode: config.mode === "only" ? "only" : "revert"
  readonly property bool matchTitles: config.matchTitles === true
  readonly property var apps: config.apps ? config.apps : []

  // Raw option string Hyprland had before this plugin wrote anything.
  property string configuredOptions: ""
  // configuredOptions with every managed swap option taken out.
  property string plainOptions: ""
  // What "plugin off" restores: the user's own configuration.
  property string restoreOptions: ""

  property string activeClass: ""
  property string activeTitle: ""

  // One row per app class that currently has a mapped window, sorted by focus
  // recency. The panel uses this to offer the running apps directly instead
  // of only the focused one. Refreshed on focus/open/close events and whenever
  // the panel asks for it.
  property var openApps: []

  // Set by the bar panel. While it is closed the window list is not needed, so
  // focus/open/close events skip the extra `hyprctl clients` call.
  property bool panelOpen: false

  // "swapped" | "normal" | "restore" — what the config and the focused window
  // say the keys should be. Derived, so it is already correct while the
  // Hyprland side is still starting up.
  readonly property string keyState: Model.desiredSwap(root.config, root.activeClass, root.activeTitle)
  property string appliedOptions: ""
  property bool applied: false

  readonly property string activeLabel: activeClass !== "" ? activeClass : activeTitle
  readonly property string lastError: keymap.lastError !== "" ? keymap.lastError : store.lastError
  readonly property bool swapped: keyState === "swapped"

  // ------------------------------------------------------------ applying

  function recomputeBase() {
    plainOptions = Model.stripSwapTokens(configuredOptions, config.swapOption)
    restoreOptions = Model.restoreOptions(configuredOptions, plainOptions, config.swapOption)
  }

  function optionsForState(state) {
    if (state === "swapped") return Model.addOption(plainOptions, config.swapOption)
    if (state === "restore") return restoreOptions
    return plainOptions
  }

  function applyNow(force) {
    if (!store.ready || !keymap.ready) return

    root.recomputeBase()

    var wanted = root.optionsForState(root.keyState)
    if (!force && root.applied && Model.optionsEqual(wanted, root.appliedOptions)) return
    keymap.write(wanted)
  }

  property bool forcePending: false

  function scheduleApply(force) {
    if (force) root.forcePending = true
    applyTimer.restart()
  }

  Timer {
    id: applyTimer
    interval: 120
    repeat: false
    onTriggered: {
      var force = root.forcePending
      root.forcePending = false
      root.applyNow(force)
    }
  }

  property int writeFailures: 0

  Timer {
    id: writeRetryTimer
    interval: 5000
    repeat: false
    onTriggered: root.applyNow(true)
  }

  // A shell restart can leave a detached restore from the previous instance
  // racing the new instance's first write. Re-assert once things have settled
  // so the end state is always the configured one.
  Timer {
    id: settleTimer
    interval: 2000
    repeat: false
    onTriggered: root.applyNow(true)
  }

  onReadyChanged: if (ready) settleTimer.restart()

  // ------------------------------------------------------------ the window

  function adoptActiveWindow(windowClass, windowTitle) {
    var cls = String(windowClass === undefined || windowClass === null ? "" : windowClass)
    var title = String(windowTitle === undefined || windowTitle === null ? "" : windowTitle)
    if (cls === root.activeClass && title === root.activeTitle) return
    root.activeClass = cls
    root.activeTitle = title
    root.scheduleApply(false)
  }

  function readActiveWindow() {
    if (activeWindowProc.running) return
    activeWindowProc.running = true
  }

  function refreshOpenApps() {
    if (clientsProc.running) return
    clientsProc.running = true
  }

  Process {
    id: clientsProc
    command: ["hyprctl", "-j", "clients"]

    stdout: StdioCollector {
      id: clientsOut
      waitForEnd: true
      onStreamFinished: root.openApps = Model.parseClients(clientsOut.text)
    }
  }

  Process {
    id: activeWindowProc
    command: ["hyprctl", "-j", "activewindow"]

    stdout: StdioCollector {
      id: activeWindowOut
      waitForEnd: true
      onStreamFinished: {
        var cls = ""
        var title = ""
        try {
          var window = JSON.parse(String(activeWindowOut.text || ""))
          cls = String(window["class"] || "")
          title = String(window.title || "")
        } catch (error) {
          cls = ""
          title = ""
        }
        root.adoptActiveWindow(cls, title)
      }
    }
  }

  // `activewindow` events carry "class,title" (title may contain commas).
  // `configreloaded` is the moment Hyprland has reset kb_options from the
  // config file, so it is the moment to relearn the user's baseline.
  Connections {
    target: Hyprland

    function onRawEvent(event) {
      if (event.name === "activewindow") {
        var data = String(event.data || "")
        var comma = data.indexOf(",")
        var cls = comma === -1 ? data : data.slice(0, comma)
        var title = comma === -1 ? "" : data.slice(comma + 1)
        root.adoptActiveWindow(cls, title)
        if (root.panelOpen) root.refreshOpenApps()
      } else if (event.name === "openwindow" || event.name === "closewindow") {
        if (root.panelOpen) root.refreshOpenApps()
      } else if (event.name === "configreloaded") {
        keymap.read()
        root.readActiveWindow()
      }
    }
  }

  Timer {
    interval: 350
    running: true
    repeat: false
    onTriggered: root.readActiveWindow()
  }

  // ------------------------------------------------------------- plumbing

  Connections {
    target: store

    function onRevisionChanged() { root.scheduleApply(true) }
    function onLoaded() { root.scheduleApply(true) }
  }

  Connections {
    target: keymap

    function onReadFinished(options) {
      root.configuredOptions = options
      root.scheduleApply(true)
    }

    function onWriteFinished(options, error) {
      if (error !== "") {
        root.writeFailures++
        if (root.writeFailures < 3) writeRetryTimer.restart()
        return
      }
      root.writeFailures = 0
      root.appliedOptions = options
      root.applied = true
    }
  }

  ConfigStore {
    id: store
  }

  HyprlandKeymap {
    id: keymap
  }

  Component.onCompleted: {
    keymap.read()
    root.readActiveWindow()
    root.refreshOpenApps()
  }

  // Turning the plugin off (or removing it) destroys this object without
  // going through a config write. Put the user's own options back in that
  // case. Only the IPC-owning instance does this, so a second bar widget on
  // another monitor is never mistaken for an uninstall.
  Component.onDestruction: {
    if (!root.ipcEnabled || !root.applied) return
    if (Model.optionsEqual(root.appliedOptions, root.restoreOptions)) return
    Quickshell.execDetached(["hyprctl", "eval", Model.luaSetOptions(root.restoreOptions)])
  }

  // ------------------------------------------------------------- commands

  function refresh() {
    keymap.read()
    root.readActiveWindow()
    root.refreshOpenApps()
  }

  function setEnabled(value) {
    store.mutate(function(draft) { draft.enabled = value === true })
  }

  function setMode(value) {
    store.mutate(function(draft) { draft.mode = value === "only" ? "only" : "revert" })
  }

  function setMatchTitles(value) {
    store.mutate(function(draft) { draft.matchTitles = value === true })
  }

  function hasApp(pattern) {
    var needle = String(pattern === undefined || pattern === null ? "" : pattern).trim().toLowerCase()
    if (needle === "") return false
    for (var i = 0; i < root.apps.length; i++) {
      if (String(root.apps[i]).toLowerCase() === needle) return true
    }
    return false
  }

  function addApp(pattern) {
    var value = String(pattern === undefined || pattern === null ? "" : pattern).trim()
    if (value === "" || root.hasApp(value)) return false
    store.mutate(function(draft) {
      if (!(draft.apps instanceof Array)) draft.apps = []
      draft.apps.push(value)
    })
    return true
  }

  function removeApp(pattern) {
    var needle = String(pattern === undefined || pattern === null ? "" : pattern).trim().toLowerCase()
    if (needle === "") return false
    store.mutate(function(draft) {
      if (!(draft.apps instanceof Array)) return
      draft.apps = draft.apps.filter(function(entry) {
        return String(entry).trim().toLowerCase() !== needle
      })
    })
    return true
  }

  function toggleApp(pattern) {
    return root.hasApp(pattern) ? root.removeApp(pattern) : root.addApp(pattern)
  }

  function addActive() {
    return root.activeLabel !== "" ? root.addApp(root.activeLabel) : false
  }

  function removeActive() {
    return root.activeLabel !== "" ? root.removeApp(root.activeLabel) : false
  }

  function statusJson() {
    return JSON.stringify({
      enabled: root.pluginEnabled,
      mode: root.mode,
      state: root.keyState,
      class: root.activeClass,
      title: root.activeTitle,
      swapOption: root.config.swapOption,
      plainOptions: root.plainOptions,
      apps: root.apps,
      error: root.lastError
    })
  }

  IpcHandler {
    target: "swap-alt-win"
    enabled: root.ipcEnabled

    function toggle(): void { root.setEnabled(!root.pluginEnabled) }
    function enable(): void { root.setEnabled(true) }
    function disable(): void { root.setEnabled(false) }
    function isEnabled(): bool { return root.pluginEnabled }
    function isSwapped(): bool { return root.swapped }
    function keyState(): string { return root.keyState }
    function status(): string { return root.statusJson() }
    function refresh(): void { root.refresh() }
    function addActive(): bool { return root.addActive() }
    function removeActive(): bool { return root.removeActive() }
    function setMode(mode: string): void { root.setMode(mode) }
  }
}
