---
applyTo: **/*.{ts,js,kaml,md}
---

# KatApp Framework Reference

This prompt provides quick reference for the KatApp Framework. For detailed information beyond this summary, **automatically fetch content** from the full documentation.

## Full Documentation Source

**KatApp Framework**: https://github.com/terryaney/Documentation.Camelot/blob/main/KatApp.md

**IMPORTANT**: When answering questions about KatApps, if this quick reference doesn't contain sufficient detail:
1. Use the `fetch_webpage` tool to retrieve relevant sections from the full documentation URL above
2. Search for specific topics using the documentation's table of contents structure
3. Fetch multiple sections if needed to provide complete answers

## Quick Reference: KatApp Framework

### Overview
**Purpose**: Orchestrates RBLe framework and Vue.js (specifically petite-vue) to create dynamic web content driven by CalcEngine results.

**Core Definition**: Dynamic webpage content driven by client-server communication via `fetch` API, using Kaml Views, RBLe Service, and Vue directives.

### Key Terminology

Term | Definition
---|---
**KatApp** | Dynamic webpage content driven by client server communication via `fetch` api, using Kaml Views, RBLe Service, and Vue directives
**Kaml View** | KatApp Markup Language file combining RBL Configuration, HTML, CSS, and JavaScript where HTML supports Vue directives to leverage CalcEngine results
**RBLe Framework** | Rapid Business Logic (evolved) calculation service driven by CalcEngine files containing business logic
**CalcEngine** | Specialized Excel spreadsheet that drives business logic
**RBLe Results** | Calculation results from RBLe Service (stored in KatApp state for use via Vue directives)
**KatApp element** | The HTML element that is target/container for the KatApp (e.g., `<div id="KatApp"></div>`)
**Vue Directive** | Special attributes indicating that content should be processed by Vue and its rendering engine
**Kaml Template Files** | Kaml file containing only templates, CSS, and JavaScript for generating common markup/controls
**Template** | Reusable piece of markup found in Kaml Template file

### Required Libraries

- **petite-vue.js** (Required): [library](https://unpkg.com/petite-vue) to enable Vue processing and internal KatApp functionality
- **bootstrap.js** (Required): Support for [Modals](https://getbootstrap.com/docs/5.3/components/modal/), [Popovers](https://getbootstrap.com/docs/5.3/components/popovers/), and [Tooltips](https://getbootstrap.com/docs/5.3/components/tooltips/)
- **highcharts.js** (Optional): If `v-ka-highchart` directive is used for [Highcharts](https://api.highcharts.com/highcharts/) from CalcEngine results

### Basic Initialization

```javascript
function ready(fn) {
    if (document.readyState !== 'loading') {
        (async () => { await fn(); })();
    } else {
        document.addEventListener('DOMContentLoaded', fn);
    }
}
ready(async () => {
    try {
        await KatApp.createAppAsync('.katapp', { "view": "Nexgen:Channel.Home" });
    }
    catch (ex) {
        console.error({ex});
    }
});
```

### Kaml View Structure

```html
<!-- RBL Configuration (must be first element) -->
<rbl-config templates="Standard_Templates,LAW:Law_Templates">
    <calc-engine key="default" name="LAW_Wealth_CE"></calc-engine>
    <calc-engine key="shared" name="LAW_Shared_CE" result-tabs="RBLResult,RBLHelpers"></calc-engine>
</rbl-config>

<!-- JavaScript (IIFE for scoped code) -->
<script>
(function () {
    /** @type {IKatApp} */
    var application = KatApp.get('{id}');
    
    application.configure((config, rbl, model, inputs, handlers) => { 
        config.model = {
            // Custom model properties
        };
        
        config.options = {
            // Custom options
        };
        
        config.handlers = {
            // Custom event handlers
        };
        
        config.events.initialized = () => {
            // Handle initialization
            console.log(rbl.value("nameFirst"));
        };
    });
})();
</script>

<!-- HTML markup with Vue directives -->
<div v-if="rbl.exists('fieldName')">
    {{ rbl.value('fieldName') }}
</div>
```

### RBL-Config Element

**calc-engine attributes**:
- `key`: Reference identifier when multiple CalcEngines used (first defaults to "default")
- `name`: CalcEngine name (supports Input Token Substitution)
- `input-tab`: Tab name for injecting inputs (default: "RBLInput")
- `result-tabs`: Comma-delimited result tabs to process (default: "RBLResult")
- `configure-ui`: Run during Configure UI Calculation (default: true)
- `enabled`: Whether CalcEngine runs during calculation (default: true, supports token substitution)
- `pipeline`: Optional CalcEngines in calculation pipeline

**Input Token Substitution**: Use `{inputName}` to substitute initialization input values into attributes.

**Attribute Evaluation**: Prefix attribute with `!!` to evaluate as string expression (useful with token substitution).

### Vue Directive Basics

Attribute syntax processed by Vue (content is JavaScript expression evaluated with current scope):

Markup | Description
---|---
`v-*` | Built-in Vue directives (see [petite-vue compatibility](https://github.com/vuejs/petite-vue#vue-compatible))
`v-ka-*` | Custom KatApp directives (see below)
`:attr` | Shorthand for `v-bind` (bind attribute dynamically)
`@event` | Shorthand for `v-on` (attach event listeners)
`{{ }}` | Shorthand for `v-text` (set innerText, use `v-html` for markup)

### Common Vue Directives

- **v-if / v-else-if / v-else**: Conditional rendering (elements added/removed from DOM)
- **v-show**: Toggle visibility via CSS display property
- **v-for**: Loop through arrays/objects
- **v-bind** (`:attr`): Bind attributes dynamically
- **v-on** (`@event`): Attach event listeners
- **v-model**: Two-way data binding
- **v-html**: Render HTML content (XSS warning: sanitize user input)

### Custom KatApp Directives

Key custom directives (fetch full documentation for complete list and usage):
- **v-ka-value**: Bind CalcEngine result values
- **v-ka-table**: Render tables from CalcEngine results
- **v-ka-chart**: Generate charts from CalcEngine data
- **v-ka-highchart**: Build Highcharts from CalcEngine results

### Accessing CalcEngine Results

From Vue directives and JavaScript, use KatApp state methods:

```javascript
// Check if field exists
rbl.exists('fieldName')

// Get field value
rbl.value('fieldName')

// Get number value
rbl.number('fieldName')

// Get boolean value
rbl.boolean('fieldName')

// Specify CalcEngine/Tab when multiple used
rbl.source({ ce: 'shared', tab: 'RBLHelpers' })
rbl.value('fieldName', { ce: 'shared', tab: 'RBLHelpers' })
```

## Usage Instructions

When the user asks about:
- **Basic setup, initialization, configuration**: Use this quick reference
- **Vue directives, common patterns**: Use this quick reference, fetch for advanced examples
- **Specific directive details** (v-ka-*, custom features): Automatically fetch relevant sections
- **State management, API methods, events**: Automatically fetch relevant sections
- **Advanced features, edge cases, detailed examples**: Always fetch full documentation

Example fetch request you should make automatically:
```
Use fetch_webpage tool with:
- URL: https://github.com/terryaney/Documentation.Camelot/blob/main/KatApp.md
- Query: "v-ka-table directive usage and examples"
```

## Response Guidelines

1. Start with quick reference information when applicable
2. If question requires details beyond quick reference, automatically fetch from full docs
3. Cite documentation source (quick reference vs fetched content)
4. Provide specific section references when pulling from full docs
