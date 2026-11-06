import { books } from './data.js';

export const STORAGE_KEY = 'zhuying-demo-v1';
export const defaults = { fontSize: 20, lineHeight: 1.8, theme: 'paper' };
const validIds = new Set(books.map(book => book.id));
export const findBook = id => books.find(book => book.id === id);
export function seedState(now = Date.now()) {
  return { version: 1, shelf: books.slice(0, 6).map((book, i) => ({ id: book.id, addedAt: now - i * 86400000 })), progress: {
    changfeng: { chapter: 2, paragraph: 0, fraction: 0, updatedAt: now - 3600000 },
    stars: { chapter: 1, paragraph: 0, fraction: 0, updatedAt: now - 86400000 },
    sunset: { chapter: 3, paragraph: 0, fraction: 0, updatedAt: now - 172800000 },
  }, settings: { ...defaults } };
}
const clamp = (value, min, max) => Math.min(max, Math.max(min, Number.isFinite(Number(value)) ? Number(value) : min));
export function normalizeState(raw) {
  if (!raw || raw.version !== 1 || !Array.isArray(raw.shelf)) throw new Error('Invalid saved state');
  const seen = new Set();
  const shelf = raw.shelf.filter(item => item && validIds.has(item.id) && !seen.has(item.id) && seen.add(item.id)).map(item => ({ id: item.id, addedAt: clamp(item.addedAt, 0, 1e15) }));
  const progress = {};
  for (const [id, item] of Object.entries(raw.progress || {})) {
    if (!validIds.has(id) || !item || typeof item !== 'object') continue;
    progress[id] = { chapter: Math.floor(clamp(item.chapter, 0, findBook(id).chapters.length - 1)), paragraph: Math.floor(clamp(item.paragraph, 0, 13)), fraction: clamp(item.fraction, 0, 1), updatedAt: clamp(item.updatedAt, 0, 1e15) };
  }
  return { version: 1, shelf, progress, settings: {
    fontSize: [16, 18, 20, 22, 24].includes(raw.settings?.fontSize) ? raw.settings.fontSize : defaults.fontSize,
    lineHeight: [1.6, 1.8, 2].includes(raw.settings?.lineHeight) ? raw.settings.lineHeight : defaults.lineHeight,
    theme: ['paper', 'light', 'dark'].includes(raw.settings?.theme) ? raw.settings.theme : defaults.theme,
  } };
}
export function loadState(storage, now) {
  try {
    const saved = storage.getItem(STORAGE_KEY) ?? storage.getItem('yueshan-demo-v1');
    return { state: saved ? normalizeState(JSON.parse(saved)) : seedState(now), error: false };
  } catch { return { state: seedState(now), error: true }; }
}
export function persistState(storage, state) {
  try { storage.setItem(STORAGE_KEY, JSON.stringify(state)); return true; } catch { return false; }
}
export function toggleShelf(state, id, now = Date.now()) {
  if (!validIds.has(id)) return false;
  const found = state.shelf.findIndex(item => item.id === id);
  if (found >= 0) { state.shelf.splice(found, 1); return false; }
  state.shelf.push({ id, addedAt: now }); return true;
}
export function shelfBooks(state, filter = 'all') {
  return state.shelf.filter(item => filter === 'reading' ? !!state.progress[item.id] : filter === 'unread' ? !state.progress[item.id] : true)
    .sort((a, b) => {
      const pa = state.progress[a.id], pb = state.progress[b.id];
      if (pa && pb) return pb.updatedAt - pa.updatedAt;
      if (pa || pb) return pa ? -1 : 1;
      return b.addedAt - a.addedAt;
    }).map(item => findBook(item.id));
}
export function searchBooks(query = '', category = '全部') {
  const key = query.trim().toLocaleLowerCase();
  return books.filter(book => (category === '全部' || category === book.category) && (!key || `${book.title} ${book.author}`.toLocaleLowerCase().includes(key)));
}
export function recordProgress(state, id, chapter, paragraph = 0, fraction = 0, now = Date.now()) {
  const book = findBook(id);
  if (!book || !Number.isInteger(chapter) || chapter < 0 || chapter >= book.chapters.length) return false;
  state.progress[id] = { chapter, paragraph: Math.floor(clamp(paragraph, 0, 13)), fraction: clamp(fraction, 0, 1), updatedAt: now };
  return true;
}
export function parseRoute(hash) {
  try {
    const url = new URL((hash || '#/shelf').slice(1), 'http://demo.local');
    const [, page, id, chapter] = url.pathname.split('/');
    if (page === 'search') return { page, query: url.searchParams.get('q') || '', category: url.searchParams.get('category') || '全部' };
    if (['book', 'read'].includes(page) && findBook(id)) {
      const index = chapter === undefined ? 0 : Number(chapter);
      if (page === 'book') return { page, id };
      if (Number.isInteger(index) && index >= 0 && index < findBook(id).chapters.length) return { page, id, chapter: index };
    }
    return { page: 'shelf' };
  } catch { return { page: 'shelf' }; }
}
