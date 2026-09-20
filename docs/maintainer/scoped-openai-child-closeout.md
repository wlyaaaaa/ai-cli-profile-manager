# Scoped OpenAI child routing: implementation and deployment audit

Under the installed scoped-routing policy, third-party Codex parents have no implicit delegation permission. Applicable user authorization limits model, effort and task scope; ordinary delegation and continuation use `openai_child`, with the existing parent messaging and status/stop interfaces. Managed OpenAI children do not become unrestricted roots.

Release `1d262106259bb6a7` is installed, its seven files match the protected registration, and the persistent desktop startup entry selects it. At closeout an unrelated real desktop task was still active in the previous process, so it was not forcibly stopped. **Installed/selected is not reported as loaded by that old process. A normal safe application restart remains necessary for its cutover.** No new background restart service was created.

The installed bridge and installed permission code passed 20 isolated authorization checks and 63 existing interaction checks. The routing implementation passed 300 Python tests, and the registration-only installer passed five checks. Upstream model responses were synthetic; no new live manufacturer E2E is claimed or required from the user.

The build used the previous verified frozen source plus exact owned changes. Other tasks' worktree edits were excluded and preserved. A machine-local shared Owner-state ACL persistence defect was repaired in its owning configuration project using its existing registered user identity and protected writer. Original grant contents and deadline were unchanged; the existing runtime and three focused checks passed.

Exact effect receipts, retained rollback inputs, deferred process cutover, cleanup and responsibility-release results remain in the existing product acceptance directory for the release. The original design is not another runtime policy, model list or permission store.
