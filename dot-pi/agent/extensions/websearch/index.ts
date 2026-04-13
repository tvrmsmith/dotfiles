/**
 * Websearch Extension for pi
 *
 * Provides two tools:
 *   - websearch: Search the web via DuckDuckGo (no API key required)
 *   - fetch_url: Fetch and extract readable content from a specific URL
 *
 * Install:
 *   1. Place in ~/.pi/agent/extensions/websearch/
 *   2. Run `npm install` in this directory
 *   3. Reload pi with /reload
 */

import type { ExtensionAPI } from "@mariozechner/pi-coding-agent";
import { Type } from "@sinclair/typebox";
import * as cheerio from "cheerio";

const USER_AGENT =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36";

interface SearchResult {
  title: string;
  url: string;
  snippet: string;
}

/**
 * Search DuckDuckGo HTML lite and parse results.
 */
async function searchDuckDuckGo(
  query: string,
  maxResults: number,
  signal?: AbortSignal
): Promise<SearchResult[]> {
  const url = `https://html.duckduckgo.com/html/?q=${encodeURIComponent(query)}`;

  const response = await fetch(url, {
    method: "POST",
    headers: {
      "User-Agent": USER_AGENT,
      "Accept": "text/html",
      "Accept-Language": "en-US,en;q=0.9",
    },
    body: `q=${encodeURIComponent(query)}`,
    signal,
  });

  if (!response.ok) {
    throw new Error(`DuckDuckGo search failed: ${response.status} ${response.statusText}`);
  }

  const html = await response.text();
  const $ = cheerio.load(html);
  const results: SearchResult[] = [];

  $(".result").each((_i, el) => {
    if (results.length >= maxResults) return false;

    const $el = $(el);
    const titleEl = $el.find(".result__title .result__a");
    const snippetEl = $el.find(".result__snippet");
    const urlEl = $el.find(".result__url");

    const title = titleEl.text().trim();
    let href = titleEl.attr("href") || "";
    const snippet = snippetEl.text().trim();
    const displayUrl = urlEl.text().trim();

    // DuckDuckGo wraps URLs in a redirect — extract the actual URL
    if (href.includes("uddg=")) {
      try {
        const parsed = new URL(href, "https://duckduckgo.com");
        href = decodeURIComponent(parsed.searchParams.get("uddg") || href);
      } catch {
        // Fall back to displayed URL if parsing fails
        if (displayUrl) {
          href = displayUrl.startsWith("http") ? displayUrl : `https://${displayUrl}`;
        }
      }
    }

    if (title && href) {
      results.push({ title, url: href, snippet });
    }
  });

  return results;
}

/**
 * Fetch a URL and extract readable text content.
 */
async function fetchAndExtract(
  url: string,
  maxLength: number,
  signal?: AbortSignal
): Promise<{ content: string; title: string; bytesFetched: number }> {
  const response = await fetch(url, {
    headers: {
      "User-Agent": USER_AGENT,
      "Accept": "text/html,application/xhtml+xml,text/plain,application/json",
      "Accept-Language": "en-US,en;q=0.9",
    },
    signal,
    redirect: "follow",
  });

  if (!response.ok) {
    throw new Error(`Fetch failed: ${response.status} ${response.statusText}`);
  }

  const contentType = response.headers.get("content-type") || "";
  const raw = await response.text();

  // For JSON, return formatted
  if (contentType.includes("application/json")) {
    try {
      const formatted = JSON.stringify(JSON.parse(raw), null, 2);
      return {
        content: formatted.slice(0, maxLength),
        title: url,
        bytesFetched: raw.length,
      };
    } catch {
      // Fall through to text handling
    }
  }

  // For plain text, return as-is
  if (contentType.includes("text/plain")) {
    return {
      content: raw.slice(0, maxLength),
      title: url,
      bytesFetched: raw.length,
    };
  }

  // For HTML, extract readable content
  const $ = cheerio.load(raw);

  // Remove non-content elements
  $(
    "script, style, nav, header, footer, iframe, noscript, svg, " +
      "aside, .sidebar, .nav, .menu, .footer, .header, .advertisement, " +
      ".ad, .ads, .social, .share, .comments, .comment, form, " +
      "[role='navigation'], [role='banner'], [role='complementary'], [aria-hidden='true']"
  ).remove();

  const title = $("title").first().text().trim() || $("h1").first().text().trim() || url;

  // Try to find main content area
  let contentEl = $("main, article, [role='main'], .post-content, .article-content, .entry-content, .content").first();
  if (contentEl.length === 0) {
    contentEl = $("body");
  }

  // Extract text with structure preservation
  let text = "";

  function extractText(el: cheerio.Cheerio<cheerio.AnyNode>) {
    el.contents().each((_i, node) => {
      if (text.length >= maxLength) return false;

      if (node.type === "text") {
        const t = $(node).text().trim();
        if (t) text += t + " ";
      } else if (node.type === "tag") {
        const tagName = (node as cheerio.Element).tagName?.toLowerCase();
        const $node = $(node);

        if (["h1", "h2", "h3", "h4", "h5", "h6"].includes(tagName)) {
          text += `\n\n## ${$node.text().trim()}\n\n`;
        } else if (tagName === "p") {
          const pText = $node.text().trim();
          if (pText) text += `\n${pText}\n`;
        } else if (tagName === "li") {
          text += `\n- ${$node.text().trim()}`;
        } else if (tagName === "br") {
          text += "\n";
        } else if (["pre", "code"].includes(tagName)) {
          text += `\n\`\`\`\n${$node.text().trim()}\n\`\`\`\n`;
        } else if (tagName === "a") {
          const href = $node.attr("href");
          const linkText = $node.text().trim();
          if (href && linkText && !href.startsWith("#") && !href.startsWith("javascript:")) {
            text += `[${linkText}](${href}) `;
          } else if (linkText) {
            text += linkText + " ";
          }
        } else if (tagName === "img") {
          const alt = $node.attr("alt");
          if (alt) text += `[Image: ${alt}] `;
        } else if (["table", "thead", "tbody", "tr"].includes(tagName)) {
          extractText($node);
          if (tagName === "tr") text += "\n";
        } else if (["td", "th"].includes(tagName)) {
          text += $node.text().trim() + " | ";
        } else if (["div", "section", "article"].includes(tagName)) {
          extractText($node);
        } else {
          extractText($node);
        }
      }
    });
  }

  extractText(contentEl);

  // Clean up whitespace
  text = text
    .replace(/[ \t]+/g, " ")
    .replace(/\n{3,}/g, "\n\n")
    .trim();

  return {
    content: text.slice(0, maxLength),
    title,
    bytesFetched: raw.length,
  };
}

