import QtQuick
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar indicator plus the configuration popup.
//
// The engine itself lives in Service.qml, which the shell mounts once whenever
// this plugin is enabled. The bar widget only renders its state and routes
// edits back to it, so every monitor shows the same truth.
//
// The icon is bright while Alt and Win are actually swapped and dim when the
// focused app is on the plugin's exception list (or the plugin is off), so the
// bar answers "what will this key do right now?" at a glance.
BarWidget {
  id: root
  moduleName: "omarchy-swap-alt-win"

  // The shell's per-plugin API, through which the service instance is found.
  // Polled slowly because there is no signal for "service appeared"; once it
  // is there the assignment is a no-op, and if a reload replaces it the next
  // tick picks the new object up.
  property var engine: null
  property int missingTicks: 0

  function locateEngine() {
    var api = root.bar ? root.bar.shell : null
    var found = api && typeof api.serviceFor === "function" ? api.serviceFor("omarchy-swap-alt-win") : null
    if (!found) {
      root.missingTicks++
      if (root.engine !== null) root.engine = null
      return
    }
    root.missingTicks = 0
    if (found !== root.engine) root.engine = found
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.locateEngine()
  }

  Component.onCompleted: root.locateEngine()

  // Null-safe view of the engine, so the widget renders before the service
  // is up and keeps rendering if it is ever torn down.
  readonly property bool ready: engine !== null && engine.ready === true
  readonly property bool pluginEnabled: engine ? engine.pluginEnabled === true : false
  readonly property bool swapped: engine ? engine.swapped === true : false
  readonly property string keyState: engine ? String(engine.keyState) : "normal"
  readonly property string activeLabel: engine ? String(engine.activeLabel) : ""
  readonly property var apps: engine && engine.apps ? engine.apps : []
  readonly property string mode: engine ? String(engine.mode) : "revert"
  readonly property bool matchTitles: engine ? engine.matchTitles === true : false
  readonly property string swapOption: engine && engine.config ? String(engine.config.swapOption) : "altwin:swap_alt_win"
  readonly property string plainOptions: engine ? String(engine.plainOptions) : ""
  readonly property string lastError: engine ? String(engine.lastError) : ""

  function setEnabled(value) { if (engine) engine.setEnabled(value) }
  function setMode(value) { if (engine) engine.setMode(value) }
  function setMatchTitles(value) { if (engine) engine.setMatchTitles(value) }
  function hasApp(pattern) { return engine ? engine.hasApp(pattern) : false }
  function toggleApp(pattern) { if (engine) engine.toggleApp(pattern) }
  function removeApp(pattern) { if (engine) engine.removeApp(pattern) }

  property bool popupOpen: false
  readonly property bool opened: popupOpen

  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }

  readonly property color panelText: Commons.Color.popups.text
  readonly property color panelDim: Util.alpha(panelText, 0.6)
  readonly property color panelRule: Util.alpha(panelText, 0.12)

  function tooltipText() {
    if (engine === null) return root.missingTicks > 5
      ? "Alt / Win swap: service not running — try: omarchy restart shell"
      : "Alt / Win swap: service is starting…"
    if (!ready) return "Alt / Win swap: starting…"
    if (lastError !== "") return "Alt / Win swap: " + lastError
    if (!pluginEnabled) return "Alt / Win swap off (right-click to turn on)"
    if (keyState === "swapped") return "Alt and Win swapped — Alt acts as Super"
    if (activeLabel !== "") return "Alt and Win normal for " + activeLabel
    return "Alt and Win normal"
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uf11c"
    slotSize: Style.bar.statusSlot
    dimmed: !root.swapped
    tooltipText: root.tooltipText()

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.setEnabled(!root.pluginEnabled)
      else if (mouseButton === Qt.MiddleButton && engine) engine.refresh()
      else root.toggle()
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)

    FocusScope {
      anchors.fill: parent
      focus: true

      Keys.onEscapePressed: root.close()

      Column {
        id: content
        width: parent.width
        spacing: Style.space(12)

        // ------------------------------------------------------- header

        Item {
          width: parent.width
          height: Math.max(titleColumn.implicitHeight, enableSwitch.implicitHeight)

          Column {
            id: titleColumn
            anchors.left: parent.left
            anchors.right: enableSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: "Alt / Win swap"
              textFormat: Text.PlainText
              color: root.panelText
              font.family: Style.font.family
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              width: parent.width
              text: root.swapOption
              textFormat: Text.PlainText
              color: root.panelDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
            }
          }

          ToggleSwitch {
            id: enableSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.pluginEnabled
            foreground: root.panelText
            accent: Commons.Color.accent
            onToggled: root.setEnabled(!root.pluginEnabled)
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: root.panelRule
        }

        // ------------------------------------------------ current state

        Column {
          width: parent.width
          spacing: Style.space(5)

          Item {
            width: parent.width
            height: Math.max(stateCaption.implicitHeight, stateValue.implicitHeight)

            Text {
              id: stateCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "KEYS"
              textFormat: Text.PlainText
              color: root.panelDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              id: stateValue
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: !root.pluginEnabled
                ? "Untouched"
                : (root.keyState === "swapped" ? "Alt / Win swapped" : "Normal")
              textFormat: Text.PlainText
              color: root.swapped ? Commons.Color.accent : root.panelText
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          Item {
            width: parent.width
            height: Math.max(focusCaption.implicitHeight, focusValue.implicitHeight)

            Text {
              id: focusCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: "FOCUSED APP"
              textFormat: Text.PlainText
              color: root.panelDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              id: focusValue
              anchors.right: parent.right
              anchors.left: focusCaption.right
              anchors.leftMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              text: root.activeLabel !== "" ? root.activeLabel : "none"
              textFormat: Text.PlainText
              elide: Text.ElideRight
              horizontalAlignment: Text.AlignRight
              color: root.activeLabel !== "" ? root.panelText : root.panelDim
              font.family: Style.font.family
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            width: parent.width
            visible: root.lastError !== ""
            text: root.lastError
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: Commons.Color.urgent
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }
        }

        Button {
          width: parent.width
          enabled: engine !== null && root.activeLabel !== "" && root.ready
          opacity: enabled ? 1 : 0.45
          text: {
            if (root.activeLabel === "") return "No focused window"
            var listed = root.hasApp(root.activeLabel)
            if (root.mode === "only") return listed ? "Stop swapping in this app" : "Swap in this app"
            return listed ? "Stop reverting in this app" : "Revert in this app"
          }
          bordered: true
          foreground: root.panelText
          onClicked: {
            if (root.activeLabel !== "") root.toggleApp(root.activeLabel)
          }
        }

        // -------------------------------------------------- app list

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            height: Math.max(appsCaption.implicitHeight, appsHint.implicitHeight)

            Text {
              id: appsCaption
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              text: root.mode === "only" ? "SWAP ONLY IN" : "REVERT IN"
              textFormat: Text.PlainText
              color: root.panelDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
              font.letterSpacing: 1
            }

            Text {
              id: appsHint
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              text: root.apps.length + (root.apps.length === 1 ? " app" : " apps")
              textFormat: Text.PlainText
              color: root.panelDim
              font.family: Style.font.family
              font.pixelSize: Style.font.caption
            }
          }

          Text {
            width: parent.width
            visible: root.apps.length === 0
            text: "No exceptions yet — add an app with the button above, or edit ~/.config/omarchy/swap-alt-win.json."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.panelDim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          Repeater {
            model: root.apps

            delegate: Item {
              required property string modelData

              width: content.width
              height: Math.max(patternText.implicitHeight, removeButton.implicitHeight) + Style.space(2)

              Text {
                id: patternText
                anchors.left: parent.left
                anchors.right: removeButton.left
                anchors.rightMargin: Style.space(8)
                anchors.verticalCenter: parent.verticalCenter
                text: modelData
                textFormat: Text.PlainText
                elide: Text.ElideRight
                color: root.panelText
                font.family: Style.font.family
                font.pixelSize: Style.font.body
              }

              Button {
                id: removeButton
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                text: "Remove"
                fontSize: Style.font.caption
                foreground: root.panelDim
                onClicked: root.removeApp(modelData)
              }
            }
          }
        }

        Rectangle {
          width: parent.width
          height: 1
          color: root.panelRule
        }

        // ------------------------------------------------------ switches

        Item {
          width: parent.width
          height: Math.max(modeText.implicitHeight, modeSwitch.implicitHeight)

          Text {
            id: modeText
            anchors.left: parent.left
            anchors.right: modeSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "Swap only inside these apps"
            textFormat: Text.PlainText
            color: root.panelText
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          ToggleSwitch {
            id: modeSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.mode === "only"
            foreground: root.panelText
            accent: Commons.Color.accent
            onToggled: root.setMode(root.mode === "only" ? "revert" : "only")
          }
        }

        Item {
          width: parent.width
          height: Math.max(titlesText.implicitHeight, titlesSwitch.implicitHeight)

          Text {
            id: titlesText
            anchors.left: parent.left
            anchors.right: titlesSwitch.left
            anchors.rightMargin: Style.space(12)
            anchors.verticalCenter: parent.verticalCenter
            text: "Match window titles too"
            textFormat: Text.PlainText
            color: root.panelText
            font.family: Style.font.family
            font.pixelSize: Style.font.bodySmall
          }

          ToggleSwitch {
            id: titlesSwitch
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            checked: root.matchTitles
            foreground: root.panelText
            accent: Commons.Color.accent
            onToggled: root.setMatchTitles(!root.matchTitles)
          }
        }

        Text {
          width: parent.width
          text: "Base options: " + (root.plainOptions !== "" ? root.plainOptions : "(none)")
          textFormat: Text.PlainText
          elide: Text.ElideRight
          color: root.panelDim
          font.family: Style.font.family
          font.pixelSize: Style.font.caption
        }
      }
    }
  }
}
