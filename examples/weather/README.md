# Weather

A bar widget that shows the temperature and an SF Symbol for the conditions, from [Open-Meteo](https://open-meteo.com). It fetches with `fetch` from `gary:effect` every 15 minutes, 10 seconds after the screen unlocks, and when you click it, and decodes the response with `Schema`. It reads the place from its settings in `shell.json` and shows Amsterdam without them.

Copy it with `gary plugin new you.weather --from weather`. To show another place, set `"settings": { "you.weather": { "latitude": 53.2, "longitude": 5.8 } }` in `~/.config/gary/shell.json`. Run `npm install` in the copy to type-check it.
