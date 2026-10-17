import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Commons as Commons
import qs.Ui
import "Model.js" as Model

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
    if (found !== root.engine) {
      root.engine = found
      if (found) found.panelOpen = root.popupOpen
    }
  }

  Timer {
    interval: 1000
    running: true
    repeat: true
    onTriggered: root.locateEngine()
  }

  Component.onCompleted: {
    root.locateEngine()
    // Start the desktop-entry scan while the panel is still closed. Accessing
    // values is what kicks the lazy scan off.
    DesktopEntries.applications.values
    catalogDebounce.restart()
  }

  // Null-safe view of the engine, so the widget renders before the service
  // is up and keeps rendering if it is ever torn down.
  readonly property bool ready: engine !== null && engine.ready === true
  readonly property bool pluginEnabled: engine ? engine.pluginEnabled === true : false
  readonly property bool swapped: engine ? engine.swapped === true : false
  readonly property string keyState: engine ? String(engine.keyState) : "normal"
  readonly property string activeLabel: engine ? String(engine.activeLabel) : ""
  readonly property var apps: engine && engine.apps ? engine.apps : []
  // Running windows, most recently focused first.
  readonly property var openApps: engine && engine.openApps ? engine.openApps : []

  // "running" lists open windows; "all" lists every installed desktop entry.
  property string appListMode: "running"
  property string appSearch: ""

  // Snapshot of DesktopEntries.applications. The live model fills in
  // asynchronously (one valuesChanged per entry). Reading it directly from the
  // list binding rebuilt the ListView over and over: delegates were destroyed
  // mid-click and contentY was reset to 0 after every wheel event. Copying it
  // to a plain array and swapping that only once the model settles keeps the
  // list stable while the user interacts.
  property var catalogSnapshot: []

  readonly property var listRows: root.appListMode === "all" ? root.allAppRows : root.runningRows

  // Icons for the running list: map each running window class (and desktop
  // name/id) to the icon of the matching desktop entry. Built once per
  // catalog change so typing in the search field does not redo the lookup.
  readonly property var appIconIndex: {
    var values = root.catalogSnapshot
    var index = ({})
    for (var i = 0; i < values.length; i++) {
      var entry = values[i]
      if (!entry) continue
      var icon = root.desktopIcon(entry.icon)
      var keys = [Model.desktopPattern(entry.id, entry.startupClass), entry.id, entry.name]
      for (var k = 0; k < keys.length; k++) {
        var key = String(keys[k] || "").trim().toLowerCase()
        if (key.slice(-8) === ".desktop") key = key.slice(0, -8)
        if (key !== "" && index[key] === undefined) index[key] = icon
      }
    }
    return index
  }

  // Running rows in the same shape as the catalog rows, so both tabs share
  // one delegate (icon, name, description, checkbox). Built from openApps
  // only, so toggling an exception does not replace the model.
  readonly property var runningRows: {
    var rows = root.openApps
    var index = root.appIconIndex
    var fallback = root.desktopIcon("")
    var out = []
    for (var i = 0; i < rows.length; i++) {
      var row = rows[i]
      var icon = index[String(row.value).toLowerCase()]
      out.push({
        value: row.value,
        label: row.label,
        description: row.description,
        icon: icon !== undefined ? icon : fallback,
        running: true
      })
    }
    return out
  }

  readonly property var allAppRows: {
    var entries = root.filterCatalog(root.catalogSnapshot, root.appSearch)

    var rows = []
    for (var i = 0; i < entries.length; i++) {
      var entry = entries[i]
      if (!entry) continue
      var pattern = Model.desktopPattern(entry.id, entry.startupClass)
      if (pattern === "") continue

      var label = String(entry.name || entry.id || pattern)
      var generic = String(entry.genericName || "").trim()
      var iconName = String(entry.icon || "")

      rows.push({
        value: pattern,
        label: label,
        // Hide the redundant class line when it is just the app name again.
        description: pattern.toLowerCase() === label.toLowerCase() ? generic : pattern,
        icon: root.desktopIcon(iconName),
        running: false,
        kind: "desktop"
      })
    }

    // Selecting an app only changes its checkmark; the catalog itself is
    // independent of the configured list so the scroll position survives.
    return rows
  }
  readonly property string mode: engine ? String(engine.mode) : "revert"
  readonly property bool matchTitles: engine ? engine.matchTitles === true : false
  readonly property string swapOption: engine && engine.config ? String(engine.config.swapOption) : "altwin:swap_alt_win"
  readonly property string plainOptions: engine ? String(engine.plainOptions) : ""
  readonly property string lastError: engine ? String(engine.lastError) : ""

  function setEnabled(value) { if (engine) engine.setEnabled(value) }
  function setMode(value) { if (engine) engine.setMode(value) }
  function setMatchTitles(value) { if (engine) engine.setMatchTitles(value) }
  function toggleApp(pattern) { if (engine) engine.toggleApp(pattern) }
  function removeApp(pattern) { if (engine) engine.removeApp(pattern) }

  function desktopIcon(name) {
    var value = String(name || "").trim()
    if (value === "") return Quickshell.iconPath("application-x-executable", true)
    if (value.indexOf("file://") === 0 || value.indexOf("image://") === 0) return value
    if (value.charAt(0) === "/") return Util.fileUrl(value)
    return Quickshell.iconPath(value, true)
  }

  function filterCatalog(values, query) {
    var source = values || []
    var needle = String(query || "").toLowerCase().trim()
    var terms = needle === "" ? [] : needle.split(/\s+/)
    var out = []
    for (var i = 0; i < source.length; i++) {
      var entry = source[i]
      if (!entry) continue

      if (terms.length > 0) {
        var keywords = ""
        try { keywords = (entry.keywords || []).join(" ") } catch (error) { keywords = "" }
        var haystack = [entry.name, entry.genericName, entry.comment, entry.id, keywords].join(" ").toLowerCase()
        var matched = true
        for (var t = 0; t < terms.length; t++) {
          if (haystack.indexOf(terms[t]) === -1) { matched = false; break }
        }
        if (!matched) continue
      }
      out.push(entry)
    }

    out.sort(function(a, b) {
      var left = String(a.name || a.id || "").toLowerCase()
      var right = String(b.name || b.id || "").toLowerCase()
      if (left < right) return -1
      if (left > right) return 1
      return 0
    })
    return out
  }

  function refreshCatalog() {
    var values = DesktopEntries.applications.values || []
    var snapshot = []
    for (var i = 0; i < values.length; i++) {
      if (values[i]) snapshot.push(values[i])
    }
    root.catalogSnapshot = snapshot
  }

  function setAppListMode(value) {
    root.appListMode = value === "all" ? "all" : "running"
    Qt.callLater(function() {
      if (root.appListMode === "all") appSearchField.forceActiveFocus()
      else panelFocus.forceActiveFocus()
    })
  }

  property bool popupOpen: false
  readonly property bool opened: popupOpen

  function open() { popupOpen = true }
  function close() { popupOpen = false }
  function toggle() { popupOpen = !popupOpen }

  // The window list goes stale while the panel is closed, so ask for a fresh
  // one on every open. While it is open, the engine follows focus and
  // open/close events.
  onPopupOpenChanged: {
    if (!engine) return
    engine.panelOpen = root.popupOpen
    if (root.popupOpen) {
      engine.refreshOpenApps()
      // Normally the scan started at widget creation and the snapshot is
      // ready. If the panel was opened immediately, take a partial snapshot
      // now and let the debounce replace it once the scan settles.
      if (root.catalogSnapshot.length === 0) {
        root.refreshCatalog()
        catalogDebounce.restart()
      }
    }
  }

  // Desktop entries appear asynchronously (and one at a time on first scan),
  // so wait for the burst to settle before swapping the snapshot. Rebuilding
  // the ListView on every addition destroyed delegates mid-click and reset
  // contentY, which is what made rows unreliable and scrolling one-directional.
  Connections {
    target: DesktopEntries.applications
    function onValuesChanged() { catalogDebounce.restart() }
  }

  Timer {
    id: catalogDebounce
    interval: 600
    repeat: false
    onTriggered: root.refreshCatalog()
  }

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
    // Monochrome line-art version of the reference: Alt and Win keycaps with
    // two arrows swapping between them. The SVG is white so MultiEffect can
    // tint it with the bar's foreground colour (and the dim state still works).
    text: ""
    iconComponent: Component {
      Item {
        anchors.fill: parent

        Image {
          id: iconImage
          anchors.fill: parent
          source: Qt.resolvedUrl("icon.svg")
          sourceSize.width: width * Screen.devicePixelRatio
          sourceSize.height: height * Screen.devicePixelRatio
          fillMode: Image.PreserveAspectFit
          smooth: true
          asynchronous: true
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: iconImage
          source: iconImage
          colorization: 1.0
          colorizationColor: button.foreground
        }
      }
    }
    opticalSize: Style.bar.iconCanvas + 3
    slotSize: Style.bar.statusSlot
    dimmed: !root.swapped
    tooltipText: root.tooltipText()

    onPressed: function(mouseButton) {
      if (mouseButton === Qt.RightButton) root.setEnabled(!root.pluginEnabled)
      else if (mouseButton === Qt.MiddleButton && engine) engine.refresh()
      else root.toggle()
    }
  }

  // KeyboardPanel (not PopupCard): PopupCard is an xdg-popup on a
  // layer-shell parent, so it never receives keyboard focus. KeyboardPanel is
  // a layer-shell surface with WlrKeyboardFocus, which is what makes the
  // All apps search field typable.
  KeyboardPanel {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(content.implicitHeight)
    // Focus the search field on open when the catalog is showing, otherwise
    // the panel itself so Escape closes it.
    focusTarget: root.appListMode === "all" ? appSearchField : panelFocus

    FocusScope {
      id: panelFocus
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

        // -------------------------------------------------- app list

        Column {
          width: parent.width
          spacing: Style.space(6)

          Item {
            width: parent.width
            // Reserve the chip strip height even with no selected apps, so
            // adding the first chip does not push the list down.
            height: Math.max(appsCaption.implicitHeight, appsHint.implicitHeight, Style.space(30))

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

            // Selected apps ride on the header line. A fixed-height, one-row
            // horizontal list means adding or removing a chip never moves the
            // app list underneath the pointer.
            ListView {
              id: chipStrip
              anchors.left: appsCaption.right
              anchors.leftMargin: Style.space(12)
              anchors.right: appsHint.left
              anchors.rightMargin: Style.space(12)
              anchors.verticalCenter: parent.verticalCenter
              height: Style.space(30)
              orientation: ListView.Horizontal
              spacing: Style.space(6)
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: contentWidth > width
              model: root.apps
              visible: root.apps.length > 0

              delegate: Item {
                required property string modelData

                readonly property string icon: {
                  var found = root.appIconIndex[String(modelData).toLowerCase()]
                  return found !== undefined ? found : root.desktopIcon("")
                }

                width: Style.space(30)
                height: width

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: chipHover.hovered
                    ? Util.alpha(root.panelText, 0.10)
                    : Util.alpha(root.panelText, 0.05)
                }

                Image {
                  id: chipIcon
                  property bool fellBack: false
                  anchors.centerIn: parent
                  width: Style.space(18)
                  height: width
                  source: icon
                  sourceSize.width: width * Screen.devicePixelRatio
                  sourceSize.height: height * Screen.devicePixelRatio
                  fillMode: Image.PreserveAspectFit
                  asynchronous: true

                  onStatusChanged: {
                    if (status === Image.Error && !fellBack) {
                      fellBack = true
                      source = Quickshell.iconPath("application-x-executable", true)
                    }
                  }
                }

                HoverHandler {
                  id: chipHover
                }

                PanelToolTip {
                  visible: chipHover.hovered
                  text: modelData
                }

                Rectangle {
                  width: Style.space(13)
                  height: width
                  radius: width / 2
                  anchors.top: parent.top
                  anchors.right: parent.right
                  color: Commons.Color.popups.background
                  border.width: 1
                  border.color: Util.alpha(root.panelText, 0.4)
                  z: 2

                  Text {
                    anchors.centerIn: parent
                    text: "✕"
                    color: root.panelText
                    font.family: Style.font.family
                    font.pixelSize: Math.round(parent.height * 0.66)
                  }

                  MouseArea {
                    anchors.fill: parent
                    anchors.margins: -Style.space(3)
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.removeApp(modelData)
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            text: "Select apps to revert or unrevert the swap"
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.panelDim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
          }

          // Two sources: the windows open right now, or the full installed
          // application catalog with icons and a search field.
          Row {
            width: parent.width
            spacing: Style.space(4)

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "Running apps"
              selected: root.appListMode === "running"
              bordered: true
              foreground: root.panelText
              fontSize: Style.font.caption
              onClicked: root.setAppListMode("running")
            }

            Button {
              width: (parent.width - parent.spacing) / 2
              text: "All apps"
              selected: root.appListMode === "all"
              bordered: true
              foreground: root.panelText
              fontSize: Style.font.caption
              onClicked: root.setAppListMode("all")
            }
          }

          TextField {
            id: appSearchField
            width: parent.width
            visible: root.appListMode === "all"
            text: root.appSearch
            placeholderText: "Search installed apps…"
            foreground: root.panelText
            font.pixelSize: Style.font.bodySmall
            onTextChanged: root.appSearch = text
            Keys.onEscapePressed: root.close()
          }

          // Scrolls once the list gets long, so the card never outgrows the
          // screen. Running rows come first (most recently focused first),
          // then configured patterns that are not open right now.
          Item {
            width: parent.width
            height: Math.min(appList.contentHeight, Style.space(190))
            clip: true
            visible: root.listRows.length > 0

            ListView {
              id: appList
              anchors.fill: parent
              model: root.listRows
              spacing: Style.space(2)
              clip: true
              boundsBehavior: Flickable.StopAtBounds

              delegate: Item {
                required property var modelData

                readonly property bool listed: {
                  var needle = String(modelData.value).toLowerCase()
                  var list = root.apps || []
                  for (var i = 0; i < list.length; i++)
                    if (String(list[i]).toLowerCase() === needle) return true
                  return false
                }

                width: appList.width
                height: Math.max(Style.space(38), rowColumn.implicitHeight + Style.space(12))

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: rowHover.hovered ? Util.alpha(root.panelText, 0.06) : "transparent"
                }

                HoverHandler {
                  id: rowHover
                }

                Row {
                  anchors.fill: parent
                  anchors.leftMargin: Style.space(4)
                  anchors.rightMargin: Style.space(4)
                  spacing: Style.space(10)

                  Item {
                    width: Style.space(20)
                    height: width
                    anchors.verticalCenter: parent.verticalCenter

                    Image {
                      id: appIconImage
                      property bool fellBack: false
                      anchors.fill: parent
                      visible: source !== ""
                      source: modelData.icon ? String(modelData.icon) : ""
                      sourceSize.width: width * Screen.devicePixelRatio
                      sourceSize.height: height * Screen.devicePixelRatio
                      fillMode: Image.PreserveAspectFit
                      asynchronous: true

                      // A desktop entry can point at a path that no longer
                      // exists; swap in the generic app icon once instead of
                      // retrying (and logging) forever.
                      onStatusChanged: {
                        if (status === Image.Error && !fellBack) {
                          fellBack = true
                          source = Quickshell.iconPath("application-x-executable", true)
                        }
                      }
                    }
                  }

                  Rectangle {
                    width: Style.space(16)
                    height: Style.space(16)
                    radius: Math.max(2, Style.cornerRadius / 2)
                    anchors.verticalCenter: parent.verticalCenter
                    color: listed ? Util.alpha(Commons.Color.accent, 0.22) : "transparent"
                    border.width: 1
                    border.color: listed
                      ? Commons.Color.accent
                      : Util.alpha(root.panelText, 0.35)

                    Text {
                      anchors.centerIn: parent
                      visible: listed
                      text: "✓"
                      color: Commons.Color.accent
                      font.family: Style.font.family
                      font.pixelSize: Math.round(parent.height * 0.85)
                      font.bold: true
                    }
                  }

                  Column {
                    id: rowColumn
                    width: parent.width
                      - Style.space(20) - Style.space(16) - parent.spacing * 2
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(2)

                    Text {
                      width: parent.width
                      text: modelData.label
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      color: root.panelText
                      font.family: Style.font.family
                      font.pixelSize: Style.font.body
                    }

                    Text {
                      width: parent.width
                      visible: modelData.description !== ""
                      text: modelData.description
                      textFormat: Text.PlainText
                      elide: Text.ElideRight
                      color: root.panelDim
                      font.family: Style.font.family
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.toggleApp(modelData.value)
                }
              }
            }
          }

          Text {
            width: parent.width
            visible: root.listRows.length === 0
            text: root.appListMode === "all"
              ? (root.appSearch.trim() !== "" ? "No matching applications." : "No applications found.")
              : "No running apps — open one and try again, or switch to All apps."
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            color: root.panelDim
            font.family: Style.font.family
            font.pixelSize: Style.font.caption
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
