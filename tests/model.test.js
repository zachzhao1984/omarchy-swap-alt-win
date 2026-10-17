const test = require("node:test")
const assert = require("node:assert/strict")
const fs = require("node:fs")
const path = require("node:path")

// Model.js is a QML JavaScript file, so it has no `module.exports`. Evaluate
// it as a function body and return the pieces we test, which keeps the runtime
// file free of node-specific plumbing.
const source = fs.readFileSync(path.join(__dirname, "..", "Model.js"), "utf8")
const names = [
  "defaultConfig",
  "normalizeConfig",
  "normalizeSwapOption",
  "normalizeApps",
  "splitOptions",
  "joinOptions",
  "addOption",
  "stripSwapTokens",
  "optionsEqual",
  "restoreOptions",
  "matchesApp",
  "matchesAny",
  "desiredSwap",
  "luaSetOptions"
]
const Model = new Function(source + "\nreturn {" + names.join(",") + "}")()

// ------------------------------------------------------------------ config

test("defaults swap keys on, everywhere", () => {
  const config = Model.defaultConfig()
  assert.equal(config.enabled, true)
  assert.equal(config.mode, "revert")
  assert.equal(config.swapOption, "altwin:swap_alt_win")
  assert.deepEqual(config.apps, [])
})

test("normalizeConfig repairs malformed documents", () => {
  const config = Model.normalizeConfig({
    enabled: "true",
    mode: "sometimes",
    swapOption: "not an option",
    matchTitles: "yes",
    apps: ["firefox", " firefox ", 42, "", "org.gnome.Nautilus"]
  })
  assert.equal(config.enabled, true)
  assert.equal(config.mode, "revert")
  assert.equal(config.swapOption, "altwin:swap_alt_win")
  assert.equal(config.matchTitles, false)
  assert.deepEqual(config.apps, ["firefox", "org.gnome.Nautilus"])
})

test("normalizeConfig refuses arrays and null", () => {
  for (const bad of [null, undefined, [], "nope", 7]) {
    const config = Model.normalizeConfig(bad)
    assert.equal(config.enabled, true)
    assert.deepEqual(config.apps, [])
  }
})

test("normalizeSwapOption only accepts option syntax", () => {
  assert.equal(Model.normalizeSwapOption("altwin:swap_lalt_lwin"), "altwin:swap_lalt_lwin")
  assert.equal(Model.normalizeSwapOption("altwin:swap alt"), "altwin:swap_alt_win")
  assert.equal(Model.normalizeSwapOption(""), "altwin:swap_alt_win")
  assert.equal(Model.normalizeSwapOption(null), "altwin:swap_alt_win")
})

test("normalizeApps caps runaway lists", () => {
  const many = Array.from({ length: 200 }, (_, i) => "app" + i)
  assert.equal(Model.normalizeApps(many).length, 100)
})

// ----------------------------------------------------------------- options

test("splitOptions trims and drops empty entries", () => {
  assert.deepEqual(Model.splitOptions(" compose:caps, ctrl:swapcaps ,, "), [
    "compose:caps",
    "ctrl:swapcaps"
  ])
  assert.deepEqual(Model.splitOptions(""), [])
  assert.deepEqual(Model.splitOptions(null), [])
})

test("addOption appends once", () => {
  assert.equal(Model.addOption("compose:caps", "altwin:swap_alt_win"), "compose:caps,altwin:swap_alt_win")
  assert.equal(
    Model.addOption("compose:caps,altwin:swap_alt_win", "altwin:swap_alt_win"),
    "compose:caps,altwin:swap_alt_win"
  )
  assert.equal(Model.addOption("", "altwin:swap_alt_win"), "altwin:swap_alt_win")
})

test("stripSwapTokens removes every managed swap variant", () => {
  assert.equal(
    Model.stripSwapTokens(
      "compose:caps,ctrl:swapcaps,altwin:swap_alt_win,altwin:swap_lalt_lwin",
      "altwin:swap_alt_win"
    ),
    "compose:caps,ctrl:swapcaps"
  )
  assert.equal(Model.stripSwapTokens("compose:caps", "altwin:swap_alt_win"), "compose:caps")
  assert.equal(
    Model.stripSwapTokens("altwin:swap_alt_win", "altwin:swap_ralt_rwin"),
    ""
  )
})

test("stripSwapTokens also removes a custom swap option", () => {
  assert.equal(
    Model.stripSwapTokens("compose:caps,custom:swap", "custom:swap"),
    "compose:caps"
  )
})

