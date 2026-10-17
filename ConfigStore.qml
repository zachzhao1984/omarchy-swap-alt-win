import QtQuick
import Quickshell
import Quickshell.Io
import "Model.js" as Model

// The plugin's config document on disk: plain JSON at
// ~/.config/omarchy/swap-alt-win.json so it can be read, diffed, and hand-edited
// (the file watcher picks up edits without a shell restart).
//
// A hand-edit that gets something wrong is repaired rather than refused:
// Model.normalizeConfig fills defaults for anything missing or malformed.
Item {
  id: root

  readonly property string home: Quickshell.env("HOME")
  readonly property string configHome: Quickshell.env("XDG_CONFIG_HOME") || (root.home + "/.config")
  readonly property string path: root.configHome + "/omarchy/swap-alt-win.json"

  property var config: Model.defaultConfig()
  property bool ready: false
  property int revision: 0
  property string lastError: ""

  signal loaded(bool existed)

  function apply(document) {
    config = Model.normalizeConfig(document)
    revision++
  }

  function save(document) {
    if (!root.ready) return false
    root.apply(document)
    file.setText(JSON.stringify(root.config, null, 2) + "\n")
    return true
  }

  // Edit through a callback that mutates a private copy, so callers do not
  // hand-roll a deep clone for every toggle.
  function mutate(change) {
    if (!root.ready) return false
    var draft = JSON.parse(JSON.stringify(root.config))
    change(draft)
    return root.save(draft)
  }

  function adopt(text) {
    var document = null
    try {
      document = JSON.parse(String(text || ""))
    } catch (error) {
      document = null
    }

    var first = !root.ready
    root.ready = true

    if (!document || typeof document !== "object" || document instanceof Array) {
      root.lastError = "Keeping the last good config: " + root.path + " is not a JSON object"
      if (first) {
        root.apply(Model.defaultConfig())
        root.loaded(true)
      }
      return
    }

    root.lastError = ""
    root.apply(document)
    if (first) root.loaded(true)
  }

  function createDefaults() {
    if (root.ready) return
    root.ready = true
    root.apply(Model.defaultConfig())
    root.loaded(false)
    file.setText(JSON.stringify(root.config, null, 2) + "\n")
  }

  FileView {
    id: file
    path: root.path
    watchChanges: true
    atomicWrites: true
    printErrors: false

    onLoaded: root.adopt(text())
    onFileChanged: reload()

    onLoadFailed: function(error) {
      if (error === FileViewError.FileNotFound) {
        root.createDefaults()
        return
      }
      root.ready = true
      root.lastError = "Cannot read " + root.path
      root.loaded(true)
    }

    onSaved: root.lastError = ""
    onSaveFailed: root.lastError = "Cannot save " + root.path
  }

  Component.onCompleted: file.reload()
}
