# Repository guidance

Read `docs/ARCHITECTURE.md`, `docs/METRICS.md`, and `docs/COROS_INTEGRATION.md` before changing data behavior.

- Native macOS 14+, Swift 6, SwiftUI, WidgetKit. No third-party dependencies by default.
- `RecoveryCore` must remain independent of SwiftUI, WidgetKit, authentication, and server DTOs.
- Widget reads a validated App Group snapshot. Only the main application writes it.
- Use explicit time zones and calendar arithmetic. Missing data is never zero by default.
- Keep demo data visibly labelled; never silently substitute it for production failures.
- Do not infer COROS response schemas from internal models. Verify official contracts before implementing adapters.
- Do not read personal health data merely to build fixtures. Do not commit credentials or user data.
- Run `./Scripts/test.sh` for core/integration changes (wraps `swift test --disable-xctest` with a CLT macro-path workaround when needed). Build the Xcode app/extension when a full Xcode installation is available; report actual validation limits honestly.
- Update architecture/metric documents with changes in contracts or interpretation.
