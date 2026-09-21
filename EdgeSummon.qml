import QtQuick
import Quickshell
import Quickshell.Wayland

// Exact-corner hot zones. The layer must cover the screen for layer-shell,
// but its input region is only two tiny squares at the physical top corners.
// It therefore cannot behave like a broad edge-proximity trigger.
// Left opens Control Center; right opens notification history.
PanelWindow {
  id: edgeRoot

  property var targetScreen: null
  property var owner: null
  // Twelve physical pixels makes the target reachable without turning the
  // surrounding desktop into a trigger. It intentionally overlays the two
  // physical top corners, above the bar, because that is where a hot-corner
  // gesture naturally lands.
  property int triggerSize: 12
  property int topInset: 0
  property int activationDelayMs: 120

  screen: targetScreen
  visible: targetScreen !== null
  color: "transparent"
  exclusionMode: ExclusionMode.Ignore
  surfaceFormat.opaque: false

  anchors {
    top: true
    bottom: true
    left: true
    right: true
  }

  mask: Region {
    Region {
      x: 0
      y: edgeRoot.topInset
      width: edgeRoot.triggerSize
      height: edgeRoot.triggerSize
    }
    Region {
      x: edgeRoot.width - edgeRoot.triggerSize
      y: edgeRoot.topInset
      width: edgeRoot.triggerSize
      height: edgeRoot.triggerSize
    }
  }

  WlrLayershell.namespace: "a-control-center-edges"
  WlrLayershell.layer: WlrLayer.Overlay
  WlrLayershell.keyboardFocus: WlrKeyboardFocus.None

  Timer {
    id: leftActivation
    interval: edgeRoot.activationDelayMs
    repeat: false
    onTriggered: if (leftCorner.containsMouse && edgeRoot.owner) edgeRoot.owner.summonLeft()
  }

  Timer {
    id: rightActivation
    interval: edgeRoot.activationDelayMs
    repeat: false
    onTriggered: if (rightCorner.containsMouse && edgeRoot.owner) edgeRoot.owner.summonRight()
  }

  // Hover-only: acceptedButtons None keeps the actual corner click-through.
  MouseArea {
    id: leftCorner
    x: 0
    y: edgeRoot.topInset
    width: edgeRoot.triggerSize
    height: edgeRoot.triggerSize
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    onContainsMouseChanged: {
      if (containsMouse) leftActivation.restart()
      else leftActivation.stop()
    }
  }

  MouseArea {
    id: rightCorner
    x: edgeRoot.width - edgeRoot.triggerSize
    y: edgeRoot.topInset
    width: edgeRoot.triggerSize
    height: edgeRoot.triggerSize
    hoverEnabled: true
    acceptedButtons: Qt.NoButton
    onContainsMouseChanged: {
      if (containsMouse) rightActivation.restart()
      else rightActivation.stop()
    }
  }
}
