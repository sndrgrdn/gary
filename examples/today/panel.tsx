const pad = (n: number) => String(n).padStart(2, "0");

function week(date: Date) {
  const day = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()));
  day.setUTCDate(day.getUTCDate() + 4 - (day.getUTCDay() || 7));

  return Math.ceil(((day.getTime() - Date.UTC(day.getUTCFullYear(), 0, 1)) / 86400000 + 1) / 7);
}

export default {
  surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },

  render(state) {
    const date = new Date(state.clock ? state.clock.epoch : Date.now());

    const day = date.toLocaleDateString("en-GB", {
      weekday: "long",
      day: "numeric",
      month: "long",
    });

    const lines: Gary.Node[] = [
      <text key="title" style="title">
        {day}
      </text>,
      <text key="time" style="bright">
        {`${pad(date.getHours())}:${pad(date.getMinutes())}  ·  week ${week(date)}`}
      </text>,
    ];

    const battery = state.battery;

    if (battery && battery.present) {
      lines.push(
        <row key="battery">
          <icon symbol={battery.charging ? "bolt.fill" : "battery.75percent"} style="dim" />
          <text style="dim">
            {battery.percent}% {battery.source === "ac" ? "on power" : "on battery"}
          </text>
        </row>,
      );
    }

    return <column style="panel">{lines}</column>;
  },
} satisfies Gary.Panel;
