const styles = ["active", "good", "bad"] as const;

let count = 0;
let style = 0;

function publish() {
  host.publish({ count });
}

publish();

module.exports = {
  render() {
    return {
      type: "row",
      gap: 4,
      action: "toggle",
      rightAction: "style",
      middleAction: "reset",
      scrollAction: "count",
      tooltip: "Scroll to count, right-click for a color, middle-click to reset",
      children: [
        { type: "icon", key: "icon", symbol: "square.stack", style: styles[style] },
        { type: "text", key: "count", text: count, style: styles[style] },
      ],
    };
  },

  onAction(action) {
    if (action === "toggle") {
      host.toggle();
    }

    if (action === "style") {
      style = (style + 1) % styles.length;
    }

    if (action === "reset") {
      count = 0;
      publish();
    }
  },

  onScroll(event) {
    if (event.action === "count" && event.y !== 0) {
      count += Math.sign(event.y);
      publish();
    }
  },
} satisfies Gary.BarWidget;
