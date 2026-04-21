import { TableClient, TableEntityResult } from "@azure/data-tables";
import { DefaultAzureCredential } from "@azure/identity";
import { InvocationContext } from "@azure/functions";

import {
  RoutingRecord,
  RoutingValidation,
  normalizeAadObjectId,
  validateRoutingRecord,
} from "./types";

type RoutingLookupResult = {
  record: RoutingRecord | null;
  validation: RoutingValidation | null;
};

type UpsertRoutingInput = {
  aadObjectId: string;
  userSlug: string;
  upstreamUrl: string;
  status: "active" | "provisioning" | "disabled";
  updatedAt?: string;
};

let tableClient: TableClient | null = null;

function getPartitionKey(normalizedAadObjectId: string): string {
  return normalizedAadObjectId.slice(0, 2);
}

function getTableClient(): TableClient {
  if (tableClient) {
    return tableClient;
  }

  const accountName = process.env.ROUTING_STORAGE_ACCOUNT_NAME ?? "";
  const tableName = process.env.ROUTING_TABLE_NAME ?? "userrouting";

  if (!accountName) {
    throw new Error("ROUTING_STORAGE_ACCOUNT_NAME is required");
  }

  const endpoint = `https://${accountName}.table.core.windows.net`;
  tableClient = new TableClient(endpoint, tableName, new DefaultAzureCredential());
  return tableClient;
}

export async function getRoutingByAadObjectId(
  aadObjectId: string,
  context: InvocationContext
): Promise<RoutingLookupResult> {
  const normalized = normalizeAadObjectId(aadObjectId);
  const partitionKey = getPartitionKey(normalized);

  try {
    const client = getTableClient();
    const entity = (await client.getEntity<Record<string, unknown>>(
      partitionKey,
      normalized
    )) as TableEntityResult<Record<string, unknown>>;

    const payload: Record<string, unknown> = {
      aad_object_id: entity.aad_object_id ?? entity.RowKey,
      user_slug: entity.user_slug,
      upstream_url: entity.upstream_url,
      status: entity.status,
      updated_at: entity.updated_at,
    };

    const validation = validateRoutingRecord(payload);
    if (!validation.valid) {
      return { record: null, validation };
    }

    return { record: validation.record, validation };
  } catch (error) {
    const maybeStatusCode =
      typeof error === "object" && error && "statusCode" in error
        ? (error as { statusCode?: number }).statusCode
        : undefined;

    if (maybeStatusCode === 404) {
      return { record: null, validation: null };
    }

    const message = error instanceof Error ? error.message : String(error);
    context.error(`Routing lookup failed for aadObjectId=${normalized}: ${message}`);
    throw error;
  }
}

export async function upsertRoutingRecord(
  input: UpsertRoutingInput,
  context: InvocationContext
): Promise<RoutingValidation> {
  const normalized = normalizeAadObjectId(input.aadObjectId);
  const payload: Record<string, unknown> = {
    aad_object_id: normalized,
    user_slug: input.userSlug,
    upstream_url: input.upstreamUrl,
    status: input.status,
    updated_at: input.updatedAt ?? new Date().toISOString(),
  };

  const validation = validateRoutingRecord(payload);
  if (!validation.valid) {
    return validation;
  }

  const partitionKey = getPartitionKey(validation.record.aadObjectId);
  try {
    const client = getTableClient();
    await client.upsertEntity(
      {
        partitionKey,
        rowKey: validation.record.aadObjectId,
        aad_object_id: validation.record.aadObjectId,
        user_slug: validation.record.userSlug,
        upstream_url: validation.record.upstreamUrl,
        status: validation.record.status,
        updated_at: validation.record.updatedAt,
      },
      "Replace"
    );
    return validation;
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    context.error(`Routing upsert failed for aadObjectId=${normalized}: ${message}`);
    throw error;
  }
}
