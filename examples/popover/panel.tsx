export default {
  surface: { attach: true, margins: { top: 6 }, anchors: { top: true, right: true } },

  render(state) {
    return (
      <column style="panel" gap={8}>
        <text key="title" style="title">
          Popover
        </text>
        <text key="count" style="bright">
          Count: {state["example.popover"]?.count ?? 0}
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
