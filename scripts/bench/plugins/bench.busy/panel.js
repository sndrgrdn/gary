const perRow = 20;
let frames = 0;
let renders = 0;
let timer = null;

function cells(row, count, last) {
  return Array.from({ length: count }, (_, column) => {
    const index = row * perRow + column;
    const changing = last && column === count - 1;

    return {
      type: "text",
      key: `c${index}`,
      text: changing ? `frame ${frames}` : `cell ${index}`,
      style: "dim",
    };
  });
}

function tree(nodes) {
  const rows = Math.ceil((nodes - 1) / (perRow + 1));
  let leaves = nodes - 1 - rows;

  const children = Array.from({ length: rows }, (_, row) => {
    const count = Math.min(perRow, leaves);
    leaves -= count;

    return { type: "row", key: `r${row}`, gap: 4, children: cells(row, count, row === rows - 1) };
  });

  return { type: "column", gap: 2, padding: 8, children };
}

module.exports = {
  surface: { width: 1200, height: 900 },

  render(state) {
    const { nodes = 100, hz = 30 } = state.settings;
    renders += 1;

    if (timer === null && hz > 0) {
      timer = setInterval(() => {
        frames += 1;
      }, 1000 / hz);
    }

    return tree(nodes);
  },

  methods: {
    stats: () => ({ frames, renders, at: Date.now() }),
  },
};
