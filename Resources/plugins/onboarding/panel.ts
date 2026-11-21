type Status = Gary.PermissionStatus;

const permissions: Record<
  Gary.PermissionName,
  { symbol: string; general: string; uses: Record<string, string> }
> = {
  accessibility: {
    symbol: "hand.raised.fill",
    general:
      "Lets plugins use your volume and brightness keys, paste for you, and open menu bar items.",
    uses: {
      mediakeys: "use your volume and brightness keys",
      paste: "paste into the app you're using",
      tray: "open your menu bar items",
    },
  },
  bluetooth: {
    symbol: "antenna.radiowaves.left.and.right",
    general: "Lets plugins show your Bluetooth devices and connect them.",
    uses: { bluetooth: "show your Bluetooth devices and connect them" },
  },
  "full-disk-access": {
    symbol: "internaldrive.fill",
    general: "Lets plugins show your current Focus and the notifications you receive.",
    uses: { focus: "show your current Focus", notifications: "show the notifications you receive" },
  },
  location: {
    symbol: "location.fill",
    general: "Lets plugins show the name of your Wi-Fi network.",
    uses: { wifi: "show the name of your Wi-Fi network" },
  },
  "screen-recording": {
    symbol: "rectangle.dashed.badge.record",
    general: "Lets plugins show the icons of your menu bar items.",
    uses: { tray: "show the icons of your menu bar items" },
  },
};

let allowingAll = false;

function listed(all: Status[]) {
  const needed = all.filter((permission) => permission.plugins.length > 0);

  return needed.length > 0 ? needed : all;
}

function isDone(permission: Status) {
  return permission.status === "granted" || permission.status === "needsRestart";
}

function sentence(parts: string[]) {
  return parts.length < 2 ? parts.join("") : `${parts.slice(0, -1).join(", ")} and ${parts.at(-1)}`;
}

function benefit(permission: Status) {
  const copy = permissions[permission.name];

  const parts = permission.plugins
    .map((plugin) => {
      const uses = [
        ...new Set(plugin.capabilities.map((capability) => copy.uses[capability]).filter(Boolean)),
      ];

      return uses.length > 0 ? `${plugin.name} ${sentence(uses)}` : null;
    })
    .filter((part): part is string => part !== null);

  return parts.length > 0 ? `Lets ${sentence(parts)}.` : copy.general;
}

function button(action: string, text: string, primary = false): Gary.Node {
  return {
    type: "button",
    key: action,
    action,
    style: primary ? "primary" : "button",
    hover: primary ? "primary-hover" : "button-hover",
    gap: 0,
    children: [
      { type: "spacer", key: "lead", width: 6 },
      { type: "text", key: "text", text, color: primary ? "on-accent" : "foreground" },
      { type: "spacer", key: "trail", width: 6 },
    ],
  };
}

function footer(missing: Status[], restarting: boolean): Gary.Node[] {
  const nodes: Gary.Node[] = missing.length > 0 || restarting ? [button("close", "Not now")] : [];
  nodes.push({ type: "spacer", key: "push" });

  if (missing.length > 1) {
    nodes.push(button("all", "Allow all", true));
  }

  if (missing.length === 0 && !restarting) {
    nodes.push(button("close", "Done", true));
  }

  return nodes;
}

function statusControl(permission: Status): Gary.Node {
  switch (permission.status) {
    case "granted":
      return {
        type: "row",
        key: "state",
        gap: 4,
        children: [
          { type: "icon", key: "check", symbol: "checkmark.circle.fill", style: "good" },
          { type: "text", key: "text", text: "Allowed", style: "good" },
        ],
      };
    case "needsRestart":
      return button("restart", "Restart Gary", true);
    case "denied":
      return button(permission.name, "Open Settings…");
    default:
      return button(permission.name, "Allow…");
  }
}

function row(permission: Status): Gary.Node {
  return {
    type: "row",
    key: permission.name,
    gap: 12,
    children: [
      {
        type: "icon",
        key: "symbol",
        symbol: permissions[permission.name].symbol,
        width: 30,
        height: 30,
        radius: 7,
        fontSize: 14,
        background: "accent",
        color: "on-accent",
      },
      {
        type: "column",
        key: "text",
        gap: 2,
        children: [
          { type: "text", key: "title", text: permission.title, style: "bright", font: "strong" },
          { type: "text", key: "benefit", text: benefit(permission), style: "secondary" },
        ],
      },
      { type: "spacer", key: "push" },
      statusControl(permission),
    ],
  };
}

function intro(shown: Status[], missing: Status[], restarting: boolean) {
  const noneNeeded = shown.every((permission) => permission.plugins.length === 0);

  if (missing.length > 0 && noneNeeded) {
    return "None of your plugins need these yet. Allow them now, and plugins you add later work right away.";
  }

  if (missing.length > 0) {
    return "Your plugins need a few permissions from macOS. Allow each one, and its row updates.";
  }

  if (restarting) {
    return "Restart Gary to finish. macOS gives Gary these permissions when it starts.";
  }

  return noneNeeded
    ? "Gary has every permission a plugin can ask for."
    : "Gary has everything your plugins need.";
}

function allowNext(all: Status[]) {
  const next = listed(all).find((permission) => !isDone(permission));

  if (next) {
    host.permissions.request(next.name).then((message) => host.log(message));
  } else {
    allowingAll = false;
  }

  return next;
}

let waitingFor: Gary.PermissionName | undefined;

module.exports = {
  surface: { width: 520, layer: "normal" },

  onTopic(topic, value) {
    if (topic !== "permissions" || !allowingAll) {
      return;
    }

    const all = value as unknown as Status[];
    const waiting = all.find((permission) => permission.name === waitingFor);

    if (!waiting || isDone(waiting)) {
      waitingFor = allowNext(all)?.name;
    }
  },

  render(state) {
    const all = state.permissions ?? [];
    const shown = listed(all);
    const missing = shown.filter((permission) => !isDone(permission));
    const restarting = shown.some((permission) => permission.status === "needsRestart");

    return {
      type: "column",
      key: "onboarding",
      padding: 22,
      gap: 18,
      children: [
        {
          type: "row",
          key: "header",
          gap: 14,
          children: [
            { type: "image", key: "icon", path: "../../Gary.icns", width: 64, height: 64 },
            {
              type: "column",
              key: "text",
              gap: 4,
              children: [
                { type: "text", key: "title", text: "Set up Gary", style: "title", fontSize: 20 },
                {
                  type: "text",
                  key: "intro",
                  text: intro(shown, missing, restarting),
                  style: "secondary",
                },
              ],
            },
          ],
        },
        {
          type: "column",
          key: "rows",
          gap: 16,
          padding: 14,
          radius: 10,
          background: "control",
          children: shown.map((permission) => row(permission)),
        },
        { type: "row", key: "footer", gap: 8, children: footer(missing, restarting) },
      ],
    };
  },

  onAction(action, _payload, state) {
    const all = state.permissions ?? [];

    if (action === "close") {
      return host.hide();
    }

    if (action === "restart") {
      return void host.permissions.restart().then((message) => host.log(message));
    }

    if (action === "all") {
      allowingAll = true;
      waitingFor = allowNext(all)?.name;

      return;
    }

    const permission = all.find((each) => each.name === action);

    if (permission) {
      host.permissions.request(permission.name).then((message) => host.log(message));
    }
  },
} satisfies Gary.Panel;
