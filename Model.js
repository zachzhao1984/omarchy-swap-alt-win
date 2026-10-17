// Pure logic for the Alt / Win swap plugin.
//
// Everything that can be decided without Hyprland or the filesystem lives
// here: config normalization, XKB option-list arithmetic, and the rule that
// picks the key state for the focused window. Kept free of QML imports so
// `node --test` (see tests/model.test.js) exercises the same code the plugin
// runs.

// XKB swap options this plugin knows how to take back out of an option list.
// `altwin:swap_alt_win` is the both-sides swap; the two one-sided variants are
// what it expands to, and users sometimes have them configured directly.
var SWAP_VARIANTS = [
  "altwin:swap_alt_win",
  "altwin:swap_lalt_lwin",
  "altwin:swap_ralt_rwin"
]

var MAX_APPS = 100

// ---------------------------------------------------------------- config

function defaultConfig() {
  return {
    version: 1,
    // Swap on by default; the whole point of installing this.
    enabled: true,
    // "revert": swap everywhere except the listed apps.
    // "only":   leave keys alone except in the listed apps.
    mode: "revert",
    // Swap both Alt keys with both Win/Super keys.
    swapOption: "altwin:swap_alt_win",
    // Test patterns against window titles as well as app classes.
    matchTitles: false,
    apps: []
  }
}

function normalizeConfig(document) {
  var source = document && typeof document === "object" && !(document instanceof Array)
    ? document
    : {}
  var defaults = defaultConfig()
  var config = defaultConfig()

  if (source.enabled !== undefined && source.enabled !== null)
    config.enabled = source.enabled === true || String(source.enabled).toLowerCase() === "true"
  else
    config.enabled = defaults.enabled

  config.mode = source.mode === "only" ? "only" : "revert"
  config.matchTitles = source.matchTitles === true
  config.swapOption = normalizeSwapOption(source.swapOption)
  config.apps = normalizeApps(source.apps)

  return config
}

function normalizeSwapOption(value) {
  var option = value === undefined || value === null ? "" : String(value).trim()
  if (!/^[A-Za-z0-9_]+:[A-Za-z0-9_]+$/.test(option))
    return defaultConfig().swapOption
  return option
}

function normalizeApps(value) {
  if (!(value instanceof Array)) return []
  var apps = []
  var seen = {}
  for (var i = 0; i < value.length && apps.length < MAX_APPS; i++) {
    if (typeof value[i] !== "string") continue
    var pattern = value[i].trim()
    if (pattern === "") continue
    var key = pattern.toLowerCase()
    if (seen[key] === true) continue
    seen[key] = true
    apps.push(pattern)
  }
  return apps
}

// --------------------------------------------------------------- options

// XKB option lists are comma separated. Split, trim, and drop empties so a
// hand-edited "a, b,,c" and "a,b,c" behave the same.
function splitOptions(value) {
  var text = value === undefined || value === null ? "" : String(value)
  var parts = text.split(",")
  var options = []
  for (var i = 0; i < parts.length; i++) {
    var part = parts[i].trim()
    if (part !== "") options.push(part)
  }
  return options
}

function joinOptions(options) {
  if (!(options instanceof Array)) return ""
  return options.join(",")
}

function hasOption(value, option) {
  var options = splitOptions(value)
  return options.indexOf(option) !== -1
}

function addOption(value, option) {
  var options = splitOptions(value)
  var token = String(option === undefined || option === null ? "" : option).trim()
  if (token !== "" && options.indexOf(token) === -1) options.push(token)
  return joinOptions(options)
}

// Remove every swap option this plugin manages. Options that are not part of
// the swap family (compose:caps, ctrl:swapcaps, ...) are left untouched.
function stripSwapTokens(value, swapOption) {
  var managed = SWAP_VARIANTS.slice()
  var custom = swapOption === undefined || swapOption === null ? "" : String(swapOption).trim()
  if (custom !== "" && managed.indexOf(custom) === -1) managed.push(custom)

  var options = splitOptions(value)
  var kept = []
  for (var i = 0; i < options.length; i++) {
    if (managed.indexOf(options[i]) === -1) kept.push(options[i])
  }
  return joinOptions(kept)
}

function optionsEqual(a, b) {
  var left = splitOptions(a)
  var right = splitOptions(b)
  if (left.length !== right.length) return false
  for (var i = 0; i < left.length; i++) {
    if (right.indexOf(left[i]) === -1) return false
  }
  return true
}

// What to put back when the plugin is switched off. If the only swap in the
// configured options is the one this plugin would have added (a shell restart
// can leave it behind without a config reload), removing it is the honest
// restore. Anything else is the user's own configuration and is left alone.
function restoreOptions(configured, plain, swapOption) {
  var expected = addOption(plain, swapOption)
  return optionsEqual(configured, expected) ? plain : String(configured === undefined || configured === null ? "" : configured)
}

// ---------------------------------------------------------------- matching

