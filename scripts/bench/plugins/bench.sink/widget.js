let frames = 0;
let renders = 0;
let timer = null;

module.exports = {
  render(state) {
    const { hz = 30 } = state.settings;
    renders += 1;

    if (timer === null && hz > 0) {
      timer = setInterval(() => {
        frames += 1;
      }, 1000 / hz);
    }

    const feed = state["bench.feed"];

    return { type: "text", text: `${feed ? feed.published : 0}/${frames}`, style: "dim" };
  },

  methods: {
    stats: () => ({ frames, renders, at: Date.now() }),
  },
};
