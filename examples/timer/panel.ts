const saved = host.storage.get("minutes");
let minutes = typeof saved === "number" ? saved : 25;
let endsAt: number | null = null;
let now = Date.now();
let ticker: number | null = null;

function start() {
  endsAt = Date.now() + minutes * 60_000;
  now = Date.now();
  ticker = setInterval(() => {
    now = Date.now();
    if (endsAt !== null && now >= endsAt) {
      stop();
      host.log("timer finished");
      host.show();
    }
  }, 1000);
}

function stop() {
  if (ticker !== null) {
    clearInterval(ticker);
  }
  ticker = null;
  endsAt = null;
}

function format(milliseconds: number) {
  const seconds = Math.ceil(milliseconds / 1000);
  return `${Math.floor(seconds / 60)}:${String(seconds % 60).padStart(2, "0")}`;
}

function button(action: string, label: string): Gary.Node {
  return {
    type: "button",
    key: action,
    action,
    hover: "hover",
    padding: 6,
    children: [{ type: "text", text: label }],
  };
}

module.exports = {
  surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },

  render() {
    const length = minutes * 60_000;
    const left = endsAt === null ? length : Math.max(0, endsAt - now);
    return {
      type: "column",
      style: "panel",
      gap: 10,
      animation: "smooth",
      children: [
        { type: "text", key: "title", text: "Timer", style: "title" },
        { type: "text", key: "left", text: format(left), style: "bright", fontSize: 28 },
        { type: "progress", key: "progress", value: 1 - left / length, width: 220 },
        {
          type: "row",
          key: "length",
          gap: 8,
          children: [
            {
              type: "slider",
              key: "slider",
              value: (minutes - 5) / 55,
              action: "minutes",
              width: 160,
            },
            { type: "text", key: "minutes", text: `${minutes} min`, style: "dim" },
          ],
        },
        {
          type: "row",
          key: "buttons",
          gap: 8,
          children: [
            endsAt === null ? button("start", "Start") : button("stop", "Stop"),
            button("close", "Close"),
          ],
        },
      ],
    };
  },

  onAction(action, payload) {
    if (action === "minutes" && typeof payload === "number" && endsAt === null) {
      minutes = Math.round(5 + payload * 55);
      host.storage.set("minutes", minutes);
    }
    if (action === "start") {
      start();
    }
    if (action === "stop") {
      stop();
    }
    if (action === "close") {
      host.hide();
    }
  },

  onKey(key) {
    if (key === "escape") {
      host.hide();
    }
  },
} satisfies Gary.Panel;
