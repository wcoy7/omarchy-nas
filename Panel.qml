import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "office.ad"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property string page: "mode"
  property string statusLine: ""
  property bool applyBusy: false
  property bool ingesting: false
  property bool installed: false
  property bool isDc: false
  property string sambaState: ""
  property string keaState: ""
  property string realm: ""
  property string hostname: ""
  property string dirMode: "host-ad"
  property bool dhcpEnabled: true
  property bool dnsEnabled: true
  property int missingPackages: 0
  property bool missingPrompted: false

  readonly property var tabs: {
    var list = [
      { id: "mode", label: "Mode" },
      { id: "network", label: "Network" },
      { id: "vlans", label: "VLANs" }
    ]
    if (dirMode === "host-ad" && dnsEnabled)
      list.push({ id: "dns", label: "DNS" })
    list.push({ id: "shares", label: "Shares" })
    if (dirMode === "host-ad" || dirMode === "local")
      list.push({ id: "users", label: "Users" })
    list.push({ id: "packages", label: "Packages" })
    return list
  }

  readonly property string modeLabel: dirMode === "join-ad"
    ? "Join AD" : (dirMode === "local" ? "Local users" : "Host AD")

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property string pluginDir: {
    var u = Qt.resolvedUrl(".").toString()
    if (u.indexOf("file://") === 0)
      u = u.substring(7)
    while (u.length > 1 && u.charAt(u.length - 1) === "/")
      u = u.substring(0, u.length - 1)
    return u
  }
  readonly property string ctlPath: pluginDir + "/bin/omarchy-adctl"

  function open() {
    root.controller.show()
  }

  function close() {
    root.controller.hide()
  }

  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  function refresh() {
    statusProc.running = false
    statusProc.command = [root.ctlPath, "status"]
    statusProc.running = true
  }

  function ingestStatus(text) {
    try {
      var d = JSON.parse(text)
    } catch (e) {
      statusLine = "Could not read status"
      return
    }
    ingesting = true
    installed = d.installed === true
    isDc = d.is_dc === true
    sambaState = d.samba || ""
    keaState = d.kea || ""
    realm = d.realm || ""
    hostname = d.hostname || ""
    dirMode = d.mode || "host-ad"
    dhcpEnabled = d.dhcp_enabled !== false
    dnsEnabled = d.dns_enabled !== false
    netIp.text = d.ip || ""
    netPrefix.text = d.prefix || "24"
    netGw.text = d.gateway || ""
    netIface.text = d.interface || ""
    netDhcpStart.text = d.dhcp_start || ""
    netDhcpEnd.text = d.dhcp_end || ""
    dnsZone.text = d.realm || dnsZone.text
    vlanModel.clear()
    var vlans = d.vlans || []
    for (var i = 0; i < vlans.length; i++) {
      var v = vlans[i]
      vlanModel.append({
        tag: String(v.tag || ""),
        parent: v.parent || "",
        ifname: v.ifname || "",
        ip: v.ip || "",
        prefix: String(v.prefix || "24"),
        gateway: v.gateway || "",
        dhcp_start: v.dhcp_start || "",
        dhcp_end: v.dhcp_end || "",
        search_domain: v.search_domain || ""
      })
    }
    hostModel.clear()
    var hosts = d.hosts || []
    for (var h = 0; h < hosts.length; h++) {
      hostModel.append({
        name: hosts[h].name || "",
        ip: hosts[h].ip || "",
        zone: hosts[h].zone || d.realm || ""
      })
    }
    shareModel.clear()
    var shares = d.shares || []
    for (var s = 0; s < shares.length; s++) {
      shareModel.append({
        name: shares[s].name || "",
        path: shares[s].path || "",
        read_only: shares[s].read_only || "no",
        valid_users: shares[s].valid_users || ""
      })
    }
    if (vlanParent.text === "")
      vlanParent.text = d.interface || ""
    if (vlanDomain.text === "")
      vlanDomain.text = d.realm || ""
    userModel.clear()
    var users = d.users || []
    for (var u = 0; u < users.length; u++) {
      userModel.append({
        name: users[u].name || "",
        kind: users[u].kind || ""
      })
    }
    pkgModel.clear()
    var pkgs = d.packages || []
    var miss = 0
    for (var p = 0; p < pkgs.length; p++) {
      pkgModel.append({
        name: pkgs[p].name || "",
        installed: pkgs[p].installed === true,
        required: pkgs[p].required === true,
        why: pkgs[p].why || "",
        missing: pkgs[p].missing === true
      })
      if (pkgs[p].missing === true)
        miss++
    }
    missingPackages = miss
    if (!missingPrompted) {
      missingPrompted = true
      if (miss > 0) {
        page = "packages"
        statusLine = miss + (miss === 1 ? " required package is missing" : " required packages are missing")
      }
    }
    ingesting = false
  }

  function runPkexec(args) {
    applyBusy = true
    statusLine = "Waiting for polkit…"
    applyProc.running = false
    applyProc.command = ["pkexec"].concat(args)
    applyProc.running = true
  }

  function applyNetwork() {
    runPkexec([
      ctlPath, "apply-network",
      netIp.text.trim(), netPrefix.text.trim(), netGw.text.trim(),
      netIface.text.trim(), netDhcpStart.text.trim(), netDhcpEnd.text.trim(),
      netDnsFwd.text.trim()
    ])
  }

  function upsertVlan() {
    var spec = JSON.stringify({
      tag: parseInt(vlanTag.text, 10),
      parent: vlanParent.text.trim(),
      ip: vlanIp.text.trim(),
      prefix: vlanPrefix.text.trim() || "24",
      gateway: vlanGw.text.trim(),
      dhcp_start: vlanDhcpStart.text.trim(),
      dhcp_end: vlanDhcpEnd.text.trim(),
      search_domain: vlanDomain.text.trim()
    })
    runPkexec([ctlPath, "vlan-upsert", spec])
  }

  function deleteVlan(tag) {
    runPkexec([ctlPath, "vlan-delete", String(tag)])
  }

  function addHost() {
    runPkexec([ctlPath, "dns-add", dnsZone.text.trim(), dnsName.text.trim(), dnsIp.text.trim()])
  }

  function deleteHost(name, ip, zone) {
    runPkexec([ctlPath, "dns-del", zone, name, ip])
  }

  function addShare() {
    runPkexec([
      ctlPath, "share-add",
      shareName.text.trim(), sharePath.text.trim(),
      shareMode.text.trim() || "0770",
      shareRo.checked ? "yes" : "no",
      shareUsers.text.trim()
    ])
  }

  function setMode(mode) {
    runPkexec([ctlPath, "set-mode", mode])
  }

  function applyService(name, on) {
    if (ingesting)
      return
    if (name === "dhcp")
      dhcpEnabled = on
    else if (name === "dns")
      dnsEnabled = on
    runPkexec([ctlPath, "set-services", name + "=" + (on ? "on" : "off")])
  }

  function joinAd() {
    runPkexec([ctlPath, "join-ad", JSON.stringify({
      realm: joinRealm.text.trim(),
      dc: joinDc.text.trim(),
      admin: joinAdmin.text.trim() || "Administrator",
      password: joinPass.text,
      workgroup: joinWorkgroup.text.trim()
    })])
  }

  function addUser() {
    runPkexec([ctlPath, "user-add", JSON.stringify({
      name: userName.text.trim(),
      password: userPass.text
    })])
  }

  function deleteUser(name) {
    runPkexec([ctlPath, "user-del", name])
  }

  function installMissing() {
    runPkexec([ctlPath, "packages-install"])
  }

  onOpenedChanged: if (opened) {
    statusLine = ""
    missingPrompted = false
    refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  component TextButton: Item {
    id: btn
    property string label: ""
    property color foreground: root.foreground
    property bool enabled: true
    signal clicked()
    implicitHeight: Style.space(28)
    implicitWidth: lab.implicitWidth + Style.space(14)
    opacity: enabled ? 1 : 0.45
    Text {
      id: lab
      anchors.centerIn: parent
      text: btn.label
      color: btn.foreground
      font.family: root.fontFamily
      font.pixelSize: Style.font.body
    }
    MouseArea {
      anchors.fill: parent
      enabled: btn.enabled
      cursorShape: Qt.PointingHandCursor
      onClicked: btn.clicked()
    }
  }

  ListModel { id: vlanModel }
  ListModel { id: hostModel }
  ListModel { id: shareModel }
  ListModel { id: userModel }
  ListModel { id: pkgModel }

  Process {
    id: statusProc
    command: [root.ctlPath, "status"]
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.ingestStatus(text)
    }
  }

  Process {
    id: applyProc
    running: false
    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      id: applyErr
      waitForEnd: true
    }
    onExited: function(code) {
      root.applyBusy = false
      if (code === 0) {
        root.statusLine = "Applied"
      } else {
        var err = applyErr.text || "apply failed"
        root.statusLine = err.split("\n")[0]
      }
      root.refresh()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.hostWidget || root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

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
            title: "Omarchy NAS"
            meta: root.modeLabel
              + (root.hostname !== "" ? " · " + root.hostname : "")
              + (root.realm !== "" ? " · " + root.realm : "")
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            width: parent.width
            visible: root.statusLine !== ""
            text: root.statusLine
            color: root.applyBusy ? root.dim : root.urgent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            text: "DHCP " + (root.dhcpEnabled ? "on" : "off")
              + "  ·  DNS " + (root.dnsEnabled ? "on" : "off")
              + "  ·  Kea " + (root.keaState || "off")
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Row {
            width: parent.width
            spacing: Style.space(6)
            Repeater {
              model: root.tabs
              TextButton {
                required property var modelData
                label: modelData.label
                foreground: root.page === modelData.id ? root.foreground : root.dim
                onClicked: root.page = modelData.id
              }
            }
          }

          PanelSeparator { foreground: root.foreground }


          // ---- Mode ----
          Column {
            visible: root.page === "mode"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "DIRECTORY"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Host AD makes this box the domain controller. Join AD is a file server on someone else’s domain. Local users is Samba with accounts on this machine only."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(8)
              Repeater {
                model: [
                  { id: "host-ad", label: "Host AD" },
                  { id: "join-ad", label: "Join AD" },
                  { id: "local", label: "Local users" }
                ]
                TextButton {
                  required property var modelData
                  label: modelData.label
                  foreground: root.dirMode === modelData.id ? root.foreground : root.dim
                  enabled: !root.applyBusy
                  onClicked: root.setMode(modelData.id)
                }
              }
            }

            Text {
              visible: root.dirMode === "host-ad" && !root.isDc
              width: parent.width
              text: "AD is not provisioned yet. Run bin/omarchy-ad-dc-setup.sh once (sudo) after setting the untagged IP."
              color: root.urgent
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            PanelSectionHeader {
              text: "DHCP AND DNS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Each is optional. DHCP is Kea on this box. DNS for Host AD is Samba; turning it off still leaves AD SRV on Samba, but DHCP clients get the forwarder instead of this box."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Row {
              spacing: Style.space(10)
              Text {
                text: "DHCP"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              ToggleSwitch {
                id: dhcpSwitch
                checked: root.dhcpEnabled
                busy: root.applyBusy
                foreground: root.foreground
                onToggled: {
                  if (root.ingesting || root.applyBusy)
                    return
                  root.applyService("dhcp", !root.dhcpEnabled)
                }
              }
            }

            Row {
              spacing: Style.space(10)
              Text {
                text: "DNS"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              ToggleSwitch {
                id: dnsSwitch
                checked: root.dnsEnabled
                busy: root.applyBusy
                foreground: root.foreground
                onToggled: {
                  if (root.ingesting || root.applyBusy)
                    return
                  root.applyService("dns", !root.dnsEnabled)
                }
              }
            }

            Column {
              visible: root.dirMode === "join-ad"
              width: parent.width
              spacing: Style.space(8)

              PanelSectionHeader {
                text: "JOIN EXISTING DOMAIN"
                foreground: root.foreground
                fontFamily: root.fontFamily
              }

              TextField { id: joinRealm; width: parent.width; foreground: root.foreground; placeholderText: "Realm (office.lan)" }
              TextField { id: joinDc; width: parent.width; foreground: root.foreground; placeholderText: "Domain controller IP or name" }
              TextField { id: joinWorkgroup; width: parent.width; foreground: root.foreground; placeholderText: "Workgroup (OFFICE)" }
              TextField { id: joinAdmin; width: parent.width; foreground: root.foreground; placeholderText: "Admin (Administrator)" }
              TextField { id: joinPass; width: parent.width; foreground: root.foreground; placeholderText: "Admin password"; echoMode: TextInput.Password }

              TextButton {
                label: root.applyBusy ? "Joining…" : "Join domain"
                enabled: !root.applyBusy
                foreground: root.foreground
                onClicked: root.joinAd()
              }
            }
          }

          // ---- Network (untagged / native LAN) ----
          Column {
            visible: root.page === "network"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "UNTAGGED LAN"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "This box’s main IP. DHCP below is the pool on this same subnet. Tagged networks live under VLANs."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField { id: netIface; width: parent.width; foreground: root.foreground; placeholderText: "Interface (e.g. eth0)" }
            TextField { id: netIp; width: parent.width; foreground: root.foreground; placeholderText: "Static IP" }
            TextField { id: netPrefix; width: parent.width; foreground: root.foreground; placeholderText: "Prefix (24)" }
            TextField { id: netGw; width: parent.width; foreground: root.foreground; placeholderText: "Gateway" }
            TextField { id: netDhcpStart; width: parent.width; foreground: root.foreground; placeholderText: "DHCP start (used when DHCP is on)"; visible: root.dhcpEnabled }
            TextField { id: netDhcpEnd; width: parent.width; foreground: root.foreground; placeholderText: "DHCP end"; visible: root.dhcpEnabled }
            TextField { id: netDnsFwd; width: parent.width; foreground: root.foreground; placeholderText: "DNS forwarder (1.1.1.1)"; visible: !root.dnsEnabled }

            TextButton {
              label: root.applyBusy ? "Applying…" : "Apply network + DHCP"
              enabled: !root.applyBusy
              foreground: root.foreground
              onClicked: root.applyNetwork()
            }
          }

          // ---- VLANs ----
          Column {
            visible: root.page === "vlans"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "TAGGED VLANS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Each tag gets its own interface, address, DHCP pool, and Samba reverse zone. Clients on that VLAN get this box as DNS. AD stays one realm."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: vlanModel
              Column {
                required property var modelData
                width: column.width
                spacing: Style.space(4)

                Text {
                  width: parent.width
                  text: "VLAN " + modelData.tag + "  ·  " + modelData.ifname
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  font.bold: true
                }
                Text {
                  width: parent.width
                  text: modelData.ip + "/" + modelData.prefix
                    + (modelData.dhcp_start !== "" ? ("  ·  DHCP " + modelData.dhcp_start + "–" + modelData.dhcp_end) : "  ·  no DHCP")
                    + (modelData.search_domain !== "" ? ("  ·  " + modelData.search_domain) : "")
                  color: root.dim
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  wrapMode: Text.WordWrap
                }
                TextButton {
                  label: "Remove VLAN " + modelData.tag
                  foreground: root.urgent
                  enabled: !root.applyBusy
                  onClicked: root.deleteVlan(modelData.tag)
                }
              }
            }

            Text {
              visible: vlanModel.count === 0
              width: parent.width
              text: "No tagged VLANs yet."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            PanelSectionHeader {
              text: "ADD OR UPDATE"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            TextField { id: vlanTag; width: parent.width; foreground: root.foreground; placeholderText: "VLAN tag (10)" }
            TextField { id: vlanParent; width: parent.width; foreground: root.foreground; placeholderText: "Parent NIC" }
            TextField { id: vlanIp; width: parent.width; foreground: root.foreground; placeholderText: "DC IP on this VLAN" }
            TextField { id: vlanPrefix; width: parent.width; foreground: root.foreground; placeholderText: "Prefix (24)" }
            TextField { id: vlanGw; width: parent.width; foreground: root.foreground; placeholderText: "Gateway (usually this IP)" }
            TextField { id: vlanDhcpStart; width: parent.width; foreground: root.foreground; placeholderText: "DHCP start" }
            TextField { id: vlanDhcpEnd; width: parent.width; foreground: root.foreground; placeholderText: "DHCP end" }
            TextField { id: vlanDomain; width: parent.width; foreground: root.foreground; placeholderText: "DNS search domain (office.lan)" }

            TextButton {
              label: root.applyBusy ? "Applying…" : "Apply VLAN"
              enabled: !root.applyBusy
              foreground: root.foreground
              onClicked: root.upsertVlan()
            }
          }

          // ---- DNS hosts ----
          Column {
            visible: root.page === "dns"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "MANUAL A RECORDS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: "Names in the AD zone. VLAN DHCP already hands out this box as nameserver; reverse zones are created when you apply a VLAN."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            TextField { id: dnsZone; width: parent.width; foreground: root.foreground; placeholderText: "Zone (office.lan)" }
            TextField { id: dnsName; width: parent.width; foreground: root.foreground; placeholderText: "Host name (printer)" }
            TextField { id: dnsIp; width: parent.width; foreground: root.foreground; placeholderText: "IPv4" }

            TextButton {
              label: "Add record"
              enabled: !root.applyBusy
              foreground: root.foreground
              onClicked: root.addHost()
            }

            Repeater {
              model: hostModel
              Row {
                required property var modelData
                width: column.width
                spacing: Style.space(8)
                Text {
                  width: parent.width - Style.space(80)
                  text: modelData.name + "  →  " + modelData.ip
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
                TextButton {
                  label: "Del"
                  foreground: root.urgent
                  enabled: !root.applyBusy
                  onClicked: root.deleteHost(modelData.name, modelData.ip, modelData.zone)
                }
              }
            }
          }

          // ---- Shares ----
          Column {
            visible: root.page === "shares"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "FILE SHARES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Repeater {
              model: shareModel
              Text {
                required property var modelData
                width: column.width
                text: modelData.name + "  ·  " + modelData.path
                  + (modelData.read_only === "yes" ? "  (read only)" : "")
                  + (modelData.valid_users !== "" ? ("  ·  " + modelData.valid_users) : "")
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                wrapMode: Text.WordWrap
              }
            }

            TextField { id: shareName; width: parent.width; foreground: root.foreground; placeholderText: "Share name" }
            TextField { id: sharePath; width: parent.width; foreground: root.foreground; placeholderText: "Path (/srv/samba/office)" }
            TextField { id: shareMode; width: parent.width; foreground: root.foreground; placeholderText: "Unix mode (0770)" }
            TextField { id: shareUsers; width: parent.width; foreground: root.foreground; placeholderText: "valid users (optional, e.g. @\"Domain Users\")" }

            Row {
              spacing: Style.space(8)
              Text {
                text: "Read only"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                anchors.verticalCenter: parent.verticalCenter
              }
              ToggleSwitch {
                id: shareRo
                checked: false
                foreground: root.foreground
              }
            }

            TextButton {
              label: "Add share"
              enabled: !root.applyBusy
              foreground: root.foreground
              onClicked: root.addShare()
            }
          }

          Column {
            visible: root.page === "users"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: root.dirMode === "host-ad" ? "DOMAIN USERS" : "LOCAL SAMBA USERS"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: root.dirMode === "host-ad"
                ? "These are Samba AD accounts on this box."
                : "Unix + Samba accounts stored on this machine. No domain."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: userModel
              Row {
                required property var modelData
                width: column.width
                spacing: Style.space(8)
                Text {
                  width: parent.width - Style.space(80)
                  text: modelData.name + (modelData.kind !== "" ? ("  ·  " + modelData.kind) : "")
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  anchors.verticalCenter: parent.verticalCenter
                }
                TextButton {
                  label: "Del"
                  foreground: root.urgent
                  enabled: !root.applyBusy
                  onClicked: root.deleteUser(modelData.name)
                }
              }
            }

            TextField { id: userName; width: parent.width; foreground: root.foreground; placeholderText: "Username" }
            TextField { id: userPass; width: parent.width; foreground: root.foreground; placeholderText: "Password"; echoMode: TextInput.Password }

            TextButton {
              label: "Add user"
              enabled: !root.applyBusy
              foreground: root.foreground
              onClicked: root.addUser()
            }
          }

          Column {
            visible: root.page === "packages"
            width: parent.width
            spacing: Style.space(8)

            PanelSectionHeader {
              text: "PACKAGES"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Text {
              width: parent.width
              text: root.missingPackages > 0
                ? (root.missingPackages + " required for this mode are not installed. Polkit will ask, then omarchy-pkg-add (or pacman) runs.")
                : "Everything this mode needs is installed."
              color: root.missingPackages > 0 ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Repeater {
              model: pkgModel
              Row {
                required property var modelData
                width: column.width
                spacing: Style.space(8)

                Text {
                  width: Style.space(18)
                  text: modelData.installed ? "✓" : (modelData.required ? "!" : "·")
                  color: modelData.installed ? root.foreground : (modelData.required ? root.urgent : root.dim)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
                Column {
                  width: parent.width - Style.space(30)
                  spacing: Style.space(1)
                  Text {
                    width: parent.width
                    text: modelData.name + (modelData.required ? "" : "  (optional)")
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    elide: Text.ElideRight
                  }
                  Text {
                    width: parent.width
                    text: modelData.why + (modelData.installed ? "  ·  installed" : "  ·  not installed")
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    wrapMode: Text.WordWrap
                  }
                }
              }
            }

            TextButton {
              visible: root.missingPackages > 0
              label: root.applyBusy ? "Installing…" : "Install missing"
              enabled: !root.applyBusy
              foreground: root.foreground
              onClicked: root.installMissing()
            }
          }
        }
      }
    }
  }
}
