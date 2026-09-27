# ADR 2: migrations run as a container inside the API task

## Status
Accepted

## Context
hookrelay's schema is managed by Prisma, and `prisma migrate deploy`
must run before a new version of the API serves traffic. There are three
common places to run it on ECS:

1. A pipeline step that starts a one-off `RunTask` before updating the
   services. This needs the pipeline to hold AWS credentials that can run
   tasks in the production network, and deploying by hand with
   `terraform apply` skips it.
2. A separate ECS service or scheduled task. It isn't ordered against the
   API rollout at all.
3. A non-essential container in the API task definition that the API
   container depends on with `condition = SUCCESS`.

## Decision
Option 3. Every API task runs `migrate` first; the API container starts
only once migrate has exited 0. If a migration fails, the task never
becomes healthy, the deployment circuit breaker rolls back to the
previous task definition, and the old version keeps serving.

## Consequences
- The schema can't lag the code, whoever deploys and however.
- **Concurrent starts race, deliberately.** Two or more API tasks start
  together on every deployment. `prisma migrate deploy` takes a Postgres
  advisory lock before applying anything, so one task applies the
  pending migrations and the others wait, then find nothing left to do.
  Prisma gives up waiting for the lock after about 10 seconds. So during a
  migration longer than that, the waiting tasks' migrate containers fail,
  those tasks stop, and ECS starts replacements that find the work done.
  That's noisy but converges. This relies on Prisma's documented locking;
  this portfolio's grainops runs the same pattern (an init container per
  pod under an advisory lock) end to end in CI.
- **Migrations must be backward compatible with the running version**,
  because during a rolling deployment the old tasks keep serving on the
  migrated schema. That's the usual expand/contract discipline, and it's
  the application's job, not something this module can enforce.
- The worker doesn't migrate. It never starts a schema change, and a
  worker running before the first API task has migrated fails its
  queries and is restarted by ECS until the schema exists.
- `health_check_grace_period_seconds` is 120, covering migration time. A
  migration that runs longer than that should be run as option 1
  instead, as a one-off.
