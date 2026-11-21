const pad = (n) => String(n).padStart(2, "0");

const week = (date) => {
  const day = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  day.setUTCDate(day.getUTCDate() + 4 - (day.getUTCDay() || 7));
  return Math.ceil(((day - Date.UTC(day.getUTCFullYear(), 0, 1)) / 86400000 + 1) / 7);
};

module.exports = {
  surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },

  render(state) {
    const date = new Date(state.clock ? state.clock.epoch : Date.now());
    const day = date.toLocaleDateString("en-GB", { weekday: "long", day: "numeric", month: "long" });
    const lines = [
      { type: "text", key: "title", text: day, style: "title" },
      { type: "text", key: "time", text: pad(date.getHours()) + ":" + pad(date.getMinutes()) + "  ·  week " + week(date), style: "bright" },
    ];
    const battery = state.battery;
    if (battery && battery.present) {
      lines.push({
        type: "row",
        key: "battery",
        children: [
          { type: "icon", symbol: battery.charging ? "bolt.fill" : "battery.75percent", style: "dim" },
          { type: "text", text: battery.percent + "% " + (battery.source === "ac" ? "on power" : "on battery"), style: "dim" },
        ],
      });
    }
    return { type: "column", children: lines };
  },
};
