// Control-center capability model. Pure data + logic, no QML imports, so it
// can be reasoned about, unit-tested under node, and extended by third-party
// plugins via the control-center.json convention described below.
//
// == Capability schema ==
// Every control in the hub is a "cap" — a plain object. The renderer in
// Panel.qml draws a cap by `kind`, reads state through its `backend`, and
// runs actions/panels through its command fields:
//
//   id       unique id (also the key used by keyboard cursor + state cache)
//   title    row label
//   glyph    Nerd Font glyph rendered in the bar's font
//   kind     "toggle" | "action" | "slider"
//   backend  how state is read/written:
//              "networking"    Quickshell.Networking (wifi on/off)
//              "bluetooth"     Quickshell.Bluetooth default adapter
//              "pipewire"      default audio sink volume (0..1.0 = 0..100%)
//              "pipewire-mute" default audio sink muted bool
//              "command"       poll+command driven (see fields below)
//   detail   plugin id whose panel this cap "opens" (e.g. omarchy.audio);
//            "" means it has none (rendered as a plain action/chevron-free)
//
// Command-backed caps ("backend": "command"):
//   read     argv to poll; output interpreted by readMode/readKey/readValue
//   readMode "json" (object; readKey extracts a field), "eq" (output equals
//            readValue), "contains" (output contains readValue)
//   readKey  field name for readMode "json"
//   readValue target string for "eq"/"contains"
//   onCommand  argv run to enable (toggles)
//   offCommand argv run to disable (toggles)
//   applyCommand template argv for sliders; the literal "{v}" is replaced
//            with the numeric value ("brightnessctl","set","{v}%")
//   min/max  slider range (sliders), default 0..100
//   unit     "%" or "K" shown beside a slider/toggle value
//   pollEvery override for the shared poller interval (ms)
//
// Fields shared by all kinds:
//   sublabel static status text for actions (default "" = derive)
//   customId "screenshot" | "lock" for actions wired to omarchy commands,
//            otherwise a bare `runCommand` argv may be supplied instead.
//
// Availability (caps are only rendered when their backend is present):
//   needsBin    binary that must exist (probed once per popup)
//   needsConn   NetworkManager connection type that must exist ("vpn");
//               detected from `nmcli -t -f TYPE con show`
//
// Safety (never auto-activate these):
//   confirm     non-empty string forces an explicit confirm step (suspend,
//               reboot, shutdown, logout)
//
// Runtime-name resolution for toggles whose command needs a dynamic value:
//   nameSlotId  id of another (hidden) cap that polls the name; the tokens
//               "{name}" in onCommand/offCommand are replaced by its value.

// One UI desktop quick panel: a single 4×4 page of information-bearing
// controls. The system actions live in their own compact row beneath it.
var COLUMNS = 4
var GRID_LIMIT = 16
var SYSTEM_ACTION_IDS = {
  "lock": true, "suspend": true, "logout": true, "reboot": true, "poweroff": true
}

// NOTE: there is no built-in capability registry here. Every capability a
// tile can show — default grid or add palette — is contributed BY A PLUGIN
// via its control-center.json (discovered by `find ... -name
// control-center.json`). The control-center plugin itself ships the core
// first-party capabilities (network/audio/power/... labelled with the omarchy
// provider that owns each subsystem) as its own manifest. Nothing else.

// ids that mark caps hidden from the grid but used as slider pills.
var HIDDEN = { "volume-mute": true }

// ---------------------------------------------------------------------------
// Slot/provider architecture (architecture spec §3, §4):
//   slot        logical capability, e.g. "wifi"      — independent of provider
//   providerId  who owns that slot today, e.g. "omarchy.network" (first-party)
//               or a third-party plugin dir. Built-ins are re-homed as
//               first-party providers rather than anonymous monolithic caps.
//   bindings    { slot: { provider, icon } } — user overrides from the picker.
// ---------------------------------------------------------------------------

// Presentation/deploy tier (UX spec §4):
//   1 = seeded on the default grid;  2 = never defaulted (palette only);
//   3 = curated subset, only user-may-default entries.
var TIER = {
  "wifi": 1, "bluetooth": 1, "airplane": 1, "nightlight": 1, "dark-mode": 1,
  "dnd": 1, "stay-awake": 1, "power-saver": 1, "vpn": 1,
  "volume": 1, "mic-mute": 1, "brightness": 1,
  "lock": 2, "suspend": 2, "logout": 2, "reboot": 2, "poweroff": 2,
  "screenshot": 1, "screen-record": 1, "terminal": 1, "files": 1,
  "monitor": 3, "settings": 3
}

