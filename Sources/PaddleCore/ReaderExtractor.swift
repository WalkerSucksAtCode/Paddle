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
        try {
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

            let root = document.querySelector('article, [itemprop="articleBody"], .article-body, .entry-content, .post-content');
            if (!root) {
                let bestNode = null;
                let maxScore = 0;
                const candidates = document.querySelectorAll('div, section, main');
                for (const node of candidates) {
                    let score = 0;
                    const paras = node.querySelectorAll('p');
                    for (const p of paras) {
                        const len = (p.innerText || '').trim().length;
                        if (len > 50) score += len;
                    }
                    // Penalize menus/comments
                    const idAndClass = ((node.id || '') + ' ' + (node.className || '')).toLowerCase();
                    if (/comment|footer|header|sidebar|nav|menu/.test(idAndClass)) score = 0;

                    if (score > maxScore) {
                        maxScore = score;
                        bestNode = node;
                    }
                }
                root = bestNode || document.body;
            }

            const clone = root.cloneNode(true);
            const unwantedSelectors = [
                'script', 'style', 'noscript', 'iframe', 'canvas', 'svg',
                'nav', 'footer', 'header', 'aside', 'form',
                '.ad', '.ads', '.advertisement', '.social-share', '.share',
                '.comments', '#comments', '.sidebar', '.related-posts',
                '[role="banner"]', '[role="navigation"]', '[role="complementary"]'
            ];
            clone.querySelectorAll(unwantedSelectors.join(',')).forEach(el => el.remove());

            const allElements = clone.querySelectorAll('*');
            for (const el of allElements) {
                const tag = el.tagName.toLowerCase();
                if (['p', 'h1', 'h2', 'h3', 'h4', 'ul', 'ol', 'li', 'blockquote', 'pre', 'code', 'figure', 'figcaption', 'img', 'a', 'strong', 'em', 'b', 'i'].includes(tag)) {
                    const href = el.getAttribute('href');
                    const src = el.getAttribute('src');
                    const alt = el.getAttribute('alt');
                    while (el.attributes.length > 0) {
                        el.removeAttribute(el.attributes[0].name);
                    }
                    if (href && (href.startsWith('http://') || href.startsWith('https://'))) el.setAttribute('href', href);
                    if (src && (src.startsWith('http://') || src.startsWith('https://') || src.startsWith('data:'))) el.setAttribute('src', src);
                    if (alt) el.setAttribute('alt', alt);
                } else if (['div', 'section', 'article', 'span'].includes(tag)) {
                    while (el.attributes.length > 0) el.removeAttribute(el.attributes[0].name);
                } else {
                    el.remove();
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
        } catch (e) {
            return null;
        }
    })()
    """
}
