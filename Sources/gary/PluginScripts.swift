import JavaScriptCore

struct PluginFunctions {
    let render: JSValue
    let dispatch: JSValue
    let call: JSValue
    let surface: JSValue

    init(_ wrappers: JSValue) {
        render = wrappers.atIndex(0)
        dispatch = wrappers.atIndex(1)
        call = wrappers.atIndex(2)
        surface = wrappers.atIndex(3)
    }
}

enum PluginScripts {
    static let functions = """
    (function (headless) {
      var m = module;
      var e = function () { return m.exports; };
      if (!headless && typeof e().render !== "function") throw new Error("module.exports.render is not a function");
      return [
        function (state) { return JSON.stringify(e().render(JSON.parse(state))); },
        function (name, args, state) {
          var f = e()[name];
          if (typeof f !== "function") return null;
          return f.apply(e(), JSON.parse(args).concat([JSON.parse(state)])) === true;
        },
        function (method, args, done) {
          var f = e().methods && e().methods[method];
          if (typeof f !== "function") throw new Error("no method " + method);
          var r = f.apply(null, JSON.parse(args));
          var text = function (v) { return v === undefined ? "" : JSON.stringify(v); };
          if (!r || typeof r.then !== "function") return done(true, text(r));
          r.then(function (v) { done(true, text(v)); }, function (x) { done(false, x instanceof Error ? x.message : String(x)); });
        },
        function (state) {
          var s = e().surface;
          if (typeof s === "function") s = s(JSON.parse(state));
          return JSON.stringify(s === undefined ? null : s);
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