// No FIRST_PARTY_PROVIDER table exists anymore: capabilities declare their
// owning provider inline in their plugin manifest (providerId per cap), so the
// picker's provider column is always plugin identity.

// Icon catalog: shared, provider-agnostic glyph registry (architecture §2).
// Every codepoint was verified against the installed JetBrainsMono Nerd Font
// cmap; only FA-solid-era entries that exist in the NF legacy set are listed.
var ICON_GLYPHS = {
  "wifi.solid": "\uF1EB", "bluetooth.solid": "\uF294", "airplane.solid": "\uF072",
  "night.moon": "\uF186", "theme.half": "\uF05E",
  "silence.bell": "\uF0F3", "silence.bell-slash": "\uF1F6",
  "awake.coffee": "\uF0F4", "energy.bolt": "\uF0E7",
  "vpn.server": "\uF0E0", "vpn.lock": "\uF023",
  "volume.up": "\uF028", "volume.mute": "\uF026", "mic.off": "\uF131",
  "brightness.sun": "\uF185",
  "cam.shot": "\uF030", "rec.video": "\uF03D",
  "lock.lock": "\uF023", "sleep.bed": "\uF236",
  "out.bracket": "\uF2F5", "restart.rotate": "\uF2F1", "power.power": "\uF011",
  "term.console": "\uF120", "files.folder": "\uF07B",
  "monitor.display": "\uF26C", "set.gear": "\uF013",
  "app.grid": "\uF00A", "app.boxes": "\uF1B0",
  "net.globe": "\uF0AC", "ai.chip": "\uF2DB",
  "time.clock": "\uF017", "media.play": "\uF04B", "info.circle": "\uF05A"
}

// Icon options offered by the picker, per slot (icon keys into ICON_GLYPHS).
var SLOT_ICONS = {
  "wifi": ["wifi.solid", "app.boxes"],
  "bluetooth": ["bluetooth.solid", "app.boxes"],
  "airplane": ["airplane.solid", "app.boxes"],
  "nightlight": ["night.moon", "brightness.sun"],
  "dark-mode": ["theme.half", "night.moon"],
  "dnd": ["silence.bell-slash", "silence.bell"],
  "stay-awake": ["awake.coffee", "energy.bolt"],
  "power-saver": ["energy.bolt", "power.power"],
  "vpn": ["vpn.lock", "vpn.server", "app.grid"],
  "volume": ["volume.up", "volume.mute"],
  "mic-mute": ["mic.off", "app.boxes"],
  "brightness": ["brightness.sun", "night.moon"],
  "screenshot": ["cam.shot", "app.grid"],
  "screen-record": ["rec.video", "cam.shot"],
  "lock": ["lock.lock", "app.grid"],
  "suspend": ["sleep.bed", "power.power"],
  "logout": ["out.bracket", "app.grid"],
  "reboot": ["restart.rotate", "out.bracket"],
  "poweroff": ["power.power", "power.power"],
  "terminal": ["term.console", "app.grid"],
  "files": ["files.folder", "app.grid"],
  "monitor": ["monitor.display", "set.gear"],
  "settings": ["set.gear", "app.grid"]
}

// Distinct smaller corner badge for plugin tiles that summon another bar
// widget's panel (architecture §3: open-tiles are visually flagged).
var PLUGIN_TILE_BADGE = true

// Decorate any capability with its slot/provider/tier defaults. Additive so
// external caps get the same guarantees as built-ins.
function normalizeCap(c, defaults) {
  var providerDefaults = defaults || {}
  c.slot = String(c.slot || c.id || "")
  c.providerId = String(
    c.providerId || providerDefaults.providerId || "a.control-center"
  )
  c.tier = isFinite(Number(c.tier)) ? Number(c.tier) : (TIER[c.id] || 3)
  return c
}

// Resolve who currently owns a slot. Returns { state, option } where
//   state "single"  one provider available -> option is it
//   state "none"    no provider is available        (bindings[slot].provider may
//                   still name a missing plugin — grid must not render it)
//   state "choose"  more than one available         (picker must resolve)
function resolveSlot(caps, bindings, slotId) {
  var slot = String(slotId || "")
  if (slot === "") return { state: "none" }
  var providers = providersForSlot(caps, slotId)
  if (!providers.length) return { state: "none" }
  if (providers.length === 1) return { state: "single", option: providers[0] }
  var bound = bindings && bindings[slot]
  if (bound && bound.provider) {
    for (var i = 0; i < providers.length; i++)
      if (providers[i].providerId === bound.provider) {
        // Bound icon must exist in the catalog; otherwise keep the cap glyph.
        providers[i].icon = homeIcon(bound.icon) || providers[i].icon
        return { state: "single", option: providers[i] }
      }
  }
  return { state: "choose", options: providers }
}

