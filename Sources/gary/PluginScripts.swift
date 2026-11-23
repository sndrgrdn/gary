@preconcurrency import JavaScriptCore

nonisolated struct PluginFunctions {
    let render: JSValue
    let dispatch: JSValue
    let call: JSValue
    let surfaces: JSValue
    let unload: JSValue

    init(_ wrappers: JSValue) {
        render = wrappers.atIndex(0)
        dispatch = wrappers.atIndex(1)
        call = wrappers.atIndex(2)
        surfaces = wrappers.atIndex(3)
        unload = wrappers.atIndex(4)
    }
}

nonisolated enum PluginScripts {
    static let modules = """
    (function (factories, links, entry, library, settings) {
      var loaded = {}, effect = null;
      function load(path) {
        if (Object.prototype.hasOwnProperty.call(loaded, path)) return loaded[path];
        if (path === "gary:effect") {
          effect = library()({
            host: host, spawn: host.spawn, hotkeys: host.hotkeys, hyperkey: host.hyperkey, fetch: globalThis.fetch, setTimeout: setTimeout, clearTimeout: clearTimeout, settings: JSON.parse(settings)
          });
          return loaded[path] = effect.exports;
        }
        var exports = loaded[path] = {};
        factories[path](exports, function (specifier) {
          if (!Object.prototype.hasOwnProperty.call(links[path], specifier)) throw new Error("cannot import \\"" + specifier + "\\" from " + path);
          return load(links[path][specifier]);
        });
        return exports;
      }
      return [load(entry).default, effect];
    })
    """

    static let functions = """
    (function (exported, headless, effect) {
      if (exported === null || typeof exported !== "object") throw new Error("the entry file has no default export");
      if (!headless && typeof exported.render !== "function") throw new Error("the default export has no render function");
      if (exported.effect !== undefined) {
        if (effect === null) throw new Error("the default export has an effect, so the plugin must import gary:effect");
        effect.start(exported.effect);
      }
      return [
        function (state, mark) {
          var s = JSON.parse(state);
          if (mark) mark();
          var n = exported.render(s);
          if (mark) mark();
          return JSON.stringify(n);
        },
        function (name, args, state, mark) {
          var f = exported[name], receive = name === "onTopic" && effect !== null;
          if (typeof f !== "function" && !receive) return null;
          var a = JSON.parse(args).concat([JSON.parse(state)]);
          if (mark) mark();
          if (receive) effect.receive(a[0]);
          if (typeof f !== "function") return null;
          var r = f.apply(exported, a);
          if (effect === null || !effect.isEffect(r)) return r === true;
          effect.run(name, r);
          return true;
        },
        function (method, args, done, mark) {
          var f = exported.methods && exported.methods[method];
          if (typeof f !== "function") throw new Error("no method " + method);
          var a = JSON.parse(args);
          if (mark) mark();
          var r = f.apply(null, a);
          if (effect !== null && effect.isEffect(r)) r = effect.promise(r);
          var text = function (v) { return v === undefined ? "" : JSON.stringify(v); };
          if (!r || typeof r.then !== "function") return done(true, text(r));
          r.then(function (v) { done(true, text(v)); }, function (x) { done(false, x !== null && typeof x === "object" && "message" in x ? String(x.message) : String(x)); });
        },
        function (state, mark) {
          var s = JSON.parse(state), out = {};
          if (mark) mark();
          var resolve = function (v) {
            if (typeof v === "function") v = v(s);
            return v === undefined ? null : v;
          };
          if (exported.surface !== undefined) out.surface = resolve(exported.surface);
          var all = exported.surfaces;
          if (all !== undefined) {
            out.surfaces = false;
            if (all !== null && typeof all === "object" && !Array.isArray(all)) {
              out.surfaces = {};
              Object.keys(all).forEach(function (k) { out.surfaces[k] = resolve(all[k]); });
            }
          }
          if (mark) mark();
          return JSON.stringify(out);
        },
        function () {
          if (effect !== null) effect.close();
        }
      ];
    })
    """

    static let jsx = """
    (function () {
      function Fragment() {}
      function flatten(items, out) {
        items.forEach(function (item) {
          if (Array.isArray(item)) flatten(item, out);
          else if (item !== null && item !== undefined && item !== false && item !== true) out.push(item);
        });
        return out;
      }
      function h(type, props) {
        var children = Array.prototype.slice.call(arguments, 2);
        if (typeof type === "function" && type !== Fragment) {
          props = Object.assign({}, props);
          if (children.length) props.children = children.length === 1 ? children[0] : children;
          return type(props);
        }
        children = flatten(children, []);
        if (type === Fragment) return children;
        var node = Object.assign({ type: type }, props);
        if (children.length) {
          if (type === "text") node.text = children.join("");
          else node.children = children;
        }
        return node;
      }
      globalThis.Gary = { h: h, Fragment: Fragment };
    })
    """

    static let timers = """
    (function (add, clear) {
      function timer(repeats) {
        return function (f, ms) {
          var args = Array.prototype.slice.call(arguments, 2);
          if (typeof f !== "function") throw new TypeError("timer callback must be a function");
          return add(function () { f.apply(null, args); }, Number(ms) || 0, repeats);
        };
      }
      globalThis.setTimeout = timer(false);
      globalThis.setInterval = timer(true);
      globalThis.clearTimeout = globalThis.clearInterval = function (id) { if (typeof id === "number") clear(id); };
    })
    """

    static let host = """
    (function (log, read, write, publish, show, hide, toggle, call, id, kinds) {
      return {
        log: log,
        storage: {
          get: function (key) { var text = read(String(key)); return text ? JSON.parse(text) : undefined; },
          set: function (key, value) {
            var text = JSON.stringify(value);
            if (value !== undefined && text === undefined) throw new TypeError("host.storage.set: " + key + " is not a JSON value");
            write(String(key), text);
          }
        },
        publish: publish,
        show: show,
        hide: hide,
        toggle: toggle,
        call: function () {
          var args = Array.prototype.slice.call(arguments), plugin = "", kind = "";
          if (args[0] !== null && typeof args[0] === "object") {
            var target = args.shift();
            plugin = target.plugin === undefined || target.plugin === id ? "" : String(target.plugin);
            kind = target.kind === undefined ? "" : String(target.kind);
          }
          var method = String(args.shift());
          return new Promise(function (resolve, reject) {
            if (plugin === "" && kind !== "" && kinds.indexOf(kind) < 0) throw new Error("host.call: " + id + " has no kind " + kind);
            call(plugin, kind, method, args.map(String), resolve, function (message) { reject(new Error(message)); });
          }).then(function (text) { return text === "" ? undefined : JSON.parse(text); });
        }
      };
    })
    """
}
