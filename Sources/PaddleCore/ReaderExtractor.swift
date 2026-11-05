import Foundation

/// JavaScript snippets for detecting and extracting article content for Reader Mode.
public enum ReaderExtractor {
    /// Probe script that evaluates whether the page has article-like content suitable for Reader Mode.
    public static let availabilityProbeScript = """
    (() => {
        if (!document || !document.body) return false;
        if (document.querySelector('article, [itemprop="articleBody"], .article-body, .entry-content, .post-content')) {
            const article = document.querySelector('article, [itemprop="articleBody"], .article-body, .entry-content, .post-content');
            if (article && (article.innerText || '').trim().length > 250) return true;
        }
        const paras = Array.from(document.querySelectorAll('p'));
        let longParas = 0;
        let totalLength = 0;
        for (const p of paras) {
            const len = (p.innerText || '').trim().length;
            if (len > 80) {
                longParas++;
                totalLength += len;
            }
        }
        return longParas >= 3 && totalLength > 400;
    })()
    """

    /// Extraction script that cleanses clutter and returns a JSON string representing `ReaderArticle`.
    public static let extractionScript = """
    (() => {
        if (!document || !document.body) return null;

        const getMeta = (prop, name) => {
            const el = document.querySelector(`meta[property="${prop}"], meta[name="${name || prop}"]`);
            return el ? el.getAttribute('content') : null;
        };

        let title = getMeta('og:title') || getMeta('twitter:title');
        if (!title) {
            const h1 = document.querySelector('h1');
            title = h1 ? h1.innerText.trim() : document.title;
        }
        title = (title || document.title || '').trim();

        let byline = getMeta('author', 'author') || getMeta('article:author') || getMeta('twitter:creator');
        if (!byline) {
            const authorEl = document.querySelector('[rel="author"], .byline, .author, [itemprop="author"]');
            if (authorEl) byline = authorEl.innerText.trim();
        }

        const siteName = getMeta('og:site_name') || location.hostname.replace(/^www\\./, '');

        let publishedTime = getMeta('article:published_time');
        if (!publishedTime) {
            const timeEl = document.querySelector('time[datetime], time');
            if (timeEl) publishedTime = timeEl.getAttribute('datetime') || timeEl.innerText.trim();
        }

        const excerpt = getMeta('og:description') || getMeta('description', 'description');

        const isClutter = (node) => {
            const idAndClass = ((node.id || '') + ' ' + (typeof node.className === 'string' ? node.className : '')).toLowerCase();
            return /comment|footer|header|sidebar|nav|menu/.test(idAndClass);
        };

        // A marked-up article only counts when it holds real text: some sites use <article> for teasers or comments.
        let root = Array.from(document.querySelectorAll('article, [itemprop="articleBody"], .article-body, .entry-content, .post-content'))
            .find(el => (el.innerText || '').trim().length > 250) || null;
        if (!root) {
            // Each paragraph scores its parent and half that for its grandparent (as Readability does), so the
            // container that holds the paragraphs wins, not an outer page wrapper that merely contains them all.
            const scores = new Map();
            const add = (node, points) => {
                if (!node || node === document.body || node === document.documentElement) return;
                scores.set(node, (scores.get(node) || 0) + points);
            };
            for (const p of document.querySelectorAll('p')) {
                const len = (p.innerText || '').trim().length;
                if (len <= 50) continue;
                add(p.parentElement, len);
                add(p.parentElement && p.parentElement.parentElement, len / 2);
            }
            let maxScore = 0;
            for (const [node, score] of scores) {
                if (score > maxScore && !isClutter(node)) {
                    maxScore = score;
                    root = node;
                }
            }
            // Articles split into sibling blocks (Wikipedia's per-heading <section>s) score each block alone: climb while
            // the parent holds clearly more paragraph text, which stops at the article's own container.
            const paragraphText = (node) => Array.from(node.querySelectorAll('p'))
                .reduce((sum, p) => { const len = (p.innerText || '').trim().length; return len > 50 ? sum + len : sum; }, 0);
            if (root) {
                let text = paragraphText(root);
                while (root.parentElement && root.parentElement !== document.body && !isClutter(root.parentElement)) {
                    const parentText = paragraphText(root.parentElement);
                    if (parentText < text * 1.4) break;
                    root = root.parentElement;
                    text = parentText;
                }
            }
            root = root || document.body;
        }

        const clone = root.cloneNode(true);
        const unwantedSelectors = [
            'script', 'style', 'noscript', 'iframe', 'canvas', 'svg', 'template', 'object', 'embed',
            'nav', 'footer', 'header', 'aside', 'form', 'button', 'input', 'select', 'textarea', 'dialog',
            '.ad', '.ads', '.advertisement', '.social-share', '.share',
            '.comments', '#comments', '.sidebar', '.related-posts',
            '.mw-editsection', '.navbox', '.noprint', '.mw-jump-link',
            '[role="banner"]', '[role="navigation"]', '[role="complementary"]', '[aria-hidden="true"]', '[hidden]'
        ];
        clone.querySelectorAll(unwantedSelectors.join(',')).forEach(el => el.remove());

        const keepWithLinks = ['p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'ul', 'ol', 'li', 'blockquote', 'pre', 'code',
            'figure', 'figcaption', 'img', 'a', 'strong', 'em', 'b', 'i'];
        const keepBare = ['div', 'section', 'article', 'span', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th',
            'caption', 'dl', 'dt', 'dd', 'sup', 'sub', 'br', 'hr', 'small', 'abbr', 'cite', 'q', 'time', 'mark'];
        for (const el of clone.querySelectorAll('*')) {
            const tag = el.tagName.toLowerCase();
            if (keepWithLinks.includes(tag)) {
                // The resolved properties turn relative and protocol-relative addresses into absolute ones.
                const href = tag === 'a' ? el.href : null;
                const src = tag === 'img' ? el.src : null;
                const alt = el.getAttribute('alt');
                while (el.attributes.length > 0) el.removeAttribute(el.attributes[0].name);
                if (href && (href.startsWith('http://') || href.startsWith('https://'))) el.setAttribute('href', href);
                if (src && (src.startsWith('http://') || src.startsWith('https://') || src.startsWith('data:'))) el.setAttribute('src', src);
                if (alt) el.setAttribute('alt', alt);
            } else if (keepBare.includes(tag)) {
                while (el.attributes.length > 0) el.removeAttribute(el.attributes[0].name);
            } else {
                // Unknown wrappers (main, font, picture, custom elements) are unwrapped so their text stays.
                el.replaceWith(...el.childNodes);
            }
        }

        const contentHTML = clone.innerHTML.trim();
        const textContent = clone.innerText ? clone.innerText.trim() : '';

        if (textContent.length < 100) return null;

        return JSON.stringify({
            title: title,
            byline: byline || null,
            publishedTime: publishedTime || null,
            siteName: siteName || null,
            excerpt: excerpt || null,
            contentHTML: contentHTML,
            textContent: textContent
        });
    })()
    """
}
