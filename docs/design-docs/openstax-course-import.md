# OpenStax course import operations

## Schema 6 cutover boundary

Every new OpenStax run uses source schema 3, plan schema 6, and the `parallel_v1` lesson
planning strategy. Suitable lessons compile as Advanced schema 6; lessons that do not pass the
deterministic suitability gate compile as Basic schema 5. There is no generated Advanced
fallback page.

This is a new-run cutover, not a legacy-data migration. Existing projects, runs, resources,
media, jobs, and artifacts retain their stored schema versions and contents. Database
constraints remain permissive enough to preserve those rows. Startup reconciliation, periodic
health work, orphan cleanup, new workers, compiler dispatch, and author operations select only
source schema 3 / plan schema 6 runs. They never resume, cancel, rewrite, or delete a legacy
run.

An author who opens a project with an unfinished legacy import sees a read-only unsupported-run
message. The only supported next action is to start a new schema 6 import in a new project. No
legacy purge command or cleanup UI exists.

The enforcement points are `lib/oli/openstax/course_import/run.ex`,
`lib/oli/openstax/course_import.ex`, `lib/oli/openstax/course_import/compiler.ex`, and the
workers under `lib/oli/openstax/course_import/worker/`. The preservation-only migration is
`priv/repo/migrations/20260817120000_preserve_legacy_openstax_runs.exs`.

## Planning lifecycle

OpenStax imports use durable Oban jobs and may continue after the author closes the browser.
AI lesson jobs run on the `course_import_ai` queue. Its per-node concurrency is configured by
`OBAN_QUEUE_SIZE_COURSE_IMPORT_AI` (default 6). Oban queue concurrency is local to each
application node, so a deployment with `N` nodes can make as many as
`N * OBAN_QUEUE_SIZE_COURSE_IMPORT_AI` provider calls across different imports.

The schema 6 database-coordinated sliding window admits up to
`OPENSTAX_COURSE_IMPORT_MAX_PARALLEL_LESSONS` lessons for one run at a time (default 3,
bounded to 1 through 8). Operators must size the queue for the cluster's combined provider rate
and spend limits. The per-run window remains bounded across nodes. Each run persists its
strategy, generation, and parallelism so an in-progress run does not change behavior during a
rollout or rollback.

The Advanced sequence is deterministic extraction and suitability followed by:

1. experience architect;
2. deterministic schema/source validation;
3. independent critic;
4. up to three architect repairs;
5. activity writer;
6. deterministic activity validation;
7. independent activity critic;
8. up to three activity repairs.

Every accepted stage and repair request is checkpointed. Repeated findings produce
`needs_attention`; they never produce a fallback page. An Advanced plan must account for every
source block, contain all required experience roles, estimate 45–75 minutes, reach at least
0.90 critic confidence, have no pending repairs, and carry complete feedback, hint, and
remediation contracts.

Accepted Advanced plans are compiled as a source-grounded learning sequence rather than a
collection of generic pages. Stage introductions cite the source material that motivates the
transition, multi-part source passages can be consolidated into one coherent screen, and
presentation patterns vary deterministically with the content. Each stage can carry
orientation, strategy, worked-example, reflection, and synthesis guidance. Generated
simulation stages map explicitly to their native follow-up and remediation activities so that
the learner-facing sequence remains complete when simulation delivery is unavailable.

Basic schema 5 retains its separate content architect, content critic, question writer, and
question critic. Newly compiled hint-bearing activities always contain a bottom-out hint, while
the authoring UI also treats an absent historical hint safely and creates it on first edit.

## Generated simulation governance

Simulation opportunity planning runs only after an Advanced plan passes its quality gate. It
may return zero to three source-grounded proposals across chemistry, physics, biology,
mathematics, astronomy, and computer science. Basic lessons never invoke it.

The canonical proposal lifecycle is:

`proposed → researching → evidence_review → designing → artifact_review → approved | omitted | failed`

