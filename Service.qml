import QtQuick

// The one live engine. The shell mounts a plugin's `service` entry point once
// whenever the plugin is enabled — whether it was enabled through the bar
// widget or through the top-level `plugins` array — so all state and all
// Hyprland writes live here and BarWidget.qml only renders what it finds.
//
// Running without the bar widget is just a matter of removing the widget from
// the bar; this service keeps going as long as the plugin is enabled.
KeySwapEngine {
  id: root
}
