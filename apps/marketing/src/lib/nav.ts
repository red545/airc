// The page's sections, as the window's sidebar lists them. Each section also names the Space it sits in (the sidebar's
// group dots use it).
export type Space = "mint" | "sky" | "lilac" | "peach" | "pink";

export interface Section {
  id: string;
  label: string;
  icon: string;
  space: Space;
}

export const groups: { title: string; items: Section[] }[] = [
  {
    title: "Story",
    items: [
      { id: "top", label: "Arc shuts down", icon: "top", space: "mint" },
      { id: "reborn", label: "Arc, reborn", icon: "reborn", space: "lilac" },
      { id: "math", label: "The math", icon: "math", space: "peach" },
      { id: "loop", label: "The loop", icon: "loop", space: "sky" },
    ],
  },
  {
    title: "Features",
    items: [
      { id: "spaces", label: "Colours", icon: "spaces", space: "peach" },
      { id: "profiles", label: "Profiles", icon: "profiles", space: "mint" },
      { id: "command", label: "Command bar", icon: "command", space: "sky" },
      { id: "import", label: "Import from Arc", icon: "import", space: "lilac" },
      { id: "links", label: "Links", icon: "links", space: "sky" },
      { id: "streaming", label: "Streaming", icon: "streaming", space: "pink" },
      { id: "private", label: "Private windows", icon: "private", space: "lilac" },
      { id: "previews", label: "Tab previews", icon: "previews", space: "sky" },
      { id: "boosts", label: "Boosts", icon: "boosts", space: "pink" },
      { id: "supported", label: "What works", icon: "works", space: "mint" },
    ],
  },
  {
    title: "People",
    items: [
      { id: "why", label: "Why I'm building this", icon: "why", space: "peach" },
      { id: "expect", label: "What to expect", icon: "expect", space: "mint" },
      { id: "team", label: "Who maintains it", icon: "team", space: "lilac" },
      { id: "qa", label: "Questions", icon: "qa", space: "sky" },
    ],
  },
];

export const all = groups.flatMap((g) => g.items);
export const spaceOf = (id: string): Space => all.find((s) => s.id === id)?.space ?? "mint";
export const SPACES: Space[] = ["mint", "sky", "lilac", "peach", "pink"];
