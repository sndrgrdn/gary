let everything = host.storage.get("everything") === true;
let waitingFor: Gary.PermissionName | null = null;

function needed(permissions: Gary.PermissionStatus[]) {
  return permissions.filter((permission) => everything || permission.plugins.length > 0);
}

function request(name: Gary.PermissionName) {
  host.permissions.request(name).then((message) => host.log(message));
}

function grantNext(permissions: Gary.PermissionStatus[]) {
  const next = permissions.find((permission) => permission.status !== "granted");
  if (next?.name === waitingFor) return;
  waitingFor = next?.name ?? null;
  if (next) request(next.name);
}

function rows(permission: Gary.PermissionStatus): Gary.Node[] {
  const key = permission.name;
  const used = new Set(permission.plugins.flatMap((plugin) => plugin.capabilities));
  const capabilities = permission.capabilities.filter((capability) => used.size === 0 || used.has(capability.name));
  const lines: Gary.Node[] = [
    { type: "row", key, children: [{ type: "text", key: "title", text: permission.title, style: "bright" }, { type: "spacer", key: "gap" }, status(permission)] },
    ...capabilities.map((capability): Gary.Node => (
      { type: "text", key: `${key}-${capability.name}`, text: `${capability.name}: ${capability.summary.replace(/\. .*$/, ".")}`, style: "dim" }
    )),
  ];
  if (permission.plugins.length > 0) {
    lines.push({ type: "text", key: `${key}-plugins`, text: "Used by " + permission.plugins.map((plugin) => plugin.name).join(", "), style: "dim" });
  }
  if (permission.restart && permission.status !== "granted") {
    lines.push({ type: "text", key: `${key}-restart`, text: "Gary sees this grant after a restart: gary quit, then open Gary.", style: "dim" });
  }
  return lines;
}

function status(permission: Gary.PermissionStatus): Gary.Node {
  if (permission.status === "granted") {
    return { type: "row", key: "status", children: [{ type: "icon", key: "icon", symbol: "checkmark.circle.fill", style: "good" }, { type: "text", key: "text", text: "Granted", style: "good" }] };
  }
  const label = permission.status === "denied" ? "Open Settings" : "Grant";
  return { type: "button", key: "status", style: "selected", padding: 6, action: permission.name, children: [{ type: "text", text: label }] };
}

function button(action: string, text: string): Gary.Node {
  return { type: "button", key: action, action, style: "selected", padding: 6, children: [{ type: "text", text }] };
}

module.exports = {
  surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 }, layer: "normal" },

  onTopic(topic, value) {
    if (topic === "permissions" && waitingFor) grantNext(value as unknown as Gary.PermissionStatus[]);
  },

  render(state) {
    const permissions = needed(state.permissions ?? []);
    const missing = permissions.filter((permission) => permission.status !== "granted");
    const intro = missing.length === 0
      ? (permissions.length === 0 ? "Your enabled plugins need no macOS permissions." : "All granted. Gary has every permission listed here.")
      : "macOS asks you to approve each permission for Gary. Grant one, and its row updates.";
    return {
      type: "column",
      style: "panel",
      children: [
        { type: "text", key: "title", text: everything ? "Gary permissions" : "Permissions for your plugins", style: "title" },
        { type: "text", key: "intro", text: intro, style: "dim" },
        ...permissions.flatMap(rows),
        {
          type: "row",
          key: "actions",
          children: [
            everything && missing.length === 0 ? { type: "spacer", key: "none" } : button("everything", "Grant everything"),
            { type: "spacer", key: "gap" },
            button("close", missing.length === 0 ? "Done" : "Later"),
          ],
        },
      ],
    };
  },

  onAction(action, _payload, state) {
    const permissions = state.permissions ?? [];
    if (action === "close") return host.hide();
    if (action === "everything") {
      everything = true;
      host.storage.set("everything", true);
      return grantNext(permissions);
    }
    const permission = permissions.find((each) => each.name === action);
    if (permission) request(permission.name);
  },
} satisfies Gary.Panel;
