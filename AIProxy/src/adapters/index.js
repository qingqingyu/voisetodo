// Adapter registry. Single source of truth for which provider types the proxy supports.
// Selector/config layer must consult this list when validating PROVIDERS entries.

import { anthropicAdapter } from "./anthropic.js";
import { geminiAdapter } from "./gemini.js";
import { openaiAdapter } from "./openai.js";

const REGISTRY = new Map([
  [anthropicAdapter.type, anthropicAdapter],
  [openaiAdapter.type, openaiAdapter],
  [geminiAdapter.type, geminiAdapter]
]);

// Re-export individual adapters for direct unit testing.
export { anthropicAdapter, openaiAdapter, geminiAdapter };

export function getAdapter(type) {
  return REGISTRY.get(type) || null;
}

export function listAdapterTypes() {
  return Array.from(REGISTRY.keys());
}
