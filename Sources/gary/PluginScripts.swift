import JavaScriptCore

struct PluginFunctions {
    let render: JSValue
    let dispatch: JSValue
    let call: JSValue
    let surfaces: JSValue

    init(_ wrappers: JSValue) {
        render = wrappers.atIndex(0)
        dispatch = wrappers.atIndex(1)
        call = wrappers.atIndex(2)
        surfaces = wrappers.atIndex(3)
    }
}

enum PluginScripts {
    static let modules = """
    (function (factories, links, entry) {
      var loaded = {};
      function load(path) {
        if (Object.prototype.hasOwnProperty.call(loaded, path)) return loaded[path];
        var exports = loaded[path] = {};
        factories[path](exports, function (specifier) {
          if (!Object.prototype.hasOwnProperty.call(links[path], specifier)) throw new Error("cannot import \\"" + specifier + "\\" from " + path);
          return load(links[path][specifier]);
        });
        return exports;
      }
      return load(entry).default;
    })
    """

    static let functions = """
    (function (x, headless) {
      if (x === null || typeof x !== "object") throw new Error("the entry file has no default export");
      if (!headless && typeof x.render !== "function") throw new Error("the default export has no render function");
      return [
        function (state, mark) {
          var s = JSON.parse(state);
          if (mark) mark();
          var n = x.render(s);
          if (mark) mark();
          return JSON.stringify(n);
        },
        function (name, args, state, mark) {
          var f = x[name];
          if (typeof f !== "function") return null;
          var a = JSON.parse(args).concat([JSON.parse(state)]);
          if (mark) mark();
          return f.apply(x, a) === true;
        },
        function (method, args, done, mark) {
          var f = x.methods && x.methods[method];
          if (typeof f !== "function") throw new Error("no method " + method);
          var a = JSON.parse(args);
          if (mark) mark();
          var r = f.apply(null, a);
          var text = function (v) { return v === undefined ? "" : JSON.stringify(v); };
          if (!r || typeof r.then !== "function") return done(true, text(r));
          r.then(function (v) { done(true, text(v)); }, function (x) { done(false, x instanceof Error ? x.message : String(x)); });
        },
        function (state, mark) {
          var s = JSON.parse(state), out = {};
          if (mark) mark();
          var resolve = function (v) {
            if (typeof v === "function") v = v(s);
            return v === undefined ? null : v;
          };
          if (x.surface !== undefined) out.surface = resolve(x.surface);
          var all = x.surfaces;
          if (all !== undefined) {
            out.surfaces = false;
            if (all !== null && typeof all === "object" && !Array.isArray(all)) {
              out.surfaces = {};
              Object.keys(all).forEach(function (k) { out.surfaces[k] = resolve(all[k]); });
            }
          }
          if (mark) mark();
          return JSON.stringify(out);
        }
      ];
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
    (function (log, read, write, publish, show, hide, toggle, call) {
      var data = null;
      function load() {
        if (data !== null) return;
        var text = read();
        try { data = text ? JSON.parse(text) : {}; } catch (e) { data = {}; }
      }
      return {
        log: log,
        storage: {
          get: function (key) { load(); return data[key]; },
          set: function (key, value) {
            load();
            if (value === undefined) delete data[key]; else data[key] = JSON.parse(JSON.stringify(value));
            write(JSON.stringify(data));
          }
        },
        publish: publish,
        show: show,
        hide: hide,
        toggle: toggle,
        call: function (method) {
          var args = Array.prototype.slice.call(arguments, 1).map(String);
          return new Promise(function (resolve, reject) {
            call(String(method), args, resolve, function (message) { reject(new Error(message)); });
          }).then(function (text) { return text === "" ? undefined : JSON.parse(text); });
        }
      };
    })
    """
}
