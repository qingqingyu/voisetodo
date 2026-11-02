import { defineCollection, z } from 'astro:content';
import { glob } from 'astro/loaders';

// 指南文章(一期 4 篇均为 draft:true —— 草稿带可见标记 + noindex,产品负责人审改后翻 false 发布)。
const guides = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/guides' }),
  schema: z.object({
    title: z.string(),
    description: z.string(),
    pubDate: z.coerce.date(),
    updatedDate: z.coerce.date().optional(),
    draft: z.boolean().default(false),
  }),
});

// 法律/政策文本(隐私政策自 PRIVACY_POLICY.md 原样迁移,不改条款)。
const legal = defineCollection({
  loader: glob({ pattern: '**/*.md', base: './src/content/legal' }),
  schema: z.object({
    title: z.string(),
  }),
});

export const collections = { guides, legal };
