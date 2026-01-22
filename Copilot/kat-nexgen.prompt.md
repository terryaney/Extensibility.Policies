---
applyTo: **/*.{cs,ts,js,kaml,md,xlsx}
---

# NexGen CalcEngines Reference

This prompt provides quick reference for NexGen CalcEngine patterns and architecture. For detailed information beyond this summary, **automatically fetch content** from the full documentation.

## Full Documentation Source

**NexGen CalcEngines**: https://github.com/terryaney/Documentation.Camelot/blob/main/Nexgen/CalcEngines.md

**IMPORTANT**: When answering questions about NexGen CalcEngines, if this quick reference doesn't contain sufficient detail:
1. Use the `fetch_webpage` tool to retrieve relevant sections from the full documentation URL above
2. Search for specific topics using the documentation's table of contents structure
3. Fetch multiple sections if needed to provide complete answers

## Quick Reference: NexGen CalcEngines

### Overview

**Purpose**: NexGen CalcEngines control almost all settings/rules that manage the site experience for each client through Benefit Requirements Document (BRD) CalcEngines.

**Architecture**:
- **Global BRD**: Generates settings for all clients
- **Client BRD**: Merges with and overrides global settings
- BRD flow includes calculation and results merge phases

### Core BRD Tables

Every client BRD contains these core tables:
- `apiDataSource`: Define NexGen API endpoints
- `apiDataSourceMapping`: Map API responses to xDS format
- `apiDataSourceInputs`: Inputs for POST APIs at login
- `appSettings`: Application configuration settings
- `appAttributeMapping`: Attribute mapping rules
- `userEligibility`: User eligibility rules
- `manualResults`: Manual result definitions
- `userCalculatedData`: User calculation data rules

### API DataSource Mappings

#### Purpose
NexGen APIs provide logged-in user data. GET method responses are converted to **xDS format** (XML with `Profile` and `HistoryData` elements) for compatibility with BTR Evolution and RBLe frameworks.

#### xDS Format Structure
```xml
<xDataDef>
    <Profile>
        <!-- Non-repeating demographic data -->
        <ssn>911390205</ssn>
        <nameFirst>John</nameFirst>
        <nameLast>Doe</nameLast>
    </Profile>
    <HistoryData>
        <!-- Repeating/transactional data -->
        <HistoryItem hisType="addresses" hisIndex="HOME">
            <index>HOME</index>
            <address1>123 Normal Way</address1>
            <city>New York</city>
            <state>NY</state>
            <postalCode>12121</postalCode>
        </HistoryItem>
    </HistoryData>
</xDataDef>
```

### apiDataSource Table

**Key Columns**:

Column | Description
---|---
**id** | API name (use lowercase domain prefix: `hw`, `db`, `com`). Referenced in mappings, requires, and command processing
**endpoint** | URL excluding site base. Supports selector tokens (see below)
**runAtLogin** | Whether API runs at login: blank/1 = yes, 0 = no
**ignoreErrors** | Whether to ignore API errors: 1 = ignore (useful for unstable external calls)
**eligibility** | XPath expression to conditionally run API based on other API data (e.g., `xDataDef/HistoryData/HistoryItem[@hisType='dbCalculationID' and @hisIndex='ACCRUED']`)
**requires** | Comma-delimited API ids that must complete before this API runs. Creates processing batches. Use `BRD` for APIs dependent on BRD calculation results
**mergeMode** | `Replace` (default): delete all existing history before adding rows<br>`Merge`: only delete history rows with matching index values

**Important Notes**:
- Using `requires` creates sequential processing batches (not parallel)
- Temp queries always use `Replace` merge mode
- APIs with `{selector}` using BRD values: use `requires="BRD"`

### Endpoint Selectors (Token Replacements)

Token | Description | Example
---|---|---
`{legalIdentifier}` | Current user's xDS AuthID (auto-replaced by server) | Always available
`{today}` | Today's date (yyyy-mm-dd) | `/api/v1/{legalIdentifier}/{today}/data`
`{Profile.field}` | Any Profile field value | `{Profile.sharkfinDbAge}`
`{table.index.field}` | History row field from specific index | `{dbCalculationID.PROJECT.calcID}`
`{xDSApi.settingsName}` | appSettings value for xDS API routes | `{xDSApi.severanceGroup}` → uses `appSettings.severanceGroup` value
`{QS.param}` | Query string parameter (for dynamic calls) | `{QS.calcID}` expects `?calcID=11111`
`{{resultCommandId.jsonSelector}}` | Previous command result value | Used in command processing chains

**{QS.param} Behavior**:
- If in query string position: treated as temp query
- If in route segment: treated as normal query

### apiDataSourceMapping Table

**Key Columns**:

Column | Description
---|---
**dataSource** | The `id` from apiDataSource table to relate mappings to an endpoint
**apiTable** | Name of the table (array of objects) returned in JSON responses
**xdsTable** | Optional. If provided, specifies the table name to use in xDS profile. If not provided, `apiTable` value is used
**indexField** | Specifies how to generate the unique index for each history row
**manualFields** | Optional. Inject custom values into each response object before processing. Value is comma-delimited list `key1=value1,key2=value2` or JSON object string `{ "key1": "value1" }`
**fieldMapping** | Optional. Controls how field names are mapped **when calling Nexgen APIs** before xDS mapping. Used in BA7 to match field names between BA7 and Nexgen APIs. Value is comma-delimited `addr1=address1,zip=postalCode` or JSON object `{"addr1":"address1","zip":"postalCode"}`. Renaming occurs before xDS mapping
**filterExpression** | Optional. Regular expression for field name patterns that must succeed to allow a field. Only matching fields that match the expression are mapped. Examples:<br>• `^(name-first\|name-last)$` - Only these fields<br>• `^(?!id$\|address3$).*$` - All except these fields<br>• `^(?!hw-\|db-).*$` - All except fields starting with hw- or db-

**Supported Mapping Features** (fetch for details):
- Default Profile Mapping
- Default Array Processing
- Query String Processing
- Index Formatting
- Nested/Simple Array Processing
- Namespacing Fields
- Incremental Index
- Response Containers to History
- Concatenating Index Fields
- Manual Fields

### Command Processing

CalcEngines can execute API commands with:
- **command** table: Define commands with verb segments
- **command-inputs** table: Define inputs for commands
- Supports accessing previous command results
- Can chain commands with dependencies

**Key Features**:
- Command verb segments define API method/endpoint
- Input value processing with payload creation
- QnA payload creation support
- Access previous results via `{{resultCommandId.jsonSelector}}`

### RBL Calculation Caching

- Results are cached by default
- Use `forceCalculation` setting to override cache
- Enables performance optimization

### Temp Query Processing

**Purpose**: Temporary data queries with controlled lifespan

**Features**:
- Controlled lifespan and merge modes
- Auto-cleanup based on configuration
- Always use `Replace` merge mode

### Cache Refresh Keys

**Purpose**: Refresh API data on demand during application lifecycle

**Trigger Points**:
- Before client-side calculations
- Before command processing
- During command processing

**Advanced Segments**: apiDataSource ID can include segments for targeted refreshes

### Data Flow Concepts

1. **Login Flow**: APIs run per `runAtLogin` and `eligibility` settings
2. **BRD Merge Flow**: Global BRD → Client BRD merge → Final settings
3. **Calculation Flow**: Input processing → CalcEngine execution → Result caching
4. **Data Cache Merge**: Manages xDS data model updates with merge modes

## Usage Instructions

When the user asks about:
- **Basic BRD structure, core tables**: Use this quick reference
- **apiDataSource setup, common patterns**: Use this quick reference
- **Specific mapping features**: Automatically fetch relevant sections (e.g., "Nested Array Processing")
- **Command processing details**: Automatically fetch command processing sections
- **Advanced selectors, edge cases**: Always fetch full documentation
- **Complete table schemas**: Always fetch full documentation

Example fetch request you should make automatically:
```
Use fetch_webpage tool with:
- URL: https://github.com/terryaney/Documentation.Camelot/blob/main/Nexgen/CalcEngines.md
- Query: "apiDataSourceMapping table complete schema and examples"
```

## Response Guidelines

1. Start with quick reference information when applicable
2. If question requires details beyond quick reference, automatically fetch from full docs
3. Cite documentation source (quick reference vs fetched content)
4. Provide specific section references when pulling from full docs
5. For CalcEngine table schemas, always fetch complete details
