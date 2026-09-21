import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Bluetooth
import Quickshell.Io
import Quickshell.Networking
import Quickshell.Services.Pipewire
import qs.Ui
import qs.Commons
import "Model.js" as Model

// Control-center hub: one bar button + one popup that can express every
// capability the bar has — toggles, sliders, quick actions, and a live
// "Open panel" tile for every enabled bar-widget plugin. Caps are plain
// objects defined in Model.js; third-party plugins can contribute caps
// through a control-center.json in their plugin directory (schema in
// Model.js). State flows through three channels:
//   backends   Networking / Bluetooth / Pipewire
//   poller     one Process chain polling command-backed caps while open
//   execution  execDetached for command write-back and panel summoning
Panel {
  id: root
  moduleName: "a.control-center"
  ipcTarget: "a.control-center"

  readonly property bool wifiOn: Networking.wifiEnabled
  readonly property bool btOn: !!(Bluetooth.defaultAdapter && Bluetooth.defaultAdapter.enabled)
  readonly property var sink: Pipewire.defaultAudioSink
  readonly property var source: Pipewire.defaultAudioSource
  readonly property real outputVolume: sink && sink.audio ? sink.audio.volume : 0
  readonly property bool outputMuted: sink && sink.audio ? sink.audio.muted : false
  readonly property bool sourceMuted: source && source.audio ? source.audio.muted : false

  property var externalCaps: []
  property var autoCaps: []
  readonly property var caps: Model.assemble(root.externalCaps || [], root.autoCaps || [])

  // ---- Backend availability probe (bin presence + NM connection types) ----
  property var availBins: ({})
  property var connTypes: ({})

  function binPresent(names) {
    if (typeof names === "string") names = [names]
    if (!Array.isArray(names) || names.length === 0) return true
    for (var i = 0; i < names.length; i++)
      if (root.availBins[names[i]] === true) return true
    return false
  }

  // A capability renders only when every backend it depends on exists. This
  // is what keeps the grid honest on machines without a given subsystem.
  function isAvailable(c) {
    if (!c) return false
    if (c.needsBin && !root.binPresent(c.needsBin)) return false
    if (c.needsAnyBin && !root.binPresent(c.needsAnyBin)) return false
    if (c.needsConn && root.connTypes[c.needsConn] !== true) return false
    return true
  }

  // While the plugin search box is being typed into, the panel's key catcher
  // must stand down so letters/spaces/arrows reach the field instead of
  // triggering grid hotkeys.
  function isSearchFocused() {
    return pluginSearchInput ? pluginSearchInput.activeFocus : false
  }

  readonly property var availableCaps: root.caps.filter(function(c) { return root.isAvailable(c) })

  // Unified quick-settings grid. gridOrder lists SLOT (or cap) ids in the
  // user's persisted order; gridCaps resolves each slot to its current
  // provider through the bindings (architecture spec §4). An empty order means
  // "not yet customized" and uses the curated Tier-1 default layout.
  property var gridOrder: []
  property var bindings: ({})
  property bool editMode: false

  function resolveGrid() {
    var base = Model.orderedGrid(root.availableCaps, root.gridOrder)
    var out = []
    var seen = {}
    for (var i = 0; i < base.length; i++) {
      var slot = base[i]
      var r = Model.resolveSlot(root.availableCaps, root.bindings, slot.slot || slot.id)
      var chosen = r.state === "none"
        ? null
        : (r.state === "single" ? r.option
          : (r.options && r.options.length ? r.options[0] : null))
      if (!chosen || seen[chosen.cap.id]) chosen = { cap: slot, providerId: slot.providerId }
      seen[chosen.cap.id] = true
      out.push(chosen.cap)
    }
    return out
  }

  readonly property var gridCaps: root.resolveGrid()

  // Compact widget contract: four 162px shells, 10px gaps, and the status
  // strip below. This is the explicit widget size from the approved design.
  readonly property real tileTarget: 162
  readonly property real gridTargetWidth:
    root.tileTarget * Model.COLUMNS + Style.space(8) * (Model.COLUMNS - 1)
  readonly property var systemActions: {
    var source = root.caps
    var ids = ["lock", "suspend", "logout", "reboot", "poweroff"]
    var out = []
    for (var i = 0; i < ids.length; i++) {
      var cap = root.capById(ids[i])
      if (cap) out.push(cap)
    }
    return out
  }
  property bool powerMenuOpen: false

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property color hoverFill: bar
    ? Style.hoverFillFor(bar.foreground, Color.accent)
    : "transparent"
  readonly property color selectedFill: bar
    ? Style.selectedFillFor(bar.foreground, Color.accent)
    : "transparent"

  readonly property color tileActiveBg: bar
    ? Qt.alpha(Color.accent, 0.24)
    : Qt.alpha(Color.accent, 0.24)
  readonly property color tileIdleBg: bar
    ? Qt.alpha(bar.foreground, 0.06)
    : "transparent"
  readonly property color liquidColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.42)
  // All surfaces and text derive from Omarchy's live palette. When the active
  // theme changes, the shell updates these bindings without a plugin-specific
  // colour table or a restart.
  readonly property color themeSurface: bar ? Qt.alpha(bar.foreground, 0.075) : "#14161d"
  readonly property color themeSurfaceRaised: bar ? Qt.alpha(bar.foreground, 0.11) : "#1c1e27"
  readonly property color themeBorder: bar ? Qt.alpha(bar.foreground, 0.14) : "#2a2c36"
  readonly property color themeText: bar ? bar.foreground : "#e8e8ee"
  readonly property color themeMutedText: bar ? Qt.alpha(bar.foreground, 0.62) : "#8b8d98"

  // Focus items = grid tiles, then the pencil/done tile. The add palette below
  // is mouse-driven (plugin rows + icon catalog), so the keyboard cursor stays
  // on the grid where every item renders.
  property var focusItems: []

  function rebuildFocus() {
    var g = root.gridCaps
    if (!Array.isArray(g)) g = []
    var items = []
    for (var i = 0; i < g.length; i++)
      items.push({ type: "cap", cap: g[i] })
    var actions = root.systemActions
    for (var j = 0; j < actions.length; j++)
      items.push({ type: "system", cap: actions[j] })
    items.push({ type: root.editMode ? "done" : "edit" })
    root.focusItems = items
    if (root.cursorIndex >= items.length)
      root.cursorIndex = Math.max(0, items.length - 1)
  }

  readonly property int cursorCount: root.focusItems.length

  function itemAt(index) {
    return index >= 0 && index < root.focusItems.length ? root.focusItems[index] : null
  }

  function capAt(index) {
    var it = root.itemAt(index)
    return it ? it.cap || null : null
  }

  function flatIndex(capOrType) {
    for (var i = 0; i < root.focusItems.length; i++) {
      var it = root.focusItems[i]
      if (it.type === "cap" && it.cap && (it.cap === capOrType || it.cap.id === capOrType)) return i
      if (it.type === capOrType) return i
    }
    return -1
  }

  function capById(id) {
    for (var i = 0; i < root.caps.length; i++)
      if (root.caps[i].id === id) return root.caps[i]
    return null
  }

  // ---- State read ----
  property var pollCache: ({})
  // Explicit refresh token: sub-key writes (and even whole-object swaps) on
  // a var-held cache do not reliably re-fire dependent bindings, so every
  // cache write bumps cacheSeq and every cache READ (valueOf/signalOf)
  // subscribes to it. Proven necessary by introspection: prefilled
  // "s-wifi:signal"=55 sat in the cache while delegates still read -1.
  property int cacheSeq: 0

  // Write one cache entry AND notify: sub-key mutation on a var-held object
  // does not reliably re-fire dependent bindings, so publish a fresh object
  // every time. All poll/optimistic writes go through here.
  function storePoll(key, value) {
    var pc = {}
    var old = root.pollCache
    if (old) for (var k in old) pc[k] = old[k]
    pc[String(key)] = value
    root.pollCache = pc
    root.cacheSeq++
  }

  function valueOf(c) {
    var seq = root.cacheSeq // subscribe: refresh whenever the cache publishes
    if (!c) return false
    if (c.backend === "networking") return root.wifiOn
    if (c.backend === "bluetooth") return root.btOn
    if (c.backend === "pipewire") return root.outputVolume
    if (c.backend === "pipewire-mute") return root.outputMuted
    if (c.backend === "pipewire-source-mute") return root.sourceMuted
    if (c.backend === "command") return root.pollCache[c.id]
    return false
  }

  function checked(c) { return c && (root.valueOf(c) === true || root.valueOf(c) === 1) }

  // Signal strength 0..100 for caps with a signalRead (wifi, bluetooth),
  // or -1 when unknown (radio off, nothing connected, not yet polled).
  function signalOf(c) {
    var seq = root.cacheSeq // subscribe: refresh whenever the cache publishes
    // NOTE: no Array.isArray here. Arrays nested in Repeater modelData fail
    // Array.isArray on this stack (proven: ["x"] stringifies but isArr=false
    // when read back from a delegate's cap) while undefined-checks work in
    // every realm. Mechanism unknown; do not "simplify" this back.
    if (!c || c.signalRead === undefined || c.signalRead === null) return -1
    var v = root.pollCache[c.id + ":signal"]
    return isFinite(v) && v >= 0 ? Math.min(100, Math.round(v)) : -1
  }

  // ---- State write ----
  // Closing must always take effect. A global time-based dismiss guard made
  // legitimate Escape/outside-dismiss and panel-to-panel hand-offs unreliable.
  function close() {
    root.notifOpened = false
    root.controller.hide()
  }

  // ---- Corner summon (EdgeSummon.qml hover zones) ----
  // Hover only OPENS, instantly, with zero delay — panels persist under the
  // normal dismiss model so the pointer can travel corner -> card. The two
  // corners switch: opening one side closes the other.
  function summonLeft() {
    if (root.notifOpened) root.notifOpened = false
    if (!root.opened) root.controller.show()
  }
  function summonRight() {
    if (root.opened) root.controller.hide()
    if (!root.notifOpened) {
      root.notifOpened = true
      root.refreshNotifHistory()
    }
  }

  // ---- Notification history (right corner) ----
  property bool notifOpened: false
  property var notifItems: []

  Process {
    id: notifProc
    command: ["python3", "-c", "import json, os, glob\nd = os.path.expanduser('~/.local/state/omarchy/notifications/history')\nfiles = sorted(glob.glob(os.path.join(d, '*.json')), reverse=True)[:10]\nout = []\nfor f in files:\n  try:\n    n = json.load(open(f))\n  except Exception:\n    continue\n  out.append({'app': n.get('app') or '', 'summary': n.get('summary') or '', 'body': n.get('body') or '', 'timestamp': n.get('timestamp') or 0})\nprint(json.dumps(out))"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyNotifHistory(text)
    }
  }

  function applyNotifHistory(output) {
    root.notifItems = Model.parseNotifHistory(output)
  }

  function refreshNotifHistory() {
    if (!notifProc.running) notifProc.running = true
  }

  function applyValue(c, value) {
    if (!c) return

    var target = value === true || value === 1 || value === "1"
    if (c.backend === "networking") { Networking.wifiEnabled = target; return }
    if (c.backend === "bluetooth") {
      if (Bluetooth.defaultAdapter)
        Quickshell.execDetached(["omarchy-bluetooth-power", target ? "on" : "off"])
      return
    }
    if (c.backend === "pipewire") {
      // PipeWire reports 1.0 for the user's normal 100% volume. Respect the
      // capability's declared limits so the visual bar and write path share
      // the exact same 0..100% scale.
      var pipewireMin = isFinite(c.min) ? Number(c.min) : 0
      var pipewireMax = isFinite(c.max) ? Number(c.max) : 1
      if (sink && sink.audio)
        sink.audio.volume = Math.max(pipewireMin, Math.min(pipewireMax, Number(value)))
      return
    }
    if (c.backend === "pipewire-mute") {
      if (sink && sink.audio) sink.audio.muted = target
      return
    }
    if (c.backend === "pipewire-source-mute") {
      if (root.source && root.source.audio) root.source.audio.muted = target
      root.requestPoll("mic-mute")
      return
    }
    if (c.backend === "command") {
      if (c.kind === "slider") {
        if (Array.isArray(c.applyCommand) && c.applyCommand.length)
          Quickshell.execDetached(Model.applyArgv(c.applyCommand, Number(value), c))
        root.requestPoll(c.id)
        return
      }
      if (c.onCommand && c.offCommand) {
        var argv = target ? c.onCommand : c.offCommand
        argv = root.resolveName(argv, c)
        Quickshell.execDetached(argv)
      }
      // Optimistic flip: tap = instant visual state (spec §motions 180ms
      // cross-fade), reconciled by the real poll moments later.
      root.storePoll(c.id, target)
      root.requestPoll(c.id)
    }
  }

  // Toggles backed by a dynamic value (e.g. VPN's active connection name)
  // poll that value through a sibling hidden cap (`nameSlotId`) and inject it
  // into the write command in place of "{name}".
  function resolveName(argv, c) {
    if (!c || !c.nameSlotId || !Array.isArray(argv)) return argv
    var slot = root.capById(c.nameSlotId)
    var name = slot ? String(root.valueOf(slot) || "") : ""
    if (name === "") return argv
    var out = []
    for (var i = 0; i < argv.length; i++) {
      var part = String(argv[i])
      out.push(part.indexOf("{name}") >= 0 ? part.split("{name}").join(name) : part)
    }
    return out
  }

  // Actions are plain when no confirm gate exists; confirmed actions always
  // go through the explicit confirm step first.
  function runAction(c, force) {
    if (!c) return
    if (c.confirm && !force) { root.pendingConfirm = c; return }
    if (c.detail) {
      root.close()
      Quickshell.execDetached(["omarchy-shell", "shell", "toggle", c.detail])
      return
    }
    if (c.runCommand && c.runCommand.length)
      Quickshell.execDetached(c.runCommand)
  }

  // The inline confirm step for destructive/expensive operations.
  property var pendingConfirm: null

  function confirmAccept() {
    var c = root.pendingConfirm
    root.pendingConfirm = null
    if (c) root.runAction(c, true)
  }

  function confirmReject() {
    root.pendingConfirm = null
  }

