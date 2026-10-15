import * as jose from "jose";
import { v } from "convex/values";
import { internal } from "./_generated/api";
import { internalAction } from "./_generated/server";

/**
 * Apple Push Notification delivery. Configure with env vars:
 * - APNS_KEY_P8: base64 of the .p8 auth key file (`base64 -i AuthKey_XXXX.p8`)
 * - APNS_KEY_ID, APNS_TEAM_ID: from the Apple Developer portal
 * - APNS_BUNDLE_ID (optional): the iOS app's bundle id, default com.dcantu.convexdashboard
 * An APNs auth key is team-wide, so an existing key used by your other apps works here too.
 */

const DEFAULT_BUNDLE_ID = "com.dcantu.convexdashboard";

// APNs rejects provider tokens regenerated more than once per 20 min, and a token is valid for
// 1h, so sign once and reuse it. Module-level cache is shared by actions in the same process.
const PROVIDER_TOKEN_TTL_MS = 50 * 60_000;
let cachedToken: { token: string; createdAt: number } | null = null;

async function providerToken(keyBase64: string, keyId: string, teamId: string): Promise<string> {
  if (cachedToken && Date.now() - cachedToken.createdAt < PROVIDER_TOKEN_TTL_MS) return cachedToken.token;
  const privateKey = await jose.importPKCS8(atob(keyBase64), "ES256");
  const token = await new jose.SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: keyId })
    .setIssuer(teamId)
    .setIssuedAt()
    .sign(privateKey);
  cachedToken = { token, createdAt: Date.now() };
  return token;
}

function isInvalidDeviceToken(status: number, body: string) {
  return status === 410 || body.includes("BadDeviceToken") || body.includes("Unregistered") || body.includes("DeviceTokenNotForTopic");
}

export const deliver = internalAction({
  args: { eventId: v.id("alertEvents") },
  returns: v.null(),
  handler: async (ctx, { eventId }) => {
    const info = await ctx.runQuery(internal.alerts.getDeliveryInfo, { eventId });
    if (!info) return null;

    const keyBase64 = process.env.APNS_KEY_P8;
    const keyId = process.env.APNS_KEY_ID;
    const teamId = process.env.APNS_TEAM_ID;
    if (!keyBase64 || !keyId || !teamId) {
      await ctx.runMutation(internal.alerts.recordDelivery, {
        eventId,
        deliveredCount: 0,
        deliveryError: "Push not configured (set APNS_KEY_P8, APNS_KEY_ID, APNS_TEAM_ID)",
        invalidTokens: [],
      });
      return null;
    }
    if (info.devices.length === 0) {
      await ctx.runMutation(internal.alerts.recordDelivery, {
        eventId,
        deliveredCount: 0,
        deliveryError: "No devices registered",
        invalidTokens: [],
      });
      return null;
    }

    const bundleId = process.env.APNS_BUNDLE_ID ?? DEFAULT_BUNDLE_ID;
    const payload = JSON.stringify({
      aps: {
        alert: { title: info.event.title, body: info.event.body },
        sound: "default",
        "thread-id": info.event.deploymentName,
      },
      eventId,
      deploymentName: info.event.deploymentName,
      ...(info.event.path ? { path: info.event.path } : {}),
    });

    let jwt: string;
    try {
      jwt = await providerToken(keyBase64, keyId, teamId);
    } catch (error) {
      await ctx.runMutation(internal.alerts.recordDelivery, {
        eventId,
        deliveredCount: 0,
        deliveryError: `Invalid APNs key: ${error instanceof Error ? error.message : String(error)}`,
        invalidTokens: [],
      });
      return null;
    }

    const send = (host: string, token: string) =>
      fetch(`https://${host}/3/device/${token}`, {
        method: "POST",
        headers: {
          authorization: `bearer ${jwt}`,
          "apns-topic": bundleId,
          "apns-push-type": "alert",
          "apns-priority": "10",
        },
        body: payload,
      });

    let delivered = 0;
    const errors: string[] = [];
    const invalidTokens: string[] = [];

    for (const device of info.devices) {
      const host = device.sandbox ? "api.sandbox.push.apple.com" : "api.push.apple.com";
      try {
        const response = await send(host, device.token);
        if (response.ok) {
          delivered += 1;
          continue;
        }
        const body = await response.text();
        if (isInvalidDeviceToken(response.status, body)) {
          invalidTokens.push(device.token);
        } else {
          errors.push(`${response.status} ${body}`.slice(0, 200));
        }
      } catch (error) {
        errors.push(error instanceof Error ? error.message : String(error));
      }
    }

    await ctx.runMutation(internal.alerts.recordDelivery, {
      eventId,
      deliveredCount: delivered,
      deliveryError: errors.length > 0 ? errors.join("; ") : undefined,
      invalidTokens,
    });
    return null;
  },
});
