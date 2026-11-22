import { getCollection } from 'astro:content';

// Top-level section display order. Sections not listed are appended after, in first-seen order.
export const SECTION_ORDER = ['Kubernetes Patterns'];

// Optional one-paragraph intro shown under a section's heading on the index (trusted static HTML).
export const SECTION_INTROS: Record<string, string> = {
  'Kubernetes Patterns':
    'Self-contained ways to run Aeron Cache on Kubernetes. Each pattern carries its own vendored Helm charts, a one-command run (<code class="rounded bg-sage-600/15 px-1.5 py-0.5 font-mono text-sm text-sage-200">make up</code>), a smoke test, and its own CI. They pull the public images from <code class="rounded bg-sage-600/15 px-1.5 py-0.5 font-mono text-sm text-sage-200">ghcr.io/bhf/aeroncache-*</code>, so there is nothing to build.',
};

// Category display order on the index and in the sidebar. Categories not listed here are
// appended after, in first-seen order.
export const CATEGORY_ORDER = [
  'All In One - Monolith',
  'Interfaces',
  'Full stack',
  'Topologies',
  'Gateways',
  'Autoscaling',
  'Near cache',
  'Service mesh',
  'GitOps',
];

export interface PatternEntry {
  id: string;
  title: string;
  slug: string;
  order: number;
  section: string;
  category: string;
  summary: string;
  status: 'draft' | 'ready';
  difficulty?: string;
  prereqs: string[];
  upstreamCharts: string[];
}

const sectionRank = (s: string) => {
  const i = SECTION_ORDER.indexOf(s);
  return i === -1 ? SECTION_ORDER.length : i;
};

const catRank = (c: string) => {
  const i = CATEGORY_ORDER.indexOf(c);
  return i === -1 ? CATEGORY_ORDER.length : i;
};

/** All patterns (from meta.yaml), sorted by category then order then title. */
export async function getPatterns(): Promise<PatternEntry[]> {
  const metas = await getCollection('patternMeta');
  return metas
    .map((m) => ({ id: m.id, slug: m.data.slug ?? m.id, ...m.data }))
    .sort(
      (a, b) =>
        sectionRank(a.section) - sectionRank(b.section) ||
        catRank(a.category) - catRank(b.category) ||
        a.order - b.order ||
        a.title.localeCompare(b.title),
    );
}

/** Patterns grouped into { category, patterns[] }, in display order, skipping empty categories. */
export async function getPatternsByCategory(): Promise<{ category: string; patterns: PatternEntry[] }[]> {
  const patterns = await getPatterns();
  const seen: string[] = [];
  for (const p of patterns) if (!seen.includes(p.category)) seen.push(p.category);
  seen.sort((a, b) => catRank(a) - catRank(b));
  return seen.map((category) => ({ category, patterns: patterns.filter((p) => p.category === category) }));
}

export interface SectionGroup {
  section: string;
  categories: { category: string; patterns: PatternEntry[] }[];
}

/** Patterns grouped section -> category -> patterns, in display order. */
export async function getPatternsBySection(): Promise<SectionGroup[]> {
  const patterns = await getPatterns();
  const sections: string[] = [];
  for (const p of patterns) if (!sections.includes(p.section)) sections.push(p.section);
  sections.sort((a, b) => sectionRank(a) - sectionRank(b));
  return sections.map((section) => {
    const inSection = patterns.filter((p) => p.section === section);
    const cats: string[] = [];
    for (const p of inSection) if (!cats.includes(p.category)) cats.push(p.category);
    cats.sort((a, b) => catRank(a) - catRank(b));
    return {
      section,
      categories: cats.map((category) => ({ category, patterns: inSection.filter((p) => p.category === category) })),
    };
  });
}