// Invoking a tile: toggles ALWAYS flip on tap (spec: tap = flip); slider and
// action tiles open/run; deepening commands live behind their chevron, which
// opens on long-press (mouse/touch) or the "o" key. Confirmed actions gate.
  function activate(c) {
    if (!c || root.pendingConfirm) return
    if (c.kind === "toggle" || c.kind === "command-mute") {
      root.applyValue(c, !root.checked(c)); return
    }
    root.runAction(c)
  }

  // Mouse-primary action: show the provider's own UI whenever it exists.
  // Providers without a panel retain their ordinary action as a safe fallback.
  function openPrimary(c) {
    if (!c || root.pendingConfirm) return
    if (c.detail) { root.runAction(c); return }
    root.activate(c)
  }

  // Mouse-secondary action: flip a declared state control. This is capability
  // data, not a provider-id switch: any plugin can name a sibling cap (for
  // example Volume -> Mute), while ordinary toggle caps toggle themselves.
  function toggleSecondary(c) {
    if (!c || root.pendingConfirm) return
    var target = c.secondaryCapId ? root.capById(c.secondaryCapId) : c
    if (target && (target.kind === "toggle" || target.kind === "command-mute")) root.activate(target)
  }

  // Long-press / "o" key: expand a detail-capable tile's panel without
  // triggering its tap semantics.
  function expand(c) {
    if (!c || root.pendingConfirm) return
    if (c.detail) root.runAction(c)
  }

  function expandCurrent() {
    if (root.pendingConfirm) { root.confirmAccept(); return }
    if (!root.cursorActive) return
    var it = root.itemAt(root.cursorIndex)
    if (it && it.type === "cap") root.expand(it.cap)
  }

  function details(c) {
    if (!c) return
    if (c.detail) root.runAction(c)
    else if (c.kind === "action" || c.kind === "launcher" || c.kind === "toggle" || c.kind === "slider") root.runAction(c)
  }

  // ---- Backend availability probe ----
  // Determines which capability backends actually exist on this machine (bin
  // on PATH, NetworkManager connection types) so unavailable caps hide
  // instead of rendering broken tiles. Rerun each open; it is a single
  // subprocess.
  Process {
    id: availProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyAvailability(text)
    }
  }

  function probeBinNames() {
    var set = {}
    for (var i = 0; i < root.caps.length; i++) {
      var c = root.caps[i]
      if (typeof c.needsBin === "string" && c.needsBin) set[c.needsBin] = true
      if (Array.isArray(c.needsAnyBin))
        for (var k = 0; k < c.needsAnyBin.length; k++)
          if (c.needsAnyBin[k]) set[c.needsAnyBin[k]] = true
    }
    var names = []
    for (var b in set) names.push(b)
    return names.join(" ")
  }

  function startAvailabilityProbe() {
    if (availProc.running) return
    availProc.command = ["bash", "-c",
      "{ for b in " + root.probeBinNames() + "; do command -v \"$b\" >/dev/null 2>&1 && echo BIN:$b; done; " +
      "nmcli -t -f TYPE con show 2>/dev/null | sort -u | sed 's/^/CONN:/'; }"]
    availProc.running = true
  }

  function applyAvailability(output) {
    var bins = {}
    var cons = {}
    var lines = String(output || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i]
      if (l.indexOf("BIN:") === 0) bins[l.substring(4).trim()] = true
      else if (l.indexOf("CONN:") === 0) cons[l.substring(5).trim()] = true
    }
    root.availBins = bins
    root.connTypes = cons
  }

  // ---- Command poller: one Process, queued reads ----
  property var pollQueue: []
  property var pollTarget: null

  Process {
    id: pollerProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPollOutput(text)
    }
  }

  function applyPollOutput(output) {
    var entry = root.pollTarget
    root.pollTarget = null
    if (entry && entry.cap) {
      if (entry.sig && Array.isArray(entry.cap.signalRead))
        root.storePoll(entry.cap.id + ":signal", Model.applySignal(entry.cap, output))
      else if (!entry.sig && Array.isArray(entry.cap.read))
        root.storePoll(entry.cap.id, Model.applyRead(entry.cap, output))
    }
    Qt.callLater(root.nextPoll)
  }

  function nextPoll() {
    var entry = root.pollQueue.shift()
    if (!entry || !entry.cap) { pollerProc.running = false; return }
    var cmd = entry.sig ? entry.cap.signalRead : entry.cap.read
    if (!Array.isArray(cmd)) { Qt.callLater(root.nextPoll); return }
    root.pollTarget = entry
    pollerProc.command = cmd
    if (!pollerProc.running) pollerProc.running = true
  }

  function requestPoll(id) {
    var cap = root.capById(id)
    if (!cap) return
    var carry = []
    for (var i = 0; i < root.pollQueue.length; i++)
      if (!root.pollQueue[i].cap || root.pollQueue[i].cap.id !== id) carry.push(root.pollQueue[i])
    if (Array.isArray(cap.read)) carry.push({ cap: cap, sig: false })
    if (Array.isArray(cap.signalRead) && root.isAvailable(cap)) carry.push({ cap: cap, sig: true })
    root.pollQueue = carry
    if (!pollerProc.running) Qt.callLater(root.nextPoll)
  }

  function withPollable() {
    var out = []
    for (var i = 0; i < root.caps.length; i++) {
      var c = root.caps[i]
      if (c.backend !== "command" || !root.isAvailable(c)) continue
      if (Array.isArray(c.read)) out.push({ cap: c, sig: false })
      if (Array.isArray(c.signalRead)) out.push({ cap: c, sig: true })
    }
    return out
  }

  Timer {
    id: pollCycle
    // The panel is only open briefly, so external bar changes visibly arrive
    // within half a second without background polling.
    interval: 400
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: {
      if (pollerProc.running) return
      root.pollQueue = root.withPollable()
      Qt.callLater(root.nextPoll)
    }
  }

  // ---- Live system telemetry for the bottom strip ----
  // Read kernel state rather than rendering mock figures. The command is
  // intentionally local, bounded, and runs only while the panel is visible.
  property var systemTelemetry: ({ batteryPercent: -1, batteryState: "", batteryWatts: -1, bluetoothConnected: false })
  readonly property int audioPercent: Math.max(0, Math.min(100, Math.round(root.outputVolume * 100)))
  readonly property bool bluetoothConnected: !!(root.systemTelemetry && root.systemTelemetry.bluetoothConnected)
  property var weatherReport: ({ temperature: "", wind: "", location: "" })

  Process {
    id: telemetryProc
    command: ["python3", "-c", "import json, glob, os, subprocess\nout={'batteryPercent':-1,'batteryState':'','batteryWatts':-1,'bluetoothConnected':False}\nfor p in glob.glob('/sys/class/power_supply/BAT*'):\n  def rd(name):\n    try:\n      return open(os.path.join(p,name)).read().strip()\n    except Exception:\n      return ''\n  try: out['batteryPercent']=int(rd('capacity'))\n  except Exception: pass\n  out['batteryState']=rd('status')\n  try:\n    power=float(rd('power_now'))\n    if power >= 0: out['batteryWatts']=round(power/1000000.0,1)\n  except Exception: pass\n  break\ntry:\n  out['bluetoothConnected']=bool(subprocess.check_output(['bluetoothctl','devices','Connected'], stderr=subprocess.DEVNULL, text=True, timeout=0.25).strip())\nexcept Exception: pass\nprint(json.dumps(out))"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applySystemTelemetry(text)
    }
  }

  function applySystemTelemetry(output) {
    var next = Model.parseJson(output)
    if (!next || typeof next !== "object") return
    root.systemTelemetry = next
  }

  Timer {
    interval: 500
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: { if (!telemetryProc.running) telemetryProc.running = true }
  }

  // Weather belongs in today's summary. It is intentionally not part of the
  // 500ms local poll loop: this uses Omarchy's configured weather provider,
  // may contact the network, and retains the last good reading on failure.
  Process {
    id: weatherProc
    command: ["bash", "-c", "omarchy-weather-status 2>/dev/null || true"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyWeather(text)
    }
  }

  function applyWeather(output) {
    var parts = String(output || "").trim().split(" · ")
    if (parts.length < 3 || parts[0] === "Weather unavailable") return
    root.weatherReport = {
      location: parts[0],
      temperature: String(parts[1]).replace(/^Temp\s+/, ""),
      wind: String(parts[2]).replace(/^Wind\s+/, "")
    }
  }

  Timer {
    interval: 15 * 60 * 1000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: { if (!weatherProc.running) weatherProc.running = true }
  }

  // ---- Discovery: external control-center.json files ----
  property var externalFiles: []
  property var externalCapsAccum: []
  property string externalFileSource: ""

  // Stage 1: list every qualified file under the plugins dir.
  Process {
    id: externalProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyFileFound(text)
    }
  }

  function startExternalDiscovery() {
    externalProc.command = ["find",
      Quickshell.env("HOME") + "/.config/omarchy/plugins",
      "-maxdepth", "3", "-name", "control-center.json", "-print"]
    if (!externalProc.running) externalProc.running = true
  }

  function applyFileFound(output) {
    root.externalFiles = String(output || "").split("\n").filter(function(s) { return s.trim() !== "" })
    root.externalCapsAccum = []
    root.readNextExternalFile()
  }

  // Stage 2: read one file at a time through its own process so a malformed
  // plugin file (or a slow disk) can never wedge the poller or the UI.
  Process {
    id: externalCatProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyExternalFile(text)
    }
  }

  function readNextExternalFile() {
    if (root.externalFiles.length === 0) {
      root.externalCaps = root.externalCapsAccum
      root.refreshPlugins()
      return
    }
    root.externalFileSource = root.externalFiles.shift()
    externalCatProc.command = ["cat", root.externalFileSource]
    if (!externalCatProc.running) externalCatProc.running = true
  }

  function applyExternalFile(output) {
    var source = root.externalFileSource
    var lastSlash = source.lastIndexOf("/")
    var base = lastSlash > 0 ? source.substring(0, lastSlash) : ""
    var caps = Model.parseExternalCaps(output, source)
    for (var i = 0; i < caps.length; i++) {
      if (caps[i].component) caps[i].component = base + "/" + String(caps[i].component)
    }
    root.externalCapsAccum.push.apply(root.externalCapsAccum, caps)
    root.readNextExternalFile()
  }

  // @@EXTERNAL_READY@@

  Process {
    id: pluginProc
    command: ["omarchy", "plugin", "list", "--json"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyPluginListing(text)
    }
  }

  function applyPluginListing(output) {
    var list = Model.parseJson(output)
    if (!Array.isArray(list)) return
    root.pluginList = list
    root.rebuildAutoTiles()
  }

  // Manifest scan (13a §6): one python3 pass over the plugin roots emitting
  // [{ id, displayName, description, category, aliases[], hasCc }]. A broken
  // manifest never fails the whole scan (per-file try/except inside).
  property var pluginList: null
  property var manifestMap: null

  Process {
    id: manifestProc
    command: ["python3", "-c", "import json, os\nroots = [os.path.expanduser('~/.config/omarchy/plugins'), '/usr/share/omarchy/shell/plugins']\nseen = set()\nout = []\nfor r in roots:\n  for p, dn, fn in os.walk(r):\n    if 'manifest.json' not in fn: continue\n    try:\n      d = json.load(open(os.path.join(p, 'manifest.json')))\n    except Exception:\n      continue\n    pid = d.get('id')\n    if not pid or pid in seen: continue\n    seen.add(pid)\n    bw = d.get('barWidget') or {}\n    out.append({'id': pid, 'displayName': bw.get('displayName') or '', 'description': bw.get('description') or '', 'category': bw.get('category') or '', 'aliases': [a for a in (bw.get('aliases') or []) if isinstance(a, str)], 'hasCc': os.path.exists(os.path.join(p, 'control-center.json'))})\nprint(json.dumps(out))"]

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyManifests(text)
    }
  }

  function applyManifests(output) {
    root.manifestMap = Model.parseManifests(output)
    root.rebuildAutoTiles()
  }

  function rebuildAutoTiles() {
    if (!root.pluginList) return
    // Claimed = built-in/external caps' details ONLY. Never derive this from
    // the assembled caps: those already contain previous auto-tiles, which
    // would make every rebuild claim (and wipe) its own output.
    var used = {}
    var ext = root.externalCaps || []
    for (var i = 0; i < ext.length; i++)
      if (ext[i] && ext[i].detail) used[ext[i].detail] = true
    root.autoCaps = Model.buildAutoTiles(root.pluginList, used, root.manifestMap || {})
  }

  function refreshPlugins() {
    if (!pluginProc.running) pluginProc.running = true
    if (!manifestProc.running) manifestProc.running = true
  }

  onCapsChanged: root.rebuildFocus()
  onAvailableCapsChanged: root.rebuildFocus()
  onGridOrderChanged: root.rebuildFocus()
  onBindingsChanged: root.rebuildFocus()
  onEditModeChanged: { if (!root.editMode) root.closeSheet(); root.cursorIndex = 0; root.pendingConfirm = null; root.rebuildFocus() }
  Component.onCompleted: {
    root.loadConfig()
    root.startAvailabilityProbe()
    root.startExternalDiscovery()
    root.refreshPlugins()
  }

  onOpenedChanged: {
    if (root.opened) {
      root.cursorActive = false
      root.cursorIndex = 0
      root.startAvailabilityProbe()
      root.startExternalDiscovery()
      root.refreshPlugins()
    } else {
      // Closing a session resets transient editor state so the next open
      // never inherits a half-finished edit mode / search / picker state.
      root.pendingConfirm = null
      root.sheetInfo = null
      root.editMode = false
      root.pluginSearch = ""
      root.selectedPlugin = ""
      root.pluginIconMode = "default"
      root.addFilter = "first"
    }
  }

  // ---- Discovery: external control-center.json files ----

  // ---- Grid persistence (architecture spec §4) ----
