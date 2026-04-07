export type CircuitSnapshot = {
  state: "open" | "closed";
  openUntil: string | null;
};

type CircuitEntry = {
  failureCount: number;
  openUntilMs: number;
};

export class PerUserCircuitBreaker {
  private readonly entries = new Map<string, CircuitEntry>();

  public constructor(
    private readonly failureThreshold: number,
    private readonly openWindowMs: number
  ) {}

  public isOpen(key: string): boolean {
    const entry = this.entries.get(key);
    if (!entry) {
      return false;
    }
    if (entry.openUntilMs <= Date.now()) {
      this.entries.delete(key);
      return false;
    }
    return true;
  }

  public recordFailure(key: string): void {
    const current = this.entries.get(key) ?? { failureCount: 0, openUntilMs: 0 };
    const nextFailureCount = current.failureCount + 1;
    if (nextFailureCount >= this.failureThreshold) {
      this.entries.set(key, {
        failureCount: nextFailureCount,
        openUntilMs: Date.now() + this.openWindowMs,
      });
      return;
    }
    this.entries.set(key, {
      failureCount: nextFailureCount,
      openUntilMs: 0,
    });
  }

  public recordSuccess(key: string): void {
    this.entries.delete(key);
  }

  public getSnapshot(key: string): CircuitSnapshot {
    const entry = this.entries.get(key);
    if (!entry || entry.openUntilMs <= Date.now()) {
      if (entry && entry.openUntilMs <= Date.now()) {
        this.entries.delete(key);
      }
      return { state: "closed", openUntil: null };
    }
    return {
      state: "open",
      openUntil: new Date(entry.openUntilMs).toISOString(),
    };
  }
}
