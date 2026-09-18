# Toolkit integration and read-only runtime diagnostics

AICLI 0.3.17 adds `aicli diagnose --json [--bridge-registry <path>]`.
The command reads module/version/hash and existing Desktop configuration, and can
verify one registered seven-file release. It never initializes user directories,
reads credentials, invokes models, or changes installation/configuration.
Verified files do not prove a currently loaded process or an end-to-end task.
Use the intended user's normal session; service-account observations are separate.

Codex machine `run` accepts `--control-file <absolute-path>` for an immutable
`aicli.run-control.v1` metadata receipt. The destination parent must already exist,
reparse paths and replacement are rejected, and the run/profile/model/workspace
binding is written before native execution. Task text, credentials and results
are never stored in this receipt. `--dry-run` performs no receipt/runtime writes.
Other engines reject this option. Clients feature-detect `runControlReceipt` in
`version --json`; legacy clients and ordinary run commands remain supported.

Toolkit uses the same validated entry and this exact run ID to request the
existing `run abort`. Request acknowledgement is not terminal cleanup. Process
termination and broker-session release remain independently verified. Explicit
cancellation before runtime identity is observed preserves cleanup evidence with
`modelIdentityEvidence=not_observed_cancelled`, null actual model/provider, and
no successful model-acceptance claim. Ordinary missing/mismatching runtime identity
continues to fail closed, and cancellation cannot turn an invalid identity into a
valid one. Closed capture error categories expose no arbitrary exception payload.

The Desktop bridge is independently content-addressed and registered by PCConfig.
A normal module update must not rebuild, downgrade, enable or replace that release,
nor activate the frozen Gemini integration. Existing concurrent source work is
not silently included in an installation or public Git commit.

Focused checks: `RuntimeDiagnostics.Tests.ps1`, `RunControlReceipt.Tests.ps1`,
`CaptureAbort.Tests.ps1`, plus machine/recovery/redaction suites and a real isolated
local file task and active-run cancellation through the public GPU broker.

Installer scripts now reject unknown arguments. Use scripts/Install.ps1 -DryRun for a zero-write installation plan, or -WhatIf for PowerShell ShouldProcess preview. A plan does not validate installed runtime behavior.