// Preferred store is the spec config file: gridOrder + per-slot bindings.
// The legacy control-center-grid.json (order only) still loads unchanged as a
// migration fallback; every save from now on writes the new file.
  readonly property string configPath: Quickshell.env("HOME")
    + "/.config/omarchy/state/control-center-config.json"
  readonly property string legacyGridPath: Quickshell.env("HOME")
    + "/.config/omarchy/state/control-center-grid.json"

  Process {
    id: configProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyConfigLoaded(text)
    }
  }

  function loadConfig() {
    configProc.command = ["cat", root.configPath]
    if (!configProc.running) configProc.running = true
  }

  function applyConfigLoaded(output) {
    var cfg = Model.normalizeConfig(Model.parseJson(output))
    if (cfg.gridOrder && cfg.gridOrder.length) {
      root.gridOrder = cfg.gridOrder
      root.bindings = cfg.bindings
      return
    }
    // New-format store absent/empty: keep the exact order saved by the legacy
    // layout, then upgrade the file on the next edit.
    gridProc.command = ["cat", root.legacyGridPath]
    if (!gridProc.running) gridProc.running = true
  }

  Process {
    id: gridProc

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyGridLoaded(text)
    }
  }

  function applyGridLoaded(output) {
    var obj = Model.parseJson(output)
    if (obj && Array.isArray(obj.order))
      root.gridOrder = obj.order.filter(function(x) { return typeof x === "string" && x !== "" })
  }

  // Persist the whole config through one serialized writer. A rapid sequence
  // of drag/picker edits must not race detached processes or leave a partial
  // JSON file after an interrupted write.
  property string queuedConfigPayload: ""
  Process {
    id: configWriteProc
    onExited: function() {
      if (root.queuedConfigPayload === "") return
      var nextPayload = root.queuedConfigPayload
      root.queuedConfigPayload = ""
      root.writeConfigPayload(nextPayload)
    }
  }

  function writeConfigPayload(payload) {
    configWriteProc.command = ["python3", "-c",
      "import json, os, sys, tempfile\np=sys.argv[1]\ndata=json.loads(sys.argv[2])\nd=os.path.dirname(p)\nos.makedirs(d, exist_ok=True)\nfd,tmp=tempfile.mkstemp(prefix='.control-center-', dir=d)\ntry:\n    with os.fdopen(fd, 'w') as f:\n        json.dump(data, f, indent=2)\n        f.write('\\n')\n        f.flush()\n        os.fsync(f.fileno())\n    os.replace(tmp, p)\nexcept Exception:\n    try: os.unlink(tmp)\n    except OSError: pass\n    raise",
      root.configPath, payload]
    configWriteProc.running = true
  }

  function persistGrid() {
    var payload = JSON.stringify({ version: 1, gridOrder: root.gridOrder, bindings: root.bindings })
    if (configWriteProc.running) {
      root.queuedConfigPayload = payload
      return
    }
    root.writeConfigPayload(payload)
  }

  function persistBindings() {
    root.persistGrid()
  }

  function toggleEditMode() {
    if (root.pendingConfirm) return
    root.editMode = !root.editMode

  }

  function removeCap(c) {
    if (!c || root.pendingConfirm) return

    root.gridOrder = root.gridOrder.filter(function(x) { return x !== c.id })
    root.persistGrid()
  }

  // Reorder the focused tile one slot. Before the grid is ever customized
  // (gridOrder empty) the curated default order is materialized first, so the
  // user's very first move fixes the whole arrangement.
  function swapGridTile(dir) {
    if (!root.editMode || root.pendingConfirm) return
    var it = root.itemAt(root.cursorIndex)
    if (!it || it.type !== "cap") return
    var order = root.gridOrder.slice()
    if (order.length === 0)
      order = root.gridCaps.map(function(c) { return c.id })
    var idx = order.indexOf(it.cap.id)
    var nidx = idx + dir
    if (idx < 0 || nidx < 0 || nidx >= order.length) return
    var t = order[idx]; order[idx] = order[nidx]; order[nidx] = t
    root.gridOrder = order
    root.persistGrid()
    var movedId = it.cap.id
    Qt.callLater(function() {
      var fi = root.flatIndex(movedId)
      if (fi >= 0) root.cursorIndex = fi
    })
  }

  // ---- Interact slider drag ----
  // Slider tiles are real controls: press + drag vertically inside the tile
  // writes the value directly (volume -> Pipewire sink, brightness ->
  // brightnessctl). The liquid follows live; a plain tap still opens the
  // detail panel. A completed drag suppresses the tap so panels don't pop
  // open after adjusting.
  property var sliderDrag: null
  property bool sliderDragActive: false

  function dragSetValue(cap, mouseY, height) {
    if (!cap || height <= 0) return
    var lo = isFinite(cap.min) ? Number(cap.min) : 0
    var hi = isFinite(cap.max) ? Number(cap.max) : 100
    var frac = Math.max(0, Math.min(1, 1 - mouseY / height))
    var value = lo + frac * (hi - lo)
    if (cap.backend === "pipewire") {
      if (sink && sink.audio) sink.audio.volume = value
      return
    }
    if (cap.backend === "command" && cap.kind === "slider") {
      root.storePoll(cap.id, value)
      root.applyValue(cap, value)
    }
  }

  // ---- Mouse-drag reorder (edit mode) ----
  // Dragging a tile lifts a ghost that follows the cursor; on release its
  // center is mapped back onto the fixed columns grid to find the target
  // slot, then the gridOrder is permuted and persisted.
  property string dragSrcId: ""
  property int dragSrcIndex: -1
  property string dragGhostGlyph: ""

  function tileCellWidth() {
    return (tileGrid.width - Style.space(8) * (tileGrid.columns - 1)) / tileGrid.columns
  }

  function gridCapsIndex(id) {
    for (var i = 0; i < root.gridCaps.length; i++)
      if (root.gridCaps[i].id === id) return i
    return -1
  }

  function prepareDrag(id, tile) {
    root.dragSrcId = id
    root.dragSrcIndex = root.gridCapsIndex(id)
    root.dragGhostGlyph = tile.cap ? (tile.displayGlyph || tile.cap.glyph || "") : ""
    var g = tile.mapToItem(tileGrid, 0, 0)
    dragGhostItem.x = g.x
    dragGhostItem.y = g.y
    dragGhostItem.width = tile.width
    dragGhostItem.height = tile.height
    dragGhostItem.visible = true
  }

  function finishDrag() {
    var id = root.dragSrcId
    dragGhostItem.visible = false
    root.dragSrcId = ""
    root.dragSrcIndex = -1
    if (id === "") return
    var c = dragGhostItem.mapToItem(tileGrid, dragGhostItem.width / 2, dragGhostItem.height / 2)
    var cell = root.tileCellWidth() + Style.space(8)
    var col = Math.round(c.x / cell)
    var row = Math.round(c.y / cell)
    var target = row * tileGrid.columns + col
    var n = root.gridCaps.length
    if (target >= n) target = n - 1
    if (target < 0) target = 0
    var src = root.gridCapsIndex(id)
    if (src < 0 || target === src) return
    root.moveTileTo(src, target)
  }

  function moveTileTo(srcIdx, dstIdx) {
    if (srcIdx < 0 || srcIdx >= root.gridCaps.length) return
    var order = root.gridOrder.slice()
    if (order.length === 0)
      order = root.gridCaps.map(function(c) { return c.id })
    if (srcIdx >= order.length) return
    var id = order[srcIdx]
    order.splice(srcIdx, 1)
    if (dstIdx > order.length) dstIdx = order.length
    order.splice(dstIdx, 0, id)
    root.gridOrder = order
    root.persistGrid()
    Qt.callLater(function() {
      var fi = root.flatIndex(id)
      if (fi >= 0) root.cursorIndex = fi
    })
  }

  function addCap(c) {
    if (!c || root.pendingConfirm || root.gridOrder.indexOf(c.id) >= 0) return

    var order = root.gridOrder.slice()
    order.push(c.id)
    root.gridOrder = order
    root.persistGrid()
  }

  // ---- Plugin manager (add tiles) ----
  // The add palette lists plugins (not flat caps): filter first/third party,
  // pick a plugin, add its tiles, and choose its icon scheme — the plugin's
  // default icons, or your own icons applied as a contiguous sequence over its
  // tiles (architecture: every tile is a plugin capability).
  property string addFilter: "first"
  property string pluginSearch: ""
  property string selectedPlugin: ""
  property int iconSeqIndex: 0
  property string pluginIconMode: "default"
  readonly property var providerGroups: root.editMode ? Model.pluginGroups(root.caps, root.gridOrder) : []
  readonly property var filteredProviders: root.filterByParty()
  readonly property var selectedGroup: root.groupByProvider(root.selectedPlugin)
  readonly property var iconCatalog: Model.allIcons()

  // addFilter is a mutually-exclusive toggle pair (a radio, never both on):
  //   "first" -> first-party plugins only, "third" -> third-party only,
  //   ""      -> cleared (neither chip lit) -> show every plugin.
  // Search is a plain case-insensitive substring over the plugin label.
  function filterByParty() {
    var out = []
    var q = root.pluginSearch.trim().toLowerCase()
    for (var i = 0; i < root.providerGroups.length; i++) {
      var g = root.providerGroups[i]
      if (root.addFilter !== "" && g.party !== root.addFilter) continue
      if (q !== "" && g.label.toLowerCase().indexOf(q) === -1) continue
      out.push(g)
    }
    return out
  }

  function toggleParty(party) {
    if (root.addFilter === party) root.addFilter = ""
    else root.addFilter = party
    root.selectedPlugin = ""
  }

  function groupByProvider(pid) {
    for (var i = 0; i < root.providerGroups.length; i++)
      if (root.providerGroups[i].providerId === pid) return root.providerGroups[i]
    return null
  }

  function selectPlugin(providerId) {
    if (root.selectedPlugin === providerId) { root.selectedPlugin = ""; return }
    root.selectedPlugin = providerId
    root.iconSeqIndex = 0
    var g = root.groupByProvider(providerId)
    root.pluginIconMode = (g && Model.pluginUsesCustomIcons(providerId, g.caps, root.bindings)) ? "custom" : "default"
  }

  function setPluginIconMode(mode) {
    if (mode !== "custom" && mode !== "default") return
    root.pluginIconMode = mode
    var g = root.groupByProvider(root.selectedPlugin)
    if (mode !== "default" || !g) return
    // Default scheme: drop every icon binding the plugin's slots carry so the
    // plugin's own manifest glyphs win again.
    for (var i = 0; i < g.caps.length; i++) {
      var slot = String(g.caps[i].slot || g.caps[i].id || "")
      if (slot !== "") root.setBinding(slot, { icon: "" })
    }
  }

  // Assign a catalog icon to the active slot of the plugin's contiguous tile
  // sequence; picking any icon switches that plugin to the custom scheme.
  function setPluginIcon(key) {
    var g = root.groupByProvider(root.selectedPlugin)
    if (!g || !g.caps.length || !key) return
    if (root.iconSeqIndex < 0 || root.iconSeqIndex >= g.caps.length) root.iconSeqIndex = 0
    var slot = String(g.caps[root.iconSeqIndex].slot || g.caps[root.iconSeqIndex].id || "")
    if (slot === "") return
    root.pluginIconMode = "custom"
    root.setBinding(slot, { icon: key })
    if (root.iconSeqIndex < g.caps.length - 1) root.iconSeqIndex++
  }

  // The icon a plugin tile currently wears: its slot binding when set;
  // otherwise the plugin's own manifest glyph — EXCEPT in "My icons" mode,
  // where unset slots stay icon-less by default until the user picks one.
  function pluginSeqGlyph(cap) {
    if (!cap) return ""
    var slot = String(cap.slot || cap.id || "")
    var b = root.bindings && root.bindings[slot]
    var g = b ? Model.homeIcon(b.icon) : null
    if (g) return g
    if (root.pluginIconMode === "custom") return ""
    return cap.glyph || ""
  }

  // Number of a plugin's tiles that are already placed on the grid.
  function groupOnGridCount(g) {
    if (!g || !g.caps) return 0
    var n = 0
    for (var i = 0; i < g.caps.length; i++) if (g.caps[i].onGrid) n++
    return n
  }

  // Catalog key currently bound to the active slot of the icon sequence.
  function pluginActiveSlotIconKey() {
    var g = root.groupByProvider(root.selectedPlugin)
    if (!g || !g.caps.length) return ""
    if (root.iconSeqIndex < 0 || root.iconSeqIndex >= g.caps.length) return ""
    var slot = String(g.caps[root.iconSeqIndex].slot || g.caps[root.iconSeqIndex].id || "")
    var b = root.bindings && root.bindings[slot]
    return (b && b.icon) ? b.icon : ""
  }

  // ---- Provider / icon picker sheet (architecture spec §4) ----
  // Long-press a tile in edit mode to choose which provider owns the slot and
  // which catalog icon it wears. Choices persist immediately into bindings,
  // then resolveGrid re-renders the tile with the chosen provider's cap.
  property var sheetInfo: null
  readonly property bool sheetOpen: root.sheetInfo !== null

  function openSheetFor(cap) {
    if (!cap || !root.editMode || root.pendingConfirm || root.sheetOpen) return
    var slot = String(cap.slot || cap.id || "")
    var providers = Model.providersForSlot(root.availableCaps, slot)
    if (!providers.length) return
    var keys = Model.SLOT_ICONS[slot] || []
    var icons = []
    for (var i = 0; i < keys.length; i++) {
      var g = Model.homeIcon(keys[i])
      if (g) icons.push({ key: keys[i], glyph: g })
    }
    if (!icons.length) icons.push({ key: "app.boxes", glyph: Model.homeIcon("app.boxes") })
    // 13a §4: native caps offer both icon sources (default in-house);
    // launcher (generic-tier) tiles only ever have the resolved in-house
    // icon, so the source radio is not shown for them at all.
    var sources = (cap.kind === "launcher") ? ["in-house"] : ["in-house", "plugin"]
    root.sheetInfo = { slot: slot, title: String(cap.title || slot), providers: providers, icons: icons,
      iconSources: sources, pluginGlyph: String(cap.glyph || "") }
  }

  function closeSheet() {
    root.sheetInfo = null
  }

  // QML has no object identity for mutation detection: replace bindings with a
  // fresh object so onBindingsChanged fires.
  function setBinding(slot, patch) {
    var b = (root.bindings && slot && root.bindings[slot]) ? root.bindings[slot] : { provider: "", icon: "" }
    if (patch.provider !== undefined) b.provider = patch.provider
    if (patch.icon !== undefined) b.icon = patch.icon
    if (patch.iconSource !== undefined) b.iconSource = patch.iconSource === "plugin" ? "plugin" : ""
    var next = {}
    for (var k in root.bindings) if (root.bindings.hasOwnProperty(k)) next[k] = root.bindings[k]
    next[slot] = b
    root.bindings = next
    root.persistBindings()
  }

  function sheetSelectProvider(providerId) {
    if (!root.sheetInfo || !providerId) return
    root.setBinding(root.sheetInfo.slot, { provider: providerId })
    root.closeSheet()
  }

  function sheetSelectIcon(iconKey) {
    if (!root.sheetInfo || !iconKey) return
    root.setBinding(root.sheetInfo.slot, { icon: iconKey })
    root.closeSheet()
  }

  // 13a §4 third field: icon source. Switching source keeps the sheet open
  // (it is a mode, not a final choice); in-house is the default.
  function sheetSelectIconSource(source) {
    if (!root.sheetInfo || !source) return
    root.setBinding(root.sheetInfo.slot, { iconSource: source })
  }

  function sheetActiveIconSource() {
    if (!root.sheetInfo) return "in-house"
    var b = root.bindings && root.bindings[root.sheetInfo.slot]
    return (b && b.iconSource === "plugin") ? "plugin" : "in-house"
  }

  function sheetActiveProvider() {
    if (!root.sheetInfo) return ""
    var b = root.bindings && root.bindings[root.sheetInfo.slot]
    if (b && b.provider) return b.provider
    return root.sheetInfo.providers.length ? root.sheetInfo.providers[0].providerId : ""
  }

  function sheetActiveGlyph() {
    if (!root.sheetInfo) return ""
    var b = root.bindings && root.bindings[root.sheetInfo.slot]
    if (b) {
      var g = Model.homeIcon(b.icon)
      if (g) return g
    }
    return root.sheetInfo.providers.length ? (root.sheetInfo.providers[0].cap.glyph || "") : ""
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "\uF00A"
    onPressed: function(b) {
      root.toggle()
    }

    PanelToolTip {
      visible: button.tooltipHovered
      text: "Control center"
      fontFamily: root.bar.fontFamily
    }
  }

  // ---- Keyboard + cursor ----
  function moveGrid(dx, dy) {
    if (root.cursorCount < 1) return
    var gridCount = root.gridCaps.length
    var systemCount = root.systemActions.length
    var systemStart = gridCount
    var systemEnd = systemStart + systemCount
    var current = root.cursorIndex
    if (current >= systemStart && current < systemEnd) {
      var systemIndex = current - systemStart
      if (dx !== 0) root.cursorIndex = systemStart + ((systemIndex + dx + systemCount) % systemCount)
      else if (dy < 0) root.cursorIndex = Math.max(0, gridCount - tileGrid.columns + Math.min(systemIndex, tileGrid.columns - 1))
      return
    }
    if (dy > 0 && systemCount > 0 && current >= Math.max(0, gridCount - tileGrid.columns)) {
      root.cursorIndex = systemStart + Math.min(current % tileGrid.columns, systemCount - 1)
      return
    }
    root.cursorIndex = Model.moveCursor(current, dx, dy, gridCount, tileGrid.columns)
  }

  // Enter/space activates the focused item: flips a toggle, opens a panel,
  // enters/exits edit mode, or adds a picked tile. While a confirm step is
  // pending, Enter answers it instead.
  function activateCurrent() {
    if (root.sheetOpen) { root.closeSheet(); return }
    if (root.pendingConfirm) { root.confirmAccept(); return }
    if (!root.cursorActive) return
    var it = root.itemAt(root.cursorIndex)
    if (!it) return
    if (it.type === "edit" || it.type === "done") { root.toggleEditMode(); return }
    if (it.type === "cap") { root.openPrimary(it.cap); return }
    if (it.type === "system") { root.runAction(it.cap); return }
    if (it.type === "add") { root.addCap(it.cap); return }
  }

  function removeCurrent() {
    if (!root.editMode || root.pendingConfirm) return
    var it = root.itemAt(root.cursorIndex)
    if (it && it.type === "cap") {
      root.removeCap(it.cap)
      if (root.cursorIndex >= root.cursorCount)
        root.cursorIndex = Math.max(0, root.cursorCount - 1)
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    centerOnBar: true
    contentWidth: panel.fittedContentWidth(
      Math.round(root.gridTargetWidth + panel.padding * 2 + Style.space(24)))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {

        if (root.pendingConfirm) return
        if (root.isSearchFocused()) return
        if (!root.cursorActive) { root.cursorActive = true; return }
        root.moveGrid(dx, dy)
      }
      onActivateRequested: function() {

        if (!root.isSearchFocused()) root.activateCurrent()
      }
      onCloseRequested: {
        if (root.sheetOpen) { root.closeSheet(); return }
        if (root.pendingConfirm) root.confirmReject()
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(t) {
        if (root.isSearchFocused()) return

        if (root.pendingConfirm) {
          if (t === " ") root.confirmAccept()
          return
        }
        if (t === " ") root.activateCurrent()
        else if (t === "o" || t === "O") root.expandCurrent()
        else if (t === "e" || t === "E" || t === "d" || t === "D") root.toggleEditMode()
        else if (t === "r" || t === "R" || t === "x" || t === "X") root.removeCurrent()
        else if (t === "[" || t === "{") root.swapGridTile(-1)
        else if (t === "]" || t === "}") root.swapGridTile(1)
      }

      ScrollView {
        id: scrollArea
        anchors.fill: parent
        clip: true
        ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
        ScrollBar.vertical.policy: column.implicitHeight > height ? ScrollBar.AsNeeded : ScrollBar.AlwaysOff
        Binding {
          target: scrollArea.contentItem
          property: "interactive"
          // Keep the panel body scrollable only when edit-mode content actually
          // overflows; otherwise drag-to-reorder stays exclusive to the tiles.
          value: column.implicitHeight > scrollArea.height
        }

      Column {
        id: column
        x: Style.space(12)
        width: scrollArea.availableWidth - Style.space(24)
        spacing: Style.space(12)

        // ---------- The quick-settings grid ----------
        Grid {
          id: tileGrid
          columns: Model.COLUMNS
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: root.gridCaps
            delegate: QuickTile {
              required property var modelData
              cap: modelData
              globalIndex: root.flatIndex(modelData.id)
              cellWidth: (tileGrid.width - Style.space(8) * (tileGrid.columns - 1)) / tileGrid.columns
            }
          }

        }

        // ---------- Bottom system strip from the supplied mockup ----------
        StatusStrip { width: parent.width }

        // ---------- Confirm step for destructive actions ----------
        Item {
          visible: root.pendingConfirm !== null
          width: parent.width
          implicitHeight: confirmRow.implicitHeight

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Qt.alpha(Color.urgent, 0.15)
          }

          Row {
            id: confirmRow
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: root.pendingConfirm && root.pendingConfirm.confirm
                ? root.pendingConfirm.confirm : ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              wrapMode: Text.WordWrap
              width: parent.width - yesBtn.width - noBtn.width - Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
            }

            Item {
              id: yesBtn
              width: Style.space(46)
              implicitHeight: Style.space(30)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: Color.urgent
              }
              Text {
                textFormat: Text.PlainText
                text: "Yes"
                color: Color.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                font.bold: true
                anchors.centerIn: parent
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.confirmAccept()
              }
            }

            Item {
              id: noBtn
              width: Style.space(46)
              implicitHeight: Style.space(30)

              Rectangle {
                anchors.fill: parent
                radius: Style.cornerRadius
                color: root.tileIdleBg
              }
              Text {
                textFormat: Text.PlainText
                text: "No"
                color: root.bar.foreground
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.body
                anchors.centerIn: parent
              }
              MouseArea {
                anchors.fill: parent
                onClicked: root.confirmReject()
              }
            }
          }
        }

        // ---------- Plugin manager / add tiles (edit mode) ----------
        // Every tile is a plugin capability, so the add palette is a plugin
        // manager: filter first/third party, pick a plugin, add its tiles, and
        // choose its icon scheme — default plugin icons, or your own icons
        // applied as a contiguous sequence over its tiles.
        PanelSeparator {
          foreground: root.bar.foreground
          visible: root.editMode
        }

        PanelSectionHeader {
          text: "ADD PLUGINS"
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          visible: root.editMode
        }

        // Search: plain substring over plugin names.
        Row {
          id: searchRow
          visible: root.editMode
          width: parent.width
          spacing: Style.space(6)

          Rectangle {
            id: searchField
            width: searchRow.width
            implicitHeight: Style.space(38)
            radius: Style.space(10)
            color: root.themeSurface
            border.width: 1
            border.color: pluginSearchInput.activeFocus ? Color.accent : root.themeBorder

            Text {
              textFormat: Text.PlainText
              text: "\uF002"
              color: Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: 18
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
            }

            TextInput {
              id: pluginSearchInput
              text: root.pluginSearch
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: 15
              clip: true
              anchors.left: parent.left
              anchors.leftMargin: Style.space(34)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              verticalAlignment: Text.AlignVCenter
              onTextChanged: root.pluginSearch = text
            }

            Text {
              textFormat: Text.PlainText
              text: root.pluginSearch === "" ? "" : "✕"
              color: Qt.darker(root.bar.foreground, 1.35)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              anchors.verticalCenter: parent.verticalCenter
            }
            // Clear button scoped to the ✕ badge only; the rest of the field is
            // free for the TextInput (typing must never reset the query).
            Item {
              width: Style.space(24)
              height: parent.height
              anchors.right: parent.right
              visible: root.pluginSearch !== ""
              MouseArea {
                anchors.fill: parent
                onClicked: { root.pluginSearch = ""; pluginSearchInput.forceActiveFocus() }
              }
            }
          }
        }

        Row {
          id: filterRow
          visible: root.editMode
          width: parent.width
          spacing: Style.space(8)

          Repeater {
            model: ["first", "third"]
            delegate: Item {
              required property string modelData
              width: (filterRow.width - Style.space(8)) / 2
              implicitHeight: Style.space(42)

              Rectangle {
                anchors.fill: parent
                radius: Style.space(10)
                color: root.addFilter === modelData ? root.selectedFill : root.themeSurface
                border.width: root.addFilter === modelData ? 1 : 0
                border.color: Color.accent
              }
              Text {
                textFormat: Text.PlainText
                text: modelData === "first" ? "First party" : "Third party"
                color: root.themeText
                font.family: "Inter"
                font.pixelSize: 14
                font.weight: Font.Medium
                anchors.centerIn: parent
              }
              // Mutually-exclusive toggle: picking a party lights only it;
              // toggling the lit one clears the filter (shows both parties).
              MouseArea {
                anchors.fill: parent
                onClicked: root.toggleParty(modelData)
              }
            }
          }
        }

        // Plugin list uses the same compact card rhythm as the main grid:
        // two equal columns, no disclosure arrows, and no uneven raw rows.
        Grid {
          id: providerList
          visible: root.editMode
          width: parent.width
          columns: 2
          spacing: Style.space(8)
          Repeater {
            model: root.editMode ? root.filteredProviders : []
            delegate: AddPluginRow {
              required property var modelData
              required property int index
              width: (providerList.width - Style.space(8)) / providerList.columns
              provider: modelData
              onGridCount: root.groupOnGridCount(modelData)
              selected: root.selectedPlugin === modelData.providerId
            }
          }
        }

        // Selected plugin: its tiles (add them), icon scheme toggle, and the
        // contiguous icon sequence editor fed by the catalog.
        Column {
          id: pluginDetail
          visible: root.editMode && root.selectedGroup !== null
          width: parent.width
          spacing: Style.space(8)

          Rectangle {
            width: parent.width
            implicitHeight: Style.space(34)
            radius: Style.cornerRadius
            color: Qt.alpha(Color.accent, 0.12)

            Text {
              textFormat: Text.PlainText
              text: root.selectedGroup ? (root.selectedGroup.label + " · " + root.selectedGroup.party) : ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
              anchors.left: parent.left
              anchors.leftMargin: Style.space(10)
              anchors.verticalCenter: parent.verticalCenter
              width: parent.width - Style.space(20)
            }

            Text {
              textFormat: Text.PlainText
              text: "✕"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              width: Style.space(24)
            }
            MouseArea {
              anchors.fill: parent
              onClicked: root.selectedPlugin = ""
            }
          }

          // The plugin's tiles — click to add any not already on the grid.
          Flow {
            id: detailFlow
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.selectedGroup ? root.selectedGroup.caps : []
              delegate: Item {
                required property var modelData
                readonly property bool onGrid: !!modelData.onGrid
                width: Style.space(84)
                implicitHeight: Style.space(42)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: parent.onGrid ? root.selectedFill : root.tileIdleBg
                  border.width: parent.onGrid ? 1 : 0
                  border.color: Qt.alpha(Color.accent, 0.5)
                }
                Row {
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(8)
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(8)
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)
                  Text {
                    textFormat: Text.PlainText
                    text: root.pluginSeqGlyph(modelData)
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.heading
                    width: Style.space(22)
                    horizontalAlignment: Text.AlignHCenter
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.title
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width - Style.space(28)
                  }
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: if (!parent.onGrid) root.addCap(modelData)
                }
              }
            }
          }

          // Icon scheme: the plugin's default icons, or your own.
          Text {
            textFormat: Text.PlainText
            text: "ICONS"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            id: iconModeRow
            width: parent.width
            spacing: Style.space(8)
            Repeater {
              model: ["default", "custom"]
              delegate: Item {
                required property string modelData
                width: (iconModeRow.width - Style.space(8)) / 2
                implicitHeight: Style.space(30)

                Rectangle {
                  anchors.fill: parent
                  radius: Style.cornerRadius
                  color: root.pluginIconMode === modelData ? root.selectedFill : root.tileIdleBg
                }
                Text {
                  textFormat: Text.PlainText
                  text: modelData === "default" ? "Default icons" : "My icons"
                  color: root.bar.foreground
                  font.family: root.bar.fontFamily
                  font.pixelSize: Style.font.caption
                  anchors.centerIn: parent
                }
                MouseArea {
                  anchors.fill: parent
                  onClicked: root.setPluginIconMode(modelData)
                }
              }
            }
          }

          // Current icon per tile, in tile order (contiguous sequence).
          Text {
            textFormat: Text.PlainText
            text: "ICON SEQUENCE"
            color: Qt.darker(root.bar.foreground, 1.4)
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.caption
          }

          Flow {
            id: seqFlow
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.selectedGroup ? root.selectedGroup.caps : []
              delegate: SeqSlot {
                required property var modelData
                required property int index
                glyph: root.pluginSeqGlyph(modelData)
                active: index === root.iconSeqIndex
                caption: String(modelData.title).charAt(0)
                onActivate: root.iconSeqIndex = index
              }
            }
          }

          // "My icons" catalog: tap a glyph to place it in the active slot.
          Column {
            visible: root.pluginIconMode === "custom"
            width: parent.width
            spacing: Style.space(6)
            Text {
              textFormat: Text.PlainText
              text: "PICK ICONS"
              color: Qt.darker(root.bar.foreground, 1.4)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
            }
            Flow {
              id: catalogFlow
              width: parent.width
              spacing: Style.space(6)
              Repeater {
                model: root.iconCatalog
                delegate: Item {
                  required property var modelData
                  width: Style.space(38)
                  implicitHeight: Style.space(38)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: modelData.key === root.pluginActiveSlotIconKey() ? root.selectedFill : root.tileIdleBg
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.glyph
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.heading
                    anchors.centerIn: parent
                  }
                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.setPluginIcon(modelData.key)
                  }
                }
              }
            }
          }
        }

        // ---------- Provider / icon picker sheet (edit mode) ----------
        // Long-press a tile in edit mode to choose which provider owns its
        // slot and which catalog icon it wears (architecture spec §4).
        Item {
          visible: root.sheetOpen
          width: parent.width
          implicitHeight: sheetCol.implicitHeight

          Rectangle {
            anchors.fill: parent
            radius: Style.cornerRadius
            color: Qt.alpha(Color.accent, 0.14)
          }

          Column {
            id: sheetCol
            anchors.left: parent.left
            anchors.right: parent.right
            spacing: Style.space(8)

            Text {
              textFormat: Text.PlainText
              text: root.sheetOpen ? ("Provider · " + root.sheetInfo.title) : ""
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Repeater {
                model: root.sheetOpen ? root.sheetInfo.providers : []
                delegate: Item {
                  required property var modelData
                  width: Math.max(Style.space(72), root.sheetOpen
                    ? Math.min(Style.space(150), sheetCol.width - Style.space(8))
                    : Style.space(72))
                  implicitHeight: Style.space(32)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: modelData.providerId === root.sheetActiveProvider()
                      ? root.selectedFill : root.tileIdleBg
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.providerId
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideMiddle
                    anchors.centerIn: parent
                    width: parent.width - Style.space(16)
                  }
                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.sheetSelectProvider(modelData.providerId)
                  }
                }
              }
            }

            Text {
              textFormat: Text.PlainText
              text: "Icon"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              width: parent.width
              spacing: Style.space(8)
              Repeater {
                model: root.sheetOpen ? root.sheetInfo.icons : []
                delegate: Item {
                  required property var modelData
                  width: Style.space(46)
                  implicitHeight: Style.space(46)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: (root.sheetOpen && modelData.glyph === root.sheetActiveGlyph())
                      ? root.selectedFill : root.tileIdleBg
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData.glyph
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.centerIn: parent
                  }
                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.sheetSelectIcon(modelData.key)
                  }
                }
              }
            }

            // 13a §4 third field: icon source radio. Shown only when the
            // tile has more than one source (native caps); generic-tier
            // launcher tiles resolve in-house only and skip this entirely.
            Text {
              visible: root.sheetOpen && root.sheetInfo.iconSources.length > 1
              textFormat: Text.PlainText
              text: "Icon source"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
            }

            Row {
              visible: root.sheetOpen && root.sheetInfo.iconSources.length > 1
              width: parent.width
              spacing: Style.space(8)
              Repeater {
                model: root.sheetOpen ? root.sheetInfo.iconSources : []
                delegate: Item {
                  required property var modelData
                  width: Style.space(110)
                  implicitHeight: Style.space(32)

                  Rectangle {
                    anchors.fill: parent
                    radius: Style.cornerRadius
                    color: (root.sheetOpen && modelData === root.sheetActiveIconSource())
                      ? root.selectedFill : root.tileIdleBg
                  }
                  Text {
                    textFormat: Text.PlainText
                    text: modelData === "plugin" ? "Plugin icon" : "In-house"
                    color: root.bar.foreground
                    font.family: root.bar.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.centerIn: parent
                  }
                  MouseArea {
                    anchors.fill: parent
                    onClicked: root.sheetSelectIconSource(modelData)
                  }
                }
              }
            }
          }
        }

        Text {
          visible: root.editMode || root.pendingConfirm
          textFormat: Text.PlainText
          text: root.pendingConfirm
            ? "Enter confirms · Escape cancels"
            : root.editMode
              ? "Group by first/third party · pick plugin · click tile to add · [ ] reorders · R removes"
              : "Arrows move · Enter opens · right-click toggles · E edit"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
          width: parent.width
        }
      }
    }

    // Always-present, normally-hidden drag ghost (roadmap constraint: declared
    // near the top of the panel, never conjured from handler code).
    Item {
      id: dragGhostItem
      z: 50
      visible: false

      Rectangle {
        id: ghostBack
        anchors.fill: parent
        radius: Style.space(22)
        color: Qt.darker(root.bar.background, 1.12)
        border.color: Qt.alpha(root.bar.foreground, 0.4)
        border.width: 2
        scale: 1.06

        Text {
          textFormat: Text.PlainText
          text: root.dragGhostGlyph
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: width > 0 ? Math.round(width * 0.5) : 28
          anchors.centerIn: parent
        }
      }
    }
  }
  }

  // Notification-history card (right corner). Separate layer from the
  // quick-settings card; the two switch via summonLeft/summonRight and share
  // the guarded close() (any dismiss closes both).
  KeyboardPanel {
    id: notifPanel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.notifOpened
    focusTarget: keyCatcher
    centerOnBar: true
    contentWidth: panel.fittedContentWidth(Math.round(Style.space(400)))
    contentHeight: panel.fittedContentHeight(notifColumn.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      anchors.fill: parent
      onCloseRequested: root.close()
    }

    ScrollView {
      id: notifScroll
      anchors.fill: parent
      clip: true
      ScrollBar.horizontal.policy: ScrollBar.AlwaysOff
      ScrollBar.vertical.policy: ScrollBar.AsNeeded

      Column {
        id: notifColumn
        x: Style.space(12)
        width: notifScroll.availableWidth - Style.space(24)
        spacing: Style.space(12)

        Text {
          textFormat: Text.PlainText
          text: "NOTIFICATIONS"
          color: root.bar.foreground
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.caption
          font.bold: true
          font.letterSpacing: 1.6
        }

        Text {
          visible: !root.notifItems || root.notifItems.length === 0
          textFormat: Text.PlainText
          text: "No recent notifications"
          color: Qt.darker(root.bar.foreground, 1.5)
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.body
        }

        Repeater {
          model: root.notifItems || []
          delegate: Column {
            required property var modelData
            width: notifColumn.width
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: (modelData.app ? modelData.app + " · " : "") + (modelData.when || "")
              color: Qt.darker(root.bar.foreground, 1.5)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              textFormat: Text.PlainText
              text: modelData.summary || "(no subject)"
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }
            Text {
              visible: (modelData.body || "") !== ""
              textFormat: Text.PlainText
              text: modelData.body
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
              width: parent.width
              maximumLineCount: 3
              elide: Text.ElideRight
            }
            Rectangle {
              color: Qt.alpha(root.bar.foreground, 0.08)
              width: parent.width
              height: 1
            }
          }
        }
      }
    }
  }

  // Corner hover summon zones, one EdgeSummon layer per screen.
  readonly property var edgeScreens: {
    var out = []
    var s = Quickshell.screens
    if (s) for (var i = 0; i < s.length; i++) out.push(s[i])
    return out
  }
  Variants {
    model: root.edgeScreens
    EdgeSummon {
      required property var modelData
      targetScreen: modelData
      owner: root
    }
  }

  // Inline components (bar-widget loader rejects top-level declarations).

