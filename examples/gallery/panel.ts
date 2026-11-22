const ring = "M12 2 A10 10 0 1 1 11.99 2";

const circle = "M12 2 A10 10 0 1 1 11.99 2 Z";

const load = Array.from(
  { length: 24 },
  (_, index) => 50 + 30 * Math.sin(index / 3) + 10 * Math.sin(index * 1.7),
);

const weekdays = ["M", "T", "W", "T", "F", "S", "S"];

let progress = 0.35;

function label(text: string): Gary.Node {
  return { type: "text", text, style: "dim" };
}

function dot(key: string, fill: Gary.Color, x = 0): Gary.Node {
  return {
    type: "shape",
    key,
    width: 22,
    height: 22,
    x,
    viewBox: [24, 24],
    paths: [{ d: circle, fill }],
  };
}

function progressRing(): Gary.Node {
  return {
    type: "stack",
    key: "ring",
    width: 64,
    height: 64,
    action: "advance",
    pressed: { scale: 0.95 },
    children: [
      {
        type: "shape",
        width: 64,
        height: 64,
        viewBox: [24, 24],
        animation: "smooth",
        duration: 0.6,
        paths: [
          { d: ring, stroke: "alpha(foreground, 0.12)", lineWidth: 2.5 },
          {
            d: ring,
            stroke: { gradient: "angular", colors: ["accent", "good", "accent"], angle: -90 },
            lineWidth: 2.5,
            cap: "round",
            trim: [0, progress],
          },
        ],
      },
      {
        type: "text",
        text: `${Math.round(progress * 100)}%`,
        style: "bright",
        width: 64,
        height: 64,
        align: "center",
      },
    ],
  };
}

function charts(): Gary.Node {
  const fade: Gary.Paint = {
    gradient: "linear",
    colors: ["alpha(accent, 0.5)", "alpha(accent, 0)"],
    angle: 90,
  };

  return {
    type: "column",
    key: "charts",
    gap: 6,
    children: [
      label("Load"),
      {
        type: "chart",
        width: 150,
        height: 26,
        min: 0,
        max: 100,
        series: [
          { values: load, mark: "area", color: fade, smooth: true },
          { values: load, color: "accent", smooth: true },
        ],
      },
      {
        type: "chart",
        width: 150,
        height: 20,
        min: 0,
        series: [{ values: load.slice(0, 12), mark: "bar", color: "good" }],
      },
    ],
  };
}

function effects(): Gary.Node {
  return {
    type: "row",
    key: "effects",
    gap: 18,
    children: [
      label("Loops"),
      {
        ...dot("pulse", "bad"),
        width: 16,
        height: 16,
        loop: { scale: [0.7, 1.1], opacity: [0.5, 1], duration: 0.8, reverse: true },
      },
      {
        type: "icon",
        key: "spin",
        symbol: "arrow.triangle.2.circlepath",
        color: "accent",
        loop: { rotation: [0, 360], duration: 1.5 },
      },
      label("Effects"),
      {
        type: "text",
        key: "tilt",
        text: "Tilt",
        style: "bright",
        rotation: -12,
        hovered: { loop: { rotation: [-10, 10], duration: 0.25, reverse: true } },
      },
      { type: "text", key: "blur", text: "Blur", style: "bright", blur: 1.5, hovered: { blur: 0 } },
      {
        type: "stack",
        key: "blend",
        width: 34,
        height: 22,
        children: [dot("red", "bad"), { ...dot("blue", "accent", 12), blend: "screen" }],
      },
    ],
  };
}

function cell(key: string, text: string, style: Gary.StyleName): Gary.Node {
  return { type: "text", key, text, style, width: 26, height: 22, align: "center", radius: 6 };
}

function calendar(today: Date): Gary.Node {
  const first = new Date(today.getFullYear(), today.getMonth(), 1);
  const length = new Date(today.getFullYear(), today.getMonth() + 1, 0).getDate();
  const blanks = (first.getDay() + 6) % 7;

  const cells = weekdays.map((day, index) => cell(`h${index}`, day, "dim"));

  for (let index = 0; index < blanks; index += 1) {
    cells.push(cell(`b${index}`, "", "default"));
  }

  for (let day = 1; day <= length; day += 1) {
    cells.push(cell(`d${day}`, String(day), day === today.getDate() ? "selected" : "default"));
  }

  return {
    type: "column",
    key: "calendar",
    gap: 6,
    children: [
      {
        type: "text",
        text: today.toLocaleDateString("en-GB", { month: "long", year: "numeric" }),
        style: "bright",
      },
      { type: "grid", columns: 7, gap: 2, align: "center", children: cells },
    ],
  };
}

function glow(): Gary.Node {
  return {
    type: "column",
    key: "glow",
    gap: 6,
    children: [
      label("Shader"),
      {
        type: "shader",
        path: "glow.metal",
        function: "glow",
        args: [1, 0.55, 0.25, 0.9],
        animated: true,
        width: 150,
        height: 150,
      },
    ],
  };
}

module.exports = {
  surface: { anchors: { top: true, right: true }, margins: { top: 8, right: 16 } },

  render() {
    return {
      type: "column",
      style: "panel",
      gap: 14,
      background: { gradient: "linear", colors: ["panel", "mix(panel, accent, 0.22)"], angle: 70 },
      children: [
        { type: "text", key: "title", text: "Gallery", style: "title" },
        { type: "row", key: "top", gap: 16, children: [progressRing(), charts()] },
        effects(),
        { type: "row", key: "bottom", gap: 16, children: [calendar(new Date()), glow()] },
      ],
    };
  },

  onAction(action) {
    if (action === "advance") {
      progress = progress >= 1 ? 0.1 : Math.min(1, progress + 0.25);
    }
  },

  onKey(key) {
    if (key === "escape") {
      host.hide();
    }
  },
} satisfies Gary.Panel;
