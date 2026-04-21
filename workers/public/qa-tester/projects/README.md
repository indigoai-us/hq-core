# Project-Specific Test Configurations

Store project-specific test configurations here.

## Structure

```
projects/
├── {your-repo}/
│   ├── pages.json       # Page list and config
│   └── custom.spec.ts   # Project-specific tests (optional)
├── {product}-site/
│   └── pages.json
└── README.md
```

## pages.json Schema

```json
{
  "name": "project-name",
  "description": "Project description",
  "baseUrl": "http://localhost:3000",
  "productionUrl": "https://example.com",
  "pages": ["/", "/about", "/pricing"],
  "criticalPaths": ["/", "/pricing"],
  "skipPages": ["/admin"],
  "customTests": ["custom.spec.ts"]
}
```

## Usage

Reference a project config:

```bash
node dist/index.js full-scan --project {your-repo}
node dist/index.js full-scan --project {your-repo} --env production
```

Or use the page list directly:

```bash
node dist/index.js full-scan --url http://localhost:3000 --pages-from projects/{your-repo}/pages.json
```
