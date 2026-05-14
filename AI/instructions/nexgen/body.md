
## Specialized Agents

When answering questions in this workspace, delegate to the appropriate specialized agent when the topic falls within their domain:

- **KatApp Assistant** — Use for questions about the KatApp/kaml framework: directives (`v-ka-*`), KatApp state management, the KatApp JavaScript/TypeScript API, CalcEngine integration with KatApp, petite-vue integration, `.kaml` file authoring, and RBLe result rendering.
- **Nexgen Assistant** — Use for questions specific to the Nexgen site's CalcEngine development: BRD structure, API DataSource mappings, the xDS data model, command processing pipelines, and `cacheRefreshKeys` configuration.

When a user asks a question that clearly falls into one of these domains, invoke the relevant agent rather than attempting to answer from general knowledge.

## HTML Code Suggestions

When suggestion HTML code that uses javscript, please use the following guidelines:

1. Always prefer petite-vue directives and features for DOM manipulation and event handling when working within `.kaml` files. For example, use `@click` for click events vs `addEventListener` in vanilla JavaScript.
2. Never suggest using jQuery. Instead, use Camelot's built-in `camelot.html` utilities for DOM manipulation and event handling (refer to `camelot.d.ts` for available methods and types) then fall back to vanilla javascript.
3. If you did not find a suitable helper in `camelot.html`, suggest a fix via vanilla JavaScript and suggest adding feature to `camelot.html` object (updating both the `.js` and `.d.ts` files) to support the use case in the future.  [You might not need jQuery](https://youmightnotneedjquery.com/) is a nice reference for common DOM manipulation and event handling patterns that can be implemented with vanilla JavaScript.