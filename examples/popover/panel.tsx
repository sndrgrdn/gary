function parseCount(value: Gary.Json | undefined): number {
  if (!(value instanceof Object) || Array.isArray(value)) {
    return 0;
  }

  const count = Number(value.count);

  return Number.isFinite(count) ? count : 0;
}

export default {
  surface: { attach: true, margins: { top: 6 }, anchors: { top: true, right: true } },

  render(state) {
    return (
      <column style="panel" gap={8}>
        <text key="title" style="title">
          Popover
        </text>
        <text key="count" style="bright">
          Count: {parseCount(state["example.popover"])}
        </text>
        <button key="close" action="close" style="button">
          <text>Close</text>
        </button>
      </column>
    );
  },

  onAction(action) {
    if (action === "close") {
      host.hide();
    }
  },
} satisfies Gary.Panel;