Research rejection returns to `researching`. Starting a new research version supersedes the
approved evidence and any unfinished downstream spec or reviewable artifact. Approved artifact
versions are immutable and cannot be rejected or overwritten. Artifact rejection leaves the
proposal available for a new artifact version. Every author operation checks project access,
schema 6 run ownership, exact record id and content hash, current state, feature flags, and
conflicting work.

Research uses the Responses API `web_search` tool with at most four searches and twelve
retrieved sources. Two to eight sources are proposed for author review, including retained
OpenStax evidence and at least one external primary or authoritative source. Domain filters
allow the reviewed NIST/IUPAC/PubChem, NASA/ESA/NOIRLab, NIH/NCBI/CDC, NIST DLMF/AMS,
ACM/IEEE/RFC Editor, and approved `.edu` sources. Records store URLs, titles, access time,
claim-level paraphrases and citations, provider/model identity, exact provider usage, and
content hashes. They do not store copied webpages.

The author must approve the exact research-set id and hash before spec design. Spec generation
and criticism validate assumptions, units, constants, algorithms, sample cases, CAPI types,
controls, remediation, keyboard behavior, text/table alternatives, reduced motion,
color-independent encoding, and WebGL fallback. Computer-science specs bound steps and item
counts and cannot execute learner-supplied code.

Six production domain references make those requirements executable instead of prompt-only:
ideal-gas relationships, constant-acceleration motion, logistic population growth,
central-difference numerical differentiation, Keplerian orbital motion, and bounded insertion
sort. Each reference defines parameter ranges and defaults, units, equations or algorithms,
learner controls, observations, three computed sample cases, typed CAPI mappings, learner
tasks, misconception correction, native follow-up routing, and accessibility behavior. The
strict schema-1 validator checks those internal mappings while continuing to accept stored
legacy specifications under their original compatibility rules.

The generated source builder receives only the approved spec and research claims, the fixed
file contract, the typed CAPI contract, and the library registry. A model-authored bundle is
limited to 16 files and 500 KB. Torus then assembles system-owned libraries and the trusted CAPI
bridge, with a final limit of 32 files and 4 MB. Generated code cannot provide or replace
reserved files and has zero runtime network access.

The deterministic local builder uses the same approved domain contract: it renders every
parameter control, computes the selected model or bounded algorithm, emits every declared
typed CAPI output, and presents the observations in a keyboard-focusable text/table region.
It is a production fallback and calibration path, not an identity-function canary.

Every generated candidate is recorded as an append-only artifact attempt with source and
content hashes, sanitized validator and critic findings, provider usage, and timestamps.
Failed candidates remain visible in the author workspace next to the approved/reviewable
version. The author review surface presents the structured specification and attempt history,
with raw JSON relegated to an expandable diagnostic view. An author may supply bounded feedback
for a generate or regenerate request; that guidance is preserved with the artifact metadata
and cannot override the approved specification or evidence.

Audited registry ids are defined in
`lib/oli/openstax/course_import/enrichment/library_registry.ex`:

- `chartjs-4.4.0`;
- selected locked D3 modules and their audited transitive runtime dependencies, excluding
  `d3-fetch`;
- `three-0.185.1` when the separate 3D flag is enabled.

Refresh the vendored copies from the exact lockfile versions with:

```bash
mix openstax.vendor_simulation_libraries
```

## Validation and delivery

Build the local validator image before enabling generated simulation work:

```bash
docker build -t torus/openstax-simulation-validator:1 \
  docker/openstax-simulation-validator
```

The Chromium validator has no network namespace or credentials, a read-only root filesystem,
30-second timeout, 512 MB memory, one CPU, bounded processes, seeded randomness, and software
WebGL. It rejects console/page errors, unauthorized requests, CAPI handshake or sample failures,
keyboard/focus failures, serious or critical accessibility findings, desktop/mobile overflow,
reduced-motion failures, and missing no-WebGL fallback. Validation persists sample results,
screenshots, DOM traces, accessibility traces, and sanitized failure records for independent
artifact criticism.

