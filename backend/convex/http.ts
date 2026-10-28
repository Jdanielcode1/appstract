import { httpRouter } from "convex/server";
import { internal } from "./_generated/api";
import { httpAction, type ActionCtx } from "./_generated/server";
import { buildBatch, newestTimestamp, parsePayload, verifySignature, type RawEvent } from "./lib/events";

/** Reject batches whose newest event is older than this (replay protection). */
const MAX_BATCH_AGE_MS = 10 * 60_000;

const http = httpRouter();

/**
 * Receives a webhook log stream created by the iOS app ("Enable monitoring"). The deployment
 * name in the path selects the HMAC secret registered via `streams.register`.
 */
http.route({
  pathPrefix: "/logs/",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const deploymentName = decodeURIComponent(new URL(request.url).pathname.slice("/logs/".length));
    if (!deploymentName) return new Response("Not found", { status: 404 });

    // Convex sends a verification event the moment a stream is created, before the app has
    // registered its secret. Any non-2xx marks the stream permanently failed, so acknowledge
    // and drop events for deployments we don't know (yet). Nothing is stored for them.
    const cached = secretCache.get(deploymentName);
    const fresh = cached && cached.at > Date.now() - SECRET_CACHE_MS ? cached.secret : null;
    const secret = fresh ?? (await loadSecret(ctx, deploymentName));
    if (!secret) return new Response("Ignored: unknown deployment", { status: 200 });

    // A stream may only report on its own deployment. A cached secret can be stale after the app
    // recreates the stream ("Repair"); recheck once before rejecting, since a 401 fails the stream.
    const accept = (event: RawEvent) => event.convex?.deployment_name === deploymentName;
    return ingest(ctx, request, fresh ? [secret, () => loadSecret(ctx, deploymentName)] : [secret], accept);
  }),
});

/**
 * Secrets by deployment, kept while this isolate stays warm so most batches skip a query (each
 * `runQuery` is a billed function call). Only ever a cache: misses and mismatches read the table.
 */
const secretCache = new Map<string, { secret: string; at: number }>();
const SECRET_CACHE_MS = 5 * 60_000;

async function loadSecret(ctx: ActionCtx, deploymentName: string): Promise<string | null> {
  const secret = await ctx.runQuery(internal.streams.getSecret, { deploymentName });
  if (secret) secretCache.set(deploymentName, { secret, at: Date.now() });
  else secretCache.delete(deploymentName);
  return secret;
}

/**
 * Manual setup: a log stream configured in the Convex dashboard, verified with the
 * WEBHOOK_SECRET env var. Accepts events from any deployment using that secret.
 */
http.route({
  path: "/logs",
  method: "POST",
  handler: httpAction(async (ctx, request) => {
    const secret = process.env.WEBHOOK_SECRET;
    if (!secret) return new Response("Server not configured", { status: 500 });
    return ingest(ctx, request, [secret], () => true);
  }),
});

/** `secret`: the secret to try, optionally with a way to reload it if the signature doesn't match. */
async function ingest(
  ctx: ActionCtx,
  request: Request,
  [secret, reload]: [string, (() => Promise<string | null>)?],
  accept: (event: RawEvent) => boolean,
): Promise<Response> {
  const body = await request.arrayBuffer();
  const signature = request.headers.get("x-webhook-signature");
  if (!(await verifySignature(secret, body, signature))) {
    const reloaded = reload && (await reload());
    if (!reloaded) return new Response(reload ? "Ignored: unknown deployment" : "Unauthorized", { status: reload ? 200 : 401 });
    if (reloaded === secret || !(await verifySignature(reloaded, body, signature))) {
      return new Response("Unauthorized", { status: 401 });
    }
  }

  let events: RawEvent[];
  try {
    events = parsePayload(new TextDecoder().decode(body)).filter(accept);
  } catch {
    return new Response("Invalid payload", { status: 400 });
  }
  if (events.length === 0) return new Response("OK", { status: 200 });

  if (newestTimestamp(events) < Date.now() - MAX_BATCH_AGE_MS) {
    return new Response("Request expired", { status: 403 });
  }

  await ctx.runMutation(internal.ingest.ingestBatch, buildBatch(events));
  return new Response("OK", { status: 200 });
}

export default http;