function providersForSlot(caps, slotId) {
  var slot = String(slotId || "")
  var out = []
  var seen = {}
  for (var i = 0; i < caps.length; i++) {
    var c = caps[i]
    if (!c || String(c.slot || "") !== slot) continue
    if (!isGriddableCap(c)) continue
    if (seen[c.providerId]) continue
    seen[c.providerId] = true
    var icon = c.glyph || homeIcon("app.boxes")
    out.push({ providerId: c.providerId, cap: c, icon: icon })
  }
  return out
}

// Resolve an icon key through the catalog (null when unknown -> caller keeps
// the cap's own glyph).
function homeIcon(iconKey) {
  if (!iconKey) return null
  return ICON_GLYPHS[iconKey] || null
}

// Normalize the persisted control-center-config.json payload. Tolerant of
// hand edits and forward versions: unknown keys are ignored, wrong types
// reset to sensible defaults rather than throwing.
function normalizeConfig(obj) {
  var config = { version: 1, gridOrder: [], bindings: {} }
  if (!obj || typeof obj !== "object") return config
  if (isFinite(Number(obj.version))) config.version = Number(obj.version)
  if (Array.isArray(obj.gridOrder)) {
    for (var i = 0; i < obj.gridOrder.length; i++)
      if (typeof obj.gridOrder[i] === "string" && obj.gridOrder[i] !== "")
        config.gridOrder.push(obj.gridOrder[i])
  }
  if (obj.bindings && typeof obj.bindings === "object") {
    for (var slot in obj.bindings) {
      if (!obj.bindings.hasOwnProperty(slot)) continue
      var b = obj.bindings[slot]
      if (!b || typeof b !== "object") continue
      config.bindings[slot] = {
        provider: typeof b.provider === "string" ? b.provider : "",
        icon: typeof b.icon === "string" ? b.icon : "",
        iconSource: b.iconSource === "plugin" ? "plugin" : ""
      }
    }
  }
  return config
}

// Apply a user binding to the slot: returns the icon key from the catalog when
// valid, otherwise the cap's own glyph.
function bindIcon(binding) {
  if (binding) {
    var g = homeIcon(binding.icon)
    if (g) return g
  }
  return null
}

// Every visible cap is a grid tile in the unified quick-settings grid.
// Kinds "command-mute" (pill states) and "hidden" (runtime slots) never
// render; custom-QML-component hosts stay out of the tile grid.
function isGriddableCap(c) {
  return !!c && isCapC(c) && !isHiddenC(c)
    && !SYSTEM_ACTION_IDS[c.id]
    && (c.kind === "toggle" || c.kind === "slider" || c.kind === "action" || c.kind === "launcher")
    && !c.component
}

// The built-in default grid: only the most frequently used controls (spec:
// keep the default face curated; everything else lives in the add palette).
// Availability still gates each entry at runtime, so absent backends simply
// tighten the grid rather than breaking it.
function defaultGridIds() {
  // A complete, balanced first page: volume and brightness are the two live
  // visualizers, while destructive session controls are intentionally kept in
  // the dedicated power row below the grid.
  return [
    "volume", "brightness", "wifi", "bluetooth",
    "airplane", "nightlight", "dark-mode", "dnd",
    "stay-awake", "power-saver", "vpn", "mic-mute",
    "screenshot", "screen-record", "terminal", "files"
  ]
}

// Project caps onto an id-order. The order is either the user's persisted
// grid (authoritative) or the curated default; ids that no longer exist are
// dropped gracefully. Never auto-append: newly discovered capabilities are
// reached through the add palette, not by mutating a user's arrangement.
function orderedGrid(capsIn, orderIds) {
  var caps = Array.isArray(capsIn) ? capsIn : []
  var order = Array.isArray(orderIds) && orderIds.length
    ? orderIds.filter(function(id) { return typeof id === "string" && id !== "" })
    : defaultGridIds()
  var out = []
  var taken = {}
  function take(c) {
    if (c && isGriddableCap(c) && !taken[c.id]) { taken[c.id] = true; out.push(c) }
  }
  for (var i = 0; i < order.length; i++) {
    for (var j = 0; j < caps.length; j++) if (caps[j].id === order[i]) { take(caps[j]); break }
  }
  return out.slice(0, GRID_LIMIT)
}

