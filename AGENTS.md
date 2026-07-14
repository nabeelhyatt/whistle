<!-- BEGIN:nextjs-agent-rules -->
# This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` before writing any code. Heed deprecation notices.
<!-- END:nextjs-agent-rules -->

## Version Bumping

Bump `MARKETING_VERSION` in `apps/macos/project.yml` by one patch increment (e.g. `1.0.0` → `1.0.1`) with every PR that changes app behavior. Docs-only or CI-only changes don't need a bump. Commit the bump in the same PR, not as a separate PR.

## Knowledge Store

`docs/solutions/` — documented solutions to past problems (runtime errors, best practices, workflow patterns), organized by category with YAML frontmatter (`module`, `tags`, `problem_type`). Relevant when implementing or debugging in documented areas.

`CONCEPTS.md` — shared domain vocabulary (entities, named processes, status concepts) — relevant when orienting to the codebase or discussing domain concepts.
