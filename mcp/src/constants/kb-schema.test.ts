import { describe, it, expect } from 'vitest';
import { readFileSync } from 'fs';
import * as kb from './kb-schema.js';
import { AI_BLOCK_SCHEMAS } from '../tools/ai-block.js';
import { EDGE_TYPES as GRAPH_EDGE_TYPES } from '../tools/graph-store.js';

const json = JSON.parse(readFileSync(new URL('../../../kb-schema.json', import.meta.url), 'utf-8'));

describe('kb-schema — single source of truth (TS side)', () => {
  it('TS consts derive verbatim from kb-schema.json', () => {
    expect(kb.STRUCTURED_TYPES).toEqual(json.structured_types);
    expect(kb.UNSTRUCTURED_TYPES).toEqual(json.unstructured_types);
    expect(kb.GENERATED_DIRS).toEqual(json.generated_dirs);
    expect(kb.EDGE_TYPES).toEqual(json.edge_types);
    expect(kb.PROJECT_SECTIONS).toEqual(json.project_sections);
    expect(kb.FORGET_PROTECTED).toEqual(json.forget_protection.protected);
    expect(kb.FORGET_DISCOUNTED).toEqual(json.forget_protection.discounted);
  });
  it('SP-2: raw group derives verbatim from kb-schema.json', () => {
    expect(kb.RAW_DIR).toEqual(json.raw.dir);
    expect(kb.RAW_STATUSES).toEqual(json.raw.statuses);
  });
  it('derived category sets are correct', () => {
    expect(kb.CONTENT_CATEGORIES).toEqual([...json.structured_types, ...json.unstructured_types]);
    expect(kb.ALL_CATEGORIES).toEqual([...json.structured_types, ...json.unstructured_types, ...json.generated_dirs]);
  });
  it('helpers reflect the manifest', () => {
    expect(kb.isStructuredType('learnings')).toBe(true);
    expect(kb.isStructuredType('state')).toBe(false);
    expect(kb.isGeneratedDir('projects')).toBe(true);
    expect(kb.isGeneratedDir('learnings')).toBe(false);
  });
  it('ai-block AI_BLOCK_SCHEMAS keys == manifest structured_types (no divergence)', () => {
    expect(Object.keys(AI_BLOCK_SCHEMAS).sort()).toEqual([...kb.STRUCTURED_TYPES].sort());
  });
  it('graph-store EDGE_TYPES == manifest edge_types (no divergence)', () => {
    expect([...GRAPH_EDGE_TYPES]).toEqual(json.edge_types);
  });
});