// Caps the picker can offer that are not already on the grid. Only tiles that
// can actually render (griddable kinds) are offered — hidden runtime slots and
// command-mute pills never appear in the add palette.
function availableForAdd(caps, orderIds) {
  var taken = {}
  var list = Array.isArray(caps) ? caps : []
  for (var i = 0; i < list.length; i++) if (isGriddableCap(list[i])) taken[list[i].id] = true
  var order = orderedGrid(list, orderIds)
  for (var k = 0; k < order.length; k++) delete taken[order[k].id]
  var out = []
  for (var j = 0; j < list.length; j++)
    if (isGriddableCap(list[j]) && taken[list[j].id]) out.push(list[j])
  return out
}

// Bar widgets that are indicators rather than popup panels; summoning them
// opens nothing, so they never become auto panel tiles.
// Only the Control Centre itself is skipped as an "open panel" tile; every
// other enabled bar-widget plugin (first-party or third-party) becomes an
// addable tile so its panel can be summoned from the grid.
var AUTO_EXCLUDE = {
  "a.control-center": true
}

// Category fallback glyphs for generic-tier (manifest-only) launcher tiles
// (13a §3.2). Keys into ICON_GLYPHS; every codepoint cmap-verified.
var CATEGORY_GLYPHS = {
  "Network": "net.globe",
  "Audio": "volume.up",
  "Media": "media.play",
  "Time": "time.clock",
  "Files": "files.folder",
  "Info": "info.circle",
  "System": "set.gear",
  "AI": "ai.chip",
  "Compositor": "app.grid"
}

var AUTO_TILE_GLYPH = "\uF1B0"

// Icons for "Open <plugin>" tiles generated from enabled bar-widget plugins.
// All codepoints verified against the installed JetBrainsMono Nerd Font.
var PLUGIN_GLYPHS = {
  "omarchy.audio": "\uF028",
  "omarchy.bluetooth": "\uF294",
  "omarchy.clock": "\uF017",
  "omarchy.monitor": "\uF26C",
  "omarchy.network": "\uF0E0",
  "omarchy.menu": "\uF0C9",
  "omarchy.power": "\uF240",
  "omarchy.tray": "\uF0E8",
  "omarchy.workspaces": "\uF0CA",
  "omarchy.keyboard-layout": "\uF11C",
  "omarchy.notifications": "\uF0F3",
  "omarchy.weather": "\uF185",
  "omarchy.media": "\uF03D",
  "omarchy.dropbox": "\uF0E8",
  "omarchy.system-update": "\uF2F1",
  "omarchy.tailscale": "\uF0E0",
  "omarchy.microphone": "\uF130",
  "omarchy.indicators": "\uF05E",
  "omarchy.active-window": "\uF2F5",
  "akitaonrails.ai-usagebar": "\uF201",
  "io.github.infiniv.dori": "\uF4AD",
  "tripleu.tor": "\uF0E0",
  "a.control-center": "\uF00A"
}

// ---- Plugin manager (add-tiles) helpers ----
// The add palette is a plugin manager: every tile is contributed by a plugin,
// so the palette lists plugins (filtered first/third party), lets the user add
// their tiles, and choose each plugin's icon scheme (default plugin icons, or
// the user's own icons applied as a contiguous sequence over its tiles).

var PROVIDER_LABELS = {
  "a.control-center": "Core controls",
  "omarchy.network": "Network",
  "omarchy.bluetooth": "Bluetooth",
  "omarchy.audio": "Audio",
  "omarchy.microphone": "Microphone",
  "omarchy.monitor": "Display",
  "omarchy.nightlight": "Night light",
  "omarchy.notifications": "Notifications",
  "omarchy.power": "Power",
  "omarchy.clock": "Clock",
  "omarchy.menu": "Omarchy menu",
  "omarchy.tray": "System tray",
  "omarchy.workspaces": "Workspaces",
  "omarchy.keyboard-layout": "Keyboard layout",
  "omarchy.theme": "Theme",
  "omarchy.capture": "Screen capture",
  "omarchy.launcher": "Launcher",
  "akitaonrails.ai-usagebar": "AI usage",
  "io.github.infiniv.dori": "Dori",
  "tripleu.tor": "Tormarchy",
  "demo-controls": "Demo controls"
}

// First-party = omarchy shell plugins + the control centre hub itself. Any
// other provider folder is third-party.
function partyOf(providerId) {
  var id = String(providerId || "")
  if (id.indexOf("omarchy.") === 0 || id === "a.control-center") return "first"
  return "third"
}

function labelFor(providerId) {
  var id = String(providerId || "")
  var known = PROVIDER_LABELS[id]
  if (known) return known
  var short = id.replace(/^plugin:/, "").replace(/^omarchy\./, "").replace(/^a\./, "")
  var words = short.split(/[.\-_/\\]/)
  var out = []
  for (var i = 0; i < words.length; i++) {
    var w = words[i].trim()
    if (!w) continue
    out.push(w.charAt(0).toUpperCase() + w.slice(1))
  }
  return out.join(" ") || id
}

