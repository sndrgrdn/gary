const pad = (n) => String(n).padStart(2, "0");

module.exports = {
  render(state) {
    const date = new Date(state.clock ? state.clock.epoch : Date.now());
    const hours = state.settings.hour12 ? ((date.getHours() + 11) % 12) + 1 : pad(date.getHours());
    return { type: "text", text: `${hours}:${pad(date.getMinutes())}`, style: "bright" };
  },
};
