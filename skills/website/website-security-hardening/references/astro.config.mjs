import { defineConfig } from 'astro/config';
import tailwindcss from '@tailwindcss/vite';
import sitemap from "@astrojs/sitemap";
import mdx from "@astrojs/mdx";
import node from "@astrojs/node";

// Shiki's css-variables theme writes colours as inline style attributes,
// which a CSP with style-src 'self' blocks. Swap each known declaration for
// a class defined in src/styles/code-tokens.css. Anything unrecognised is
// left as a style attribute, so it shows up in a CSP crawl.
const STYLE_TO_CLASS = [
  [/^color:var\(--astro-code-([a-z-]+)\)$/, (m) => `ac-fg-${m[1]}`],
  [/^background-color:var\(--astro-code-([a-z-]+)\)$/, (m) => `ac-bg-${m[1]}`],
  [/^overflow-x:auto$/, () => "ac-overflow"],
  [/^font-style:italic$/, () => "ac-italic"],
  [/^font-weight:bold$/, () => "ac-bold"],
  [/^text-decoration:underline$/, () => "ac-underline"],
];

function styleToClass(node) {
  const style = node.properties?.style;
  if (typeof style !== "string") return;
  const kept = [];
  for (const decl of style.split(";").map((d) => d.replace(/\s+/g, "")).filter(Boolean)) {
    const rule = STYLE_TO_CLASS.find(([re]) => re.test(decl));
    if (rule) this.addClassToHast(node, rule[1](decl.match(rule[0])));
    else kept.push(decl);
  }
  if (kept.length) node.properties.style = kept.join(";");
  else delete node.properties.style;
}

const shikiStyleToClass = { name: "style-to-class", pre: styleToClass, span: styleToClass };

export default defineConfig({
  adapter: node({ mode: 'standalone' }),

  // Emit every script and stylesheet as a file, never inline, so the
  // Content-Security-Policy needs no 'unsafe-inline' or hashes.
  build: {
    inlineStylesheets: 'never',
  },

  markdown: {
    drafts: true,
    shikiConfig: {
      theme: "css-variables",
      transformers: [shikiStyleToClass],
    }
  },
  vite: {
    plugins: [tailwindcss()],
    build: {
      assetsInlineLimit: 0,
    },
  },
  shikiConfig: {
    wrap: true,
    skipInline: false,
    drafts: true
  },
  site: 'https://colindomoney.com',
  integrations: [sitemap(), mdx()]
});