test("optionsEqual is order insensitive", () => {
  assert.equal(Model.optionsEqual("a,b", "b,a"), true)
  assert.equal(Model.optionsEqual("a,b", "a,b,c"), false)
  assert.equal(Model.optionsEqual("", ""), true)
})

test("restoreOptions returns the user's own configuration", () => {
  // The only swap present is the one the plugin adds: taking it back out is
  // the correct restore.
  assert.equal(
    Model.restoreOptions("compose:caps,altwin:swap_alt_win", "compose:caps", "altwin:swap_alt_win"),
    "compose:caps"
  )
  // A swap the user configured themselves (different variant) is preserved.
  assert.equal(
    Model.restoreOptions("compose:caps,altwin:swap_lalt_lwin", "compose:caps", "altwin:swap_alt_win"),
    "compose:caps,altwin:swap_lalt_lwin"
  )
  // Nothing to restore is still nothing.
  assert.equal(Model.restoreOptions("", "", "altwin:swap_alt_win"), "")
})

// ---------------------------------------------------------------- matching

test("matchesApp matches classes case-insensitively", () => {
  assert.equal(Model.matchesApp("firefox", "Firefox", ""), true)
  assert.equal(Model.matchesApp("fire", "Firefox", ""), true)
  assert.equal(Model.matchesApp("^firefox$", "firefox-esr", ""), false)
  assert.equal(Model.matchesApp("firefox|chromium", "chromium", ""), true)
})

test("matchesApp survives a class name that is not a valid regex", () => {
  assert.equal(Model.matchesApp("my[app", "my[app", ""), true)
})

test("title: patterns target the title only", () => {
  assert.equal(Model.matchesApp("title:youtube", "firefox", "YouTube — Firefox"), true)
  assert.equal(Model.matchesApp("title:youtube", "YouTube", ""), false)
})

test("matchTitles widens plain patterns to titles", () => {
  assert.equal(Model.matchesAny(["youtube"], "firefox", "YouTube — Firefox", false), false)
  assert.equal(Model.matchesAny(["youtube"], "firefox", "YouTube — Firefox", true), true)
})

test("matchesAny ignores blank patterns", () => {
  assert.equal(Model.matchesAny(["", "  "], "firefox", "", true), false)
  assert.equal(Model.matchesAny(null, "firefox", "", true), false)
})

// ------------------------------------------------------------------- state

test("revert mode swaps outside the list, normal inside", () => {
  const config = Model.normalizeConfig({ enabled: true, mode: "revert", apps: ["firefox"] })
  assert.equal(Model.desiredSwap(config, "firefox", ""), "normal")
  assert.equal(Model.desiredSwap(config, "org.gnome.Nautilus", ""), "swapped")
})

test("only mode swaps inside the list, normal outside", () => {
  const config = Model.normalizeConfig({ enabled: true, mode: "only", apps: ["firefox"] })
  assert.equal(Model.desiredSwap(config, "firefox", ""), "swapped")
  assert.equal(Model.desiredSwap(config, "org.gnome.Nautilus", ""), "normal")
})

test("no focused window falls through to the mode default", () => {
  const revert = Model.normalizeConfig({ enabled: true, mode: "revert", apps: ["firefox"] })
  assert.equal(Model.desiredSwap(revert, "", ""), "swapped")
  const only = Model.normalizeConfig({ enabled: true, mode: "only", apps: ["firefox"] })
  assert.equal(Model.desiredSwap(only, "", ""), "normal")
})

test("disabled always restores", () => {
  const config = Model.normalizeConfig({ enabled: false, mode: "only", apps: ["firefox"] })
  assert.equal(Model.desiredSwap(config, "firefox", ""), "restore")
  assert.equal(Model.desiredSwap(config, "other", ""), "restore")
})

test("title rules follow focus when matchTitles is on", () => {
  const config = Model.normalizeConfig({
    enabled: true,
    mode: "revert",
    matchTitles: true,
    apps: ["title:youtube"]
  })
  assert.equal(Model.desiredSwap(config, "firefox", "YouTube — Firefox"), "normal")
  assert.equal(Model.desiredSwap(config, "firefox", "Hacker News"), "swapped")
})

// --------------------------------------------------------------- hyprland

test("luaSetOptions emits one quoted Lua string", () => {
  assert.equal(
    Model.luaSetOptions("compose:caps,altwin:swap_alt_win"),
    'hl.config({ input = { kb_options = "compose:caps,altwin:swap_alt_win" } })'
  )
  assert.equal(Model.luaSetOptions(""), 'hl.config({ input = { kb_options = "" } })')
  assert.equal(Model.luaSetOptions(null), 'hl.config({ input = { kb_options = "" } })')
})