// Bottom status strip from the supplied HTML mockup. It owns the three small
// actions and the upward power menu; destructive commands keep the existing
// confirmation gate in root.runAction.
component StatusStrip: Item {
  id: statusStrip
  // The HTML status card is 72px logical, which is 90px at this session's
  // 125%-class shell scale.
  implicitHeight: Style.space(68)
  property date now: new Date()
  readonly property string weatherTemperature: root.weatherReport && root.weatherReport.temperature
    ? String(root.weatherReport.temperature) : "Today"
  readonly property string weatherDetail: root.weatherReport && root.weatherReport.wind
    ? String(root.weatherReport.wind) : Qt.formatDate(statusStrip.now, "dddd")
  readonly property int batteryPercent: root.systemTelemetry && isFinite(root.systemTelemetry.batteryPercent)
    ? Math.max(0, Math.min(100, Number(root.systemTelemetry.batteryPercent))) : -1
  readonly property string batteryState: root.systemTelemetry && root.systemTelemetry.batteryState
    ? String(root.systemTelemetry.batteryState) : "Battery"
  readonly property real batteryWatts: root.systemTelemetry && isFinite(root.systemTelemetry.batteryWatts)
    ? Number(root.systemTelemetry.batteryWatts) : -1

  Timer {
    interval: 1000
    repeat: true
    running: root.opened
    onTriggered: statusStrip.now = new Date()
  }

  Rectangle {
    anchors.fill: parent
    radius: Style.space(11)
    color: root.themeSurface
    border.width: 1
    border.color: root.themeBorder
  }

  Item {
    anchors.fill: parent
    anchors.leftMargin: Style.space(14)
    anchors.rightMargin: Style.space(14)

    Column {
      id: statusClock
      anchors.left: parent.left
      anchors.verticalCenter: parent.verticalCenter
      spacing: 1
      Text {
        text: Qt.formatTime(statusStrip.now, "h:mm AP")
        color: Color.accent
        font.family: "Inter"
        font.pixelSize: 32
        font.weight: Font.Medium
      }
      Text {
        text: Qt.formatDate(statusStrip.now, "ddd, dd MMM")
        color: root.themeMutedText
        font.family: "Inter"
        font.pixelSize: 15
      }
    }

    Row {
      id: stats
      anchors.left: statusClock.right
      anchors.leftMargin: Style.space(18)
      anchors.right: actionPill.left
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      spacing: Style.space(12)

      // Status space is for today's information. Wireless state remains in
      // the Wi-Fi/Bluetooth tiles where its meters are directly actionable.
      StatusMetric {
        glyph: "\uF0C2"; color: Color.accent
        primary: statusStrip.weatherTemperature
        secondary: statusStrip.weatherDetail
      }
      StatusSeparator {}
      StatusMetric {
        glyph: "\uF240"; color: Color.accent
        primary: statusStrip.batteryPercent >= 0 ? String(statusStrip.batteryPercent) + "%" : "—"
        secondary: statusStrip.batteryWatts >= 0
          ? statusStrip.batteryWatts.toFixed(1) + "W · " + statusStrip.batteryState
          : statusStrip.batteryState
      }
    }

    Item {
      id: actionPill
      anchors.right: parent.right
      anchors.verticalCenter: parent.verticalCenter
      width: Style.space(80)
      height: Style.space(30)

      Rectangle {
        anchors.fill: parent
        radius: height / 2
        color: root.themeSurfaceRaised
        border.width: 1
        border.color: root.themeBorder
      }

      StatusIconButton {
        x: Style.space(4)
        anchors.verticalCenter: parent.verticalCenter
        glyph: root.editMode ? "✓" : "✎"
        onClicked: root.toggleEditMode()
      }
      StatusIconButton {
        x: Style.space(28)
        anchors.verticalCenter: parent.verticalCenter
        glyph: "\uF013"
        onClicked: {
          var settings = root.capById("settings")
          if (settings) root.openPrimary(settings)
        }
      }
      StatusIconButton {
        x: Style.space(52)
        anchors.verticalCenter: parent.verticalCenter
        glyph: "\uF011"
        glyphColor: Color.urgent
        active: root.powerMenuOpen
        onClicked: root.powerMenuOpen = !root.powerMenuOpen
      }
    }

    Item {
      id: powerMenu
      visible: root.powerMenuOpen
      z: 20
      width: Style.space(150)
      height: powerMenuColumn.implicitHeight + Style.space(8)
      anchors.right: actionPill.right
      anchors.bottom: actionPill.top
      anchors.bottomMargin: Style.space(10)

      Rectangle {
        anchors.fill: parent
        radius: Style.space(11)
        color: root.themeSurfaceRaised
        border.width: 1
        border.color: root.themeBorder
      }
      Column {
        id: powerMenuColumn
        anchors.fill: parent
        anchors.margins: Style.space(4)
        PowerMenuAction { capId: "lock"; glyph: "\uF023"; label: "Lock" }
        PowerMenuAction { capId: "suspend"; glyph: "\uF186"; label: "Sleep" }
        PowerMenuAction { capId: "logout"; glyph: "\uF2F5"; label: "Logout" }
        Rectangle { width: parent.width - Style.space(8); x: Style.space(4); height: 1; color: root.themeBorder }
        PowerMenuAction { capId: "reboot"; glyph: "\uF2F1"; label: "Restart" }
        PowerMenuAction { capId: "poweroff"; glyph: "\uF011"; label: "Off"; danger: true }
      }
    }
  }
}

