const symbol = (percent, charging) => {
  if (charging) {
    return "battery.100percent.bolt";
  }

  const level = [0, 25, 50, 75, 100].reduce((best, step) => (percent >= step ? step : best), 0);

  return `battery.${level}percent`;
};

export default {
  render(state) {
    const battery = state.battery;

    if (!battery || !battery.present) {
      return { type: "row", children: [] };
    }

    const style = battery.source === "ac" ? "good" : battery.percent <= 20 ? "bad" : "default";

    return {
      type: "row",
      children: [
        { type: "icon", key: "icon", symbol: symbol(battery.percent, battery.charging), style },
        { type: "text", key: "percent", text: `${battery.percent}%` },
      ],
    };
  },
};
