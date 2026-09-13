import { type Env, Stack } from "@skylabs-digital/cac";
import * as docs from "@skylabs-digital/docs-cac";

/**
 * The section this repo announces on docs.skylabs.digital
 * (skylabs/docs/standards/docs-publishing.md §5). Separate from cac/stack.ts:
 * it authenticates with GitHub identity, not with an idachu key.
 */
export default (env: Env) => {
  const stack = new Stack("workflows", env);
  new docs.Section(stack, {
    slug: "workflows",
    name: "CI/CD workflows",
    group: "platform",
    icon: "🔁",
    description: "The reusable release, security and docs pipelines every repo calls.",
    order: 4,
    repo: "skylabs-digital/.github",
  });
  return stack;
};