component StatusSeparator: Rectangle {
  width: 1; height: Style.space(23); color: root.themeBorder
}

component StatusMetric: Item {
  property string glyph: ""; property color color: root.themeMutedText
  property string primary: ""; property string secondary: ""
  width: metricRow.implicitWidth; height: Style.space(30)
  Row {
    id: metricRow; spacing: Style.space(5); anchors.verticalCenter: parent.verticalCenter
    Text { text: glyph; color: parent.parent.color; font.family: root.bar.fontFamily; font.pixelSize: 24 }
    Column {
      Text { text: primary; color: root.themeText; font.family: "Inter"; font.pixelSize: 15; font.weight: Font.Medium }
      Text { text: secondary; color: root.themeMutedText; font.family: "Inter"; font.pixelSize: 13 }
    }
  }
}

component StatusPair: Item {
  property string topGlyph: ""; property color topColor: Color.accent; property string topText: ""
  property string bottomGlyph: ""; property color bottomColor: Color.accent; property string bottomText: ""
  width: pairColumn.implicitWidth; height: Style.space(30)
  Column {
    id: pairColumn; spacing: 1; anchors.verticalCenter: parent.verticalCenter
    Row {
      spacing: 3
      Text { text: topGlyph; color: topColor; font.family: root.bar.fontFamily; font.pixelSize: 17 }
      Text { text: topText; color: root.themeText; font.family: "Inter"; font.pixelSize: 14 }
    }
    Row {
      spacing: 3
      Text { text: bottomGlyph; color: bottomColor; font.family: root.bar.fontFamily; font.pixelSize: 17 }
      Text { text: bottomText; color: root.themeText; font.family: "Inter"; font.pixelSize: 14 }
    }
  }
}