// A pattern matches the window class case-insensitively. It is treated as a
// regular expression when it is one, and as a plain substring when it is not
// (a class name with a stray "[" should still be usable).
//
// `title:foo` always targets the window title, whatever matchTitles says.
function matchesApp(pattern, windowClass, windowTitle) {
  var text = String(pattern === undefined || pattern === null ? "" : pattern).trim()
  if (text === "") return false

  var target = windowClass
  if (text.toLowerCase().indexOf("title:") === 0) {
    text = text.slice(6).trim()
    target = windowTitle
  }
  if (text === "") return false

  return patternMatches(text, target)
}

function patternMatches(pattern, value) {
  var needle = String(pattern === undefined || pattern === null ? "" : pattern)
  var haystack = String(value === undefined || value === null ? "" : value)
  if (needle === "" || haystack === "") return false
  try {
    return new RegExp(needle, "i").test(haystack)
  } catch (error) {
    return haystack.toLowerCase().indexOf(needle.toLowerCase()) !== -1
  }
}

function matchesAny(patterns, windowClass, windowTitle, matchTitles) {
  if (!(patterns instanceof Array)) return false
  for (var i = 0; i < patterns.length; i++) {
    var pattern = String(patterns[i] === undefined || patterns[i] === null ? "" : patterns[i]).trim()
    if (pattern === "") continue
    if (pattern.toLowerCase().indexOf("title:") === 0) {
      if (matchesApp(pattern, windowClass, windowTitle)) return true
      continue
    }
    if (matchesApp(pattern, windowClass)) return true
    if (matchTitles === true && patternMatches(pattern, windowTitle)) return true
  }
  return false
}

// --------------------------------------------------------- running apps

// Reduce `hyprctl -j clients` to one row per app class, most recently focused
// first. Windows that are not mapped (hidden workspaces, special workspaces
// that never appeared) are skipped; a class-less window falls back to its
// title so it is still selectable.
function parseClients(text) {
  var clients = null
  try {
    clients = JSON.parse(String(text === undefined || text === null ? "" : text))
  } catch (error) {
    return []
  }
  if (!(clients instanceof Array)) return []

  var rows = []
  var byKey = {}
  for (var i = 0; i < clients.length; i++) {
    var client = clients[i]
    if (!client || typeof client !== "object") continue
    if (client.mapped === false) continue

    var cls = String(client["class"] === undefined || client["class"] === null ? "" : client["class"]).trim()
    var title = String(client.title === undefined || client.title === null ? "" : client.title).trim()
    if (cls === "" && title === "") continue

    var name = cls !== "" ? cls : title
    var key = name.toLowerCase()
    if (byKey[key]) {
      byKey[key].count++
      if (byKey[key].description === "") byKey[key].description = title
      continue
    }

    var order = Number(client.focusHistoryID)
    var row = {
      value: name,
      label: name,
      description: title,
      // Grouping bookkeeping, stripped before the rows leave this function.
      order: isFinite(order) ? order : 1e15,
      count: 1
    }
    byKey[key] = row
    rows.push(row)
  }

  rows.sort(function(a, b) { return a.order - b.order })

  var out = []
  for (var j = 0; j < rows.length; j++) {
    var description = rows[j].description
    if (rows[j].count > 1) {
      description = rows[j].count + " windows" + (description !== "" ? " · " + description : "")
    }
    out.push({ value: rows[j].value, label: rows[j].label, description: description })
  }
  return out
}

// The pattern stored when the user picks a desktop entry. StartupWMClass is
// what the app asks the compositor to call its window; the desktop id (minus
// the .desktop suffix) is the conventional fallback for entries that do not
// declare one.
function desktopPattern(entryId, startupClass) {
  var cls = String(startupClass === undefined || startupClass === null ? "" : startupClass).trim()
  if (cls !== "") return cls
  var id = String(entryId === undefined || entryId === null ? "" : entryId).trim()
  if (id.length > 8 && id.slice(-8) === ".desktop") id = id.slice(0, -8)
  return id
}

// ------------------------------------------------------------- hyprland

// The Lua snippet that sets the global keyboard options. Hyprland 0.5x+ has
// no working `hyprctl keyword` for the Lua config parser; eval is the live
// path. JSON string escaping is a subset of Lua's for the ASCII option
// strings XKB uses, so JSON.stringify gives a correctly quoted literal.
function luaSetOptions(options) {
  return 'hl.config({ input = { kb_options = ' + JSON.stringify(String(options === undefined || options === null ? "" : options)) + ' } })'
}

// ------------------------------------------------------------- state rule

// "swapped" | "normal" | "restore"
//
// "restore" is the plugin-off state: put back whatever the user had configured
// before the plugin touched anything.
function desiredSwap(config, windowClass, windowTitle) {
  if (!config || config.enabled !== true) return "restore"

  var hit = matchesAny(config.apps, windowClass, windowTitle, config.matchTitles === true)
  if (config.mode === "only") return hit ? "swapped" : "normal"
  return hit ? "normal" : "swapped"
}

function stateLabel(state) {
  if (state === "swapped") return "Swapped"
  if (state === "restore") return "Plugin off"
  return "Normal"
}
