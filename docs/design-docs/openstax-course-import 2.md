# OpenStax course import operations

OpenStax course imports use durable Oban jobs and may continue after the author closes the
browser. Lesson planning supports two strategies:

- `parallel_v1` is the default for new runs. A database-coordinated sliding window admits up
  to `OPENSTAX_COURSE_IMPORT_MAX_PARALLEL_LESSONS` lessons for one run at a time (default 3,
  bounded to 1 through 8).
- `serial_v1` preserves compatibility for runs created before parallel planning and can be
  selected for new runs with `OPENSTAX_COURSE_IMPORT_PLANNING_STRATEGY=serial_v1`.

AI lesson jobs run on the `course_import_ai` queue. Its per-node concurrency is configured by
`OBAN_QUEUE_SIZE_COURSE_IMPORT_AI` (default 6). Oban queue concurrency is local to each
application node, so a deployment with `N` nodes can make as many as
`N * OBAN_QUEUE_SIZE_COURSE_IMPORT_AI` provider calls across different imports. Operators
must size the queue for the cluster's combined OpenAI rate and spend limits. The per-run
sliding window is database-coordinated and remains bounded across nodes.

Changing the planning strategy or per-run window affects new runs only. Each run persists its
strategy, generation, and parallelism so an in-progress run does not change behavior during a
rollout or rollback. Changing the Oban queue size takes effect when Oban starts and controls all
lesson jobs admitted on that node. The periodic health worker and one unique startup
reconciliation recover missing or exhausted lesson jobs from their persisted lesson states.