component StatusIconButton: Item {
  property string glyph: ""; property color glyphColor: root.themeText; property bool active: false
  signal clicked()
  width: Style.space(23); height: width
  Rectangle { anchors.fill: parent; radius: width / 2; color: active ? Qt.alpha(Color.urgent, 0.18) : (tap.containsMouse ? root.themeSurfaceRaised : "transparent") }
  Text { anchors.centerIn: parent; text: glyph; color: glyphColor; font.family: root.bar.fontFamily; font.pixelSize: 19 }
  MouseArea { id: tap; anchors.fill: parent; hoverEnabled: true; onClicked: parent.clicked() }
}

component PowerMenuAction: Item {
  property string capId: ""; property string glyph: ""; property string label: ""; property bool danger: false
  width: parent ? parent.width : Style.space(142); height: Style.space(30)
  Rectangle { anchors.fill: parent; radius: Style.space(7); color: menuTap.containsMouse ? (danger ? Qt.alpha(Color.urgent, 0.2) : root.themeSurface) : "transparent" }
  Row { anchors.left: parent.left; anchors.leftMargin: Style.space(9); anchors.verticalCenter: parent.verticalCenter; spacing: Style.space(8)
    Text { text: glyph; color: danger ? Color.urgent : root.themeMutedText; font.family: root.bar.fontFamily; font.pixelSize: 20 }
    Text { text: label; color: danger ? Color.urgent : root.themeText; font.family: "Inter"; font.pixelSize: 14 }
  }
  MouseArea { id: menuTap; anchors.fill: parent; hoverEnabled: true; onClicked: { root.powerMenuOpen = false; var c = root.capById(capId); if (c) root.runAction(c) } }
}

