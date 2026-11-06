import { books, chapterName, chapterParagraphs } from './data.js';
import { findBook, loadState, persistState, toggleShelf, shelfBooks, searchBooks, recordProgress, parseRoute } from './store.js';

const paths = {
  mountain: '<path d="m3 18 7-12 5 8 3-5 5 9Z"/>',
  shelf: '<path d="M4 4v16M9 4v16M14 5v15m3-15 4 14M3 20h19"/>',
  compass: '<circle cx="12" cy="12" r="9"/><path d="m16 8-2.5 5.5L8 16l2.5-5.5Z"/>',
  search: '<circle cx="10.5" cy="10.5" r="6.5"/><path d="m16 16 5 5"/>',
  arrow: '<path d="M4 12h16m-6-6 6 6-6 6"/>',
  left: '<path d="m14 5-7 7 7 7"/>',
  right: '<path d="m10 5 7 7-7 7"/>',
  book: '<path d="M12 5c-3-2-7-2-9-1v15c3-1 6-1 9 1 3-2 6-2 9-1V4c-2-1-6-1-9 1Zm0 0v15"/>',
  bookmark: '<path d="M6 4h12v17l-6-4-6 4Z"/>',
  check: '<path d="m5 12 4 4L19 6"/>',
  grid: '<rect x="3" y="3" width="7" height="7" rx="1"/><rect x="14" y="3" width="7" height="7" rx="1"/><rect x="3" y="14" width="7" height="7" rx="1"/><rect x="14" y="14" width="7" height="7" rx="1"/>',
  list: '<path d="M8 5h13M8 12h13M8 19h13M3 5h.1M3 12h.1M3 19h.1"/>',
  clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  settings: '<path d="M4 6h16M4 12h16M4 18h16"/><circle cx="9" cy="6" r="2"/><circle cx="15" cy="12" r="2"/><circle cx="9" cy="18" r="2"/>',
  close: '<path d="m6 6 12 12M6 18 18 6"/>',
  sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2m0 16v2M2 12h2m16 0h2M5 5l1.5 1.5m11 11L19 19M5 19l1.5-1.5m11-11L19 5"/>',
  moon: '<path d="M20 15a9 9 0 0 1-11-11 9 9 0 1 0 11 11Z"/>',
  more: '<circle cx="5" cy="12" r="1"/><circle cx="12" cy="12" r="1"/><circle cx="19" cy="12" r="1"/>',
  leaf: '<path d="M20 3C9 2 2 7 5 15c5 6 15 1 15-12ZM4 21 15 10"/>',
};
const icon = (name, cls = '') => `<svg class="icon ${cls}" width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${paths[name] || paths.book}</svg>`;
const esc = text => String(text).replace(/[&<>"']/g, char => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
let storage;
try { storage = window.localStorage; } catch { storage = { getItem() { throw new Error('Unavailable'); }, setItem() { throw new Error('Unavailable'); } }; }
const loaded = loadState(storage);
let state = loaded.state;
let currentRoute;
let shelfFilter = 'all';
let shelfLayout = 'grid';
let overlay = null;
let returnFocus = null;
let toastTimer;
let saveTimer;
let readingReady = false;
let storageWarning = false;
const app = document.querySelector('#app');
const overlayRoot = document.querySelector('#overlay-root');
const toastRoot = document.querySelector('#toast-root');

function persist() {
  if (!persistState(storage, state) && !storageWarning) {
    storageWarning = true;
    toast('本地保存暂不可用，本次进度可能无法保留');
  }
}
function toast(message, action) {
  clearTimeout(toastTimer);
  toastRoot.innerHTML = `<div class="toast">${icon('check')}<span>${esc(message)}</span>${action ? '<button data-action="undo">撤销</button>' : ''}</div>`;
  toastRoot._undo = action;
  toastTimer = setTimeout(() => { toastRoot.innerHTML = ''; toastRoot._undo = null; }, 4500);
}
function cover(book, extra = '') {
  return `<div class="cover cover-${book.color} ${extra}" aria-label="${esc(book.title)}封面"><div class="cover-grain"></div><span class="cover-edition">竹影 · 故事典藏</span><div class="cover-sun"></div><div class="cover-mountain mountain-back"></div><div class="cover-mountain mountain-front"></div><div class="cover-orbit"></div><div class="cover-window"></div><div class="cover-type"><span>${esc(book.title)}</span><small>${esc(book.author)} 著</small></div><span class="cover-imprint">ZHUYING ORIGINAL</span></div>`;
}
function logo() { return `<a class="logo" href="#/shelf" aria-label="竹影首页"><span class="logo-mark">${icon('mountain')}</span><span>竹影<small>ZHUYING</small></span></a>`; }
function sidebar(active) {
  return `<aside class="sidebar">${logo()}<div class="nav-caption">我的阅读空间</div><nav aria-label="主导航"><a class="nav-item ${active === 'shelf' ? 'active' : ''}" href="#/shelf">${icon('shelf')}<span>我的书架</span><span class="nav-count">${state.shelf.length}</span></a><a class="nav-item ${active === 'search' ? 'active' : ''}" href="#/search">${icon('compass')}<span>发现好书</span></a></nav><div class="sidebar-quote"><span>“</span><p>读书，是一场<br>不必远行的远行。</p><div class="quote-line"></div><small>在字里行间，遇见山海</small></div><div class="sidebar-bottom"><button class="nav-item" data-action="settings">${icon('settings')}<span>阅读偏好</span></button><div class="local-note"><span class="status-dot"></span>你的阅读，只属于你</div></div></aside>`;
}
function shell(content, active = 'shelf') {
  return `${sidebar(active)}<div class="workspace"><header class="topbar"><span class="topbar-breadcrumb">我的空间 <span>/</span> ${active === 'search' ? '发现好书' : active === 'book' ? '作品详情' : '我的书架'}</span><form class="header-search" data-search-form><label class="sr-only" for="header-query">搜索书名或作者</label>${icon('search')}<input id="header-query" name="q" placeholder="搜索书名或作者" autocomplete="off" value="${currentRoute?.page === 'search' ? esc(currentRoute.query) : ''}"><button type="submit" aria-label="搜索">${icon('arrow')}</button></form><button class="avatar" data-action="about" aria-label="关于这个 Demo">山</button></header><main class="main-content" id="main-content">${content}</main><footer class="app-footer"><span>竹影 <span class="footer-dot">·</span> 让故事，继续发生</span><span>交互预览 / 原创示例内容</span></footer></div><nav class="mobile-nav" aria-label="移动端导航"><a href="#/shelf" class="${active === 'shelf' ? 'active' : ''}">${icon('shelf')}<span>书架</span></a><a href="#/search" class="${active === 'search' ? 'active' : ''}">${icon('compass')}<span>发现</span></a><button data-action="settings">${icon('settings')}<span>偏好</span></button></nav>`;
}
function readingUrl(book) { return `#/read/${book.id}/${state.progress[book.id]?.chapter || 0}`; }
function progressPercent(book) { const p = state.progress[book.id]; return p ? Math.min(99, Math.round(((p.chapter + p.paragraph / 14) / book.chapters.length) * 100)) : 0; }
function card(book, discovery = false) {
  const p = state.progress[book.id];
  const saved = state.shelf.some(item => item.id === book.id);
  return `<article class="book-card" data-book="${book.id}"><div class="book-cover-wrap"><a class="cover-link" href="${discovery ? `#/book/${book.id}` : readingUrl(book)}" aria-label="${discovery ? '查看' : '阅读'}${book.title}">${cover(book)}<span class="cover-hover">${icon(discovery ? 'arrow' : 'book')}${discovery ? '查看作品' : p ? '继续阅读' : '开始阅读'}</span></a><button class="book-menu" data-action="book-menu" data-id="${book.id}" aria-label="${book.title}的更多操作">${icon('more')}</button></div><div class="book-card-info"><a class="book-title" href="#/book/${book.id}">${book.title}</a><div class="book-author">${book.author}<span>·</span>${book.genre}</div>${discovery ? `<p class="book-summary">${book.intro.split('\n')[0]}</p><div class="discovery-meta"><span>${book.status} · ${book.words}字</span><button class="small-save ${saved ? 'saved' : ''}" data-action="toggle-shelf" data-id="${book.id}" aria-label="${saved ? '移出' : '加入'}书架">${icon(saved ? 'check' : 'bookmark')}</button></div>` : `<div class="book-progress-label">${p ? `<span>已读 ${progressPercent(book)}%</span><span>${chapterName(book, p.chapter).split(' ')[0]}</span>` : '<span class="unread-dot">尚未开始，故事在等你</span>'}</div><div class="book-progress-track"><span style="width:${progressPercent(book)}%"></span></div>`}</div></article>`;
}
function shelfPage() {
  const list = shelfBooks(state, shelfFilter);
  const recent = shelfBooks(state, 'reading')[0];
  const readingCount = shelfBooks(state, 'reading').length;
  const hero = recent ? `<section class="continue-card"><div class="continue-copy"><div class="eyebrow"><span class="status-dot"></span> 把时间，留给好故事</div><h2>翻开书，<br>继续你的山海。</h2><p class="continue-book">《${recent.title}》<span>${recent.author} 著</span></p><p class="continue-chapter">上次读到 · ${chapterName(recent, state.progress[recent.id].chapter)}</p><a class="button button-primary" href="${readingUrl(recent)}">继续阅读 ${icon('arrow')}</a><span class="continue-progress">已读 ${progressPercent(recent)}%</span></div><div class="hero-art"><div class="hero-ring ring-one"></div><div class="hero-ring ring-two"></div><span class="hero-spark spark-one">✦</span><span class="hero-spark spark-two">✧</span><a href="${readingUrl(recent)}" class="hero-book" aria-label="继续阅读${recent.title}">${cover(recent)}</a><div class="hero-caption">每一页，都是新的风景</div></div></section>` : `<section class="continue-card welcome-card"><div class="continue-copy"><div class="eyebrow">为你的下一段旅程</div><h2>故事的起点，<br>就在这一页。</h2><p class="continue-book">总有一本书，与你恰好相逢。</p><a class="button button-primary" href="#/search">寻找一本好书 ${icon('arrow')}</a></div><div class="welcome-mountain">${icon('mountain')}</div></section>`;
  return shell(`<section class="page-heading"><div><div class="eyebrow muted">A LITTLE SPACE FOR YOURSELF</div><h1>我的书架<span class="heading-dot">.</span></h1><p>生活很忙，记得给自己留一页时间。</p></div><a class="text-link" href="#/search">去发现好书 ${icon('arrow')}</a></section><div class="dashboard-row">${hero}<aside class="reading-note"><div class="note-top">${icon('leaf')}<span>阅读，是一种日常</span></div><div class="note-quote">世界很大，<br>书里还有<br><em>另一个世界。</em></div><div class="note-bottom"><div><strong>${state.shelf.length}<small>本</small></strong><span>书架收藏</span></div><div><strong>${readingCount}<small>本</small></strong><span>正在阅读</span></div></div></aside></div><section class="shelf-section"><div class="section-toolbar"><div class="shelf-tabs" role="group" aria-label="筛选书架">${[['all', '全部收藏', state.shelf.length], ['reading', '正在阅读', readingCount], ['unread', '尚未开始', state.shelf.length - readingCount]].map(([key, label, count]) => `<button class="shelf-tab ${shelfFilter === key ? 'active' : ''}" data-action="filter" data-filter="${key}" aria-pressed="${shelfFilter === key}">${label}<small>${count}</small></button>`).join('')}</div><div class="shelf-controls"><span>${icon('clock')}最近阅读</span><div class="layout-switch" role="group" aria-label="书架布局"><button class="${shelfLayout === 'grid' ? 'selected' : ''}" data-action="layout" data-layout="grid" aria-label="网格布局" aria-pressed="${shelfLayout === 'grid'}">${icon('grid')}</button><button class="${shelfLayout === 'list' ? 'selected' : ''}" data-action="layout" data-layout="list" aria-label="列表布局" aria-pressed="${shelfLayout === 'list'}">${icon('list')}</button></div></div></div>${list.length ? `<div class="book-grid ${shelfLayout === 'list' ? 'list-view' : ''}">${list.map(book => card(book)).join('')}</div>` : emptyState(shelfFilter === 'all' ? '你的书架，等待第一个故事' : '这里还没有书', shelfFilter === 'all' ? '去发现一本喜欢的小说，把它加入书架吧。' : '换个筛选看看，或去发现新的故事。', true)}</section>`, 'shelf');
}
function emptyState(title, message, link = false) { return `<div class="empty-state">${icon('book')}<h2>${title}</h2><p>${message}</p>${link ? '<a class="button button-primary" href="#/search">去发现好书</a>' : ''}</div>`; }
function searchPage(route) {
  const list = searchBooks(route.query, route.category);
  return shell(`<section class="discovery-heading"><div class="eyebrow muted">FIND YOUR NEXT CHAPTER</div><h1>下一段故事，<br>从这里开始<span class="heading-dot">.</span></h1><p>在熟悉的名字里重逢，也在陌生的世界里出发。</p><form class="discovery-search" data-search-form>${icon('search')}<label class="sr-only" for="discovery-query">搜索书名或作者</label><input id="discovery-query" name="q" placeholder="试试「长风」或作者「林间渡」" value="${esc(route.query)}" autocomplete="off"><button class="button button-primary" type="submit">搜索好书 ${icon('arrow')}</button></form></section><div class="discovery-categories" role="group" aria-label="题材筛选">${['全部', '奇幻', '都市', '科幻', '古风', '悬疑', '仙侠'].map(category => `<button class="category-chip ${route.category === category ? 'active' : ''}" data-action="category" data-category="${category}" aria-pressed="${route.category === category}">${category}</button>`).join('')}</div><div class="search-result-heading"><h2>${route.query ? `“${esc(route.query)}”的搜索结果` : '故事小馆'}</h2><span>${list.length} 部作品 · 原创模拟书库</span></div>${list.length ? `<div class="book-grid discovery-grid">${list.map(book => card(book, true)).join('')}</div>` : `${emptyState('还没有找到这个故事', '换个书名或作者试试。当前演示书库包含 8 部原创示例作品。')}<button class="button button-outline center-button" data-action="clear-search">浏览全部作品 ${icon('arrow')}</button>`}`, 'search');
}
function tocList(book, current = -1) {
  return `<ol class="toc-list">${book.chapters.map((_, index) => `<li><a class="toc-item ${index === current ? 'current' : ''}" href="#/read/${book.id}/${index}" ${index === current ? 'aria-current="true"' : ''}><span>${chapterName(book, index)}</span>${index === current ? '<small>正在阅读</small>' : icon('right')}</a></li>`).join('')}</ol>`;
}
function bookPage(book) {
  const saved = state.shelf.some(item => item.id === book.id);
  const progress = state.progress[book.id];
  return shell(`<a class="back-link" href="#/search">${icon('left')}返回发现</a><section class="book-detail"><div class="detail-cover">${cover(book)}</div><div class="detail-info"><div class="eyebrow">${book.genre} <span class="detail-status">${book.status}</span></div><h1>${book.title}</h1><p class="detail-author">${book.author} <span>著</span></p><p class="detail-subtitle">${book.subtitle}</p><div class="book-tags">${book.tags.map(tag => `<span>${tag}</span>`).join('')}</div><div class="detail-numbers"><span><strong>${book.words}</strong> 字</span><span><strong>${book.chapters.length}</strong> 章示例</span><span>原创演示作品</span></div><div class="detail-actions"><a class="button button-primary" href="${readingUrl(book)}">${icon('book')}${progress ? '继续阅读' : '开始阅读'}${icon('arrow')}</a><button class="button button-outline" data-action="toggle-shelf" data-id="${book.id}">${icon(saved ? 'check' : 'bookmark')}${saved ? '已在书架' : '加入书架'}</button></div>${progress ? `<p class="detail-progress">${icon('clock')}上次读到 ${chapterName(book, progress.chapter)} · 已读 ${progressPercent(book)}%</p>` : ''}</div></section><div class="detail-body"><section class="synopsis"><div class="section-title"><span class="section-number">01</span><h2>故事简介</h2></div>${book.intro.split('\n').map(p => `<p>${p}</p>`).join('')}<div class="sample-notice">${icon('leaf')}这里的书名、封面与故事均为原创演示内容，用于预览阅读体验。</div></section><section class="detail-toc"><div class="section-title"><span class="section-number">02</span><h2>章节目录</h2><span class="toc-count">共 ${book.chapters.length} 章示例</span></div>${tocList(book, progress?.chapter)}</section></div>`, 'book');
}
function readerPage(book, chapter) {
  const saved = state.shelf.some(item => item.id === book.id);
  return `<div class="reader theme-${state.settings.theme}" style="--reading-font:${state.settings.fontSize}px;--reading-line:${state.settings.lineHeight}"><div class="reading-progress-bar"><span id="reading-progress-fill"></span></div><header class="reader-header"><a class="reader-back" href="#/shelf">${icon('left')}<span>返回书架</span></a><a href="#/book/${book.id}" class="reader-book-name">${book.title}<span>${book.author} 著</span></a><button class="icon-button" data-action="settings" aria-label="阅读设置">${icon('settings')}</button></header><main class="reader-content"><div class="chapter-kicker">${book.genre} <span>／</span> ${String(chapter + 1).padStart(2, '0')} OF ${String(book.chapters.length).padStart(2, '0')}</div><h1>${chapterName(book, chapter)}</h1><div class="chapter-meta"><span>${book.author} 著</span><span>原创示例章节</span><span>约 3 分钟阅读</span></div><article class="chapter-text" aria-label="章节正文">${chapterParagraphs(book, chapter).map((p, index) => `<p data-paragraph="${index}">${p}</p>`).join('')}</article><div class="chapter-end"><span></span>${icon('leaf')}<span></span></div><p class="chapter-end-note">${chapter === book.chapters.length - 1 ? '你已读完全部示例章节，感谢同行。' : '故事还在继续，不妨再读一章。'}</p><nav class="chapter-navigation" aria-label="章节翻页"><button class="button button-outline" data-action="chapter" data-chapter="${chapter - 1}" ${chapter === 0 ? 'disabled' : ''}>${icon('left')}上一章</button><button class="button button-primary" data-action="chapter" data-chapter="${chapter + 1}" ${chapter === book.chapters.length - 1 ? 'disabled' : ''}>${chapter === book.chapters.length - 1 ? '已是最后一章' : '下一章'}${icon('right')}</button></nav><div class="reader-footnote">竹影 · 在字里行间，遇见山海</div></main><aside class="reader-tools" aria-label="阅读工具"><button data-action="toc">${icon('list')}<span>目录</span></button><button data-action="settings">${icon('settings')}<span>设置</span></button><button data-action="toggle-shelf" data-id="${book.id}" class="${saved ? 'is-saved' : ''}">${icon(saved ? 'check' : 'bookmark')}<span>${saved ? '已收藏' : '收藏'}</span></button><a href="#/book/${book.id}">${icon('book')}<span>详情</span></a></aside><div class="reader-position" id="reader-position">${chapter + 1} / ${book.chapters.length} 章</div></div>`;
}

function captureReading() {
  if (currentRoute?.page !== 'read' || !readingReady) return null;
  const paragraphs = [...document.querySelectorAll('[data-paragraph]')];
  const visible = paragraphs.find(p => p.getBoundingClientRect().bottom > 110) || paragraphs.at(-1);
  if (!visible) return null;
  const box = visible.getBoundingClientRect();
  return { paragraph: Number(visible.dataset.paragraph), fraction: Math.max(0, Math.min(1, (110 - box.top) / box.height)) };
}
function saveReading() {
  const anchor = captureReading();
  if (!anchor) return;
  recordProgress(state, currentRoute.id, currentRoute.chapter, anchor.paragraph, anchor.fraction);
  persist();
}
function restoreReading(anchor) {
  readingReady = false;
  requestAnimationFrame(() => requestAnimationFrame(() => {
    if (currentRoute?.page !== 'read') return;
    const p = anchor && document.querySelector(`[data-paragraph="${anchor.paragraph}"]`);
    if (p && (anchor.paragraph > 0 || anchor.fraction > 0)) {
      const box = p.getBoundingClientRect();
      window.scrollTo(0, window.scrollY + box.top + box.height * anchor.fraction - 110);
    } else window.scrollTo(0, 0);
    readingReady = true;
    updateReadingIndicator();
  }));
}
function updateReadingIndicator() {
  if (currentRoute?.page !== 'read') return;
  const content = document.querySelector('.reader-content');
  if (!content) return;
  const percent = Math.max(0, Math.min(100, window.scrollY / Math.max(1, document.documentElement.scrollHeight - innerHeight) * 100));
  document.querySelector('#reading-progress-fill').style.width = `${percent}%`;
  document.querySelector('#reader-position').textContent = `${currentRoute.chapter + 1} / ${findBook(currentRoute.id).chapters.length} 章 · 本章 ${Math.round(percent)}%`;
}
function render(options = {}) {
  closeOverlay(false);
  currentRoute = parseRoute(location.hash);
  document.body.classList.toggle('is-reading', currentRoute.page === 'read');
  const book = findBook(currentRoute.id);
  if (currentRoute.page === 'read') {
    const progress = state.progress[book.id];
    const anchor = options.anchor || (progress?.chapter === currentRoute.chapter ? progress : null);
    app.innerHTML = readerPage(book, currentRoute.chapter);
    recordProgress(state, book.id, currentRoute.chapter, anchor?.paragraph || 0, anchor?.fraction || 0);
    persist();
    restoreReading(anchor);
    document.title = `${chapterName(book, currentRoute.chapter)} · ${book.title} · 竹影`;
  } else {
    readingReady = false;
    app.innerHTML = currentRoute.page === 'search' ? searchPage(currentRoute) : currentRoute.page === 'book' ? bookPage(book) : shelfPage();
    if (!options.keepScroll) window.scrollTo(0, 0);
    document.title = `${currentRoute.page === 'book' ? book.title : currentRoute.page === 'search' ? '发现好书' : '我的书架'} · 竹影`;
  }
}

function openOverlay(type, id) {
  saveReading();
  returnFocus = document.activeElement;
  overlay = { type, id };
  let content;
  if (type === 'toc') {
    const book = findBook(currentRoute.id);
    content = `<div class="drawer-heading"><div><div class="eyebrow muted">CONTENTS</div><h2>章节目录</h2></div><button class="icon-button" data-action="close-overlay" aria-label="关闭目录">${icon('close')}</button></div><p class="drawer-subtitle">${book.title} · 共 ${book.chapters.length} 章示例</p><div class="drawer-scroll">${tocList(book, currentRoute.chapter)}</div>`;
  } else if (type === 'settings') {
    content = settingsContent();
  } else if (type === 'menu') {
    const book = findBook(id);
    const saved = state.shelf.some(item => item.id === id);
    content = `<div class="drawer-heading"><h2>${book.title}</h2><button class="icon-button" data-action="close-overlay" aria-label="关闭操作菜单">${icon('close')}</button></div><p class="drawer-subtitle">${book.author} · ${book.genre}</p><a class="menu-row" href="#/book/${id}">${icon('book')}查看作品详情${icon('right')}</a><a class="menu-row" href="${readingUrl(book)}">${icon('arrow')}${state.progress[id] ? '继续阅读' : '开始阅读'}${icon('right')}</a><button class="menu-row" data-action="toggle-shelf" data-id="${id}">${icon('bookmark')}${saved ? '移出书架' : '加入书架'}</button><p class="settings-note">移出书架后，阅读进度仍会保留。</p>`;
  } else {
    content = `<div class="drawer-heading"><h2>关于竹影</h2><button class="icon-button" data-action="close-overlay" aria-label="关闭介绍">${icon('close')}</button></div><div class="about-content">${logo()}<h3>一个安静的私人阅读角落。</h3><p>这是一个可交互的界面 Demo。你可以搜索 8 本原创示例小说，体验收藏、选章、阅读和进度恢复。</p><p>书籍信息、字数与正文均为演示数据。书架和阅读偏好保存在当前浏览器，不连接真实书源。</p><span class="about-version">DESIGN PREVIEW · V0.1</span></div>`;
  }
  overlayRoot.innerHTML = `<div class="overlay-backdrop" data-action="close-overlay"></div><section class="drawer ${type === 'menu' || type === 'about' ? 'compact-drawer' : ''}" role="dialog" aria-modal="true" aria-label="${type === 'toc' ? '章节目录' : type === 'settings' ? '阅读偏好' : type === 'menu' ? '书籍操作' : '关于竹影'}">${content}</section>`;
  app.inert = true;
  document.body.classList.add('overlay-open');
  overlayRoot.querySelector('button, a, input')?.focus();
  if (type === 'toc') overlayRoot.querySelector('.toc-item.current')?.scrollIntoView({ block: 'center' });
}
function settingsContent() {
  return `<div class="drawer-heading"><div><div class="eyebrow muted">MAKE IT YOURS</div><h2>阅读偏好</h2></div><button class="icon-button" data-action="close-overlay" aria-label="关闭设置">${icon('close')}</button></div><p class="drawer-subtitle">让每一页，都合你的心意。</p><div class="settings-body"><fieldset><legend>阅读主题</legend><div class="theme-options">${[['paper', '暖纸', 'sun'], ['light', '明亮', 'sun'], ['dark', '夜读', 'moon']].map(([theme, title, glyph]) => `<button data-action="theme" data-theme="${theme}" class="theme-option theme-swatch-${theme} ${state.settings.theme === theme ? 'active' : ''}" aria-pressed="${state.settings.theme === theme}">${icon(glyph)}<span>${title}</span>${state.settings.theme === theme ? icon('check') : ''}</button>`).join('')}</div></fieldset><fieldset><legend>文字大小 <span>${state.settings.fontSize} px</span></legend><div class="segmented">${[16, 18, 20, 22, 24].map(size => `<button class="${state.settings.fontSize === size ? 'active' : ''}" data-action="font" data-size="${size}" aria-pressed="${state.settings.fontSize === size}">${size}</button>`).join('')}</div></fieldset><fieldset><legend>段落行距</legend><div class="segmented">${[[1.6, '紧凑'], [1.8, '适中'], [2, '宽松']].map(([size, title]) => `<button class="${state.settings.lineHeight === size ? 'active' : ''}" data-action="line" data-size="${size}" aria-pressed="${state.settings.lineHeight === size}">${title}</button>`).join('')}</div></fieldset><div class="settings-preview theme-${state.settings.theme}" style="font-size:${state.settings.fontSize}px;line-height:${state.settings.lineHeight}"><span>阅读预览</span><p>山海有相逢，长风自有归处。<br>在字里行间，遇见另一个世界。</p></div><p class="settings-note">${icon('check')}偏好自动保存在当前浏览器</p><button class="reset-settings" data-action="reset-settings">恢复默认设置</button></div>`;
}
function closeOverlay(focus = true) {
  if (!overlay) return;
  overlay = null;
  overlayRoot.innerHTML = '';
  app.inert = false;
  document.body.classList.remove('overlay-open');
  if (focus && returnFocus?.isConnected) returnFocus.focus();
}
function updateSettings(key, value) {
  const focused = document.activeElement;
  const action = focused?.dataset.action;
  const anchor = captureReading();
  state.settings[key] = value;
  persist();
  if (currentRoute.page === 'read') {
    app.innerHTML = readerPage(findBook(currentRoute.id), currentRoute.chapter);
    restoreReading(anchor);
  }
  overlayRoot.querySelector('.drawer').innerHTML = settingsContent();
  const selector = key === 'theme' ? `[data-theme="${value}"]` : `[data-action="${action}"][data-size="${value}"]`;
  overlayRoot.querySelector(selector)?.focus();
}

document.addEventListener('submit', event => {
  if (!event.target.matches('[data-search-form]')) return;
  event.preventDefault();
  const query = new FormData(event.target).get('q').trim();
  if (!query) { event.target.querySelector('input').focus(); toast('输入一个书名或作者，开始寻找故事'); return; }
  location.hash = `/search?q=${encodeURIComponent(query)}`;
});
document.addEventListener('click', event => {
  const link = event.target.closest('a[href^="#/"]');
  if (link && overlay) closeOverlay(false);
  if (link && link.hash === location.hash) { event.preventDefault(); if (currentRoute.page === 'read') window.scrollTo({ top: 0, behavior: 'smooth' }); }
  const button = event.target.closest('[data-action]');
  if (!button) return;
  const { action, id } = button.dataset;
  if (action === 'settings') openOverlay('settings');
  else if (action === 'toc') openOverlay('toc');
  else if (action === 'about') openOverlay('about');
  else if (action === 'book-menu') openOverlay('menu', id);
  else if (action === 'close-overlay') closeOverlay();
  else if (action === 'filter') { shelfFilter = button.dataset.filter; render({ keepScroll: true }); }
  else if (action === 'layout') { shelfLayout = button.dataset.layout; render({ keepScroll: true }); }
  else if (action === 'category') location.hash = `/search?q=${encodeURIComponent(currentRoute.query)}&category=${encodeURIComponent(button.dataset.category)}`;
  else if (action === 'clear-search') location.hash = '/search';
  else if (action === 'chapter') {
    const chapter = Number(button.dataset.chapter);
    if (chapter >= 0 && chapter < findBook(currentRoute.id).chapters.length) location.hash = `/read/${currentRoute.id}/${chapter}`;
  } else if (action === 'toggle-shelf') {
    saveReading();
    const anchor = captureReading();
    const added = toggleShelf(state, id);
    persist();
    render({ keepScroll: true, anchor });
    toast(added ? '已加入书架，好故事不走散' : '已移出书架，阅读进度仍然保留', !added ? () => { toggleShelf(state, id); persist(); render({ keepScroll: true, anchor: captureReading() }); toast('已重新加入书架'); } : null);
  } else if (action === 'undo') { toastRoot._undo?.(); }
  else if (action === 'theme') updateSettings('theme', button.dataset.theme);
  else if (action === 'font') updateSettings('fontSize', Number(button.dataset.size));
  else if (action === 'line') updateSettings('lineHeight', Number(button.dataset.size));
  else if (action === 'reset-settings') {
    const anchor = captureReading();
    state.settings = { fontSize: 20, lineHeight: 1.8, theme: 'paper' };
    persist();
    if (currentRoute.page === 'read') { app.innerHTML = readerPage(findBook(currentRoute.id), currentRoute.chapter); restoreReading(anchor); }
    overlayRoot.querySelector('.drawer').innerHTML = settingsContent();
    overlayRoot.querySelector('[data-action="reset-settings"]').focus();
  }
});
document.addEventListener('keydown', event => {
  if (!overlay) return;
  if (event.key === 'Escape') closeOverlay();
  if (event.key === 'Tab') {
    const nodes = [...overlayRoot.querySelectorAll('a[href], button:not([disabled]), input')];
    const first = nodes[0], last = nodes.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
  }
});
let toolsHidden = false;
document.addEventListener('click', event => {
  if (!event.target.closest('.chapter-text') || window.getSelection()?.toString() || overlay) return;
  toolsHidden = !toolsHidden;
  document.querySelector('.reader')?.classList.toggle('tools-hidden', toolsHidden);
});
window.addEventListener('hashchange', () => { clearTimeout(saveTimer); saveReading(); toolsHidden = false; render(); });
window.addEventListener('scroll', () => {
  if (currentRoute?.page !== 'read' || !readingReady || overlay) return;
  updateReadingIndicator();
  clearTimeout(saveTimer);
  saveTimer = setTimeout(saveReading, 250);
}, { passive: true });
window.addEventListener('pagehide', saveReading);
document.addEventListener('visibilitychange', () => { if (document.hidden) saveReading(); });
persist();
render();
if (loaded.error) toast('本地记录暂不可用，已载入示例书架');
