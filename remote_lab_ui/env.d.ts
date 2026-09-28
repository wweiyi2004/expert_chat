/// <reference types="@cloudflare/workers-types" />

declare namespace Cloudflare {
  interface Env {
    // Optional in the reference UI; getDb reports an absent binding explicitly.
    DB?: D1Database;
  }
}
