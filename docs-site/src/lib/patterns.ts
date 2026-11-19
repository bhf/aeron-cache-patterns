import { getCollection } from 'astro:content';

// Category display order on the index and in the sidebar. Categories not listed here are
// appended after, in first-seen order.
export const CATEGORY_ORDER = [
  'Foundations',
  'Interfaces',
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
  category: string;
  summary: string;
  status: 'draft' | 'ready';
  difficulty?: string;
  prereqs: string[];
  upstreamCharts: string[];
}

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
