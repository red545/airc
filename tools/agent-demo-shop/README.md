# Steepwell: the agent demo's made-up shop

The homepage's Airc Agent video (marketing part `aidemo`, `apps/browser/Sources/Airc/Debug/MarketingAgentDemo.swift`)
runs on this shop. Steepwell, its products, prices, reviews, people and address are invented; nothing is sold.

- `build.py` writes the pages into `site/` (`python3 build.py`).
- `render/products.py` renders the product photos with Blender's Cycles from shapes modelled in the script (no outside
  models or textures): `python3 render/products.py <out>` with the `bpy` module (Blender 4.2+).
  `render/images.py <out> site` turns them into `site/assets/img/*.webp` and makes the favicons
  (`AIDEMO_FAV_FONT=<Inter-SemiBold.ttf>` for the demo profile's letter icons).
- `serve.py <port>` serves `site/` the way the app does; `measure.py <port>` prints the centres of the controls the
  demo agent clicks at its 1280 × 800 viewport. Update the script in MarketingAgentDemo.swift when they move.

Fonts: Inter and Instrument Serif, both under the SIL Open Font License (`site/assets/fonts/*-OFL.txt`).