// Group every griddable cap by the plugin that provides it, sorted by display
// label. Tiles already on the grid are still listed (so icon schemes apply to
// them too); each cap carries an onGrid flag for the add UI.
function pluginGroups(caps, orderIds) {
  var orderSet = {}
  var order = orderedGrid(caps, orderIds)
  for (var i = 0; i < order.length; i++) if (order[i]) orderSet[order[i].id] = true
  var groups = {}
  for (var j = 0; j < caps.length; j++) {
    var c = caps[j]
    if (!isGriddableCap(c)) continue
    var pid = String(c.providerId || "a.control-center")
    if (!groups[pid]) groups[pid] = []
    c.onGrid = !!orderSet[c.id]
    groups[pid].push(c)
  }
  var out = []
  for (var p in groups) {
    if (!groups.hasOwnProperty(p)) continue
    out.push({ providerId: p, label: labelFor(p), party: partyOf(p), caps: groups[p] })
  }
  out.sort(function (a, b) { return a.label < b.label ? -1 : (a.label > b.label ? 1 : 0) })
  return out
}

// Flat, sorted list of every selectable catalog icon — the "my icons"
// sequencer source.
function allIcons() {
  var out = []
  for (var key in ICON_GLYPHS) {
    if (!ICON_GLYPHS.hasOwnProperty(key)) continue
    out.push({ key: key, glyph: ICON_GLYPHS[key] })
  }
  out.sort(function (a, b) { return a.key < b.key ? -1 : (a.key > b.key ? 1 : 0) })
  return out
}

// A plugin uses custom icons when any of its slots carries a user-chosen icon
// binding; "default" means the plugin's own manifest glyphs win.
function pluginUsesCustomIcons(providerId, caps, bindings) {
  var b = bindings || {}
  for (var i = 0; i < caps.length; i++) {
    var slot = String(caps[i].slot || caps[i].id || "")
    if (slot !== "" && b[slot] && b[slot].icon) return true
  }
  return false
}

// ---- Lenient JSON for command output ----
function parseJson(text) {
  var s = String(text === undefined || text === null ? "" : text).replace(/^\s+|\s+$/g, "")
  if (s === "") return null
  try {
    return JSON.parse(s)
  } catch (err) {
    var lines = s.split("\n")
    for (var i = 0; i < lines.length; i++) {
      var candidate = lines[i].replace(/^\s+|\s+$/g, "")
      if (candidate === "" || candidate.charAt(0) !== "{") continue
      try { return JSON.parse(candidate) } catch (err2) {}
    }
    return null
  }
}

// Interpret a polled read against a cap's readMode.
function applyRead(rule, rawOutput) {
  var output = String(rawOutput === undefined || rawOutput === null ? "" : rawOutput)
  if (!rule) return false
  var mode = rule.readMode || "eq"
  if (mode === "json") {
    var obj = parseJson(output)
    var key = rule.readKey
    return !!(obj && key && obj[key])
  }
  if (mode === "percent") {
    // brightnessctl -m prints: device,class,current,percent,max — grab the
    // "NN%" field rather than whichever bare number comes first.
    var m = output.match(/,(\d+)%/)
    return m ? Number(m[1]) : 0
  }
  if (mode === "contains") return output.indexOf(rule.readValue) !== -1
  if (mode === "nonempty") return output.trim() !== ""
  if (mode === "raw") return output.trim()
  return output.trim() === String(rule.readValue || "")
}

// Interpret a polled SIGNAL read against a cap's signalMode. Returns 0..100,
// or -1 when there is no signal (radio off, nothing connected, unparseable).
// Modes: "number" (bare 0..100, e.g. nmcli wifi SIGNAL column) and "rssi"
// (dBm, e.g. `bluetoothctl info` RSSI line; -100dBm -> 0, -50dBm -> 100).
function applySignal(rule, rawOutput) {
  var output = String(rawOutput === undefined || rawOutput === null ? "" : rawOutput)
  if (!rule || !Array.isArray(rule.signalRead)) return -1
  var m = output.match(/-?\d+/)
  if (!m) return -1
  var v = Number(m[0])
  if (!isFinite(v)) return -1
  if ((rule.signalMode || "number") === "rssi")
    return Math.max(0, Math.min(100, Math.round((v + 100) * 2)))
  return Math.max(0, Math.min(100, Math.round(v)))
}

