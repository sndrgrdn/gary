let ticks = 0;
let renders = 0;

setInterval(() => {
  ticks += 1;
}, 1000);

export default {
  render() {
    renders += 1;

    return { type: "text", text: `tick ${ticks}`, style: "dim" };
  },

  methods: {
    stats: () => ({ renders, ticks, at: Date.now() }),
  },
};
