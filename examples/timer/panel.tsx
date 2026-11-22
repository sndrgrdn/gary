function parseMinutes(value: Gary.Json | undefined): number {
  const minutes = Number(value);

  return Number.isInteger(minutes) && minutes >= 5 && minutes <= 60 ? minutes : 25;
}

function parseFraction(payload: Gary.ActionPayload): number | null {
  const fraction = Number(payload);

  return payload !== null && payload !== "" && fraction >= 0 && fraction <= 1 ? fraction : null;
}

let minutes = parseMinutes(host.storage.get("minutes"));
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

function Button({ action, label }: { action: string; label: string }) {
  return (
    <button key={action} action={action} hover="hover" padding={6}>
      <text>{label}</text>
    </button>
  );
}

export default {
  surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },

  render() {
    const length = minutes * 60_000;
    const left = endsAt === null ? length : Math.max(0, endsAt - now);

    return (
      <column style="panel" gap={10} animation="smooth">
        <text key="title" style="title">
          Timer
        </text>
        <text key="left" style="bright" fontSize={28}>
          {format(left)}
        </text>
        <progress key="progress" value={1 - left / length} width={220} />
        <row key="length" gap={8}>
          <slider key="slider" value={(minutes - 5) / 55} action="minutes" width={160} />
          <text key="minutes" style="dim">
            {minutes} min
          </text>
        </row>
        <row key="buttons" gap={8}>
          {endsAt === null ? (
            <Button action="start" label="Start" />
          ) : (
            <Button action="stop" label="Stop" />
          )}
          <Button action="close" label="Close" />
        </row>
      </column>
    );
  },

  onAction(action, payload) {
    const fraction = parseFraction(payload);

    if (action === "minutes" && fraction !== null && endsAt === null) {
      minutes = Math.round(5 + fraction * 55);
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
