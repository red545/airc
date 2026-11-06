import { defineConfig } from "astro/config";

export default defineConfig({
  site: "https://aircbrowser.com",
  devToolbar: { enabled: false },
  server: {
    port: Number(process.env.PORT ?? 4381),
    // Previews are reached over the tailnet (*.ts.net) as well as localhost.
    allowedHosts: [".ts.net"],
  },
  vite: {
    server: { allowedHosts: [".ts.net"] },
  },
  build: {
    inlineStylesheets: "always",
  },
});
