const rows = Array.from({ length: 120 }, (_, i) => i);

export default {
  surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 8 } },
  render() {
    return {
      type: "column",
      key: "card",
      width: 360,
      padding: 8,
      gap: 6,
      children: [
        { type: "text", key: "title", style: "title", text: "Bench menu" },
        {
          type: "scroll",
          key: "list",
          height: 420,
          children: rows.map((i) => ({
            type: "row",
            key: `r${i}`,
            gap: 8,
            padding: [4, 6],
            children: [
              { type: "icon", key: "i", symbol: i % 2 ? "star" : "circle" },
              { type: "text", key: "t", text: `Row ${i}` },
              { type: "text", key: "d", style: "dim", text: `detail ${i * 7}` },
            ],
          })),
        },
      ],
    };
  },
};
