import { InvocationContext } from "@azure/functions";

import { PerUserCircuitBreaker } from "../resilience/circuit";
import { RoutingCache } from "./cache";
import { getRoutingByAadObjectId } from "./table-store";
import {
  CacheStatus,
  LookupResult,
  RoutingRecord,
  validateRoutingRecord,
  normalizeAadObjectId,
  isUuidV4ish,
} from "./types";

const CACHE_TTL_SEC_RAW = Number.parseInt(
  process.env.ROUTING_CACHE_TTL_SEC ?? "600",
  10
);
const ROUTING_CACHE_TTL_SEC =
  Number.isFinite(CACHE_TTL_SEC_RAW) && CACHE_TTL_SEC_RAW > 0
    ? CACHE_TTL_SEC_RAW
    : 600;

const FAILURE_THRESHOLD_RAW = Number.parseInt(
  process.env.ROUTING_FAILURE_THRESHOLD ?? "3",
  10
);
const ROUTING_FAILURE_THRESHOLD =
  Number.isFinite(FAILURE_THRESHOLD_RAW) && FAILURE_THRESHOLD_RAW > 0
    ? FAILURE_THRESHOLD_RAW
    : 3;

const CIRCUIT_OPEN_SEC_RAW = Number.parseInt(
  process.env.ROUTING_CIRCUIT_OPEN_SEC ?? "60",
  10
);
const ROUTING_CIRCUIT_OPEN_SEC =
  Number.isFinite(CIRCUIT_OPEN_SEC_RAW) && CIRCUIT_OPEN_SEC_RAW > 0
    ? CIRCUIT_OPEN_SEC_RAW
    : 60;

const routingCache = new RoutingCache(ROUTING_CACHE_TTL_SEC * 1000);
const circuitBreaker = new PerUserCircuitBreaker(
  ROUTING_FAILURE_THRESHOLD,
  ROUTING_CIRCUIT_OPEN_SEC * 1000
);

type OverridePayload = Record<string, Partial<RoutingRecord>>;

let routingOverrideMap: OverridePayload = {};
try {
  const raw = JSON.parse(process.env.ROUTING_OVERRIDE_JSON ?? "{}");
  if (raw && typeof raw === "object") {
    routingOverrideMap = raw as OverridePayload;
  }
} catch {
  routingOverrideMap = {};
}

export type RoutingResolution = {
  aadObjectId: string;
  cache: CacheStatus;
  lookupResult: LookupResult;
  routingValid: boolean;
  validationError: string | null;
  record: RoutingRecord | null;
};

export function normalizeAndValidateAadObjectId(aadObjectId: string): {
  normalized: string;
  valid: boolean;
} {
  const normalized = normalizeAadObjectId(aadObjectId);
  return {
    normalized,
    valid: isUuidV4ish(normalized),
  };
}

function resolveOverrideRecord(aadObjectId: string): RoutingRecord | null {
  const override = routingOverrideMap[aadObjectId];
  if (!override || typeof override !== "object") {
    return null;
  }

  const validation = validateRoutingRecord({
    aad_object_id: aadObjectId,
    user_slug: override.userSlug,
    upstream_url: override.upstreamUrl,
    status: override.status,
    updated_at: override.updatedAt ?? new Date().toISOString(),
  });

  if (!validation.valid) {
    return null;
  }

  return validation.record;
}

export async function resolveRouting(
  aadObjectId: string,
  context: InvocationContext
): Promise<RoutingResolution> {
  const { normalized, valid } = normalizeAndValidateAadObjectId(aadObjectId);
  if (!valid) {
    return {
      aadObjectId: normalized,
      cache: "miss",
      lookupResult: "invalid_aad_object_id",
      routingValid: false,
      validationError: "invalid_aad_object_id",
      record: null,
    };
  }

  const cached = routingCache.get(normalized);
  if (cached) {
    return {
      aadObjectId: normalized,
      cache: "hit",
      lookupResult: "found",
      routingValid: true,
      validationError: null,
      record: cached,
    };
  }

  const overrideRecord = resolveOverrideRecord(normalized);
  if (overrideRecord) {
    return {
      aadObjectId: normalized,
      cache: "hit",
      lookupResult: "found",
      routingValid: true,
      validationError: null,
      record: overrideRecord,
    };
  }

  try {
    const lookup = await getRoutingByAadObjectId(normalized, context);

    if (!lookup.record && !lookup.validation) {
      return {
        aadObjectId: normalized,
        cache: "miss",
        lookupResult: "not_found",
        routingValid: false,
        validationError: null,
        record: null,
      };
    }

    if (lookup.validation && !lookup.validation.valid) {
      return {
        aadObjectId: normalized,
        cache: "miss",
        lookupResult: "found",
        routingValid: false,
        validationError: lookup.validation.validationError,
        record: null,
      };
    }

    if (!lookup.record) {
      return {
        aadObjectId: normalized,
        cache: "miss",
        lookupResult: "store_error",
        routingValid: false,
        validationError: "missing_record",
        record: null,
      };
    }

    routingCache.set(lookup.record);
    return {
      aadObjectId: normalized,
      cache: "miss",
      lookupResult: "found",
      routingValid: true,
      validationError: null,
      record: lookup.record,
    };
  } catch {
    return {
      aadObjectId: normalized,
      cache: "miss",
      lookupResult: "store_error",
      routingValid: false,
      validationError: "store_error",
      record: null,
    };
  }
}

export function isUpstreamCircuitOpen(aadObjectId: string): boolean {
  return circuitBreaker.isOpen(normalizeAadObjectId(aadObjectId));
}

export function recordUpstreamFailure(aadObjectId: string): void {
  circuitBreaker.recordFailure(normalizeAadObjectId(aadObjectId));
}

export function recordUpstreamSuccess(aadObjectId: string): void {
  circuitBreaker.recordSuccess(normalizeAadObjectId(aadObjectId));
}

export function getUpstreamCircuitSnapshot(aadObjectId: string): {
  state: "open" | "closed";
  openUntil: string | null;
} {
  return circuitBreaker.getSnapshot(normalizeAadObjectId(aadObjectId));
}