// Percent display for a slider value in its range.
function sliderPercent(value, cap) {
  if (!cap || cap.kind !== "slider" || !isFinite(value)) return 0
  var lo = isFinite(cap.min) ? Number(cap.min) : 0
  var hi = isFinite(cap.max) ? Number(cap.max) : 100
  if (hi <= lo) return 0
  return Math.max(0, Math.min(100, Math.round(((Number(value) - lo) / (hi - lo)) * 100)))
}

// Template substitution for applyCommand sliders. {v} -> bare value; {p} ->
// integer percent.
function applyArgv(argv, value, cap) {
  if (!argv || !argv.length) return []
  var v = Number(value)
  var p = sliderPercent(v, cap)
  var out = []
  for (var i = 0; i < argv.length; i++)
    out.push(String(argv[i]).replace("{v}", isFinite(v) ? v : String(value)).replace("{p}", isFinite(p) ? p : "0"))
  return out
}

function isCapC(c) { return !!c && !!c.id && (c.title || c.id) && !!c.kind }

// Combine every plugin's registered capabilities + auto-discovered panel tiles
// into the grid model. Hidden caps (see isHidden) stay in the registry so
// sliders can bind to their pills, but no renderer shows them.
function isHiddenC(c) { return !!c && !!HIDDEN[c.id] }

function assemble(externalCaps, autoCaps) {
  var all = []
  var seenIds = {}
  function push(c) {
    if (c && isCapC(c) && !(c.kind === "command-mute" && !HIDDEN[c.id])) {
      var normalized = normalizeCap(c)
      var originalId = String(normalized.id)
      // Capability ids back state/cache/polling. Providers may intentionally
      // share a slot (for example two "suspend" implementations), but they
      // must never share that runtime key. Keep the first id stable (the core
      // provider does so today) and namespace later collisions by provider.
      if (seenIds[originalId]) {
        var copy = {}
        for (var key in normalized) copy[key] = normalized[key]
        var baseId = String(normalized.providerId || "provider") + ":" + originalId
        var uniqueId = baseId
        var suffix = 2
        while (seenIds[uniqueId]) uniqueId = baseId + ":" + suffix++
        copy.id = uniqueId
        normalized = copy
      }
      seenIds[String(normalized.id)] = true
      all.push(normalized)
    }
  }
  for (var e = 0; e < externalCaps.length; e++) push(externalCaps[e])
  for (var a = 0; a < autoCaps.length; a++) push(autoCaps[a])
  return all
}

// Fold installed plugins into launcher tiles (13a generic tier). Enabled
// bar-widget panels not claimed by a built-in/external cap become launcher
// caps that summon them. manifests maps plugin id -> { displayName,
// description, category, aliases } from manifest.json files; when absent the
// legacy per-plugin glyph table applies (no visual churn for existing tiles).
function buildAutoTiles(plugins, existingExpandIds, manifests) {
  var out = []
  if (!plugins || !plugins.length) return out
  var taken = existingExpandIds || {}
  var mans = manifests || {}
  for (var i = 0; i < plugins.length; i++) {
    var p = plugins[i]
    if (!p || p.enabled !== true) continue
    var kinds = p.kinds || []
    if (kinds.indexOf("bar-widget") === -1) continue
    var pid = String(p.id || "")
    if (pid === "" || AUTO_EXCLUDE[pid] || taken[pid]) continue
    taken[pid] = true
    out.push({ id: "plugin:" + pid, title: String((mans[pid] && mans[pid].displayName) || p.name || pid),
               glyph: resolveLauncherIcon(pid, mans[pid] || null),
               kind: "launcher", backend: "none", sublabel: "Open", detail: pid,
               providerId: pid, tier: 3 })
  }
  return out
}

// In-house icon resolution for a generic-tier plugin (13a §3): legacy table
// first (preserves current tile icons), then keyword match over
// displayName + description + aliases against known slot names, then the
// category fallback glyph, then the generic plugin glyph.
function resolveLauncherIcon(pid, manifest) {
  if (PLUGIN_GLYPHS[pid]) return PLUGIN_GLYPHS[pid]
  var text = ""
  if (manifest) {
    text = (String(manifest.displayName || "") + " " + String(manifest.description || "")
      + " " + (manifest.aliases || []).join(" ")).toLowerCase()
  }
  if (text !== "") {
    for (var slot in SLOT_ICONS) {
      if (!SLOT_ICONS.hasOwnProperty(slot)) continue
      if (text.indexOf(slot) !== -1 && SLOT_ICONS[slot].length)
        return homeIcon(SLOT_ICONS[slot][0]) || AUTO_TILE_GLYPH
    }
  }
  if (manifest && manifest.category && CATEGORY_GLYPHS[manifest.category])
    return homeIcon(CATEGORY_GLYPHS[manifest.category]) || AUTO_TILE_GLYPH
  return AUTO_TILE_GLYPH
}

