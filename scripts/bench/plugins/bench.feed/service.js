const item = (index) => ({
  id: index,
  name: `item ${index}`,
  value: index * 1.5,
  tags: ["alpha", "beta"],
});

const itemBytes = JSON.stringify(item(1000)).length + 1;
let items = [];
let published = 0;
let timer = null;

export default {
  methods: {
    start(bytes) {
      items = Array.from(
        { length: Math.max(1, Math.round(Number(bytes) / itemBytes)) },
        (_, index) => item(index),
      );
      clearInterval(timer);
      timer = setInterval(() => {
        published += 1;
        host.publish({ items, published });
      }, 1000);

      return JSON.stringify({ items, published }).length;
    },
    stats: () => ({ published, at: Date.now() }),
  },
};
