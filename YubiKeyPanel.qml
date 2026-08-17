import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar button plus popup for a YubiKey: is it plugged in, and what codes does
// it hold. Presence comes from sysfs, which is instant; ykman is only run when
// there is something to ask it.
Panel {
  id: root
  moduleName: "io.github.achevalier-dev.yubikey"
  ipcTarget: "io.github.achevalier-dev.yubikey"

  property bool present: false
  property string product: ""
  property string serial: ""
  property var accounts: []
  property var contextTokens: []
  property string filter: ""
  property bool loading: false
  property string pendingAccount: ""
  property int secondsLeft: 30

  property int cursorIndex: 0
  property bool cursorActive: false

  readonly property bool typeAvailable: setting("autoType", true) === true
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Accounts matching the focused window first, then the rest; the filter the
  // user types narrows both.
  readonly property var visibleAccounts: {
    var needle = filter.toLowerCase()
    var hits = []
    var rest = []
    for (var i = 0; i < accounts.length; i++) {
      var account = String(accounts[i])
      if (needle && account.toLowerCase().indexOf(needle) < 0) continue
      if (matched[account]) hits.push(account)
      else rest.push(account)
    }
    return hits.concat(rest)
  }

  // Derived, not assigned: the window context and the account list arrive from
  // two processes and either can win the race.
  readonly property var matched: {
    var hits = ({})
    for (var i = 0; i < accounts.length; i++) {
      var account = String(accounts[i])
      var lower = account.toLowerCase()
      for (var j = 0; j < contextTokens.length; j++) {
        if (lower.indexOf(contextTokens[j]) >= 0) {
          hits[account] = true
          break
        }
      }
    }
    return hits
  }

  readonly property string stateText: {
    if (!present) return "Not plugged in"
    if (loading) return "Reading key…"
    return accounts.length + (accounts.length === 1 ? " account" : " accounts")
  }

  // omarchy renders this glyph itself, so the font is guaranteed to have it.
  readonly property string glyph: present ? "󰌆" : "󰀦"

  // Rows under the account list, in the shape the first-party panels use: a
  // label that hands off to the terminal or the menu.
  readonly property var actionKeys: ["add", "info", "applications", "troubleshoot"]

  function labelFor(key) {
    switch (key) {
    case "add": return "Add account…"
    case "info": return "Key info"
    case "applications": return "Applications…"
    case "troubleshoot": return "Troubleshoot…"
    }
    return key
  }

  function runAction(key) {
    close()
    if (!bar) return
    if (key === "add") bar.run("yubikey-menu add")
    else if (key === "info") bar.run("yubikey-menu info")
    else if (key === "applications") bar.run("omarchy-menu summon yubikey.applications")
    else if (key === "troubleshoot") bar.run("omarchy-menu summon yubikey.fix")
  }

  visible: true
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function clampCursor() {
    var count = visibleAccounts.length
    if (count === 0) {
      cursorIndex = 0
      return
    }
    if (cursorIndex >= count) cursorIndex = count - 1
    if (cursorIndex < 0) cursorIndex = 0
  }

  function moveCursor(dx, dy) {
    cursorActive = true
    if (dy === 0) return
    cursorIndex = cursorIndex + dy
    clampCursor()
  }

  function accountAt(index) {
    var list = visibleAccounts
    if (index < 0 || index >= list.length) return ""
    return String(list[index])
  }

  // The CLI owns the touch prompt, the clipboard timeout, and the refocus
  // before typing — the panel just says which account and which way.
  function useAccount(account, viaTyping) {
    if (!account) return
    root.pendingAccount = account
    close()
    if (bar) bar.run((viaTyping && typeAvailable ? "yubikey-menu type " : "yubikey-menu code ") + shellQuote(account))
  }

  // Account names carry @ and . and arrive from the key, not from us — quote
  // them properly rather than trusting them inside a double-quoted string.
  function shellQuote(value) {
    return "'" + String(value).replace(/'/g, "'\\''") + "'"
  }

  function refresh() {
    if (!present) {
      root.accounts = []
      return
    }
    if (accountsProc.running) return
    root.loading = true
    accountsProc.collected = ""
    accountsProc.running = true
  }

  onOpenedChanged: {
    if (opened) {
      cursorActive = false
      cursorIndex = 0
      filter = ""
      presenceProc.running = true
      contextProc.running = true
      refresh()
    }
  }

  // ── Presence ────────────────────────────────────────────────────────────────
  // Yubico's USB vendor id is 1050. Reading sysfs costs nothing, so the widget
  // can answer "is it plugged in" without waking ykman.
  Process {
    id: presenceProc
    property bool found: false
    command: ["bash", "-lc",
      "for id in /sys/bus/usb/devices/*/idVendor; do [[ $(<\"$id\") == 1050 ]] || continue; printf '%s\\n' \"$(<\"$(dirname \"$id\")/product\")\"; exit 0; done"]
    running: true
    onRunningChanged: if (running) presenceProc.found = false
    stdout: SplitParser {
      onRead: function (data) {
        var name = String(data).trim()
        if (!name) return
        presenceProc.found = true
        root.product = name
        if (!root.present) {
          root.present = true
          if (root.opened) root.refresh()
        }
      }
    }
    onExited: function (code) {
      // No line on stdout during *this* run means no Yubico device on the bus.
      root.present = presenceProc.found
      if (!presenceProc.found) {
        root.product = ""
        root.accounts = []
        root.serial = ""
      }
    }
  }

  // udev tells us the moment the key goes in or out, so no polling loop.
  Process {
    id: udevProc
    command: ["udevadm", "monitor", "--udev", "--subsystem-match=usb"]
    running: true
    stdout: SplitParser {
      onRead: function (data) {
        if (String(data).indexOf("usb") < 0) return
        recheck.restart()
      }
    }
    onExited: udevRestart.start()
  }

  Timer {
    id: recheck
    interval: 400
    onTriggered: if (!presenceProc.running) presenceProc.running = true
  }

  Timer {
    id: udevRestart
    interval: 5000
    onTriggered: udevProc.running = true
  }

  // A slow backstop in case a udev event is ever missed.
  Timer {
    interval: 30000
    running: true
    repeat: true
    onTriggered: if (!presenceProc.running) presenceProc.running = true
  }

  // ── Accounts ────────────────────────────────────────────────────────────────
  Process {
    id: accountsProc
    property string collected: ""
    command: ["bash", "-lc", "ykman oath accounts list 2>/dev/null; ykman list --serials 2>/dev/null | head -n1"]
    stdout: SplitParser {
      onRead: function (data) { accountsProc.collected += String(data) + "\n" }
    }
    onExited: {
      var lines = accountsProc.collected.split("\n").filter(function (l) { return l.trim() !== "" })
      var serial = ""
      if (lines.length && /^[0-9]+$/.test(lines[lines.length - 1].trim())) serial = lines.pop().trim()
      root.serial = serial
      root.accounts = lines
      root.loading = false
      root.clampCursor()
    }
  }

  // What is on screen right now, so the accounts that belong to it can lead.
  Process {
    id: contextProc
    property string collected: ""
    command: ["bash", "-lc", "hyprctl activewindow -j 2>/dev/null | jq -r '(.class // \"\") + \" \" + (.title // \"\")'; hostname; id -un"]
    stdout: SplitParser {
      onRead: function (data) { contextProc.collected += String(data) + "\n" }
    }
    onExited: {
      var lines = contextProc.collected.split("\n")
      var text = String(lines[0] || "").toLowerCase()
      var own = [String(lines[1] || "").toLowerCase().trim(), String(lines[2] || "").toLowerCase().trim()]
      contextProc.collected = ""
      var stop = " com www net org co uk io app the and for your new tab page home sign login log account accounts secure security verify verification two factor authentication authenticator browser brave chrome chromium firefox mozilla zen google window private "
      root.contextTokens = text.split(/[^a-z0-9]+/).filter(function (t) {
        return t.length >= 3 && stop.indexOf(" " + t + " ") < 0 && own.indexOf(t) < 0
      })
    }
  }

  // TOTP codes roll on a 30 second boundary; the ring says how much of the
  // current one is left so nothing gets pasted a second before it dies.
  Timer {
    interval: 1000
    running: root.opened
    repeat: true
    triggeredOnStart: true
    onTriggered: root.secondsLeft = 30 - (Math.floor(Date.now() / 1000) % 30)
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.glyph
    dimmed: !root.present
    tooltipText: root.present ? (root.product || "YubiKey") + " · click for codes" : "No YubiKey plugged in"

    onPressed: function (b) {
      if (b === Qt.RightButton) root.bar.run("yubikey-menu type")
      else if (b === Qt.MiddleButton) root.bar.run("yubikey-menu info")
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(620))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function (dx, dy) {
        if (!root.cursorActive) {
          root.cursorActive = true
          return
        }
        root.moveCursor(dx, dy)
      }
      onActivateRequested: root.useAccount(root.accountAt(root.cursorIndex), false)
      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onDeleteRequested: root.filter = root.filter.slice(0, -1)
      onTextKey: function (t) {
        // Typing narrows the list; the only reserved key is the one that types
        // the highlighted code back into the window you came from.
        if (t === "\t") {
          root.useAccount(root.accountAt(root.cursorIndex), true)
          return
        }
        root.filter += t
        root.cursorIndex = 0
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          PanelHero {
            width: parent.width
            title: "YubiKey"
            meta: root.stateText
            detail: root.present && root.secondsLeft > 0 && root.accounts.length ? root.secondsLeft + "s" : ""
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.present ? 1.0 : 0.5

            iconComponent: Component {
              Text {
                text: root.glyph
                color: root.present ? root.foreground : root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.display
              }
            }
          }

          Text {
            width: parent.width
            visible: root.present
            text: root.product + (root.serial ? " · " + root.serial : "")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            elide: Text.ElideRight
          }

          Column {
            width: parent.width
            visible: !root.present
            spacing: Style.space(8)

            Text {
              width: parent.width
              text: "No YubiKey is plugged in. Insert it and this panel fills in on its own — presence comes from udev, so there is nothing to refresh."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          Text {
            width: parent.width
            visible: root.filter !== ""
            text: "filter: " + root.filter
            color: root.foreground
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          PanelSeparator { foreground: root.foreground }

          Column {
            width: parent.width
            visible: root.present
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "KEY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: root.actionKeys

              Rectangle {
                id: actionRow
                required property string modelData
                width: parent.width
                implicitHeight: Style.space(32)
                radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                color: "transparent"

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  text: root.labelFor(actionRow.modelData)
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onEntered: parent.color = Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  onExited: parent.color = "transparent"
                  onClicked: root.runAction(actionRow.modelData)
                }
              }
            }
          }

          PanelSeparator { foreground: root.foreground }

          PanelSectionHeader {
            visible: root.present
            text: "ACCOUNTS"
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.present && root.visibleAccounts.length === 0
            text: root.loading ? "Reading the key…" : (root.filter ? "Nothing matches that." : "No OATH accounts on this key.")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
          }

          Column {
            width: parent.width
            visible: root.present
            spacing: Style.space(4)

            Repeater {
              model: root.visibleAccounts

              Rectangle {
                id: accountRow
                required property string modelData
                required property int index
                width: parent.width
                implicitHeight: Style.space(32)
                radius: Style.cornerRadius > 0 ? Style.space(8) : 0
                color: root.cursorActive && root.cursorIndex === index
                  ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
                  : "transparent"

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.left: parent.left
                  anchors.leftMargin: Style.space(10)
                  anchors.right: badge.left
                  anchors.rightMargin: Style.space(6)
                  text: accountRow.modelData
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                }

                Text {
                  id: badge
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.right: parent.right
                  anchors.rightMargin: Style.space(10)
                  visible: root.matched[accountRow.modelData] === true
                  text: "this window"
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }

                MouseArea {
                  anchors.fill: parent
                  hoverEnabled: true
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  cursorShape: Qt.PointingHandCursor
                  onEntered: {
                    root.cursorActive = true
                    root.cursorIndex = accountRow.index
                  }
                  onClicked: function (mouse) {
                    root.useAccount(accountRow.modelData, mouse.button === Qt.RightButton)
                  }
                }
              }
            }
          }

          Text {
            width: parent.width
            text: !root.present
              ? "esc close"
              : (root.typeAvailable
                ? "type to filter · enter copy · tab or right-click type · esc close"
                : "type to filter · enter copy · esc close")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }
        }
      }
    }
  }
}
