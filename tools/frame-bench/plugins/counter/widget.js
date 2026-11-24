import { every } from "./every";

let count = 0;

setInterval(() => (count += 1), every);

export default {
  render() {
    return {
      type: "row",
      gap: 4,
      children: [
        { type: "icon", key: "icon", symbol: "bolt" },
        { type: "text", key: "n", text: String((count * 7) % 1000) },
      ],
    };
  },
};