// One quick-settings tile. Toggles flip on activate; sliders draw a liquid
// level and open their panel on tap (like the bar's sound/display icons);
// actions open their panel or run a command; the pencil/done tile enters the
// Android-style add/remove editor.
component QuickTile: Item {
  id: q
  property var cap: null
  property string tileType: "cap"
  required property int globalIndex
  property real cellWidth: 0
  property bool square: false

  readonly property bool isEdit: q.tileType === "edit"
  readonly property bool isCap: typeof q.cap === "object" && q.cap !== null
  readonly property bool showRemove: root.editMode && q.isCap
  readonly property bool sel: root.cursorActive && globalIndex === root.cursorIndex

  // One UI desktop tiles retain the tactile squircle, but expose title and
  // live state instead of making users memorize icon-only controls.
  readonly property real tileRadius: Style.space(9)
  readonly property bool pluginTile: q.isCap && (q.cap.kind === "action" || q.cap.kind === "launcher") && q.cap.sublabel === "Open"

  // Icon actually shown (13a §4 icon source): "plugin" forces the provider's
  // own manifest glyph; otherwise (in-house default) the user's catalog icon
  // for the slot wins, falling back to the cap glyph (which for launcher
  // tiles already IS the resolved in-house icon).
  readonly property string displayGlyph: q.isCap
    ? ((root.bindings && root.bindings[(q.cap.slot || q.cap.id)] && root.bindings[(q.cap.slot || q.cap.id)].iconSource === "plugin")
      ? (q.cap.glyph || "")
      : (Model.bindIcon(root.bindings && root.bindings[(q.cap.slot || q.cap.id)]) || q.cap.glyph || ""))
    : ""

  readonly property int percent: q.isCap ? Model.sliderPercent(Number(root.valueOf(q.cap) || 0), q.cap) : 0
  readonly property var muteCap: q.isCap && q.cap.mutedCapId ? root.capById(q.cap.mutedCapId) : null
  readonly property bool isSlider: q.isCap && q.cap.kind === "slider"
  readonly property bool muted: q.isCap && !!muteCap && root.checked(muteCap)
  readonly property int signalLevel: q.isCap ? root.signalOf(q.cap) : -1
  // Wi-Fi/Bluetooth get the same quiet bottom meter as sliders. Bluetooth
  // does not expose RSSI on every adapter; when a device is connected we use
  // a full link bar rather than claiming an invented signal percentage.
  readonly property bool bluetoothLink: q.isCap && q.cap.id === "bluetooth"
    && root.bluetoothConnected && q.tileOn
  readonly property bool liquidShown: (q.isSlider && !q.muted)
    || (q.signalLevel >= 0 && q.tileOn && !q.isSlider)
    || q.bluetoothLink
  readonly property real liquidFrac: q.liquidShown
    ? (q.isSlider
      ? Math.max(0, Math.min(1, q.percent / 100.0))
      : q.signalLevel >= 0
        ? Math.max(0, Math.min(1, q.signalLevel / 100.0))
        : 1.0)
    : 0.0

  readonly property bool tileOn: q.isEdit ? root.editMode
    : q.isSlider ? (q.percent > 0)
    : root.checked(q.cap)

  readonly property string stateLabel: {
    if (q.isEdit) return root.editMode ? "Done" : "Customize"
    if (!q.isCap) return ""
    if (q.isSlider) return String(q.percent) + "%"
    if (q.cap.id === "bluetooth" && root.bluetoothConnected) return "Connected"
    if (q.cap.sublabel) return String(q.cap.sublabel)
    if (q.cap.kind === "launcher") return "Open"
    // The mockup uses one quiet state line, without a visual affordance for a
    // secondary action. Pointer and keyboard details remain available through
    // the universal interaction contract, but do not alter the tile's rhythm.
    if (q.cap.detail && (q.cap.kind === "toggle" || q.cap.kind === "command-mute"))
      return q.tileOn ? "On" : "Off"
    return q.tileOn ? "On" : "Off"
  }
  readonly property bool hasSecondaryAction: q.isCap &&
    (q.cap.kind === "toggle" || q.cap.kind === "command-mute" || !!q.cap.secondaryCapId)

  width: cellWidth > 0 ? cellWidth : 0
  // The mockup's uniform 72px tile height.
  implicitHeight: square && cellWidth > 0 ? cellWidth : Style.space(52)

  Rectangle {
    id: base
    anchors.fill: parent
    radius: q.tileRadius
    color: q.tileOn ? root.selectedFill : root.themeSurface
  }

  Rectangle {
    id: liquidTrack
    x: Style.space(9)
    y: parent.height - Style.space(12)
    width: parent.width - Style.space(18)
    height: 4
    radius: 2
    color: root.themeBorder
    visible: q.liquidShown
  }

  Rectangle {
    id: liquid
    x: liquidTrack.x
    y: liquidTrack.y
    width: liquidTrack.width * q.liquidFrac
    height: liquidTrack.height
    radius: 2
    color: root.liquidColor
    visible: q.liquidShown
  }

  Item {
    anchors.fill: parent
    anchors.margins: Style.space(9)

    Text {
      id: glyph
      textFormat: Text.PlainText
      text: q.isEdit ? (root.editMode ? "✓" : "✎")
        : (q.isCap ? (q.muted && muteCap && muteCap.glyph ? muteCap.glyph : q.displayGlyph) : "")
      color: q.tileOn ? Color.accent : root.themeMutedText
      font.family: root.bar.fontFamily
      font.pixelSize: 26
      anchors.left: parent.left
      anchors.verticalCenter: q.isSlider ? undefined : parent.verticalCenter
      anchors.top: q.isSlider ? parent.top : undefined
      anchors.topMargin: q.isSlider ? 1 : 0
    }

    Column {
      anchors.left: glyph.right
      anchors.leftMargin: Style.space(10)
      anchors.verticalCenter: q.isSlider ? undefined : parent.verticalCenter
      anchors.top: q.isSlider ? parent.top : undefined
      anchors.topMargin: q.isSlider ? 1 : 0
      anchors.right: parent.right
      spacing: 1

      Text {
        textFormat: Text.PlainText
        text: q.isEdit ? (root.editMode ? "Done" : "Edit") : (q.isCap ? q.cap.title : "")
        color: root.themeText
        font.family: "Inter"
        font.pixelSize: 16
        font.weight: Font.Medium
        elide: Text.ElideRight
        width: parent.width
      }
      Text {
        textFormat: Text.PlainText
        text: q.stateLabel
        color: root.themeMutedText
        font.family: "Inter"
        font.pixelSize: 14
        visible: !q.isSlider
        elide: Text.ElideRight
        width: parent.width
      }
    }

  }

  // Focus = a 2px accent outline ring (UX spec §5: highlight without fill).
  Rectangle {
    anchors.fill: parent
    anchors.margins: -2
    radius: q.tileRadius + 2
    color: "transparent"
    border.width: q.sel ? 2 : 0
    border.color: Color.accent
    visible: q.sel
  }

  // The supplied mockup is deliberately still; only instantaneous press
  // feedback remains for pointer confidence.
  Rectangle {
    anchors.fill: parent
    radius: q.tileRadius
    color: Qt.alpha(root.bar.foreground, 0.09)
    opacity: (pressedArea.pressed && !root.pendingConfirm) ? 1 : 0
  }

  MouseArea {
    id: pressedArea
    anchors.fill: parent
    hoverEnabled: true
    acceptedButtons: Qt.LeftButton | Qt.RightButton
    drag.target: (root.editMode && q.isCap) ? root.dragGhostItem : null
    drag.axis: Qt.XAxis | Qt.YAxis
    drag.threshold: Style.space(6)
    onPressed: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      if (root.editMode && q.isCap) root.prepareDrag(q.cap.id, q)
      else if (!root.editMode && q.isSlider && !root.pendingConfirm)
        root.sliderDrag = { src: q.cap.id, y0: mouse.y, active: false }
    }
    onPositionChanged: function(mouse) {
      var sd = root.sliderDrag
      if (!sd || sd.src !== q.cap.id || !pressedArea.pressed) return
      if (!sd.active && Math.abs(mouse.y - sd.y0) > 4) sd.active = true
      if (sd.active) {
        root.sliderDragActive = true
        root.dragSetValue(q.cap, mouse.y, q.height)
      }
    }
    onPressAndHold: function(mouse) {
      if (mouse.button !== Qt.LeftButton) return
      if (root.editMode && q.isCap && !q.isEdit) { root.openSheetFor(q.cap); return }
      if (!root.editMode && root.pendingConfirm === null && q.isCap && !q.isEdit)
        root.expand(q.cap)
    }
    onReleased: function(mouse) {
      if (root.sliderDragActive) {
        // A completed fader drag suppresses the follow-up tap (no panel pop).
        root.sliderDrag = null
        Qt.callLater(function() { root.sliderDragActive = false })
      }
      root.finishDrag()
    }
    onContainsMouseChanged: if (containsMouse) {

      root.cursorActive = true
      root.cursorIndex = q.globalIndex
    }
    onClicked: function(mouse) {
      if (root.sliderDragActive) { root.sliderDragActive = false; root.sliderDrag = null; return }
      root.sliderDrag = null
      if (!root.cursorActive) root.cursorActive = true
      if (root.pendingConfirm) return
      // Left shows a provider's interface; right uses the cap's declared
      // secondary state action. Neither path knows provider identities.
      if (mouse.button === Qt.RightButton) {
        if (!root.editMode && q.isCap) root.toggleSecondary(q.cap)
        return
      }
      if (mouse.button !== Qt.LeftButton) return
      if (root.editMode) {
        if (q.isEdit) root.toggleEditMode()
        else if (q.isCap) { root.cursorIndex = q.globalIndex }
        return
      }
      if (q.isEdit) root.toggleEditMode()
      else if (q.isCap) root.openPrimary(q.cap)
    }
  }

  // Remove badge, kept above the tile's MouseArea so it stays clickable
  // during drags.
  Rectangle {
    visible: q.showRemove
    anchors.right: parent.right
    anchors.top: parent.top
    width: 18
    height: 18
    radius: 9
    color: Color.urgent
    z: 6

    Text {
      textFormat: Text.PlainText
      text: "x"
      color: Color.foreground
      anchors.centerIn: parent
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
    }
    MouseArea {
      anchors.fill: parent
      onClicked: {
        root.cursorActive = true
        root.cursorIndex = q.globalIndex
        root.removeCap(q.cap)
      }
    }
  }

  // Plugin "Open <panel>" tiles get a distinct smallest-corner badge
  // (architecture spec §3): they summon another bar widget's panel.
  Rectangle {
    visible: q.pluginTile
    z: 5
    anchors.left: parent.left
    anchors.top: parent.top
    anchors.margins: Style.space(3)
    width: Style.space(16)
    height: Style.space(16)
    radius: Style.space(8)
    color: Qt.alpha(Color.accent, 0.9)

    Text {
      textFormat: Text.PlainText
      text: "\uF00A"
      color: Color.foreground
      font.family: root.bar.fontFamily
      font.pixelSize: Style.font.caption
      anchors.centerIn: parent
    }
  }
}