// Parse one manifest-scan payload: an array of { id, displayName,
// description, category, aliases, hasCc }. Invalid entries are dropped;
// output is keyed by plugin id for buildAutoTiles.
function parseManifests(text) {
  var out = {}
  var list = parseJson(text)
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var m = list[i]
    if (!m || typeof m.id !== "string" || m.id === "") continue
    var aliases = []
    if (Array.isArray(m.aliases))
      for (var j = 0; j < m.aliases.length; j++)
        if (typeof m.aliases[j] === "string" && m.aliases[j] !== "") aliases.push(m.aliases[j])
    out[m.id] = {
      displayName: typeof m.displayName === "string" ? m.displayName : "",
      description: typeof m.description === "string" ? m.description : "",
      category: typeof m.category === "string" ? m.category : "",
      aliases: aliases,
      hasCc: m.hasCc === true
    }
  }
  return out
}

// Parse a notification-history scan payload: newest-first [{ app, summary,
// body, timestamp(ms) }]. Caps at 10, drops invalid entries, labels relative
// time ("just now", "Nm ago", "Nh ago", "Nd ago").
function parseNotifHistory(text) {
  var out = []
  var list = parseJson(text)
  if (!Array.isArray(list)) return out
  var now = Date.now()
  for (var i = 0; i < list.length && out.length < 10; i++) {
    var n = list[i]
    if (!n || (typeof n.summary !== "string" && typeof n.body !== "string")) continue
    out.push({
      app: String(n.app || ""),
      summary: String(n.summary || ""),
      body: String(n.body || ""),
      when: relTime(Number(n.timestamp) || 0, now)
    })
  }
  return out
}

function relTime(ts, now) {
  if (!isFinite(ts) || ts <= 0) return ""
  var m = Math.max(0, Math.floor((now - ts) / 60000))
  if (m < 1) return "just now"
  if (m < 60) return m + "m ago"
  var h = Math.floor(m / 60)
  if (h < 24) return h + "h ago"
  return Math.floor(h / 24) + "d ago"
}

// Keyword search over caps (file 13 §5): id, title, and searchKeywords.
function searchCaps(query, caps) {
  var q = String(query === undefined || query === null ? "" : query).toLowerCase()
  if (q === "" || !Array.isArray(caps)) return []
  var out = []
  for (var i = 0; i < caps.length; i++) {
    var c = caps[i]
    if (!c) continue
    if (String(c.id || "").toLowerCase().indexOf(q) !== -1
      || String(c.title || "").toLowerCase().indexOf(q) !== -1) { out.push(c); continue }
    var keys = c.searchKeywords
    if (Array.isArray(keys))
      for (var k = 0; k < keys.length; k++)
        if (String(keys[k]).toLowerCase().indexOf(q) !== -1) { out.push(c); break }
  }
  return out
}

