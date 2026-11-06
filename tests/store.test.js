import test from 'node:test';
import assert from 'node:assert/strict';
import { books, chapterParagraphs } from '../src/data.js';
import { STORAGE_KEY, seedState, normalizeState, loadState, persistState, toggleShelf, shelfBooks, searchBooks, recordProgress, parseRoute } from '../src/store.js';

const memory = () => { const values = new Map(); return { getItem: key => values.get(key) ?? null, setItem: (key, value) => values.set(key, value) }; };

test('Zhuying reads the previous browser shelf and writes only the new storage key', () => {
  const storage = memory(), old = seedState(1000000000);
  old.settings.theme = 'dark'; old.shelf = [];
  storage.setItem('yueshan-demo-v1', JSON.stringify(old));
  assert.equal(STORAGE_KEY, 'zhuying-demo-v1');
  assert.deepEqual(loadState(storage).state, old);
  const current = seedState(2000000000);
  assert.equal(persistState(storage, current), true);
  assert.deepEqual(loadState(storage).state, current);
  assert.equal(storage.getItem('yueshan-demo-v1'), JSON.stringify(old));
});

test('new visitors get a coherent demo shelf with three independent reading records', () => {
  const state = seedState(1000000000);
  assert.equal(state.shelf.length, 6);
  assert.equal(new Set(state.shelf.map(item => item.id)).size, 6);
  assert.equal(shelfBooks(state, 'reading').length, 3);
  assert.equal(shelfBooks(state, 'unread').length, 3);
  assert.equal(shelfBooks(state)[0].id, 'changfeng');
});
test('search matches book title and author, trims input, and handles no match', () => {
  assert.deepEqual(searchBooks(' 长风 ').map(book => book.id), ['changfeng']);
  assert.deepEqual(searchBooks('林间渡').map(book => book.id), ['changfeng']);
  assert.equal(searchBooks('不存在的小说').length, 0);
  assert.equal(searchBooks(' ').length, 8);
});
test('category filters intersect with the search query', () => {
  assert.equal(searchBooks('', '科幻').length, 2);
  assert.equal(searchBooks('群星', '科幻')[0].id, 'stars');
  assert.equal(searchBooks('群星', '都市').length, 0);
});
test('removing and re-adding a favorite preserves its reading progress', () => {
  const state = seedState();
  const progress = { ...state.progress.changfeng };
  assert.equal(toggleShelf(state, 'changfeng'), false);
  assert.equal(state.shelf.some(item => item.id === 'changfeng'), false);
  assert.deepEqual(state.progress.changfeng, progress);
  assert.equal(toggleShelf(state, 'changfeng', 42), true);
  assert.equal(state.shelf.filter(item => item.id === 'changfeng').length, 1);
  assert.deepEqual(state.progress.changfeng, progress);
});
test('reading works without a favorite and reorders books by recent activity', () => {
  const state = seedState(1000000000);
  assert.equal(recordProgress(state, 'echo', 2, 6, .45, 2000000000), true);
  assert.equal(state.shelf.some(item => item.id === 'echo'), false);
  recordProgress(state, 'sunset', 5, 3, .2, 2000000001);
  assert.equal(shelfBooks(state)[0].id, 'sunset');
  assert.equal(state.progress.changfeng.chapter, 2);
});
test('invalid chapter navigation cannot replace valid reading progress', () => {
  const state = seedState();
  const previous = { ...state.progress.changfeng };
  for (const value of [-1, 12, 1.5, NaN]) assert.equal(recordProgress(state, 'changfeng', value), false);
  assert.equal(recordProgress(state, 'unknown', 0), false);
  assert.equal(toggleShelf(state, 'unknown'), false);
  assert.deepEqual(state.progress.changfeng, previous);
});
test('progress, favorites, and preferences survive a save/load round trip', () => {
  const storage = memory();
  const state = seedState();
  state.settings = { fontSize: 24, lineHeight: 2, theme: 'dark' };
  recordProgress(state, 'changfeng', 7, 5, .65, 9000);
  toggleShelf(state, 'echo');
  assert.equal(persistState(storage, state), true);
  assert.deepEqual(loadState(storage).state, state);
  assert.equal(loadState(storage).error, false);
});
test('an intentionally empty shelf remains empty after reload', () => {
  const storage = memory();
  const state = seedState();
  state.shelf = [];
  persistState(storage, state);
  assert.equal(loadState(storage).state.shelf.length, 0);
});
test('corrupt storage falls back safely and signals the error', () => {
  const storage = memory();
  storage.setItem(STORAGE_KEY, '{not json');
  assert.equal(loadState(storage).error, true);
  storage.setItem(STORAGE_KEY, JSON.stringify({ version: 4, shelf: [] }));
  assert.equal(loadState(storage).error, true);
  const blocked = { getItem() { throw new Error('Blocked'); }, setItem() { throw new Error('Full'); } };
  assert.equal(loadState(blocked).error, true);
  assert.equal(persistState(blocked, seedState()), false);
});
test('normalization deduplicates favorites and bounds untrusted saved state', () => {
  const state = seedState();
  state.shelf.push({ id: 'changfeng', addedAt: 0 }, { id: 'unknown', addedAt: 1 });
  state.progress.changfeng = { chapter: 900, paragraph: -20, fraction: 4, updatedAt: 'bad' };
  state.settings = { fontSize: 200, lineHeight: 10, theme: '<script>' };
  const actual = normalizeState(state);
  assert.equal(actual.shelf.length, 6);
  assert.deepEqual(actual.progress.changfeng, { chapter: 11, paragraph: 0, fraction: 1, updatedAt: 0 });
  assert.deepEqual(actual.settings, { fontSize: 20, lineHeight: 1.8, theme: 'paper' });
});
test('routes parse encoded search terms and reject invalid book/chapter addresses', () => {
  assert.deepEqual(parseRoute('#/search?q=%E9%95%BF%E9%A3%8E&category=%E5%A5%87%E5%B9%BB'), { page: 'search', query: '长风', category: '奇幻' });
  assert.deepEqual(parseRoute('#/read/changfeng/2'), { page: 'read', id: 'changfeng', chapter: 2 });
  assert.deepEqual(parseRoute('#/book/stars'), { page: 'book', id: 'stars' });
  for (const hash of ['#/read/changfeng/-1', '#/read/changfeng/12', '#/book/unknown', '#/unknown']) assert.deepEqual(parseRoute(hash), { page: 'shelf' });
});
test('every mock work has usable original chapter content', () => {
  assert.equal(new Set(books.map(book => book.id)).size, books.length);
  for (const book of books) for (let i = 0; i < book.chapters.length; i++) {
    const paragraphs = chapterParagraphs(book, i);
    assert.equal(paragraphs.length, 14);
    assert.ok(paragraphs.every(text => typeof text === 'string' && text.length > 0));
    assert.ok(paragraphs.some(text => text.includes(book.chapters[i])));
  }
});