// One plugin in the add-tiles manager: label, party footing, tile count, and
// how many of its tiles are already placed. Click to open its icon editor.
component AddPluginRow: Item {
  id: pr
  property var provider
  property int onGridCount: 0
  property bool selected: false

  width: parent.width
  implicitHeight: Style.space(52)

  Rectangle {
    anchors.fill: parent
    radius: Style.space(9)
    color: pr.selected ? root.selectedFill : root.themeSurface
    border.width: pr.selected ? 1 : 0
    border.color: root.themeBorder
  }

  Text {
    id: providerGlyph
    textFormat: Text.PlainText
    text: pr.provider && pr.provider.caps && pr.provider.caps.length ? pr.provider.caps[0].glyph : "\uF00A"
    color: pr.selected ? Color.accent : root.themeMutedText
    font.family: root.bar.fontFamily
    font.pixelSize: 24
    anchors.left: parent.left
    anchors.leftMargin: Style.space(10)
    anchors.verticalCenter: parent.verticalCenter
  }

  Text {
    id: badge
    textFormat: Text.PlainText
    text: pr.provider ? pr.provider.label : ""
    color: root.themeText
    font.family: "Inter"
    font.pixelSize: 14
    font.weight: Font.Medium
    elide: Text.ElideRight
    anchors.left: providerGlyph.right
    anchors.leftMargin: Style.space(9)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(9)
    anchors.top: parent.top
    anchors.topMargin: Style.space(9)
  }

  Text {
    textFormat: Text.PlainText
    text: pr.provider ? (String(pr.provider.caps.length) + " controls" + (pr.onGridCount ? " · " + pr.onGridCount + " added" : "")) : ""
    color: root.themeMutedText
    font.family: "Inter"
    font.pixelSize: 12
    elide: Text.ElideRight
    anchors.left: providerGlyph.right
    anchors.leftMargin: Style.space(9)
    anchors.right: parent.right
    anchors.rightMargin: Style.space(9)
    anchors.bottom: parent.bottom
    anchors.bottomMargin: Style.space(9)
  }

  MouseArea {
    anchors.fill: parent
    onClicked: root.selectPlugin(pr.provider.providerId)
  }
}

// One slot of a plugin's contiguous icon sequence. Tapping makes it the active
// slot the catalog fills next.
component SeqSlot: Item {
  id: slot
  required property string glyph
  required property string caption
  property bool active: false
  signal activate()

  width: Style.space(38)
  implicitHeight: Style.space(38)

  Rectangle {
    anchors.fill: parent
    radius: Style.cornerRadius
    color: slot.active ? root.selectedFill : root.tileIdleBg
  }
  Text {
    textFormat: Text.PlainText
    text: slot.glyph === "" ? "+" : slot.glyph
    color: slot.glyph === "" ? Qt.darker(root.bar.foreground, 1.6) : root.bar.foreground
    font.family: root.bar.fontFamily
    font.pixelSize: slot.glyph === "" ? Style.font.caption : Style.font.heading
    anchors.centerIn: parent
  }
  Rectangle {
    visible: slot.active
    anchors.bottom: parent.bottom
    anchors.horizontalCenter: parent.horizontalCenter
    width: Style.space(10)
    height: 2
    color: Color.accent
  }
  MouseArea {
    anchors.fill: parent
    onClicked: slot.activate()
  }
}
}
