/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as admin from "../admin.js";
import type * as captures from "../captures.js";
import type * as conductorClient from "../conductorClient.js";
import type * as defaultTemplate from "../defaultTemplate.js";
import type * as files from "../files.js";
import type * as lib_auth from "../lib/auth.js";
import type * as orgs from "../orgs.js";
import type * as pipeline from "../pipeline.js";
import type * as pipelineInternal from "../pipelineInternal.js";
import type * as projects from "../projects.js";
import type * as promptRenderer from "../promptRenderer.js";
import type * as settings from "../settings.js";
import type * as templates from "../templates.js";
import type * as users from "../users.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  admin: typeof admin;
  captures: typeof captures;
  conductorClient: typeof conductorClient;
  defaultTemplate: typeof defaultTemplate;
  files: typeof files;
  "lib/auth": typeof lib_auth;
  orgs: typeof orgs;
  pipeline: typeof pipeline;
  pipelineInternal: typeof pipelineInternal;
  projects: typeof projects;
  promptRenderer: typeof promptRenderer;
  settings: typeof settings;
  templates: typeof templates;
  users: typeof users;
}>;

/**
 * A utility for referencing Convex functions in your app's public API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = api.myModule.myFunction;
 * ```
 */
export declare const api: FilterApi<
  typeof fullApi,
  FunctionReference<any, "public">
>;

/**
 * A utility for referencing Convex functions in your app's internal API.
 *
 * Usage:
 * ```js
 * const myFunctionReference = internal.myModule.myFunction;
 * ```
 */
export declare const internal: FilterApi<
  typeof fullApi,
  FunctionReference<any, "internal">
>;

export declare const components: {};
