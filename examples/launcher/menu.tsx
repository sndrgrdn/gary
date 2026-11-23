const limit = 8;
const width = 480;

let apps: Gary.InstalledApp[] = [];
let query = "";
let selected = 0;

async function loadApps() {
  apps = await host.apps.installed();
}

loadApps();

function matches() {
  const needle = query.trim().toLowerCase();

  return apps.filter((app) => app.name.toLowerCase().includes(needle)).slice(0, limit);
}

function open(app: Gary.InstalledApp | undefined) {
  host.hide();

  if (app) {
    host.apps
      .activate(app.app ?? app.path)
      .catch((error) => host.log(`opening ${app.name} failed: ${error}`));
  }
}

export default {
  surface: {
    anchors: { top: true, bottom: true, left: true, right: true },
    exclusionMode: "ignore",
    background: "backdrop",
  },

  render(state) {
    const { spacing } = state.theme;

    return (
      <column key="card" width={width} style="surface" padding={spacing.item} gap={4}>
        <input
          key="query"
          value={query}
          placeholder="Search apps"
          change="filter"
          submit="open"
          padding={[4, spacing.item]}
          width={width - 2 * spacing.item}
        />
        {matches().map((app, index) => (
          <row
            key={app.path}
            action={`pick:${index}`}
            hoverAction={`hover:${index}`}
            style={index === selected ? "selected" : undefined}
            gap={spacing.item}
            padding={[4, spacing.item]}
          >
            <image key="icon" path={app.path} width={20} height={20} />
            <text key="name">{app.name}</text>
            <spacer />
          </row>
        ))}
      </column>
    );
  },

  onHotkey(id) {
    if (id === "open") {
      query = "";
      selected = 0;
      loadApps();
      host.toggle();
    }
  },

  onKey(key) {
    if (key === "down") {
      selected = Math.min(selected + 1, matches().length - 1);
    } else if (key === "up") {
      selected = Math.max(selected - 1, 0);
    } else {
      return false;
    }

    return true;
  },

  onAction(action, payload) {
    if (action === "filter") {
      query = String(payload ?? "");
      selected = 0;
    } else if (action.startsWith("hover:") && payload === true) {
      selected = Number(action.slice("hover:".length));
    } else if (action.startsWith("pick:")) {
      open(matches()[Number(action.slice("pick:".length))]);
    } else if (action === "open") {
      open(matches()[selected]);
    }
  },
} satisfies Gary.Menu;