Only an exact validated and author-approved content-addressed artifact can be previewed or
compiled. The Advanced compiler joins the stable proposal id and stage placement to the
approved artifact, trusted iframe security profile, typed CAPI rules, native follow-up, and
deterministic remediation. Disabling delivery or activating the global kill switch removes the
generated reference while preserving the native explanatory/follow-up activity and all
immutable artifact records.

The seeded end-to-end workflow is
`test/scenarios/delivery/generated_simulation_iframe_security.scenario.yaml`. It exercises
retained source data, research approval, spec and bundle generation, isolated validation,
artifact approval, compilation, publication, enrollment, page viewing, delivery metadata, and
the native-content result produced by the global delivery kill switch. The scenario creates
projects, publication state, sections, users, and enrollment through `Oli.Scenarios`; its narrow
OpenStax hook uses production import contexts for prerequisites not yet represented by scenario
directives. It does not use fixtures, factories, or mocks: validation and execution run through
`Oli.Scenarios.execute_file/2` and the production import, authoring, publishing, and delivery
contexts.

## Operational telemetry

`Oli.OpenStax.CourseImport.Telemetry` emits two generated-simulation events:

- `[:oli, :openstax, :course_import, :simulation_stage]` for opportunity, research,
  specification, artifact, and delivery stages;
- `[:oli, :openstax, :course_import, :simulation_author_decision]` for evidence and artifact
  approvals, rejections, omissions, and cancellations.

Stage measurements include candidate counts, elapsed milliseconds, exact provider input and
output tokens, web-search and source counts, repairs, validation findings, artifact bytes, and
CAPI sample totals/failures. Bounded metadata includes stage/outcome, model/provider,
rendering mode, registered library ids, record version, and scoped ids. Prompts, source text,
claims, URLs, generated code, and free-form author reasons are intentionally excluded. The same
duration and usage details remain persisted in opportunity generation metadata, research
validation payloads, specification generation history, and artifact generation metadata.

## Feature gates

These gates are independent and default off outside development:

- `openstax_advanced_pages_v6`;
- `openstax_generated_enrichment`;
- `openstax_simulation_web_research`;
- `openstax_simulation_3d_generation`;
- `openstax_generated_simulation_delivery`.

`OPENSTAX_GENERATED_SIMULATION_KILL_SWITCH=true` is the global delivery kill switch. Generation
and delivery are intentionally separate trust decisions: disabling generation stops new work;
disabling delivery or activating the kill switch invokes the native fallback without deleting
research, specs, or artifacts.

Provider configuration reuses `OPENAI_API_KEY`. Opportunity and spec design default to
GPT-5.6 Terra; independent criticism and untrusted bundle generation default to GPT-5.6 Sol.
Model overrides are configured in `config/runtime.exs`.

## Pilot acceptance

Before enabling the pilot, run migrations, compilation, formatting, focused OpenStax suites,
frontend type checks and hint tests, the scenario schema suite, and the generated-simulation
workflow scenario. Record repository-wide failures that predate this work separately; do not
describe a focused pass as a full-suite pass.

The pilot corpus covers gas relationships, motion or circuits, population or enzyme behavior,
calculus or probability, orbital or stellar interpretation, and sorting or data-structure
behavior. `test/support/openstax_simulation_pilot_corpus.ex` provides twelve distinct,
network-independent calibration snapshots—two per domain—with canonical OpenStax provenance.
It also defines one deterministic opportunity, approved-evidence, specification, CAPI, and
fallback contract per pilot domain, including the astronomy 3D/Three.js and no-WebGL contract
and bounded computer-science state transitions. These snapshots are concise paraphrases for
repeatable routing and governance tests; live upstream extraction remains a separate acceptance
step.

Every domain still requires a real provider-backed, author-approved research and artifact
version, deterministic browser sample success, complete source coverage, and manual
instructional and visual signoff before staging delivery is enabled.
