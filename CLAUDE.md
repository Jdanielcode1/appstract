# Convex Go (iOS)

Unofficial native iOS dashboard for Convex. Targets and folders keep the `ConvexDashboard` name. See `README.md` for setup.

## Stack

- SwiftUI, MVVM with `@Observable @MainActor` view models (not `ObservableObject`)
- Convex Management + Deployment APIs over `URLSession` + `async/await`
- `backend/`: optional self-hosted Convex project for monitoring, alerts and Ask AI

## Project layout

```
project.yml       — XcodeGen spec; run `xcodegen generate` after adding/removing files (the .xcodeproj is generated)
Config/           — Signing.xcconfig + Local.xcconfig (gitignored: DEVELOPMENT_TEAM, BUNDLE_ID_PREFIX)
ConvexDashboard/  — App/, Models/, Services/, ViewModels/, Views/, Theme/, Resources/
ConvexWidgets/    — WidgetKit extension
backend/          — Convex functions (`convex/`) + tests (`tests/`)
```

## Rules

- **Secrets:** tokens and keys live in the Keychain only, never `UserDefaults`, plists, source or logs.
- **Read-only by default:** the only write calls are pause/unpause, usage limits and log streams. Destructive actions always confirm first.
- **Networking:** all requests go through the API clients in `Services/`; views and view models never build requests.
- **Self-hosted:** each user deploys their own `backend/`. Single-owner auth (`APP_KEY`); every public backend function calls `assertAppKey`. Token-only features must work with no backend configured.
- **Design:** use the `Color.convex*` tokens, `.convexDisplay` / `.convexMono` fonts and the shared components in `Theme/Theme.swift`. Never use the Convex symbol or Apple's logo.
- **Convex code:** read `backend/convex/_generated/ai/guidelines.md` first.

## Commands

```bash
xcodegen generate                      # regenerate the Xcode project
cd backend && npm test                 # backend unit tests
cd backend && npm run typecheck
cd backend && npx convex dev           # run the backend
```
