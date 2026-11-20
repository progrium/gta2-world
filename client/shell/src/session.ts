// The link is the session (design doc, shell UI). Until the lobby and server
// land (workstreams C and D), every page uses one fixed session id unless the
// URL names one: #s=<id>.

export const FIXED_SESSION_ID = "m1-local";

export function sessionIdFromUrl(href: string = location.href): string {
  try {
    const u = new URL(href);
    const fromHash = new URLSearchParams(u.hash.replace(/^#/, "")).get("s");
    const id = fromHash ?? u.searchParams.get("s");
    if (id && /^[A-Za-z0-9_-]{1,64}$/.test(id)) return id;
  } catch {
    /* fall through */
  }
  return FIXED_SESSION_ID;
}
