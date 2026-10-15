/* eslint-disable */
/**
 * Generated `api` utility.
 *
 * THIS CODE IS AUTOMATICALLY GENERATED.
 *
 * To regenerate, run `npx convex dev`.
 * @module
 */

import type * as ai from "../ai.js";
import type * as alerts from "../alerts.js";
import type * as catalog from "../catalog.js";
import type * as chat from "../chat.js";
import type * as cleanup from "../cleanup.js";
import type * as crons from "../crons.js";
import type * as dashboard from "../dashboard.js";
import type * as http from "../http.js";
import type * as ingest from "../ingest.js";
import type * as lib_ai from "../lib/ai.js";
import type * as lib_alerts from "../lib/alerts.js";
import type * as lib_auth from "../lib/auth.js";
import type * as lib_catalog from "../lib/catalog.js";
import type * as lib_chat from "../lib/chat.js";
import type * as lib_config from "../lib/config.js";
import type * as lib_events from "../lib/events.js";
import type * as lib_gateway from "../lib/gateway.js";
import type * as lib_prompts from "../lib/prompts.js";
import type * as push from "../push.js";
import type * as rollups from "../rollups.js";
import type * as streams from "../streams.js";

import type {
  ApiFromModules,
  FilterApi,
  FunctionReference,
} from "convex/server";

declare const fullApi: ApiFromModules<{
  ai: typeof ai;
  alerts: typeof alerts;
  catalog: typeof catalog;
  chat: typeof chat;
  cleanup: typeof cleanup;
  crons: typeof crons;
  dashboard: typeof dashboard;
  http: typeof http;
  ingest: typeof ingest;
  "lib/ai": typeof lib_ai;
  "lib/alerts": typeof lib_alerts;
  "lib/auth": typeof lib_auth;
  "lib/catalog": typeof lib_catalog;
  "lib/chat": typeof lib_chat;
  "lib/config": typeof lib_config;
  "lib/events": typeof lib_events;
  "lib/gateway": typeof lib_gateway;
  "lib/prompts": typeof lib_prompts;
  push: typeof push;
  rollups: typeof rollups;
  streams: typeof streams;
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
