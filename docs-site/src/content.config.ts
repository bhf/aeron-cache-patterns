import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

// Patterns live OUTSIDE this site, at ../patterns, so each pattern folder stays self-contained
// (its README.md is both the GitHub readme and the docs source). We read two things per pattern:
//   - patternDocs: the README.md body (rendered to HTML), id = the pattern folder name
//   - patternMeta: the sibling meta.yaml (structured metadata), same id
// Pages join them by id. The _template scaffold is excluded.

const stripName = (suffix: RegExp) => ({ entry }: { entry: string }) => entry.replace(suffix, '');

const patternDocs = defineCollection({
  loader: glob({
    pattern: ['*/README.md', '!_template/**'],
    base: '../patterns',
    generateId: stripName(/\/README\.md$/),
  }),
});

const patternMeta = defineCollection({
  loader: glob({
    pattern: ['*/meta.yaml', '!_template/**'],
    base: '../patterns',
    generateId: stripName(/\/meta\.yaml$/),
  }),
  schema: z.object({
    title: z.string(),
    slug: z.string().optional(),
    order: z.number().default(99),
    section: z.string().default('Kubernetes Patterns'),
    category: z.string(),
    summary: z.string(),
    status: z.enum(['draft', 'ready']).default('draft'),
    difficulty: z.string().optional(),
    prereqs: z.array(z.string()).default([]),
    upstreamCharts: z.array(z.string()).default([]),
    projectItem: z.string().optional(),
  }),
});

export const collections = { patternDocs, patternMeta };
