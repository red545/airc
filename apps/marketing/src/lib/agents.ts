// Agents (docs/user/agents.md): the homepage's "For AI agents" section, its sidebar row and the privacy page's paragraph
// show once the release that brings them is published, the way /features shows a "next" row (previews and `astro dev`
// show them now). The release step turns the catalog row's `since: "next"` into its version, which turns these on too.
import { groups, shown } from "../data/catalog";
import { getPublished, SHOW_UNRELEASED } from "./release";

export const AGENTS_ROW = "Use Airc from Claude";

export const FOLLOW_ROW = "Follow along";

export const REMOTE_ROW = "From your other devices";

/** The homepage line about other devices on the Tailscale network, once the release that brings it is published. */
export async function remoteShown(): Promise<boolean> {
  const row = groups.flatMap((g) => g.features).find((f) => f.title === REMOTE_ROW);
  return row ? shown(row, await getPublished(), SHOW_UNRELEASED) : false;
}

/** The homepage line about the sidebar's Agents folder and Watch, once the release that brings it is published. */
export async function followAlongShown(): Promise<boolean> {
  const row = groups.flatMap((g) => g.features).find((f) => f.title === FOLLOW_ROW);
  return row ? shown(row, await getPublished(), SHOW_UNRELEASED) : false;
}

export async function agentsShown(): Promise<boolean> {
  const row = groups.flatMap((g) => g.features).find((f) => f.title === AGENTS_ROW);
  return row ? shown(row, await getPublished(), SHOW_UNRELEASED) : false;
}

// The Airc Agent hero (the agent button and the pane's Connect card, recorded from the app: public/video/agent-demo.*):
// shown once the release that brings the button is published; previews and `astro dev` show it now. Until then the
// section keeps its MCP lead.
export const AGENT_BUTTON_ROW = "Agent button and Connect";

export async function agentHeroShown(): Promise<boolean> {
  const row = groups.flatMap((g) => g.features).find((f) => f.title === AGENT_BUTTON_ROW);
  return row ? shown(row, await getPublished(), SHOW_UNRELEASED) : SHOW_UNRELEASED;
}
