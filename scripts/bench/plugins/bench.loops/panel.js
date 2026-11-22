const pulse = { opacity: [0.3, 1], scale: [0.8, 1.1], duration: 1, reverse: true };
let renders = 0;

function dots(mode) {
  return Array.from({ length: 20 }, (_, index) => {
    const dot = { type: "icon", key: `d${index}`, symbol: "circle.fill" };

    return mode === "loops" ? { ...dot, loop: pulse } : dot;
  });
}

export default {
  surface: { width: 600, height: 240 },

  render(state) {
    const { mode = "loops" } = state.settings;
    renders += 1;

    if (mode === "shader") {
      return {
        type: "shader",
        path: "glow.metal",
        function: "glow",
        args: [0.2, 0.5, 1, 1],
        animated: true,
        width: 200,
        height: 200,
      };
    }

    return { type: "row", gap: 8, padding: 16, children: dots(mode) };
  },

  methods: {
    stats: () => ({ renders, at: Date.now() }),
  },
};
