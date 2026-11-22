const step = 1 / 16;
let hideTimer = 0;

host.mediakeys.intercept(["volume-up", "volume-down"]);

function parseLevel(payload: Gary.ActionPayload): number | null {
  const level = Number(payload);

  return payload !== null && payload !== "" && level >= 0 && level <= 1 ? level : null;
}

function volume(state: Gary.State): number {
  return state.audio?.output?.volume ?? 0;
}

function flash() {
  host.show("osd");
  clearTimeout(hideTimer);
  hideTimer = setTimeout(() => host.hide("osd"), 1500);
}

function nudge(state: Gary.State, by: number) {
  host.audio.setVolume(Math.min(1, Math.max(0, volume(state) + by)));
  flash();
}

function Button({ action, label }: { action: string; label: string }) {
  return (
    <button key={action} action={action} style="button">
      <text>{label}</text>
    </button>
  );
}

function osd(state: Gary.State): Gary.Node {
  const level = volume(state);

  return (
    <row
      gap={12}
      padding={[14, 18]}
      radius={18}
      material="vibrant"
      background="alpha(panel, 0.5)"
      animation="smooth"
    >
      <icon
        key="icon"
        symbol={level === 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"}
        fontSize={18}
        width={24}
      />
      <progress key="level" value={level} width={180} />
    </row>
  );
}

function settings(state: Gary.State): Gary.Node {
  return (
    <column style="panel" gap={10}>
      <text key="title" style="title">
        Volume
      </text>
      <slider key="volume" value={volume(state)} action="volume" width={220} />
      <row key="buttons" gap={8}>
        <Button action="down" label="−" />
        <Button action="up" label="+" />
        <Button action="flash" label="Show OSD" />
        <Button action="close" label="Close" />
      </row>
    </column>
  );
}

export default {
  surfaces: {
    main: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },
    osd: {
      anchors: { bottom: true },
      margins: 80,
      layer: "overlay",
      clickThrough: true,
      background: "none",
    },
  },

  render(state) {
    return state.surface === "osd" ? osd(state) : settings(state);
  },

  onMediaKey(event, state) {
    nudge(state, event.key === "volume-up" ? step : -step);
  },

  onAction(action, payload, state) {
    const level = parseLevel(payload);

    if (action === "volume" && level !== null) {
      host.audio.setVolume(level);
      flash();
    }

    if (action === "up" || action === "down") {
      nudge(state, action === "up" ? step : -step);
    }

    if (action === "flash") {
      flash();
    }

    if (action === "close") {
      host.hide();
    }
  },
} satisfies Gary.Panel;