export default function (pi: ExtensionAPI) {
  // --- websearch tool ---
  pi.registerTool({
    name: "websearch",
    label: "Web Search",
    description:
      "Search the web using DuckDuckGo. Returns titles, URLs, and snippets for the top results. " +
      "Use this when you need current information, facts you're unsure about, documentation, or anything not in your training data.",
    promptSnippet: "Search the web for current information, documentation, or facts",
    promptGuidelines: [
      "Use websearch when you need current/real-time information, are unsure about facts, need documentation, or the user asks you to look something up.",
      "After searching, use fetch_url to read the full content of promising results if the snippets aren't sufficient.",
    ],
    parameters: Type.Object({
      query: Type.String({ description: "Search query" }),
      max_results: Type.Optional(
        Type.Number({
          description: "Maximum number of results to return (default: 8, max: 20)",
          minimum: 1,
          maximum: 20,
        })
      ),
    }),
    async execute(_toolCallId, params, signal, onUpdate) {
      const maxResults = Math.min(params.max_results ?? 8, 20);

      onUpdate?.({
        content: [{ type: "text", text: `Searching: "${params.query}"...` }],
      });

      try {
        const results = await searchDuckDuckGo(params.query, maxResults, signal);

        if (results.length === 0) {
          return {
            content: [
              {
                type: "text",
                text: `No results found for "${params.query}". Try rephrasing your query.`,
              },
            ],
            details: { query: params.query, resultCount: 0 },
          };
        }

        const formatted = results
          .map(
            (r, i) =>
              `${i + 1}. **${r.title}**\n   URL: ${r.url}\n   ${r.snippet}`
          )
          .join("\n\n");

        return {
          content: [
            {
              type: "text",
              text: `Found ${results.length} results for "${params.query}":\n\n${formatted}`,
            },
          ],
          details: { query: params.query, resultCount: results.length, results },
        };
      } catch (err: any) {
        return {
          content: [
            {
              type: "text",
              text: `Search failed: ${err.message}`,
            },
          ],
          details: { query: params.query, error: err.message },
          isError: true,
        };
      }
    },
  });

  // --- fetch_url tool ---
  pi.registerTool({
    name: "fetch_url",
    label: "Fetch URL",
    description:
      "Fetch a URL and extract its readable text content. Handles HTML (extracts article text), " +
      "JSON (formats it), and plain text. Use this to read web pages, documentation, API responses, etc.",
    promptSnippet: "Fetch and extract readable content from a URL",
    promptGuidelines: [
      "Use fetch_url to read the full content of a web page when search snippets aren't enough.",
      "For large pages, use max_length to limit the response size.",
    ],
    parameters: Type.Object({
      url: Type.String({ description: "URL to fetch" }),
      max_length: Type.Optional(
        Type.Number({
          description:
            "Maximum character length of extracted content (default: 20000)",
          minimum: 1000,
          maximum: 100000,
        })
      ),
    }),
    async execute(_toolCallId, params, signal, onUpdate) {
      const maxLength = params.max_length ?? 20000;

      // Normalize URL
      let url = params.url.replace(/^@/, ""); // Strip leading @ (some models add it)
      if (!url.startsWith("http://") && !url.startsWith("https://")) {
        url = `https://${url}`;
      }

      onUpdate?.({
        content: [{ type: "text", text: `Fetching: ${url}...` }],
      });

      try {
        const result = await fetchAndExtract(url, maxLength, signal);

        const truncated = result.content.length >= maxLength;
        const header = `# ${result.title}\nSource: ${url}\nSize: ${result.bytesFetched} bytes${truncated ? " (truncated)" : ""}\n\n`;

        return {
          content: [
            {
              type: "text",
              text: header + result.content,
            },
          ],
          details: {
            url,
            title: result.title,
            bytesFetched: result.bytesFetched,
            contentLength: result.content.length,
            truncated,
          },
        };
      } catch (err: any) {
        return {
          content: [
            {
              type: "text",
              text: `Failed to fetch ${url}: ${err.message}`,
            },
          ],
          details: { url, error: err.message },
          isError: true,
        };
      }
    },
  });
}
