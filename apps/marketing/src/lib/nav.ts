// The page's sections, as the window's sidebar lists them. Each section also names the Space (window tint) it sits in.
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
      { id: "math", label: "The math", icon: "math", space: "peach" },
      { id: "loop", label: "The loop", icon: "loop", space: "sky" },
    ],
  },
  {
    title: "Airc",
    items: [
      { id: "spaces", label: "Spaces", icon: "swipe", space: "mint" },
      { id: "command", label: "Command bar", icon: "command", space: "sky" },
      { id: "colour", label: "Colours and profiles", icon: "spaces", space: "lilac" },
      { id: "import", label: "Import and links", icon: "import", space: "peach" },
      { id: "boosts", label: "Boosts and Capture", icon: "boosts", space: "pink" },
      { id: "little-arc", label: "Little Airc and streaming", icon: "little", space: "sky" },
      { id: "supported", label: "What works", icon: "works", space: "mint" },
    ],
  },
  {
    title: "People",
    items: [
      { id: "team", label: "Who builds it", icon: "team", space: "lilac" },
      { id: "qa", label: "Questions", icon: "qa", space: "sky" },
    ],
  },
];

export const all = groups.flatMap((g) => g.items);
export const spaceOf = (id: string): Space => all.find((s) => s.id === id)?.space ?? "mint";
export const SPACES: Space[] = ["mint", "sky", "lilac", "peach", "pink"];
