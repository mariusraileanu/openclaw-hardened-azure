export const ROUTING_STATUSES = ["active", "provisioning", "disabled"] as const;

export type RoutingStatus = (typeof ROUTING_STATUSES)[number];

export type LookupResult =
  | "found"
  | "not_found"
  | "invalid_aad_object_id"
  | "store_error";

export type CacheStatus = "hit" | "miss";

export type CircuitState = "open" | "closed";

export type RoutingRecord = {
  aadObjectId: string;
  userSlug: string;
  upstreamUrl: string;
  status: RoutingStatus;
  updatedAt: string;
};

export type RoutingValidation =
  | {
      valid: true;
      record: RoutingRecord;
    }
  | {
      valid: false;
      validationError: string;
      partialRecord: Partial<RoutingRecord>;
    };

export function normalizeAadObjectId(value: string): string {
  return value.trim().toLowerCase();
}

export function isUuidV4ish(value: string): boolean {
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i.test(
    value
  );
}

export function validateRoutingRecord(
  payload: Record<string, unknown>
): RoutingValidation {
  const aadObjectId = normalizeAadObjectId(String(payload.aad_object_id ?? ""));
  const userSlug = String(payload.user_slug ?? "").trim();
  const upstreamUrl = String(payload.upstream_url ?? "").trim();
  const status = String(payload.status ?? "").trim().toLowerCase();
  const updatedAt = String(payload.updated_at ?? "").trim();

  const partialRecord: Partial<RoutingRecord> = {
    aadObjectId,
    userSlug,
    upstreamUrl,
    status: ROUTING_STATUSES.includes(status as RoutingStatus)
      ? (status as RoutingStatus)
      : undefined,
    updatedAt,
  };

  if (!isUuidV4ish(aadObjectId)) {
    return {
      valid: false,
      validationError: "invalid_aad_object_id",
      partialRecord,
    };
  }

  if (!userSlug) {
    return {
      valid: false,
      validationError: "missing_user_slug",
      partialRecord,
    };
  }

  let url: URL;
  try {
    url = new URL(upstreamUrl);
  } catch {
    return {
      valid: false,
      validationError: "invalid_upstream_url",
      partialRecord,
    };
  }

  if (url.protocol !== "http:" && url.protocol !== "https:") {
    return {
      valid: false,
      validationError: "unsupported_upstream_protocol",
      partialRecord,
    };
  }

  if (!ROUTING_STATUSES.includes(status as RoutingStatus)) {
    return {
      valid: false,
      validationError: "invalid_status",
      partialRecord,
    };
  }

  if (!updatedAt) {
    return {
      valid: false,
      validationError: "missing_updated_at",
      partialRecord,
    };
  }

  return {
    valid: true,
    record: {
      aadObjectId,
      userSlug,
      upstreamUrl: url.origin + url.pathname.replace(/\/$/, ""),
      status: status as RoutingStatus,
      updatedAt,
    },
  };
}
