import { RoutingRecord } from "./types";

type CacheEntry = {
  record: RoutingRecord;
  expiresAtMs: number;
};

export class RoutingCache {
  private readonly records = new Map<string, CacheEntry>();

  public constructor(private readonly ttlMs: number) {}

  public get(aadObjectId: string): RoutingRecord | null {
    const entry = this.records.get(aadObjectId);
    if (!entry) {
      return null;
    }
    if (Date.now() >= entry.expiresAtMs) {
      this.records.delete(aadObjectId);
      return null;
    }
    return entry.record;
  }

  public set(record: RoutingRecord): void {
    this.records.set(record.aadObjectId, {
      record,
      expiresAtMs: Date.now() + this.ttlMs,
    });
  }
}