// Validate a plugin capability file (a JSON array of caps). Invalid entries
// are dropped so one bad plugin can't take the hub down. Id policy: the
// manifest's own `id` is authoritative (the control-center plugin keeps bare
// ids like "wifi" so persisted gridOrder stays portable); only when a plugin
// omits `id` do we synthesize a source-uniqued one. Duplicate ids across
// plugins are the author's responsibility — duplicate *slots* are the
// provider-selection mechanism and are expected.
function parseExternalCaps(text, sourceTag) {
  var out = []
  var source = String(sourceTag || "plugin")
  // providerId falls back to the plugin directory basename (stable across the
  // renaming of the manifest file).
  var dirEnd = source.lastIndexOf("/")
  var dir = dirEnd >= 0 ? source.substring(0, dirEnd) : source
  var nameStart = dir.lastIndexOf("/")
  var providerShort = (nameStart >= 0 ? dir.substring(nameStart + 1) : dir) || source
  var list = parseJson(text)
  if (!Array.isArray(list)) return out
  for (var i = 0; i < list.length; i++) {
    var c = list[i]
    if (!isCapC(c)) continue
    if (c.kind !== "toggle" && c.kind !== "action" && c.kind !== "slider" && c.kind !== "launcher" && c.kind !== "command-mute" && c.kind !== "hidden") continue
    var clean = {
      id: c.id !== undefined && c.id !== "" ? String(c.id) : source + ":" + String(c.id),
      title: String(c.title),
      glyph: String(c.glyph || AUTO_TILE_GLYPH),
      kind: c.kind,
      backend: c.backend || (c.kind === "slider" ? "command" : "command"),
      detail: String(c.detail || ""),
      sublabel: c.sublabel !== undefined ? String(c.sublabel) : "",
      slot: String(c.slot || c.id || ""),
      providerId: String(c.providerId || providerShort),
      tier: isFinite(Number(c.tier)) ? Number(c.tier) : 3
    }
    if (Array.isArray(c.read)) clean.read = c.read.map(String)
    if (c.readMode) clean.readMode = String(c.readMode)
    if (c.readKey) clean.readKey = String(c.readKey)
    if (c.readValue !== undefined) clean.readValue = c.readValue
    if (Array.isArray(c.onCommand)) clean.onCommand = c.onCommand.map(String)
    if (Array.isArray(c.offCommand)) clean.offCommand = c.offCommand.map(String)
    if (Array.isArray(c.runCommand)) clean.runCommand = c.runCommand.map(String)
    if (Array.isArray(c.applyCommand)) clean.applyCommand = c.applyCommand.map(String)
    if (Array.isArray(c.signalRead)) clean.signalRead = c.signalRead.map(String)
    if (c.signalMode) clean.signalMode = String(c.signalMode)
    if (c.secondaryCapId) clean.secondaryCapId = String(c.secondaryCapId)
    if (c.needsBin) clean.needsBin = String(c.needsBin)
    if (Array.isArray(c.needsAnyBin)) clean.needsAnyBin = c.needsAnyBin.map(String)
    if (c.needsConn) clean.needsConn = String(c.needsConn)
    if (c.confirm) clean.confirm = String(c.confirm)
    if (c.min !== undefined && isFinite(Number(c.min))) clean.min = Number(c.min)
    if (c.max !== undefined && isFinite(Number(c.max))) clean.max = Number(c.max)
    if (c.unit !== undefined) clean.unit = String(c.unit)
    if (c.mutedCapId) clean.mutedCapId = String(c.mutedCapId)
    if (c.component) clean.component = String(c.component)
    out.push(clean)
  }
  return out
}

// Grid cursor math over a flattened list of N caps, `cols` wide.
function moveCursor(current, dx, dy, count, cols) {
  if (!isFinite(current)) return 0
  if (!isFinite(count) || count < 1) count = 0
  var columns = isFinite(cols) && cols > 0 ? Number(cols) : COLUMNS
  if (current >= count) current = Math.max(0, count - 1)
  if (dx === 0 && dy === 0) return current
  var totalRows = Math.max(1, Math.ceil(count / columns))
  var col = current % columns
  var row = Math.floor(current / columns)
  if (dx === 0) {
    var nextRow = row + dy
    if (nextRow < 0) nextRow = 0
    if (nextRow > totalRows - 1) nextRow = totalRows - 1
    var idx = nextRow * columns + col
    return idx >= count ? count - 1 : idx
  }
  var nextCol = (col + dx + columns) % columns
  var result = row * columns + nextCol
  return result >= count ? count - 1 : result
}

if (typeof module !== "undefined") {
  module.exports = {
    COLUMNS: COLUMNS,
    GRID_LIMIT: GRID_LIMIT,
    HIDDEN: HIDDEN,
    TIER: TIER,
    ICON_GLYPHS: ICON_GLYPHS,
    SLOT_ICONS: SLOT_ICONS,
    PLUGIN_GLYPHS: PLUGIN_GLYPHS,
    AUTO_TILE_GLYPH: AUTO_TILE_GLYPH,
    PLUGIN_TILE_BADGE: PLUGIN_TILE_BADGE,
    applyRead: applyRead,
    applySignal: applySignal,
    sliderPercent: sliderPercent,
    applyArgv: applyArgv,
    assemble: assemble,
    buildAutoTiles: buildAutoTiles,
    resolveLauncherIcon: resolveLauncherIcon,
    parseManifests: parseManifests,
    parseNotifHistory: parseNotifHistory,
    searchCaps: searchCaps,
    CATEGORY_GLYPHS: CATEGORY_GLYPHS,
    parseExternalCaps: parseExternalCaps,
    partyOf: partyOf,
    labelFor: labelFor,
    pluginGroups: pluginGroups,
    allIcons: allIcons,
    pluginUsesCustomIcons: pluginUsesCustomIcons,
    moveCursor: moveCursor,
    parseJson: parseJson,
    isGriddableCap: isGriddableCap,
    defaultGridIds: defaultGridIds,
    orderedGrid: orderedGrid,
    availableForAdd: availableForAdd,
    normalizeCap: normalizeCap,
    resolveSlot: resolveSlot,
    providersForSlot: providersForSlot,
    homeIcon: homeIcon,
    normalizeConfig: normalizeConfig,
    bindIcon: bindIcon
  }
}
