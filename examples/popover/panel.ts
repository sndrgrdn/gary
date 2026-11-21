function parseCount(value: Gary.Json | undefined): number {
  if (!(value instanceof Object) || Array.isArray(value)) {
    return 0;
  }

  const count = Number(value.count);

  return Number.isFinite(count) ? count : 0;
}

module.exports = {
  surface: { attach: true, margins: { top: 6 }, anchors: { top: true, right: true } },

  render(state) {
    return {
      type: "column",
      style: "panel",
      gap: 8,
      children: [
        { type: "text", key: "title", text: "Popover", style: "title" },
        {
          type: "text",
          key: "count",
          text: `Count: ${parseCount(state["example.popover"])}`,
          style: "bright",
        },
        {
          type: "button",
          key: "close",
          action: "close",
          style: "button",
          children: [{ type: "text", text: "Close" }],
        },
      ],
    };
  },

  onAction(action) {
    if (action === "close") {
      host.hide();
    }
  },
} satisfies Gary.Panel;
