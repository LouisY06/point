# Working on Point

Start with [the project plan](docs/PROJECT_PLAN.md) and [README](README.md). Claim one workstream with the team, then use a branch such as `feature/ble-transport`, `feature/live-voice`, or `feature/session-map`.

```sh
git switch main
git pull --ff-only
git switch -c feature/your-change
swift test
```

Keep changes focused and open a pull request against `main`. Describe the resulting behavior, how you checked it, and whether it uses simulated or real data. Coordinate changes to the shared transport model and main view model with the team.

- Preserve the credential-free preview while adding real services or hardware.
- Keep provider credentials in an unshared local Xcode scheme. Never commit them, personal signing settings, or environment files.
- Keep the reusable algorithm and feedback logic in `PointCore`; keep UI in `App`.
- Add meaningful regression tests when changing geometry, progression, feedback, or asynchronous cancellation.
- Run `swift test` and build the Point app before requesting review. The Swift package tests are separate from the app scheme's test action, which runs the `PointUITests` VoiceOver audit (`UITests/`) in a simulator.
- Keep every control VoiceOver-readable: label icon-only buttons, hide decorative artwork with `.accessibilityHidden(true)`, mark screen titles with `.isHeader`, and announce status changes that only appear as text. Run the audit when touching `App/` views.
- Edit `project.yml` when changing project configuration; regenerate with XcodeGen and include the resulting shared project changes. Ordinary edits to existing Swift files do not require regeneration.
- Keep speculative artwork and render output local. Only add approved assets that the app actually uses.
- Update the project plan when a planned integration becomes working and verified.

For app validation, open `Point.xcodeproj`, select the Point scheme and an installed iPhone simulator, and build/run. A CLI build can use an available simulator name from `xcrun simctl list devices available`:

```sh
xcodebuild -project Point.xcodeproj -scheme Point \
  -destination 'platform=iOS Simulator,name=YOUR_INSTALLED_SIMULATOR' \
  build CODE_SIGNING_ALLOWED=NO
```

Run the VoiceOver audit the same way with `test` in place of `build`. Each test launches a screen, checks the spoken label of every control, and fails on anything Xcode's accessibility audit reports.
