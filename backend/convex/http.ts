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
    const secret = await ctx.runQuery(internal.streams.getSecret, { deploymentName });
    if (!secret) return new Response("Ignored: unknown deployment", { status: 200 });

    // A stream may only report on its own deployment.
    return ingest(ctx, request, secret, (event) => event.convex?.deployment_name === deploymentName);
  }),
});

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
    return ingest(ctx, request, secret, () => true);
  }),
});

async function ingest(
  ctx: ActionCtx,
  request: Request,
  secret: string,
  accept: (event: RawEvent) => boolean,
): Promise<Response> {
  const body = await request.arrayBuffer();
  if (!(await verifySignature(secret, body, request.headers.get("x-webhook-signature")))) {
    return new Response("Unauthorized", { status: 401 });
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
